//! scrubber_integration_test.zig — the DecodeScheduler-dependent scrub cases
//! (the pure Scrubber state-machine cases live in scrubber.zig).
//!
//! Two layers, sharing one keyframe-grid model:
//!  - Scheduler-level: proves the Scrubber's decisions, when mapped onto real
//!    seeks, give (a) low keyframe-scrub latency during a drag and (b) the
//!    EXACT target frame once the scrub settles. Runs the scheduler in
//!    force-synchronous mode so decode happens inline on this thread:
//!    request_seek's flush + reseek and the decode-forward are fully
//!    deterministic with no worker race.
//!  - Controller-level: drives the same seam through
//!    PlaybackController.seek()/tick(), pinning drop counts, the exact-resolve
//!    epsilon, EOS clamping, and the settled frame presented after a drag.

const std = @import("std");

const backend_mod = @import("backend.zig");
const scrubber_mod = @import("scrubber.zig");
const ds = @import("decode_scheduler.zig");
const sys_clock = @import("sys_clock.zig");
const ts = @import("test_support.zig");
const pc = @import("playback_controller.zig");
const wall_clock_mod = @import("wall_clock.zig");

const Backend = backend_mod.Backend;
const VideoFrame = backend_mod.VideoFrame;
const Scrubber = scrubber_mod.Scrubber;
const ScrubResolve = scrubber_mod.ScrubResolve;
const ResolveMode = scrubber_mod.ResolveMode;
const DecodeScheduler = ds.DecodeScheduler;
const StreamHandle = ds.StreamHandle;
const PlaybackController = pc.PlaybackController;
const WallClockMs = wall_clock_mod.WallClockMs;
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

// -----------------------------------------------------------------------
// Controller-level fixtures. ScrubGridBackend sits on the same keyframe grid
// as KeyframeBackend but only counts frame releases (drops); ExactPtsBackend
// yields an explicit, hand-picked PTS sequence.
// -----------------------------------------------------------------------
const ScrubGridBackend = struct {
    allocator: std.mem.Allocator,
    drop_counter: *std.atomic.Value(i32),
    next_index: i32 = 0,

    fn create(allocator: std.mem.Allocator, drop_counter: *std.atomic.Value(i32)) *ScrubGridBackend {
        const self = allocator.create(ScrubGridBackend) catch @panic("oom");
        self.* = .{ .allocator = allocator, .drop_counter = drop_counter };
        return self;
    }

    pub fn deinit(self: *ScrubGridBackend) void {
        self.allocator.destroy(self);
    }
    pub fn durationSeconds(_: *ScrubGridBackend) f64 {
        return @as(f64, @floatFromInt(kTotalFrames)) / @as(f64, @floatFromInt(kFps));
    }
    pub fn videoWidth(_: *ScrubGridBackend) i32 {
        return 0;
    }
    pub fn videoHeight(_: *ScrubGridBackend) i32 {
        return 1;
    }
    pub fn seek(self: *ScrubGridBackend, pts_seconds: f64) bool {
        const target = frameOfPts(pts_seconds);
        self.next_index = keyframeAtOrBefore(target);
        return true;
    }
    pub fn nextVideoFrame(self: *ScrubGridBackend) ?VideoFrame {
        if (self.next_index >= kTotalFrames) return null;
        const idx = self.next_index;
        self.next_index += 1;
        return .{
            .pts_seconds = @as(f64, @floatFromInt(idx)) / @as(f64, @floatFromInt(kFps)),
            // A released frame bumps the drop counter.
            .release_hook = ts.countingRelease(self.drop_counter),
        };
    }

    fn backend(self: *ScrubGridBackend) Backend {
        return ts.backend(self);
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

    pub fn deinit(self: *ExactPtsBackend) void {
        self.allocator.free(self.pts_sequence);
        self.allocator.destroy(self);
    }
    pub fn durationSeconds(_: *ExactPtsBackend) f64 {
        return 100.0;
    }
    pub fn videoWidth(_: *ExactPtsBackend) i32 {
        return 0;
    }
    pub fn videoHeight(_: *ExactPtsBackend) i32 {
        return 1;
    }
    pub fn seek(self: *ExactPtsBackend, _: f64) bool {
        self.armed = true;
        self.idx = 0;
        return true;
    }
    pub fn nextVideoFrame(self: *ExactPtsBackend) ?VideoFrame {
        if (!self.armed or self.idx >= self.pts_sequence.len) return null;
        const pts = self.pts_sequence[self.idx];
        self.idx += 1;
        return .{
            .pts_seconds = pts,
            .release_hook = ts.countingRelease(self.drop_counter),
        };
    }

    fn backend(self: *ExactPtsBackend) Backend {
        return ts.backend(self);
    }
};

// Per-test decode pool for the controller-level cases: one worker,
// force-synchronous where the build supports it (release builds fall back to
// a single async worker; the cases hold in both modes).
fn makeSched() *DecodeScheduler {
    return DecodeScheduler.init(alloc, 1, true) catch @panic("sched init failed");
}

// The controller-level cases play video-only clips; the sink is never invoked.
const NullMixSink = struct {
    fn mixImpl(_: *anyopaque, interleaved: []const f32, channel_count: i32) i32 {
        _ = interleaved;
        _ = channel_count;
        return 0;
    }
    const vtable: pc.MixSink.VTable = .{ .mix = mixImpl };
    fn sink(self: *NullMixSink) pc.MixSink {
        return .{ .ptr = self, .vtable = &vtable };
    }
};

// =======================================================================
// Controller-level scrub resolve: PlaybackController.seek()/tick() drives the
// Scrubber's decisions through the real scheduler seam.
// =======================================================================

test "seek(): a fast burst resolves Keyframe with no forward-decode drops; a lone seek resolves Exact" {
    // Target deliberately near the END of a GOP so an Exact resolve must decode
    // nearly a full GOP forward, while a Keyframe resolve stops dead at the
    // keyframe.
    const target = @as(f64, @floatFromInt(kGopFrames - 1)) / @as(f64, @floatFromInt(kFps)) + 20.0;

    // --- Exact: a lone seek (no prior scrub history) always resolves Exact. ---
    var exact_drops = std.atomic.Value(i32).init(0);
    {
        const sched = makeSched();
        defer sched.deinit();
        var controller = PlaybackController.init();
        defer controller.deinit();
        try controller.load(alloc, sched, ScrubGridBackend.create(alloc, &exact_drops).backend(), 0.0);
        controller.seek(target, WallClockMs.init(0.0));
        controller.shutdown();
    }
    try std.testing.expect(exact_drops.load(.monotonic) >= @divTrunc(kGopFrames, 2)); // decoded across most of a GOP

    // --- Keyframe: priming, then a fast in-burst follow-up seek. ---
    var kf_drops = std.atomic.Value(i32).init(0);
    {
        const sched = makeSched();
        defer sched.deinit();
        var controller = PlaybackController.init();
        defer controller.deinit();
        try controller.load(alloc, sched, ScrubGridBackend.create(alloc, &kf_drops).backend(), 0.0);
        controller.seek(1.0, WallClockMs.init(0.0)); // prime (Exact, trivial forward decode)
        kf_drops.store(0, .monotonic); // isolate the SECOND (Keyframe) resolve only
        controller.seek(target, WallClockMs.init(20.0)); // 20ms later, huge jump -> fast drag -> Keyframe
        // Check BEFORE shutdown: request_seek() flushes the queue; the count here
        // is purely the flush (shutdown adds worker-pushed post-seek frames).
        try std.testing.expect(kf_drops.load(.monotonic) <= @as(i32, @intCast(ds.kDecodeAheadCapacity)));
        controller.shutdown();
    }
}

test "an exact resolve treats a frame within epsilon of the target as arrived" {
    const kEps = 1.0 / 120.0; // mirrors applyScrubResolve()'s tolerance
    const target = 10.0;

    // A frame within epsilon of the target is NOT dropped — the forward
    // decode stops there and leaves it for the present step.
    var drops_in_tolerance = std.atomic.Value(i32).init(0);
    {
        const sched = makeSched();
        defer sched.deinit();
        var controller = PlaybackController.init();
        defer controller.deinit();
        try controller.load(alloc, sched, ExactPtsBackend.create(alloc, &.{target - kEps * 0.5}, &drops_in_tolerance).backend(), 0.0);
        controller.seek(target, WallClockMs.init(0.0));
        // Check before shutdown(): unregister releases the in-tolerance survivor,
        // which would otherwise inflate this count by one.
        try std.testing.expectEqual(0, drops_in_tolerance.load(.monotonic));
        controller.shutdown();
    }

    // A frame outside epsilon IS dropped; the forward decode then stops at
    // the next frame, which is within tolerance.
    var drops_out_of_tolerance = std.atomic.Value(i32).init(0);
    {
        const sched = makeSched();
        defer sched.deinit();
        var controller = PlaybackController.init();
        defer controller.deinit();
        try controller.load(alloc, sched, ExactPtsBackend.create(alloc, &.{ target - kEps * 2.0, target - kEps * 0.5 }, &drops_out_of_tolerance).backend(), 0.0);
        controller.seek(target, WallClockMs.init(0.0));
        try std.testing.expectEqual(1, drops_out_of_tolerance.load(.monotonic));
        controller.shutdown();
    }
}

test "seek() past end-of-stream clamps at EOS instead of hanging" {
    var drops = std.atomic.Value(i32).init(0);
    const sched = makeSched();
    defer sched.deinit();
    var controller = PlaybackController.init();
    defer controller.deinit();
    try controller.load(alloc, sched, ScrubGridBackend.create(alloc, &drops).backend(), 0.0);

    // Lone seek -> Exact. Target far beyond the clip's duration, so the
    // backend reports EOS before reaching the target and the exact resolve
    // must clamp there rather than decode forever.
    const start = sys_clock.milliTimestamp();
    controller.seek(@as(f64, @floatFromInt(kTotalFrames)) / @as(f64, @floatFromInt(kFps)) + 1000.0, WallClockMs.init(0.0));
    const elapsed = sys_clock.milliTimestamp() - start;

    try std.testing.expect(elapsed < 5_000); // bounded, not hung

    controller.shutdown();
}

test "after a drag burst settles, the next tick presents the exact settled target frame" {
    var drops = std.atomic.Value(i32).init(0);
    const sched = makeSched();
    defer sched.deinit();
    var controller = PlaybackController.init();
    defer controller.deinit();
    try controller.load(alloc, sched, ScrubGridBackend.create(alloc, &drops).backend(), 0.0);
    controller.play(WallClockMs.init(0.0));

    // Frame-aligned targets sidestep the present-selector's own half-frame
    // tolerance landing on a coin-flip between two adjacent frames.
    const last_target = 400.0 / @as(f64, @floatFromInt(kFps));
    controller.seek(100.0 / @as(f64, @floatFromInt(kFps)), WallClockMs.init(1000.0)); // prime -> Exact
    controller.seek(300.0 / @as(f64, @floatFromInt(kFps)), WallClockMs.init(1020.0)); // fast -> Keyframe
    controller.seek(last_target, WallClockMs.init(1040.0)); // fast -> Keyframe (approximate frame on screen)

    var sink = NullMixSink{}; // never invoked: no audio
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
