//! playback_controller_test.zig — port of tests/core/test_playback_controller.cpp.
//!
//! No Godot, no GPU. The controller registers with the process-wide
//! DecodeScheduler.instance() singleton (async worker pool), same as the
//! Binding does, so the deterministic (scheduler-timing-independent) branches
//! are what these cases pin. The scrub-resolve cases drive the real scheduler
//! seam through seek()/tick().

const std = @import("std");

const backend_mod = @import("backend.zig");
const channel_mixer = @import("channel_mixer.zig");
const canonical_mix_format = @import("canonical_mix_format.zig");
const wall_clock_mod = @import("wall_clock.zig");
const pc = @import("playback_controller.zig");
const sys_clock = @import("sys_clock.zig");

const Backend = backend_mod.Backend;
const VideoFrame = backend_mod.VideoFrame;
const AudioChunk = backend_mod.AudioChunk;
const AudioTrackInfo = backend_mod.AudioTrackInfo;
const WallClockMs = wall_clock_mod.WallClockMs;
const PlaybackController = pc.PlaybackController;
const MixSink = pc.MixSink;

const alloc = std.testing.allocator;

// Free every warning string and the list (transfers back ownership).
fn drainWarnings(controller: *PlaybackController) void {
    var w = controller.takeWarnings();
    for (w.items) |s| alloc.free(s);
    w.deinit(alloc);
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) != null);
}

// -----------------------------------------------------------------------
// MultiTrackFakeBackend — a deterministic decoder mock with a configurable set
// of audio tracks and an effectively unbounded audio-chunk supply, so
// fillAudio()'s half-fill loop can run to completion without hitting EOS
// mid-test.
// -----------------------------------------------------------------------
const TrackSpec = struct { channels: i32, sample_rate: i32 };

const MultiTrackFakeBackend = struct {
    allocator: std.mem.Allocator,
    tracks: []TrackSpec,
    chunk_frames: i32,
    next_index: i32 = 0,
    live_track: i32 = 0,
    reselect_should_succeed: bool = true,
    samples: []f32 = &.{},
    select_calls: i32 = 0,
    reselect_calls: i32 = 0,

    fn create(allocator: std.mem.Allocator, tracks: []const TrackSpec, chunk_frames: i32) *MultiTrackFakeBackend {
        const self = allocator.create(MultiTrackFakeBackend) catch @panic("oom");
        const owned = allocator.dupe(TrackSpec, tracks) catch @panic("oom");
        self.* = .{ .allocator = allocator, .tracks = owned, .chunk_frames = chunk_frames };
        return self;
    }

    fn openFn(_: *anyopaque, _: []const u8) bool {
        return true;
    }
    fn closeFn(_: *anyopaque) void {}
    fn deinitFn(p: *anyopaque) void {
        const self: *MultiTrackFakeBackend = @ptrCast(@alignCast(p));
        self.allocator.free(self.tracks);
        if (self.samples.len > 0) self.allocator.free(self.samples);
        self.allocator.destroy(self);
    }
    fn durFn(_: *anyopaque) f64 {
        return 10.0;
    }
    fn wFn(_: *anyopaque) i32 {
        return 640;
    }
    fn hFn(_: *anyopaque) i32 {
        return 360;
    }
    fn chFn(p: *anyopaque) i32 {
        const self: *MultiTrackFakeBackend = @ptrCast(@alignCast(p));
        return if (self.tracks.len == 0) 0 else self.tracks[0].channels;
    }
    fn rateFn(p: *anyopaque) i32 {
        const self: *MultiTrackFakeBackend = @ptrCast(@alignCast(p));
        return if (self.tracks.len == 0) 0 else self.tracks[0].sample_rate;
    }
    fn trackCountFn(p: *anyopaque) i32 {
        const self: *MultiTrackFakeBackend = @ptrCast(@alignCast(p));
        return @intCast(self.tracks.len);
    }
    fn trackInfoFn(p: *anyopaque, index: i32) AudioTrackInfo {
        const self: *MultiTrackFakeBackend = @ptrCast(@alignCast(p));
        var info: AudioTrackInfo = .{};
        if (index >= 0 and @as(usize, @intCast(index)) < self.tracks.len) {
            info.channels = self.tracks[@intCast(index)].channels;
            info.sample_rate = self.tracks[@intCast(index)].sample_rate;
            info.is_default = index == 0;
        }
        return info;
    }
    fn selectTrackFn(p: *anyopaque, index: i32) void {
        const self: *MultiTrackFakeBackend = @ptrCast(@alignCast(p));
        self.live_track = index;
        self.select_calls += 1;
    }
    fn reselectTrackFn(p: *anyopaque, index: i32, _: f64) bool {
        const self: *MultiTrackFakeBackend = @ptrCast(@alignCast(p));
        self.reselect_calls += 1;
        if (!self.reselect_should_succeed) return false;
        self.live_track = index;
        return true;
    }
    fn seekFn(p: *anyopaque, pts_seconds: f64) bool {
        const self: *MultiTrackFakeBackend = @ptrCast(@alignCast(p));
        var idx: i32 = @intFromFloat(pts_seconds * 30.0);
        if (idx < 0) idx = 0;
        self.next_index = idx;
        return true;
    }
    fn nextVideoFrameFn(p: *anyopaque) ?VideoFrame {
        const self: *MultiTrackFakeBackend = @ptrCast(@alignCast(p));
        if (self.next_index >= 300) return null;
        const f: VideoFrame = .{ .pts_seconds = @as(f64, @floatFromInt(self.next_index)) / 30.0 };
        self.next_index += 1;
        return f;
    }
    fn nextAudioChunkFn(p: *anyopaque) ?AudioChunk {
        const self: *MultiTrackFakeBackend = @ptrCast(@alignCast(p));
        if (self.tracks.len == 0 or self.live_track < 0 or
            @as(usize, @intCast(self.live_track)) >= self.tracks.len) return null;
        const t = self.tracks[@intCast(self.live_track)];
        const n: usize = @as(usize, @intCast(self.chunk_frames)) * @as(usize, @intCast(t.channels));
        if (self.samples.len < n) {
            if (self.samples.len > 0) self.allocator.free(self.samples);
            self.samples = self.allocator.alloc(f32, n) catch @panic("oom");
        }
        @memset(self.samples[0..n], 0.25);
        return .{
            .samples = self.samples[0..n],
            .frame_count = self.chunk_frames,
            .channel_count = t.channels,
            .sample_rate = t.sample_rate,
        };
    }

    const vtable: Backend.VTable = .{
        .open = openFn,
        .close = closeFn,
        .deinit = deinitFn,
        .duration_seconds = durFn,
        .video_width = wFn,
        .video_height = hFn,
        .audio_channel_count = chFn,
        .audio_sample_rate = rateFn,
        .seek = seekFn,
        .next_video_frame = nextVideoFrameFn,
        .next_audio_chunk = nextAudioChunkFn,
        .audio_track_count = trackCountFn,
        .audio_track_info = trackInfoFn,
        .select_audio_track = selectTrackFn,
        .reselect_audio_track = reselectTrackFn,
    };

    fn backend(self: *MultiTrackFakeBackend) Backend {
        return .{ .ptr = self, .vtable = &vtable };
    }
};

fn makeStereoBackend() Backend {
    return MultiTrackFakeBackend.create(alloc, &.{.{ .channels = 2, .sample_rate = 48000 }}, 4096).backend();
}

// -----------------------------------------------------------------------
// ShortAudioBackend — one audio track that yields exactly ONE real chunk of
// `total_frames` frames, then permanent EOS.
// -----------------------------------------------------------------------
const ShortAudioBackend = struct {
    allocator: std.mem.Allocator,
    total_frames: i32,
    next_index: i32 = 0,
    delivered: bool = false,
    samples: []f32 = &.{},

    fn create(allocator: std.mem.Allocator, total_frames: i32) *ShortAudioBackend {
        const self = allocator.create(ShortAudioBackend) catch @panic("oom");
        self.* = .{ .allocator = allocator, .total_frames = total_frames };
        return self;
    }

    fn openFn(_: *anyopaque, _: []const u8) bool {
        return true;
    }
    fn closeFn(_: *anyopaque) void {}
    fn deinitFn(p: *anyopaque) void {
        const self: *ShortAudioBackend = @ptrCast(@alignCast(p));
        if (self.samples.len > 0) self.allocator.free(self.samples);
        self.allocator.destroy(self);
    }
    fn durFn(_: *anyopaque) f64 {
        return 10.0;
    }
    fn wFn(_: *anyopaque) i32 {
        return 640;
    }
    fn hFn(_: *anyopaque) i32 {
        return 360;
    }
    fn chFn(_: *anyopaque) i32 {
        return 2;
    }
    fn rateFn(_: *anyopaque) i32 {
        return 48000;
    }
    fn seekFn(p: *anyopaque, pts_seconds: f64) bool {
        const self: *ShortAudioBackend = @ptrCast(@alignCast(p));
        var idx: i32 = @intFromFloat(pts_seconds * 30.0);
        if (idx < 0) idx = 0;
        self.next_index = idx;
        return true;
    }
    fn nextVideoFrameFn(p: *anyopaque) ?VideoFrame {
        const self: *ShortAudioBackend = @ptrCast(@alignCast(p));
        if (self.next_index >= 300) return null;
        const f: VideoFrame = .{ .pts_seconds = @as(f64, @floatFromInt(self.next_index)) / 30.0 };
        self.next_index += 1;
        return f;
    }
    fn nextAudioChunkFn(p: *anyopaque) ?AudioChunk {
        const self: *ShortAudioBackend = @ptrCast(@alignCast(p));
        if (self.delivered) return null; // permanent EOS after the one real chunk
        self.delivered = true;
        const n: usize = @as(usize, @intCast(self.total_frames)) * 2;
        if (self.samples.len < n) {
            if (self.samples.len > 0) self.allocator.free(self.samples);
            self.samples = self.allocator.alloc(f32, n) catch @panic("oom");
        }
        @memset(self.samples[0..n], 0.5);
        return .{
            .samples = self.samples[0..n],
            .frame_count = self.total_frames,
            .channel_count = 2,
            .sample_rate = 48000,
        };
    }

    const vtable: Backend.VTable = .{
        .open = openFn,
        .close = closeFn,
        .deinit = deinitFn,
        .duration_seconds = durFn,
        .video_width = wFn,
        .video_height = hFn,
        .audio_channel_count = chFn,
        .audio_sample_rate = rateFn,
        .seek = seekFn,
        .next_video_frame = nextVideoFrameFn,
        .next_audio_chunk = nextAudioChunkFn,
    };

    fn backend(self: *ShortAudioBackend) Backend {
        return .{ .ptr = self, .vtable = &vtable };
    }
};

// -----------------------------------------------------------------------
// Scrub-resolve fixtures.
// -----------------------------------------------------------------------
const kScrubFps: i32 = 30;
const kScrubGopFrames: i32 = 30; // 1s GOP
const kScrubTotalFrames: i32 = 1200; // 40s clip

fn scrubFrameOfPts(pts: f64) i32 {
    return @intFromFloat(@round(pts * @as(f64, @floatFromInt(kScrubFps))));
}
fn scrubKeyframeAtOrBefore(frame: i32) i32 {
    return @divTrunc(frame, kScrubGopFrames) * kScrubGopFrames;
}

// A release closure that bumps a drop counter (models a released surface).
fn dropRelease(p: ?*anyopaque) void {
    const counter: *std.atomic.Value(i32) = @ptrCast(@alignCast(p.?));
    _ = counter.fetchAdd(1, .monotonic);
}

const ScrubGridBackend = struct {
    allocator: std.mem.Allocator,
    drop_counter: *std.atomic.Value(i32),
    next_index: i32 = 0,

    fn create(allocator: std.mem.Allocator, drop_counter: *std.atomic.Value(i32)) *ScrubGridBackend {
        const self = allocator.create(ScrubGridBackend) catch @panic("oom");
        self.* = .{ .allocator = allocator, .drop_counter = drop_counter };
        return self;
    }

    fn openFn(_: *anyopaque, _: []const u8) bool {
        return true;
    }
    fn closeFn(_: *anyopaque) void {}
    fn deinitFn(p: *anyopaque) void {
        const self: *ScrubGridBackend = @ptrCast(@alignCast(p));
        self.allocator.destroy(self);
    }
    fn durFn(_: *anyopaque) f64 {
        return @as(f64, @floatFromInt(kScrubTotalFrames)) / @as(f64, @floatFromInt(kScrubFps));
    }
    fn wFn(_: *anyopaque) i32 {
        return 0;
    }
    fn hFn(_: *anyopaque) i32 {
        return 1;
    }
    fn zeroFn(_: *anyopaque) i32 {
        return 0;
    }
    fn seekFn(p: *anyopaque, pts_seconds: f64) bool {
        const self: *ScrubGridBackend = @ptrCast(@alignCast(p));
        const target = scrubFrameOfPts(pts_seconds);
        self.next_index = scrubKeyframeAtOrBefore(target);
        return true;
    }
    fn nextVideoFrameFn(p: *anyopaque) ?VideoFrame {
        const self: *ScrubGridBackend = @ptrCast(@alignCast(p));
        if (self.next_index >= kScrubTotalFrames) return null;
        const idx = self.next_index;
        self.next_index += 1;
        return .{
            .pts_seconds = @as(f64, @floatFromInt(idx)) / @as(f64, @floatFromInt(kScrubFps)),
            .release_ctx = self.drop_counter,
            .release_fn = dropRelease,
        };
    }
    fn nextAudioChunkFn(_: *anyopaque) ?AudioChunk {
        return null;
    }

    const vtable: Backend.VTable = .{
        .open = openFn,
        .close = closeFn,
        .deinit = deinitFn,
        .duration_seconds = durFn,
        .video_width = wFn,
        .video_height = hFn,
        .audio_channel_count = zeroFn,
        .audio_sample_rate = zeroFn,
        .seek = seekFn,
        .next_video_frame = nextVideoFrameFn,
        .next_audio_chunk = nextAudioChunkFn,
    };

    fn backend(self: *ScrubGridBackend) Backend {
        return .{ .ptr = self, .vtable = &vtable };
    }
};

// -----------------------------------------------------------------------
// ExactPtsBackend — an explicit, hand-picked PTS sequence, used only to probe
// applyScrubResolve()'s epsilon boundary. The sequence only "arms" once seek()
// is called, so the initial register_stream decode-ahead does not race to
// consume these hand-picked frames first.
// -----------------------------------------------------------------------
const ExactPtsBackend = struct {
    allocator: std.mem.Allocator,
    pts_sequence: []f64,
    drop_counter: *std.atomic.Value(i32),
    idx: usize = 0,
    armed: bool = false,

    fn create(allocator: std.mem.Allocator, pts_sequence: []const f64, drop_counter: *std.atomic.Value(i32)) *ExactPtsBackend {
        const self = allocator.create(ExactPtsBackend) catch @panic("oom");
        const owned = allocator.dupe(f64, pts_sequence) catch @panic("oom");
        self.* = .{ .allocator = allocator, .pts_sequence = owned, .drop_counter = drop_counter };
        return self;
    }

    fn openFn(_: *anyopaque, _: []const u8) bool {
        return true;
    }
    fn closeFn(_: *anyopaque) void {}
    fn deinitFn(p: *anyopaque) void {
        const self: *ExactPtsBackend = @ptrCast(@alignCast(p));
        self.allocator.free(self.pts_sequence);
        self.allocator.destroy(self);
    }
    fn durFn(_: *anyopaque) f64 {
        return 100.0;
    }
    fn wFn(_: *anyopaque) i32 {
        return 0;
    }
    fn hFn(_: *anyopaque) i32 {
        return 1;
    }
    fn zeroFn(_: *anyopaque) i32 {
        return 0;
    }
    fn seekFn(p: *anyopaque, _: f64) bool {
        const self: *ExactPtsBackend = @ptrCast(@alignCast(p));
        self.armed = true;
        self.idx = 0;
        return true;
    }
    fn nextVideoFrameFn(p: *anyopaque) ?VideoFrame {
        const self: *ExactPtsBackend = @ptrCast(@alignCast(p));
        if (!self.armed or self.idx >= self.pts_sequence.len) return null;
        const pts = self.pts_sequence[self.idx];
        self.idx += 1;
        return .{
            .pts_seconds = pts,
            .release_ctx = self.drop_counter,
            .release_fn = dropRelease,
        };
    }
    fn nextAudioChunkFn(_: *anyopaque) ?AudioChunk {
        return null;
    }

    const vtable: Backend.VTable = .{
        .open = openFn,
        .close = closeFn,
        .deinit = deinitFn,
        .duration_seconds = durFn,
        .video_width = wFn,
        .video_height = hFn,
        .audio_channel_count = zeroFn,
        .audio_sample_rate = zeroFn,
        .seek = seekFn,
        .next_video_frame = nextVideoFrameFn,
        .next_audio_chunk = nextAudioChunkFn,
    };

    fn backend(self: *ExactPtsBackend) Backend {
        return .{ .ptr = self, .vtable = &vtable };
    }
};

// -----------------------------------------------------------------------
// MixSink test doubles.
// -----------------------------------------------------------------------
const CappedMixSink = struct {
    accept_cap: i32,
    last_offered: i32 = 0,

    fn mixImpl(p: *anyopaque, interleaved: []const f32, channel_count: i32) i32 {
        const self: *CappedMixSink = @ptrCast(@alignCast(p));
        const frame_count: i32 = @intCast(interleaved.len / @as(usize, @intCast(channel_count)));
        self.last_offered = frame_count;
        return @min(frame_count, self.accept_cap);
    }

    const vtable: MixSink.VTable = .{ .mix = mixImpl };

    fn sink(self: *CappedMixSink) MixSink {
        return .{ .ptr = self, .vtable = &vtable };
    }
};

const AcceptAllMixSink = struct {
    fn mixImpl(_: *anyopaque, interleaved: []const f32, channel_count: i32) i32 {
        return @intCast(interleaved.len / @as(usize, @intCast(channel_count)));
    }
    const vtable: MixSink.VTable = .{ .mix = mixImpl };
    fn sink(self: *AcceptAllMixSink) MixSink {
        return .{ .ptr = self, .vtable = &vtable };
    }
};

// =======================================================================
// WallClockMs
// =======================================================================

test "WallClockMs holds its value and supports comparison/arithmetic via .ms" {
    const a = WallClockMs.init(100.0);
    const b = WallClockMs.init(30.0);
    try std.testing.expectEqual(100.0, a.ms);
    try std.testing.expectEqual(30.0, b.ms);
    try std.testing.expectApproxEqAbs(70.0, a.ms - b.ms, 1e-9);
    try std.testing.expectEqual(0.0, (WallClockMs{}).ms);
}

// =======================================================================
// load() / canonical mix format
// =======================================================================

test "load() derives the Canonical Mix Format and warns once on a mixed sample rate" {
    var controller = PlaybackController.init();
    defer controller.deinit();
    try controller.load(alloc, MultiTrackFakeBackend.create(alloc, &.{
        .{ .channels = 1, .sample_rate = 44100 }, // track 0: default -> canonical rate
        .{ .channels = 2, .sample_rate = 48000 }, // track 1: differing rate -> one warning
        .{ .channels = 6, .sample_rate = 44100 }, // track 2: matches canonical rate -> no warning
    }, 4096).backend(), 0.0);

    try std.testing.expect(controller.loaded);
    try std.testing.expectEqual(6, controller.canonical_channels); // max across tracks
    try std.testing.expectEqual(44100, controller.canonical_sample_rate); // first audio-bearing

    var warnings = controller.takeWarnings();
    defer {
        for (warnings.items) |s| alloc.free(s);
        warnings.deinit(alloc);
    }
    try std.testing.expectEqual(1, warnings.items.len);
    try expectContains(warnings.items[0], "differs from the canonical rate");

    controller.shutdown();
}

test "a silent clip (no audio tracks) reports zero channels and no warnings" {
    var controller = PlaybackController.init();
    defer controller.deinit();
    try controller.load(alloc, MultiTrackFakeBackend.create(alloc, &.{}, 4096).backend(), 0.0);

    try std.testing.expect(controller.loaded);
    try std.testing.expectEqual(0, controller.canonical_channels);
    try std.testing.expectEqual(0, controller.canonical_sample_rate);
    var w = controller.takeWarnings();
    defer w.deinit(alloc);
    try std.testing.expect(w.items.len == 0);

    controller.shutdown();
}

test "an out-of-range pre-load track selection is validated and reset once load() runs" {
    var controller = PlaybackController.init();
    defer controller.deinit();
    // Pre-load selection: no stream yet, so this just records desired_track_.
    controller.requestAudioTrack(2);
    {
        var w = controller.takeWarnings();
        defer w.deinit(alloc);
        try std.testing.expect(w.items.len == 0); // no validation possible yet
    }

    try controller.load(alloc, MultiTrackFakeBackend.create(alloc, &.{.{ .channels = 2, .sample_rate = 48000 }}, 4096).backend(), 0.0);

    try std.testing.expectEqual(0, controller.desired_track); // out of range -> fell back to 0
    var warnings = controller.takeWarnings();
    defer {
        for (warnings.items) |s| alloc.free(s);
        warnings.deinit(alloc);
    }
    try std.testing.expectEqual(1, warnings.items.len);
    try expectContains(warnings.items[0], "out of range");

    controller.shutdown();
}

test "drive_audio advances the clock by only the accepted-and-real frame count" {
    var controller = PlaybackController.init();
    defer controller.deinit();
    try controller.load(alloc, makeStereoBackend(), 0.0);
    controller.play(WallClockMs.init(0.0));

    // The sink accepts far fewer frames than fillAudio() will have topped the
    // ring up with, so the clock must advance by exactly the accepted count.
    var sink = CappedMixSink{ .accept_cap = 100 };
    const frame = controller.tick(1.0 / 60.0, WallClockMs.init(16.6), sink.sink());
    _ = frame; // no video frames are queued in this test; present is a Hold

    try std.testing.expect(sink.last_offered > 100); // proves back-pressure was exercised
    try std.testing.expectApproxEqRel(@as(f64, 100.0) / 48000.0, controller.mediaTime(), 0.01);

    controller.shutdown();
}

test "a mid-stream reselect the backend refuses rolls the desired track back" {
    var controller = PlaybackController.init();
    defer controller.deinit();
    const be = MultiTrackFakeBackend.create(alloc, &.{ .{ .channels = 2, .sample_rate = 48000 }, .{ .channels = 2, .sample_rate = 48000 } }, 4096);
    be.reselect_should_succeed = false;
    try controller.load(alloc, be.backend(), 0.0);
    controller.play(WallClockMs.init(0.0));

    controller.requestAudioTrack(1); // deferred: applied on the next tick()
    try std.testing.expectEqual(1, controller.desired_track);

    var sink = CappedMixSink{ .accept_cap = 4096 };
    _ = controller.tick(1.0 / 60.0, WallClockMs.init(16.6), sink.sink());

    try std.testing.expectEqual(0, controller.desired_track); // rolled back
    try std.testing.expectEqual(0, controller.live_track);
    var warnings = controller.takeWarnings();
    defer {
        for (warnings.items) |s| alloc.free(s);
        warnings.deinit(alloc);
    }
    try std.testing.expectEqual(1, warnings.items.len);
    try expectContains(warnings.items[0], "failed; recovering via seek");

    controller.shutdown();
}

test "stop() resets transport state and tick() is a no-op before load()" {
    var controller = PlaybackController.init();
    defer controller.deinit();
    var sink = CappedMixSink{ .accept_cap = 4096 };
    try std.testing.expect(controller.tick(1.0 / 60.0, WallClockMs.init(0.0), sink.sink()) == null);

    try controller.load(alloc, makeStereoBackend(), 0.0);
    controller.play(WallClockMs.init(0.0));
    try std.testing.expect(controller.playing);

    controller.stop();
    try std.testing.expect(!controller.playing);
    try std.testing.expectApproxEqAbs(0.0, controller.position, 1e-9);

    controller.shutdown();
}

// =======================================================================
// Track switch reconcile
// =======================================================================

test "request_audio_track while stopped applies immediately via select_audio_track (cheap apply)" {
    var controller = PlaybackController.init();
    defer controller.deinit();
    const be = MultiTrackFakeBackend.create(alloc, &.{ .{ .channels = 2, .sample_rate = 48000 }, .{ .channels = 2, .sample_rate = 48000 } }, 4096);
    try controller.load(alloc, be.backend(), 0.0);
    try std.testing.expect(!controller.playing);

    controller.requestAudioTrack(1);

    try std.testing.expectEqual(1, controller.desired_track);
    try std.testing.expectEqual(1, controller.live_track); // applied immediately
    try std.testing.expectEqual(1, be.select_calls);
    try std.testing.expectEqual(0, be.reselect_calls); // cheap path never touches reselect
    var w = controller.takeWarnings();
    defer w.deinit(alloc);
    try std.testing.expect(w.items.len == 0);

    controller.shutdown();
}

test "a live reselect success converges desired/live, and a converged reconcile is a no-op" {
    var controller = PlaybackController.init();
    defer controller.deinit();
    const be = MultiTrackFakeBackend.create(alloc, &.{ .{ .channels = 2, .sample_rate = 48000 }, .{ .channels = 2, .sample_rate = 48000 } }, 4096);
    try controller.load(alloc, be.backend(), 0.0);
    controller.play(WallClockMs.init(0.0));

    controller.requestAudioTrack(1); // deferred: applied on the next tick()
    try std.testing.expectEqual(1, controller.desired_track);
    try std.testing.expectEqual(0, controller.live_track); // not yet reconciled

    var sink = CappedMixSink{ .accept_cap = 4096 };
    _ = controller.tick(1.0 / 60.0, WallClockMs.init(16.6), sink.sink()); // reconciles: reselect succeeds

    try std.testing.expectEqual(1, controller.desired_track);
    try std.testing.expectEqual(1, controller.live_track);
    try std.testing.expectEqual(1, be.reselect_calls);
    var w = controller.takeWarnings();
    defer w.deinit(alloc);
    try std.testing.expect(w.items.len == 0);

    // Further ticks: desired == live now, so reconcile's own no-op guard must
    // stop it from reselecting again every tick.
    _ = controller.tick(1.0 / 60.0, WallClockMs.init(33.2), sink.sink());
    _ = controller.tick(1.0 / 60.0, WallClockMs.init(49.8), sink.sink());
    try std.testing.expectEqual(1, be.reselect_calls); // unchanged

    controller.shutdown();
}

test "requesting the already-desired track is a no-op and never touches the backend" {
    var controller = PlaybackController.init();
    defer controller.deinit();
    const be = MultiTrackFakeBackend.create(alloc, &.{ .{ .channels = 2, .sample_rate = 48000 }, .{ .channels = 2, .sample_rate = 48000 } }, 4096);
    try controller.load(alloc, be.backend(), 0.0);
    try std.testing.expectEqual(0, be.select_calls); // load() had no pending switch to apply

    controller.requestAudioTrack(0); // already desired -> short-circuits

    try std.testing.expectEqual(0, be.select_calls);
    try std.testing.expectEqual(0, be.reselect_calls);
    var w = controller.takeWarnings();
    defer w.deinit(alloc);
    try std.testing.expect(w.items.len == 0);

    controller.shutdown();
}

// =======================================================================
// One-clock rule
// =======================================================================

test "one-clock rule: audio-master tick() never adds the render delta on top of accepted audio frames" {
    var controller = PlaybackController.init();
    defer controller.deinit();
    try controller.load(alloc, makeStereoBackend(), 0.0);
    controller.play(WallClockMs.init(0.0));

    var sink = CappedMixSink{ .accept_cap = 480 }; // 480 frames @ 48kHz = 10ms of real audio
    // A deliberately huge render delta: if the clock ever added this on top of
    // the accepted-frame accounting, media_time would be off by orders of
    // magnitude (~1s instead of ~10ms).
    _ = controller.tick(1.0, WallClockMs.init(16.6), sink.sink());

    try std.testing.expectApproxEqRel(@as(f64, 480.0) / 48000.0, controller.mediaTime(), 0.01);

    controller.shutdown();
}

test "one-clock rule: a silent clip advances the clock by exactly the render delta, once per tick" {
    var controller = PlaybackController.init();
    defer controller.deinit();
    try controller.load(alloc, MultiTrackFakeBackend.create(alloc, &.{}, 4096).backend(), 0.0);
    controller.play(WallClockMs.init(0.0));

    var sink = CappedMixSink{ .accept_cap = 4096 }; // never invoked: no audio track

    _ = controller.tick(0.1, WallClockMs.init(100.0), sink.sink());
    try std.testing.expectApproxEqAbs(0.1, controller.mediaTime(), 1e-9);
    _ = controller.tick(0.1, WallClockMs.init(200.0), sink.sink());
    try std.testing.expectApproxEqAbs(0.2, controller.mediaTime(), 1e-9); // linear, not doubled

    controller.shutdown();
}

test "one-clock rule: audio exhaustion falls back to the render delta exactly once per tick" {
    var controller = PlaybackController.init();
    defer controller.deinit();
    try controller.load(alloc, ShortAudioBackend.create(alloc, 100).backend(), 0.0);
    controller.play(WallClockMs.init(0.0));
    var sink = AcceptAllMixSink{};

    // Tick 1: the ring's one real chunk (100 frames) drains in full — the clock
    // advances from real audio accounting only.
    _ = controller.tick(1.0 / 60.0, WallClockMs.init(16.6), sink.sink());
    try std.testing.expectApproxEqRel(@as(f64, 100.0) / 48000.0, controller.mediaTime(), 0.01);

    // Ticks 2-4: the ring is now empty and EOS'd (audio_exhausted()), so each
    // tick must fall back to exactly one render-delta advance.
    _ = controller.tick(0.1, WallClockMs.init(33.2), sink.sink());
    _ = controller.tick(0.1, WallClockMs.init(50.0), sink.sink());
    _ = controller.tick(0.1, WallClockMs.init(66.6), sink.sink());

    try std.testing.expectApproxEqRel(@as(f64, 100.0) / 48000.0 + 0.3, controller.mediaTime(), 0.01);

    controller.shutdown();
}

test "one-clock rule: the transition tick (drained AND exhausted) advances by real frames only, not real+delta" {
    var controller = PlaybackController.init();
    defer controller.deinit();
    try controller.load(alloc, ShortAudioBackend.create(alloc, 100).backend(), 0.0);
    controller.play(WallClockMs.init(0.0));
    var sink = AcceptAllMixSink{};

    // A huge render delta: if the transition tick stacked it on top of the 100
    // real frames, media_time would be off by ~1s rather than ~2ms.
    _ = controller.tick(1.0, WallClockMs.init(16.6), sink.sink());

    try std.testing.expectApproxEqRel(@as(f64, 100.0) / 48000.0, controller.mediaTime(), 0.01);

    controller.shutdown();
}

test "one-clock rule: a partial drain that leaves audio remaining does NOT trigger the delta fallback" {
    var controller = PlaybackController.init();
    defer controller.deinit();
    try controller.load(alloc, ShortAudioBackend.create(alloc, 1000).backend(), 0.0);
    controller.play(WallClockMs.init(0.0));
    // Accept far fewer than the 1000-frame chunk so the ring is NOT empty after.
    var sink = CappedMixSink{ .accept_cap = 100 };

    _ = controller.tick(1.0, WallClockMs.init(16.6), sink.sink());

    // Accepted 100 real frames, ring still has 900 — not exhausted, so no delta.
    try std.testing.expectApproxEqRel(@as(f64, 100.0) / 48000.0, controller.mediaTime(), 0.01);

    controller.shutdown();
}

test "accepted-vs-real: silence offered during underrun is never counted as real audio" {
    var controller = PlaybackController.init();
    defer controller.deinit();
    try controller.load(alloc, ShortAudioBackend.create(alloc, 100).backend(), 0.0);
    controller.play(WallClockMs.init(0.0));
    var sink = AcceptAllMixSink{}; // accepts every frame offered, including silence

    _ = controller.tick(1.0 / 60.0, WallClockMs.init(16.6), sink.sink()); // drains the one real 100-frame chunk
    const after_real = controller.mediaTime();

    // The ring is now empty and EOS'd: driveAudio() offers 256 silent frames and
    // this sink accepts all 256, but real_frames == 0 — the clock must advance by
    // the render-delta fallback only, NOT by an extra 256/48000s of "accepted"
    // silence stacked on top of it.
    _ = controller.tick(0.1, WallClockMs.init(33.2), sink.sink());

    try std.testing.expectApproxEqRel(after_real + 0.1, controller.mediaTime(), 0.01);

    controller.shutdown();
}

// =======================================================================
// derive_canonical_mix_format — the pure, scheduler-free half of load()
// =======================================================================

test "derive_canonical_mix_format: max channel count across tracks; first audio-bearing rate wins" {
    const be = MultiTrackFakeBackend.create(alloc, &.{
        .{ .channels = 1, .sample_rate = 44100 },
        .{ .channels = 2, .sample_rate = 48000 },
        .{ .channels = 6, .sample_rate = 44100 },
    }, 4096);
    defer be.backend().deinit();

    var fmt = try canonical_mix_format.deriveCanonicalMixFormat(alloc, be.backend());
    defer fmt.deinit(alloc);

    try std.testing.expect(fmt.has_audio);
    try std.testing.expectEqual(6, fmt.channels); // max across tracks
    try std.testing.expectEqual(44100, fmt.sample_rate); // first audio-bearing track
    try std.testing.expectEqual(3, fmt.track_infos.items.len);
    try std.testing.expectEqual(44100, fmt.track_infos.items[2].sample_rate);
}

test "derive_canonical_mix_format: mixed sample rate warns exactly once, later matching tracks silent" {
    const be = MultiTrackFakeBackend.create(alloc, &.{
        .{ .channels = 1, .sample_rate = 44100 }, .{ .channels = 2, .sample_rate = 48000 },
        .{ .channels = 6, .sample_rate = 44100 }, .{ .channels = 2, .sample_rate = 48000 },
    }, 4096);
    defer be.backend().deinit();

    var fmt = try canonical_mix_format.deriveCanonicalMixFormat(alloc, be.backend());
    defer fmt.deinit(alloc);

    try std.testing.expectEqual(1, fmt.warnings.items.len);
    try expectContains(fmt.warnings.items[0], "differs from the canonical rate");
}

test "derive_canonical_mix_format: a silent clip (no tracks) yields no audio and no warnings" {
    const be = MultiTrackFakeBackend.create(alloc, &.{}, 4096);
    defer be.backend().deinit();

    var fmt = try canonical_mix_format.deriveCanonicalMixFormat(alloc, be.backend());
    defer fmt.deinit(alloc);

    try std.testing.expect(!fmt.has_audio);
    try std.testing.expectEqual(0, fmt.channels);
    try std.testing.expectEqual(0, fmt.sample_rate);
    try std.testing.expect(fmt.warnings.items.len == 0);
}

test "derive_canonical_mix_format: channel count clamped to kMaxMixSourceChannels" {
    const be = MultiTrackFakeBackend.create(alloc, &.{.{ .channels = 8, .sample_rate = 48000 }}, 4096);
    defer be.backend().deinit();

    var fmt = try canonical_mix_format.deriveCanonicalMixFormat(alloc, be.backend());
    defer fmt.deinit(alloc);

    try std.testing.expectEqual(channel_mixer.max_mix_source_channels, fmt.channels);
}

test "derive_canonical_mix_format: track metadata without sample-rate audio is still collected" {
    const be = MultiTrackFakeBackend.create(alloc, &.{.{ .channels = 2, .sample_rate = 0 }}, 4096);
    defer be.backend().deinit();

    var fmt = try canonical_mix_format.deriveCanonicalMixFormat(alloc, be.backend());
    defer fmt.deinit(alloc);

    try std.testing.expect(!fmt.has_audio);
    try std.testing.expectEqual(0, fmt.sample_rate);
    try std.testing.expectEqual(2, fmt.channels); // channel count is still tracked
    try std.testing.expectEqual(1, fmt.track_infos.items.len);
}

test "load() clamps a track's channel count to kMaxMixSourceChannels" {
    var controller = PlaybackController.init();
    defer controller.deinit();
    try controller.load(alloc, MultiTrackFakeBackend.create(alloc, &.{.{ .channels = 8, .sample_rate = 48000 }}, 4096).backend(), 0.0);

    try std.testing.expectEqual(channel_mixer.max_mix_source_channels, controller.canonical_channels);

    controller.shutdown();
}

test "a mid-stream switch to a differing sample-rate track is refused while playing" {
    var controller = PlaybackController.init();
    defer controller.deinit();
    try controller.load(alloc, MultiTrackFakeBackend.create(alloc, &.{ .{ .channels = 2, .sample_rate = 48000 }, .{ .channels = 2, .sample_rate = 44100 } }, 4096).backend(), 0.0);
    drainWarnings(&controller); // drain load()'s own mixed-sample-rate warning
    controller.play(WallClockMs.init(0.0));

    controller.requestAudioTrack(1); // differing rate while playing -> refused

    try std.testing.expectEqual(0, controller.desired_track); // unchanged
    var warnings = controller.takeWarnings();
    defer {
        for (warnings.items) |s| alloc.free(s);
        warnings.deinit(alloc);
    }
    try std.testing.expectEqual(1, warnings.items.len);
    try expectContains(warnings.items[0], "Rejecting switch");

    controller.shutdown();
}

test "a switch to a differing sample-rate track is allowed while stopped" {
    var controller = PlaybackController.init();
    defer controller.deinit();
    try controller.load(alloc, MultiTrackFakeBackend.create(alloc, &.{ .{ .channels = 2, .sample_rate = 48000 }, .{ .channels = 2, .sample_rate = 44100 } }, 4096).backend(), 0.0);
    drainWarnings(&controller); // drain load()'s own mixed-sample-rate warning
    try std.testing.expect(!controller.playing);

    controller.requestAudioTrack(1); // stopped: no live audio path to disturb

    try std.testing.expectEqual(1, controller.desired_track);
    try std.testing.expectEqual(1, controller.live_track);
    var w = controller.takeWarnings();
    defer w.deinit(alloc);
    try std.testing.expect(w.items.len == 0);

    controller.shutdown();
}

// =======================================================================
// Scrub resolve
// =======================================================================

test "seek(): a fast burst resolves Keyframe with no forward-decode drops; a lone seek resolves Exact" {
    // Target deliberately near the END of a GOP so an Exact resolve must decode
    // nearly a full GOP forward, while a Keyframe resolve stops dead at the
    // keyframe.
    const target = @as(f64, @floatFromInt(kScrubGopFrames - 1)) / @as(f64, @floatFromInt(kScrubFps)) + 20.0;

    // --- Exact: a lone seek (no prior scrub history) always resolves Exact. ---
    var exact_drops = std.atomic.Value(i32).init(0);
    {
        var controller = PlaybackController.init();
        defer controller.deinit();
        try controller.load(alloc, ScrubGridBackend.create(alloc, &exact_drops).backend(), 0.0);
        controller.seek(target, WallClockMs.init(0.0));
        controller.shutdown();
    }
    try std.testing.expect(exact_drops.load(.monotonic) >= @divTrunc(kScrubGopFrames, 2)); // decoded across most of a GOP

    // --- Keyframe: priming, then a fast in-burst follow-up seek. ---
    var kf_drops = std.atomic.Value(i32).init(0);
    {
        var controller = PlaybackController.init();
        defer controller.deinit();
        try controller.load(alloc, ScrubGridBackend.create(alloc, &kf_drops).backend(), 0.0);
        controller.seek(1.0, WallClockMs.init(0.0)); // prime (Exact, trivial forward decode)
        kf_drops.store(0, .monotonic); // isolate the SECOND (Keyframe) resolve only
        controller.seek(target, WallClockMs.init(20.0)); // 20ms later, huge jump -> fast drag -> Keyframe
        // Check BEFORE shutdown: request_seek() flushes the queue; the count here
        // is purely the flush (shutdown adds worker-pushed post-seek frames).
        try std.testing.expect(kf_drops.load(.monotonic) <= @as(i32, @intCast(decode_scheduler_kDecodeAheadCapacity)));
        controller.shutdown();
    }
}

const decode_scheduler_kDecodeAheadCapacity = @import("decode_scheduler.zig").kDecodeAheadCapacity;

test "the exact-resolve spin treats a frame within epsilon of the target as arrived" {
    const kSpinEps = 1.0 / 120.0; // mirrors applyScrubResolve()'s tolerance
    const target = 10.0;

    // A frame within epsilon of the target is NOT dropped — the spin stops
    // immediately and leaves it for the present step.
    var drops_in_tolerance = std.atomic.Value(i32).init(0);
    {
        var controller = PlaybackController.init();
        defer controller.deinit();
        try controller.load(alloc, ExactPtsBackend.create(alloc, &.{target - kSpinEps * 0.5}, &drops_in_tolerance).backend(), 0.0);
        controller.seek(target, WallClockMs.init(0.0));
        // Check before shutdown(): unregister releases the in-tolerance survivor,
        // which would otherwise inflate this count by one.
        try std.testing.expectEqual(0, drops_in_tolerance.load(.monotonic));
        controller.shutdown();
    }

    // A frame outside epsilon IS dropped; the spin then stops at the next frame,
    // which is within tolerance.
    var drops_out_of_tolerance = std.atomic.Value(i32).init(0);
    {
        var controller = PlaybackController.init();
        defer controller.deinit();
        try controller.load(alloc, ExactPtsBackend.create(alloc, &.{ target - kSpinEps * 2.0, target - kSpinEps * 0.5 }, &drops_out_of_tolerance).backend(), 0.0);
        controller.seek(target, WallClockMs.init(0.0));
        try std.testing.expectEqual(1, drops_out_of_tolerance.load(.monotonic));
        controller.shutdown();
    }
}

test "seek() past end-of-stream terminates the exact-resolve spin instead of hanging (bounded spin)" {
    var drops = std.atomic.Value(i32).init(0);
    var controller = PlaybackController.init();
    defer controller.deinit();
    try controller.load(alloc, ScrubGridBackend.create(alloc, &drops).backend(), 0.0);

    // Lone seek -> Exact. Target far beyond the clip's duration, so the backend
    // reports EOS immediately after the reseek and the forward-decode spin must
    // give up via atEnd() rather than hang.
    const start = sys_clock.milliTimestamp();
    controller.seek(@as(f64, @floatFromInt(kScrubTotalFrames)) / @as(f64, @floatFromInt(kScrubFps)) + 1000.0, WallClockMs.init(0.0));
    const elapsed = sys_clock.milliTimestamp() - start;

    try std.testing.expect(elapsed < 5_000); // bounded, not hung

    controller.shutdown();
}

test "the exact-resolve spin backoff is bounded far below the old kMaxSpins=100000" {
    // Regression guard for the busy-wait replacement: the spin's total iteration
    // ceiling (yield + sleep phases) must be far smaller than the old
    // 100000-yield hot-loop.
    try std.testing.expect(pc.kScrubMaxYieldSpins + pc.kScrubMaxSleepSpins < 10000);
    try std.testing.expect(pc.kScrubMaxYieldSpins > 0);
    try std.testing.expect(pc.kScrubMaxSleepSpins > 0);
    try std.testing.expect(pc.kScrubSpinSleepMs > 0.0);
}

test "after a drag burst settles, the next tick presents the exact settled target frame" {
    var drops = std.atomic.Value(i32).init(0);
    var controller = PlaybackController.init();
    defer controller.deinit();
    try controller.load(alloc, ScrubGridBackend.create(alloc, &drops).backend(), 0.0);
    controller.play(WallClockMs.init(0.0));

    // Frame-aligned targets sidestep the present-selector's own half-frame
    // tolerance landing on a coin-flip between two adjacent frames.
    const last_target = 400.0 / @as(f64, @floatFromInt(kScrubFps));
    controller.seek(100.0 / @as(f64, @floatFromInt(kScrubFps)), WallClockMs.init(1000.0)); // prime -> Exact
    controller.seek(300.0 / @as(f64, @floatFromInt(kScrubFps)), WallClockMs.init(1020.0)); // fast -> Keyframe
    controller.seek(last_target, WallClockMs.init(1040.0)); // fast -> Keyframe (approximate frame on screen)

    var sink = CappedMixSink{ .accept_cap = 0 }; // never invoked: no audio
    // 150ms later (past the 100ms settle debounce): the pending settle fires
    // inside this tick() and resolves Exact to the last drag target. delta_seconds
    // is tiny so tick()'s post-settle clock advance does not push `now` into the
    // present selector's half-frame tolerance of the NEXT frame.
    const frame = controller.tick(0.001, WallClockMs.init(1190.0), sink.sink());

    try std.testing.expect(frame != null);
    try std.testing.expectApproxEqAbs(last_target, frame.?.pts_seconds, 1e-9);
    if (frame) |f| f.release();

    controller.shutdown();
}
