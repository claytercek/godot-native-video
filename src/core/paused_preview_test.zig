//! Independent paused-preview contract tests: real controller and scheduler,
//! deterministic keyframe decoder at the public Backend boundary. No Godot/GPU.
const std = @import("std");
const core = @import("core");
const Backend = core.backend.Backend;
const Frame = core.backend.VideoFrame;
const Controller = core.playback_controller.PlaybackController;
const Scheduler = core.decode_scheduler.DecodeScheduler;
const WallClockMs = core.wall_clock.WallClockMs;
const alloc = std.testing.allocator;

const Decoder = struct {
    cursor: i32 = 0,
    live: std.atomic.Value(i32) = .init(0),
    audio_pulls: std.atomic.Value(u32) = .init(0),
    fail_seek: std.atomic.Value(bool) = .init(false),

    fn cast(p: *anyopaque) *Decoder {
        return @ptrCast(@alignCast(p));
    }
    fn open(_: *anyopaque, _: []const u8) bool {
        return true;
    }
    fn noop(_: *anyopaque) void {}
    fn duration(_: *anyopaque) f64 {
        return 4.0;
    }
    fn dimension(_: *anyopaque) i32 {
        return 16;
    }
    fn channels(_: *anyopaque) i32 {
        return 2;
    }
    fn rate(_: *anyopaque) i32 {
        return 48000;
    }
    fn color(_: *anyopaque) core.backend.Colorimetry {
        return .bt709_defaults;
    }
    fn trackCount(_: *anyopaque) i32 {
        return 1;
    }
    fn trackInfo(_: *anyopaque, index: i32) core.backend.AudioTrackInfo {
        return if (index == 0) .{ .channels = 2, .sample_rate = 48000, .is_default = true } else .{};
    }
    fn select(_: *anyopaque, _: i32) void {}
    fn reselect(_: *anyopaque, _: i32, _: f64) bool {
        return true;
    }
    fn seek(p: *anyopaque, pts: f64) bool {
        const self = cast(p);
        if (self.fail_seek.load(.acquire)) return false;
        self.cursor = @intFromFloat(@floor(@max(pts, 0.0)) * 30.0);
        return true;
    }
    fn release(p: ?*anyopaque) void {
        _ = cast(p.?).live.fetchSub(1, .monotonic);
    }
    fn video(p: *anyopaque) ?Frame {
        const self = cast(p);
        if (self.cursor >= 120) return null;
        const marker = self.cursor;
        self.cursor += 1;
        _ = self.live.fetchAdd(1, .monotonic);
        return .{
            .pts_seconds = @as(f64, @floatFromInt(marker)) / 30.0,
            .height = marker,
            .release_hook = .{ .ctx = self, .func = release },
        };
    }
    fn audio(p: *anyopaque) ?core.backend.AudioChunk {
        _ = cast(p).audio_pulls.fetchAdd(1, .monotonic);
        return null;
    }
    const vtable: Backend.VTable = .{
        .open = open,
        .close = noop,
        .deinit = noop,
        .duration_seconds = duration,
        .video_width = dimension,
        .video_height = dimension,
        .audio_channel_count = channels,
        .audio_sample_rate = rate,
        .colorimetry = color,
        .audio_track_count = trackCount,
        .audio_track_info = trackInfo,
        .select_audio_track = select,
        .reselect_audio_track = reselect,
        .seek = seek,
        .next_video_frame = video,
        .next_audio_chunk = audio,
    };
};

const Fixture = struct {
    decoder: Decoder = .{},
    controller: Controller = .init(),
    scheduler: *Scheduler = undefined,
    mix_calls: u32 = 0,

    // Initialize in place: the scheduler retains pointers into this fixture.
    fn init(self: *Fixture) !void {
        self.scheduler = try Scheduler.init(alloc, 1, true);
        errdefer self.scheduler.deinit();
        try self.controller.load(alloc, self.scheduler, .{ .ptr = &self.decoder, .vtable = &Decoder.vtable }, 0.0);
        self.controller.play(at(0));
        self.controller.setPaused(true);
    }
    fn deinit(self: *Fixture) void {
        self.controller.deinit();
        self.scheduler.deinit();
        std.testing.expectEqual(@as(i32, 0), self.decoder.live.load(.monotonic)) catch @panic("preview frame ownership leaked");
    }
    fn mix(p: *anyopaque, samples: []const f32, channel_count: i32) i32 {
        const self: *Fixture = @ptrCast(@alignCast(p));
        self.mix_calls += 1;
        return @intCast(samples.len / @as(usize, @intCast(channel_count)));
    }
    const sink_vtable: core.playback_controller.MixSink.VTable = .{ .mix = mix };
    fn sink(self: *Fixture) core.playback_controller.MixSink {
        return .{ .ptr = self, .vtable = &sink_vtable };
    }
};

fn at(ms: f64) WallClockMs {
    return .{ .ms = ms };
}

// ReleaseSafe uses a real worker even when force-synchronous was requested.
// Keep injected scrub time fixed while waiting for that worker, with a bounded
// real-time deadline. Polling this decoder is unrelated to agent-status polling.
fn expectPreview(f: *Fixture, now: f64, marker: i32) !void {
    const deadline = core.sys_clock.milliTimestamp() + 5000;
    while (true) {
        if (f.controller.pollPausedPreview(at(now))) |frame| {
            defer frame.release();
            try std.testing.expectEqual(marker, frame.height);
            try std.testing.expectApproxEqAbs(@as(f64, @floatFromInt(marker)) / 30.0, frame.pts_seconds, 1e-9);
            try std.testing.expectApproxEqAbs(frame.pts_seconds, f.controller.position, 1e-9);
            return;
        }
        if (!f.controller.needsPausedPreview()) return error.PreviewEndedWithoutFrame;
        if (core.sys_clock.milliTimestamp() >= deadline) return error.PreviewTimedOut;
        core.sys_clock.sleep(100 * std.time.ns_per_us);
    }
}

fn expectIdle(f: *Fixture, now: f64) !void {
    try std.testing.expect(!f.controller.needsPausedPreview());
    if (f.controller.pollPausedPreview(at(now))) |frame| {
        frame.release();
        return error.UnrequestedPreview;
    }
}

test "paused preview: lone exact seek transfers one target frame, then holds" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    try expectIdle(&f, 0);
    f.controller.seek(1.3, at(1000));
    try std.testing.expect(f.controller.needsPausedPreview());
    try expectPreview(&f, 1000, 39);
    try expectIdle(&f, 2000);
}

test "paused preview: superseding burst flushes old frames and settles exactly once" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    f.controller.seek(1.3, at(1000)); // Leave this exact preview unconsumed.
    f.controller.seek(2.7, at(1020));
    try expectPreview(&f, 1020, 60); // Current keyframe, never old frame 39.
    try std.testing.expect(f.controller.needsPausedPreview()); // Exact settle owed.
    f.controller.seek(0.8, at(1040));
    try expectPreview(&f, 1040, 0);
    try std.testing.expect(f.controller.pollPausedPreview(at(1139)) == null);
    try std.testing.expect(f.controller.needsPausedPreview());
    try expectPreview(&f, 1140, 24);
    try expectIdle(&f, 5000);
}

test "paused preview: polling and paused tick never mix audio or advance clock" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    f.controller.seek(1.3, at(1000));
    const clock_before = f.controller.mediaTime();
    const audio_before = f.decoder.audio_pulls.load(.monotonic);
    try expectPreview(&f, 1000, 39);
    for (0..10) |i| {
        try expectIdle(&f, 2000 + @as(f64, @floatFromInt(i)) * 1000);
        if (f.controller.tick(10.0, at(2000 + @as(f64, @floatFromInt(i)) * 1000), f.sink())) |frame| {
            frame.release();
            return error.UnrequestedTickPreview;
        }
    }
    try std.testing.expectApproxEqAbs(clock_before, f.controller.mediaTime(), 1e-9);
    try std.testing.expectEqual(audio_before, f.decoder.audio_pulls.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 0), f.mix_calls);
}

test "paused preview: failed exact seek cannot present an earlier queued frame" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    f.controller.seek(1.3, at(1000));
    f.decoder.fail_seek.store(true, .release);
    f.controller.seek(2.7, at(2000));
    try expectIdle(&f, 2100);
}

test "paused preview: seek beyond EOS clears pending without a stale frame" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    f.controller.seek(1.3, at(1000));
    f.controller.seek(8.0, at(2000));
    const deadline = core.sys_clock.milliTimestamp() + 5000;
    while (f.controller.needsPausedPreview()) {
        if (f.controller.pollPausedPreview(at(2100))) |frame| {
            frame.release();
            return error.StaleFrameAtEos;
        }
        if (core.sys_clock.milliTimestamp() >= deadline) return error.EosPreviewTimedOut;
        core.sys_clock.sleep(100 * std.time.ns_per_us);
    }
    try expectIdle(&f, 2200);
}

test "paused preview: stop, play, unpause and shutdown cancel outstanding burst" {
    const Cancel = enum { stop, play, unpause, shutdown };
    inline for (std.meta.tags(Cancel)) |cancel| {
        var f: Fixture = .{};
        try f.init();
        defer f.deinit();
        f.controller.seek(1.3, at(1000));
        f.controller.seek(2.7, at(1020));
        try std.testing.expect(f.controller.needsPausedPreview());
        switch (cancel) {
            .stop => f.controller.stop(),
            .play => f.controller.play(at(1030)),
            .unpause => f.controller.setPaused(false),
            .shutdown => f.controller.shutdown(),
        }
        try expectIdle(&f, 5000);
    }
}
