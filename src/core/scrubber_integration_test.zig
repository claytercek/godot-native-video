//! scrubber_integration_test.zig — the two DecodeScheduler-dependent cases from
//! tests/core/test_scrubber.cpp (the pure Scrubber state-machine cases already
//! live in scrubber.zig).
//!
//! Integration with the decode scheduler — proves the Scrubber's decisions,
//! when mapped onto real seeks, give (a) low keyframe-scrub latency during a
//! drag and (b) the EXACT target frame once the scrub settles. Runs the
//! scheduler in force-synchronous mode so decode happens inline on this thread:
//! request_seek's flush + reseek and the decode-forward are fully deterministic
//! with no worker race.

const std = @import("std");

const backend_mod = @import("backend.zig");
const scrubber_mod = @import("scrubber.zig");
const ds = @import("decode_scheduler.zig");
const sys_clock = @import("sys_clock.zig");
const ts = @import("test_support.zig");

const Backend = backend_mod.Backend;
const VideoFrame = backend_mod.VideoFrame;
const Scrubber = scrubber_mod.Scrubber;
const ScrubResolve = scrubber_mod.ScrubResolve;
const ResolveMode = scrubber_mod.ResolveMode;
const DecodeScheduler = ds.DecodeScheduler;
const StreamHandle = ds.StreamHandle;
const Surface = ts.Surface;

const alloc = std.testing.allocator;

// Keyframe grid: a keyframe every kGopFrames frames. A Keyframe resolve snaps to
// the keyframe at/before the target; an Exact resolve seeks that keyframe then
// decodes FORWARD to the target frame (more frames decoded = higher latency, but
// lands on the precise frame).
const kFps: i32 = 30;
const kGopFrames: i32 = 30; // 1s GOP
const kTotalFrames: i32 = 1200; // 40s clip

fn frameOfPts(pts: f64) i32 {
    return @intFromFloat(@round(pts * @as(f64, @floatFromInt(kFps))));
}
fn keyframeAtOrBefore(frame: i32) i32 {
    return @divTrunc(frame, kGopFrames) * kGopFrames;
}

// A backend whose seek() snaps to the preceding keyframe. Each decoded frame
// carries its frame index in `height` so a test can assert which frame a resolve
// lands on and measure the consumer-side cost of reaching it.
const KeyframeBackend = struct {
    allocator: std.mem.Allocator,
    live: *std.atomic.Value(i32),
    next_index: i32 = 0,
    surfaces: std.ArrayList(*Surface) = .empty,

    fn create(allocator: std.mem.Allocator, live: *std.atomic.Value(i32)) *KeyframeBackend {
        const self = allocator.create(KeyframeBackend) catch @panic("oom");
        self.* = .{ .allocator = allocator, .live = live };
        return self;
    }

    pub fn deinit(self: *KeyframeBackend) void {
        for (self.surfaces.items) |s| self.allocator.destroy(s);
        self.surfaces.deinit(self.allocator);
        self.allocator.destroy(self);
    }
    pub fn durationSeconds(_: *KeyframeBackend) f64 {
        return @as(f64, @floatFromInt(kTotalFrames)) / @as(f64, @floatFromInt(kFps));
    }
    pub fn videoWidth(_: *KeyframeBackend) i32 {
        return 0;
    }
    pub fn videoHeight(_: *KeyframeBackend) i32 {
        return 1;
    }
    pub fn seek(self: *KeyframeBackend, pts_seconds: f64) bool {
        const target = frameOfPts(pts_seconds);
        self.next_index = keyframeAtOrBefore(target);
        return true;
    }
    pub fn nextVideoFrame(self: *KeyframeBackend) ?VideoFrame {
        if (self.next_index >= kTotalFrames) return null;
        const idx = self.next_index;
        self.next_index += 1;
        _ = self.live.fetchAdd(1, .monotonic);
        const surf = self.allocator.create(Surface) catch @panic("oom");
        surf.* = .{ .live = self.live };
        self.surfaces.append(self.allocator, surf) catch @panic("oom");
        return .{
            .pts_seconds = @as(f64, @floatFromInt(idx)) / @as(f64, @floatFromInt(kFps)),
            .height = idx, // carry frame index for the marker assertion
            .pixel_format = .nv12,
            .release_hook = surf.hook(),
        };
    }

    fn backend(self: *KeyframeBackend) Backend {
        return ts.backend(self);
    }
};

// Pull the first frame the scheduler delivers after a (re)seek, spinning briefly
// while the worker pumps. Releases nothing — caller owns the returned frame.
fn waitFirstFrame(sched: *DecodeScheduler, s: StreamHandle) VideoFrame {
    var f = sched.nextFrame(s);
    const deadline = sys_clock.milliTimestamp() + 5_000;
    while (f == null) {
        sys_clock.sleep(50 * std.time.ns_per_us);
        f = sched.nextFrame(s);
        std.debug.assert(sys_clock.milliTimestamp() < deadline);
    }
    return f.?;
}

const ResolveResult = struct {
    presented_index: i32 = -1,
    frames_to_present: i64 = 0,
};

// Map a ScrubResolve onto the scheduler. A Keyframe resolve just reseeks to the
// (keyframe-snapped) target and presents whatever the backend yields first. An
// Exact resolve reseeks to the same place but then DROPS forward to the precise
// target frame before presenting.
fn applyResolve(sched: *DecodeScheduler, s: StreamHandle, r: ScrubResolve) ResolveResult {
    sched.requestSeek(s, r.target_seconds);

    var f = waitFirstFrame(sched, s);
    var presented = f.height;
    var popped: i64 = 1;

    if (r.mode == .exact) {
        const want = frameOfPts(r.target_seconds);
        while (presented < want) {
            f.release();
            f = waitFirstFrame(sched, s);
            presented = f.height;
            popped += 1;
        }
    }
    f.release();
    return .{ .presented_index = presented, .frames_to_present = popped };
}

test "exact-frame-on-settle: settle resolves to the precise target frame" {
    var live = std.atomic.Value(i32).init(0);
    // Force-synchronous: decode runs inline on this thread.
    const sched = try DecodeScheduler.init(alloc, 1, true);
    defer sched.deinit();
    const s = try sched.registerStream(KeyframeBackend.create(alloc, &live).backend());

    var scrub = Scrubber.init(ts.makeScrubConfig());

    // A fast drag burst: targets that do NOT sit on the keyframe grid, so a
    // keyframe scrub lands on a DIFFERENT frame than the exact target.
    const targets = [_]f64{ 10.40, 12.70, 15.15 }; // frames 312, 381, 454
    var now_ms: f64 = 0.0;
    _ = scrub.onSeek(2.0, .{ .ms = now_ms }); // prime
    for (targets) |t| {
        now_ms += 20.0; // 20ms apart -> fast burst -> keyframe
        const last = scrub.onSeek(t, .{ .ms = now_ms });
        try std.testing.expectEqual(ResolveMode.keyframe, last.mode);
        const kf = applyResolve(sched, s, last);
        // Keyframe scrub lands on the keyframe at/before the target.
        try std.testing.expectEqual(keyframeAtOrBefore(frameOfPts(t)), kf.presented_index);
    }

    // The user stops moving. After the debounce, the Scrubber emits an Exact
    // resolve at the LAST target.
    now_ms += 150.0;
    const settle = scrub.poll(.{ .ms = now_ms });
    try std.testing.expect(settle != null);
    try std.testing.expectEqual(ResolveMode.exact, settle.?.mode);

    const exact = applyResolve(sched, s, settle.?);
    // MARKER ASSERTION: the settled frame is EXACTLY the last drag target.
    const want = frameOfPts(targets[2]);
    try std.testing.expectEqual(want, exact.presented_index);

    sched.unregisterStream(s);
    try std.testing.expectEqual(0, live.load(.monotonic));
}

test "scrub-latency perf metric: keyframe scrub reaches a frame far sooner than exact" {
    var live = std.atomic.Value(i32).init(0);
    // Force-synchronous so the consumer-side pop count is a clean, deterministic
    // latency proxy.
    const sched = try DecodeScheduler.init(alloc, 1, true);
    defer sched.deinit();
    const s = try sched.registerStream(KeyframeBackend.create(alloc, &live).backend());

    // Target deliberately near the END of a GOP so an exact resolve must decode a
    // near-full GOP forward, while a keyframe scrub stops at the keyframe.
    const target = @as(f64, @floatFromInt(kGopFrames - 1)) / @as(f64, @floatFromInt(kFps)) + 20.0;
    const want = frameOfPts(target);

    // Keyframe scrub cost (the feedback-latency proxy during a drag).
    const kf = applyResolve(sched, s, .{ .mode = .keyframe, .target_seconds = target });
    try std.testing.expectEqual(keyframeAtOrBefore(want), kf.presented_index);

    // Exact resolve cost (the precise settle/resume path).
    const exact = applyResolve(sched, s, .{ .mode = .exact, .target_seconds = target });
    try std.testing.expectEqual(want, exact.presented_index);

    // A keyframe scrub presents immediately (one frame); exact decodes forward.
    try std.testing.expectEqual(1, kf.frames_to_present);
    try std.testing.expect(kf.frames_to_present < exact.frames_to_present);
    // Real win: with the target at the back of the GOP, exact must decode forward
    // at least half a GOP further than the keyframe scrub.
    try std.testing.expect(exact.frames_to_present >= kf.frames_to_present + @as(i64, @intCast(@divTrunc(kGopFrames, 2))));

    sched.unregisterStream(s);
    try std.testing.expectEqual(0, live.load(.monotonic));
}
