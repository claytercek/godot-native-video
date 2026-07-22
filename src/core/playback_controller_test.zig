//! PlaybackController tests. No Godot, no GPU. Each case constructs its own
//! DecodeScheduler and injects it at load(), requesting force-synchronous
//! mode so decode runs inline on the test thread where the build supports it
//! (release builds fall back to a single async worker; the cases hold in
//! both modes). The scrub-resolve cases that drive seek()/tick() against the
//! real scheduler live in scrubber_integration_test.zig.

const std = @import("std");

const backend_mod = @import("backend.zig");
const channel_mixer = @import("channel_mixer.zig");
const wall_clock_mod = @import("wall_clock.zig");
const pc = @import("playback_controller.zig");
const ds = @import("decode_scheduler.zig");
const ts = @import("test_support.zig");

const Backend = backend_mod.Backend;
const VideoFrame = backend_mod.VideoFrame;
const AudioChunk = backend_mod.AudioChunk;
const AudioTrackInfo = backend_mod.AudioTrackInfo;
const WallClockMs = wall_clock_mod.WallClockMs;
const PlaybackController = pc.PlaybackController;
const MixSink = pc.MixSink;
const DecodeScheduler = ds.DecodeScheduler;

const alloc = std.testing.allocator;

// Per-test decode pool: one worker, force-synchronous where available for
// deterministic inline decode.
fn makeSched() *DecodeScheduler {
    return DecodeScheduler.init(alloc, 1, true) catch @panic("sched init failed");
}

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
    seek_should_succeed: bool = true,
    samples: []f32 = &.{},
    select_calls: i32 = 0,
    reselect_calls: i32 = 0,

    fn create(allocator: std.mem.Allocator, tracks: []const TrackSpec, chunk_frames: i32) *MultiTrackFakeBackend {
        const self = allocator.create(MultiTrackFakeBackend) catch @panic("oom");
        const owned = allocator.dupe(TrackSpec, tracks) catch @panic("oom");
        self.* = .{ .allocator = allocator, .tracks = owned, .chunk_frames = chunk_frames };
        return self;
    }

    pub fn deinit(self: *MultiTrackFakeBackend) void {
        self.allocator.free(self.tracks);
        if (self.samples.len > 0) self.allocator.free(self.samples);
        self.allocator.destroy(self);
    }
    pub fn audioChannelCount(self: *MultiTrackFakeBackend) i32 {
        return if (self.tracks.len == 0) 0 else self.tracks[0].channels;
    }
    pub fn audioSampleRate(self: *MultiTrackFakeBackend) i32 {
        return if (self.tracks.len == 0) 0 else self.tracks[0].sample_rate;
    }
    pub fn audioTrackCount(self: *MultiTrackFakeBackend) i32 {
        return @intCast(self.tracks.len);
    }
    pub fn audioTrackInfo(self: *MultiTrackFakeBackend, index: i32) AudioTrackInfo {
        var info: AudioTrackInfo = .{};
        if (index >= 0 and @as(usize, @intCast(index)) < self.tracks.len) {
            info.channels = self.tracks[@intCast(index)].channels;
            info.sample_rate = self.tracks[@intCast(index)].sample_rate;
            info.is_default = index == 0;
        }
        return info;
    }
    pub fn selectAudioTrack(self: *MultiTrackFakeBackend, index: i32) void {
        self.live_track = index;
        self.select_calls += 1;
    }
    pub fn reselectAudioTrack(self: *MultiTrackFakeBackend, index: i32, _: f64) bool {
        self.reselect_calls += 1;
        if (!self.reselect_should_succeed) return false;
        self.live_track = index;
        return true;
    }
    pub fn seek(self: *MultiTrackFakeBackend, pts_seconds: f64) bool {
        if (!self.seek_should_succeed) return false;
        var idx: i32 = @intFromFloat(pts_seconds * 30.0);
        if (idx < 0) idx = 0;
        self.next_index = idx;
        return true;
    }
    pub fn nextVideoFrame(self: *MultiTrackFakeBackend) ?VideoFrame {
        if (self.next_index >= 300) return null;
        const f: VideoFrame = .{ .pts_seconds = @as(f64, @floatFromInt(self.next_index)) / 30.0 };
        self.next_index += 1;
        return f;
    }
    pub fn nextAudioChunk(self: *MultiTrackFakeBackend) ?AudioChunk {
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

    fn backend(self: *MultiTrackFakeBackend) Backend {
        return ts.backend(self);
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

    pub fn deinit(self: *ShortAudioBackend) void {
        if (self.samples.len > 0) self.allocator.free(self.samples);
        self.allocator.destroy(self);
    }
    pub fn audioChannelCount(_: *ShortAudioBackend) i32 {
        return 2;
    }
    pub fn audioSampleRate(_: *ShortAudioBackend) i32 {
        return 48000;
    }
    pub fn seek(self: *ShortAudioBackend, pts_seconds: f64) bool {
        var idx: i32 = @intFromFloat(pts_seconds * 30.0);
        if (idx < 0) idx = 0;
        self.next_index = idx;
        return true;
    }
    pub fn nextVideoFrame(self: *ShortAudioBackend) ?VideoFrame {
        if (self.next_index >= 300) return null;
        const f: VideoFrame = .{ .pts_seconds = @as(f64, @floatFromInt(self.next_index)) / 30.0 };
        self.next_index += 1;
        return f;
    }
    pub fn nextAudioChunk(self: *ShortAudioBackend) ?AudioChunk {
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

    fn backend(self: *ShortAudioBackend) Backend {
        return ts.backend(self);
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
    const sched = makeSched();
    defer sched.deinit();
    var controller = PlaybackController.init();
    defer controller.deinit();
    try controller.load(alloc, sched, MultiTrackFakeBackend.create(alloc, &.{
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
    const sched = makeSched();
    defer sched.deinit();
    var controller = PlaybackController.init();
    defer controller.deinit();
    try controller.load(alloc, sched, MultiTrackFakeBackend.create(alloc, &.{}, 4096).backend(), 0.0);

    try std.testing.expect(controller.loaded);
    try std.testing.expectEqual(0, controller.canonical_channels);
    try std.testing.expectEqual(0, controller.canonical_sample_rate);
    var w = controller.takeWarnings();
    defer w.deinit(alloc);
    try std.testing.expect(w.items.len == 0);

    controller.shutdown();
}

test "an out-of-range pre-load track selection is validated and reset once load() runs" {
    const sched = makeSched();
    defer sched.deinit();
    var controller = PlaybackController.init();
    defer controller.deinit();
    // Pre-load selection: no stream yet, so this just records desired_track.
    controller.requestAudioTrack(2);
    {
        var w = controller.takeWarnings();
        defer w.deinit(alloc);
        try std.testing.expect(w.items.len == 0); // no validation possible yet
    }

    try controller.load(alloc, sched, MultiTrackFakeBackend.create(alloc, &.{.{ .channels = 2, .sample_rate = 48000 }}, 4096).backend(), 0.0);

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
    const sched = makeSched();
    defer sched.deinit();
    var controller = PlaybackController.init();
    defer controller.deinit();
    try controller.load(alloc, sched, makeStereoBackend(), 0.0);
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
    const sched = makeSched();
    defer sched.deinit();
    var controller = PlaybackController.init();
    defer controller.deinit();
    const be = MultiTrackFakeBackend.create(alloc, &.{ .{ .channels = 2, .sample_rate = 48000 }, .{ .channels = 2, .sample_rate = 48000 } }, 4096);
    be.reselect_should_succeed = false;
    try controller.load(alloc, sched, be.backend(), 0.0);
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

test "an unresolved exact seek does not re-anchor the playback clock" {
    const sched = makeSched();
    defer sched.deinit();
    var controller = PlaybackController.init();
    defer controller.deinit();
    const fake = MultiTrackFakeBackend.create(alloc, &.{.{ .channels = 2, .sample_rate = 48000 }}, 4096);
    try controller.load(alloc, sched, fake.backend(), 0.0);

    fake.seek_should_succeed = false;
    controller.play(WallClockMs.init(0.0));

    try std.testing.expectApproxEqAbs(0.0, controller.mediaTime(), 1e-9);
    try std.testing.expectApproxEqAbs(0.0, controller.position, 1e-9);
    var warnings = controller.takeWarnings();
    defer {
        for (warnings.items) |s| alloc.free(s);
        warnings.deinit(alloc);
    }
    try std.testing.expectEqual(1, warnings.items.len);
    try expectContains(warnings.items[0], "backend_seek_failed");

    controller.shutdown();
}

test "stop() resets transport state and tick() is a no-op before load()" {
    const sched = makeSched();
    defer sched.deinit();
    var controller = PlaybackController.init();
    defer controller.deinit();
    var sink = CappedMixSink{ .accept_cap = 4096 };
    try std.testing.expect(controller.tick(1.0 / 60.0, WallClockMs.init(0.0), sink.sink()) == null);

    try controller.load(alloc, sched, makeStereoBackend(), 0.0);
    controller.play(WallClockMs.init(0.0));
    try std.testing.expect(controller.playing);

    controller.stop();
    try std.testing.expect(!controller.playing);
    try std.testing.expectApproxEqAbs(0.0, controller.position, 1e-9);

    controller.shutdown();
}

test "6-channel back-pressure never races the source reader ahead (bounded backlog)" {
    // Regression for the cross-platform "audio too fast + choppy" bug on
    // multi-channel clips. A back-pressured sink accepts far fewer frames than
    // driveAudio() offers (Godot's downstream buffer holds ~1/channels as many
    // frames as we push). The old code drained the whole offered block from the
    // ring but advanced only by `accepted`, discarding the surplus; fillAudio()
    // then refilled the over-drained ring, pulling the reader ~channels× real
    // time. The fix consumes only the accepted frames, so the reader is pulled
    // at playback rate and the decoded-vs-served backlog stays within one ring.
    const sched = makeSched();
    defer sched.deinit();
    var controller = PlaybackController.init();
    defer controller.deinit();
    try controller.load(alloc, sched, MultiTrackFakeBackend.create(
        alloc,
        &.{.{ .channels = 6, .sample_rate = 48000 }},
        1024, // 1024-frame chunks, as real AAC delivers
    ).backend(), 0.0);
    controller.play(WallClockMs.init(0.0));

    var sink = CappedMixSink{ .accept_cap = 170 }; // ~1024/6: heavy back-pressure

    var t: f64 = 0.0;
    var i: usize = 0;
    while (i < 300) : (i += 1) {
        t += 16.6;
        _ = controller.tick(1.0 / 60.0, WallClockMs.init(t), sink.sink());
    }

    // Every decoded frame is either served to the sink or still buffered in the
    // ring, so the backlog can never exceed one ring's worth. Under the old
    // drop-the-surplus code this gap grew without bound (the reader raced ~6×
    // ahead), reaching hundreds of thousands of frames over 300 ticks.
    const decoded = controller.audio_telemetry.decoded_frames_in;
    const served = controller.audio_telemetry.frames_served;
    const ring_capacity: u64 = 48000 / 2;
    try std.testing.expect(decoded - served <= ring_capacity + 1024);

    controller.shutdown();
}

// =======================================================================
// Track switch reconcile
// =======================================================================

test "request_audio_track while stopped applies immediately via select_audio_track (cheap apply)" {
    const sched = makeSched();
    defer sched.deinit();
    var controller = PlaybackController.init();
    defer controller.deinit();
    const be = MultiTrackFakeBackend.create(alloc, &.{ .{ .channels = 2, .sample_rate = 48000 }, .{ .channels = 2, .sample_rate = 48000 } }, 4096);
    try controller.load(alloc, sched, be.backend(), 0.0);
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
    const sched = makeSched();
    defer sched.deinit();
    var controller = PlaybackController.init();
    defer controller.deinit();
    const be = MultiTrackFakeBackend.create(alloc, &.{ .{ .channels = 2, .sample_rate = 48000 }, .{ .channels = 2, .sample_rate = 48000 } }, 4096);
    try controller.load(alloc, sched, be.backend(), 0.0);
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
    const sched = makeSched();
    defer sched.deinit();
    var controller = PlaybackController.init();
    defer controller.deinit();
    const be = MultiTrackFakeBackend.create(alloc, &.{ .{ .channels = 2, .sample_rate = 48000 }, .{ .channels = 2, .sample_rate = 48000 } }, 4096);
    try controller.load(alloc, sched, be.backend(), 0.0);
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
    const sched = makeSched();
    defer sched.deinit();
    var controller = PlaybackController.init();
    defer controller.deinit();
    try controller.load(alloc, sched, makeStereoBackend(), 0.0);
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
    const sched = makeSched();
    defer sched.deinit();
    var controller = PlaybackController.init();
    defer controller.deinit();
    try controller.load(alloc, sched, MultiTrackFakeBackend.create(alloc, &.{}, 4096).backend(), 0.0);
    controller.play(WallClockMs.init(0.0));

    var sink = CappedMixSink{ .accept_cap = 4096 }; // never invoked: no audio track

    _ = controller.tick(0.1, WallClockMs.init(100.0), sink.sink());
    try std.testing.expectApproxEqAbs(0.1, controller.mediaTime(), 1e-9);
    _ = controller.tick(0.1, WallClockMs.init(200.0), sink.sink());
    try std.testing.expectApproxEqAbs(0.2, controller.mediaTime(), 1e-9); // linear, not doubled

    controller.shutdown();
}

test "one-clock rule: audio exhaustion falls back to the render delta exactly once per tick" {
    const sched = makeSched();
    defer sched.deinit();
    var controller = PlaybackController.init();
    defer controller.deinit();
    try controller.load(alloc, sched, ShortAudioBackend.create(alloc, 100).backend(), 0.0);
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
    const sched = makeSched();
    defer sched.deinit();
    var controller = PlaybackController.init();
    defer controller.deinit();
    try controller.load(alloc, sched, ShortAudioBackend.create(alloc, 100).backend(), 0.0);
    controller.play(WallClockMs.init(0.0));
    var sink = AcceptAllMixSink{};

    // A huge render delta: if the transition tick stacked it on top of the 100
    // real frames, media_time would be off by ~1s rather than ~2ms.
    _ = controller.tick(1.0, WallClockMs.init(16.6), sink.sink());

    try std.testing.expectApproxEqRel(@as(f64, 100.0) / 48000.0, controller.mediaTime(), 0.01);

    controller.shutdown();
}

test "one-clock rule: a partial drain that leaves audio remaining does NOT trigger the delta fallback" {
    const sched = makeSched();
    defer sched.deinit();
    var controller = PlaybackController.init();
    defer controller.deinit();
    try controller.load(alloc, sched, ShortAudioBackend.create(alloc, 1000).backend(), 0.0);
    controller.play(WallClockMs.init(0.0));
    // Accept far fewer than the 1000-frame chunk so the ring is NOT empty after.
    var sink = CappedMixSink{ .accept_cap = 100 };

    _ = controller.tick(1.0, WallClockMs.init(16.6), sink.sink());

    // Accepted 100 real frames, ring still has 900 — not exhausted, so no delta.
    try std.testing.expectApproxEqRel(@as(f64, 100.0) / 48000.0, controller.mediaTime(), 0.01);

    controller.shutdown();
}

test "accepted-vs-real: silence offered during underrun is never counted as real audio" {
    const sched = makeSched();
    defer sched.deinit();
    var controller = PlaybackController.init();
    defer controller.deinit();
    try controller.load(alloc, sched, ShortAudioBackend.create(alloc, 100).backend(), 0.0);
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

test "load() clamps a track's channel count to kMaxMixSourceChannels" {
    const sched = makeSched();
    defer sched.deinit();
    var controller = PlaybackController.init();
    defer controller.deinit();
    try controller.load(alloc, sched, MultiTrackFakeBackend.create(alloc, &.{.{ .channels = 8, .sample_rate = 48000 }}, 4096).backend(), 0.0);

    try std.testing.expectEqual(channel_mixer.max_mix_source_channels, controller.canonical_channels);

    controller.shutdown();
}

test "a mid-stream switch to a differing sample-rate track is refused while playing" {
    const sched = makeSched();
    defer sched.deinit();
    var controller = PlaybackController.init();
    defer controller.deinit();
    try controller.load(alloc, sched, MultiTrackFakeBackend.create(alloc, &.{ .{ .channels = 2, .sample_rate = 48000 }, .{ .channels = 2, .sample_rate = 44100 } }, 4096).backend(), 0.0);
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

test "canonical channel count stays at the cross-track max regardless of the selected track" {
    // A stereo commentary track plus a 5.1 main track: the Canonical Mix
    // Format is fixed at load() to the max across tracks (6ch), so switching
    // between the tracks must never change it — the channel mixer converts
    // whichever native format the live track emits.
    const sched = makeSched();
    defer sched.deinit();
    var controller = PlaybackController.init();
    defer controller.deinit();
    try controller.load(alloc, sched, MultiTrackFakeBackend.create(alloc, &.{
        .{ .channels = 2, .sample_rate = 48000 }, // stereo commentary (default)
        .{ .channels = 6, .sample_rate = 48000 }, // 5.1 main
    }, 4096).backend(), 0.0);

    try std.testing.expectEqual(6, controller.canonical_channels);
    try std.testing.expectEqual(48000, controller.canonical_sample_rate);

    controller.requestAudioTrack(1); // stopped: applies immediately
    try std.testing.expectEqual(1, controller.live_track);
    try std.testing.expectEqual(6, controller.canonical_channels); // unchanged

    controller.requestAudioTrack(0);
    try std.testing.expectEqual(0, controller.live_track);
    try std.testing.expectEqual(6, controller.canonical_channels); // unchanged

    controller.shutdown();
}

test "a switch to a differing sample-rate track is allowed while stopped" {
    const sched = makeSched();
    defer sched.deinit();
    var controller = PlaybackController.init();
    defer controller.deinit();
    try controller.load(alloc, sched, MultiTrackFakeBackend.create(alloc, &.{ .{ .channels = 2, .sample_rate = 48000 }, .{ .channels = 2, .sample_rate = 44100 } }, 4096).backend(), 0.0);
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
