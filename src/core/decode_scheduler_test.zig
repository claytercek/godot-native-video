const std = @import("std");

const backend_mod = @import("backend.zig");
const ds = @import("decode_scheduler.zig");
const sys_clock = @import("sys_clock.zig");
const ts = @import("test_support.zig");

const Backend = backend_mod.Backend;
const VideoFrame = backend_mod.VideoFrame;
const AudioChunk = backend_mod.AudioChunk;
const AudioTrackInfo = backend_mod.AudioTrackInfo;
const DecodeScheduler = ds.DecodeScheduler;
const StreamHandle = ds.StreamHandle;
// Each decoded frame carries a heap-allocated release tracker so a leak /
// double-release / use-after-recycle is detectable per surface.
const Surface = ts.Surface;

// -----------------------------------------------------------------------
// FakeBackend — a deterministic, Godot-free decoder mock.
//
// Each backend belongs to one stream id. It produces `frame_count` frames with
// a known, monotonic frame index encoded in BOTH the width field (stream id)
// and the pts (frame index). A small optional sleep models decode latency so
// the pool's fairness and serialization are actually exercised under timing.
// -----------------------------------------------------------------------
const FakeBackend = struct {
    allocator: std.mem.Allocator,
    stream_id: i32,
    frame_count: i32,
    next_index: i32 = 0,
    live: ?*std.atomic.Value(i32),
    total: ?*std.atomic.Value(i64),
    decode_micros: i32 = 0,
    surfaces: std.ArrayList(*Surface) = .empty,

    fn create(
        allocator: std.mem.Allocator,
        stream_id: i32,
        frame_count: i32,
        live: ?*std.atomic.Value(i32),
        total: ?*std.atomic.Value(i64),
        decode_micros: i32,
    ) *FakeBackend {
        const self = allocator.create(FakeBackend) catch @panic("oom");
        self.* = .{
            .allocator = allocator,
            .stream_id = stream_id,
            .frame_count = frame_count,
            .live = live,
            .total = total,
            .decode_micros = decode_micros,
        };
        return self;
    }

    pub fn deinit(self: *FakeBackend) void {
        for (self.surfaces.items) |s| self.allocator.destroy(s);
        self.surfaces.deinit(self.allocator);
        self.allocator.destroy(self);
    }
    pub fn durationSeconds(self: *FakeBackend) f64 {
        return @as(f64, @floatFromInt(self.frame_count)) / 30.0;
    }
    pub fn videoWidth(self: *FakeBackend) i32 {
        return self.stream_id;
    }
    pub fn videoHeight(_: *FakeBackend) i32 {
        return 1;
    }
    pub fn seek(self: *FakeBackend, pts_seconds: f64) bool {
        var idx: i32 = @intFromFloat(pts_seconds * 30.0);
        if (idx < 0) idx = 0;
        self.next_index = idx;
        return true;
    }
    pub fn nextVideoFrame(self: *FakeBackend) ?VideoFrame {
        if (self.next_index >= self.frame_count) return null; // EOS
        if (self.decode_micros > 0) {
            sys_clock.sleep(@as(u64, @intCast(self.decode_micros)) * std.time.ns_per_us);
        }
        const idx = self.next_index;
        self.next_index += 1;
        if (self.live) |l| _ = l.fetchAdd(1, .monotonic);
        const surf = self.allocator.create(Surface) catch @panic("oom");
        surf.* = .{ .live = self.live, .total = self.total };
        self.surfaces.append(self.allocator, surf) catch @panic("oom");
        return .{
            .pts_seconds = @as(f64, @floatFromInt(idx)) / 30.0,
            .width = self.stream_id, // carry the stream id for corruption checks
            .height = idx, // carry the frame index for order checks
            .pixel_format = .nv12,
            .release_hook = surf.hook(),
        };
    }

    fn backend(self: *FakeBackend) Backend {
        return ts.backend(self);
    }
};

// -----------------------------------------------------------------------
// required_pool_depth — the surface-lifetime sizing contract.
// -----------------------------------------------------------------------
test "requiredPoolDepth = queue depth + in-flight + frame latency" {
    // 7 usable queue slots + 1 being presented + 3 retire-ring frames = 11.
    try std.testing.expectEqual(11, ds.requiredPoolDepth(7, 3));
    try std.testing.expectEqual(2, ds.requiredPoolDepth(0, 1));
    try std.testing.expectEqual(
        (ds.kDecodeAheadCapacity - 1) + 1 + 3,
        ds.requiredPoolDepth(ds.kDecodeAheadCapacity - 1, 3),
    );
}

test "worker count is bounded and independent of stream count" {
    const alloc = std.testing.allocator;
    const sched = try DecodeScheduler.init(alloc, 2, false);
    defer sched.deinit();
    try std.testing.expectEqual(2, sched.workerCount());

    var live = std.atomic.Value(i32).init(0);
    var released = std.atomic.Value(i64).init(0);
    // Register many more streams than workers; the pool must NOT grow.
    var streams: std.ArrayList(StreamHandle) = .empty;
    defer streams.deinit(alloc);
    var i: i32 = 0;
    while (i < 16) : (i += 1) {
        try streams.append(alloc, try sched.registerStream(
            FakeBackend.create(alloc, i, 30, &live, &released, 0).backend(),
        ));
    }
    try std.testing.expectEqual(2, sched.workerCount()); // still 2

    for (streams.items) |s| sched.unregisterStream(s);
    try std.testing.expectEqual(0, live.load(.monotonic)); // no surface leaked
}

// -----------------------------------------------------------------------
// Multi-stream stress: many streams, few workers, per-stream order preserved,
// no cross-stream corruption, no leak. Repeated over many iterations.
// -----------------------------------------------------------------------
test "multi-stream stress: per-stream order preserved, no corruption" {
    const alloc = std.testing.allocator;
    const kStreams = 24;
    const kFramesPerStream = 120;
    const kWorkers = 3; // << kStreams, to prove sharing

    var iter: usize = 0;
    while (iter < 5) : (iter += 1) {
        var live = std.atomic.Value(i32).init(0);
        var released = std.atomic.Value(i64).init(0);

        const sched = try DecodeScheduler.init(alloc, kWorkers, false);
        defer sched.deinit();
        try std.testing.expectEqual(kWorkers, sched.workerCount());

        var streams: std.ArrayList(StreamHandle) = .empty;
        defer streams.deinit(alloc);
        var i: i32 = 0;
        while (i < kStreams) : (i += 1) {
            // Stagger decode latency a little so workers interleave streams.
            const micros = @mod(i, 3) * 5;
            try streams.append(alloc, try sched.registerStream(
                FakeBackend.create(alloc, i, kFramesPerStream, &live, &released, micros).backend(),
            ));
        }

        // Consume every frame of every stream on the main thread. Assert each
        // stream's frames arrive strictly in index order and carry that id.
        var next_expected = [_]i32{0} ** kStreams;
        var total_consumed: i32 = 0;
        const total_expected: i32 = kStreams * kFramesPerStream;

        const deadline = sys_clock.milliTimestamp() + 20_000;

        while (total_consumed < total_expected) {
            var progressed = false;
            var s: usize = 0;
            while (s < kStreams) : (s += 1) {
                const f = sched.nextFrame(streams.items[s]) orelse continue;
                progressed = true;
                // Cross-stream corruption check: frame must belong to stream s.
                try std.testing.expectEqual(@as(i32, @intCast(s)), f.width);
                // Per-stream order check: frame index is exactly the next one.
                try std.testing.expectEqual(next_expected[s], f.height);
                try std.testing.expectApproxEqAbs(
                    @as(f64, @floatFromInt(next_expected[s])) / 30.0,
                    f.pts_seconds,
                    1e-9,
                );
                next_expected[s] += 1;
                total_consumed += 1;
                // Mimic the present path: release the surface back to the pool.
                f.release();
            }
            if (!progressed) sys_clock.sleep(50 * std.time.ns_per_us);
            try std.testing.expect(sys_clock.milliTimestamp() < deadline);
        }

        // Every stream delivered exactly its frames, in order.
        //
        // atEnd() is EVENTUALLY true, not immediately: eos is worker-reported,
        // and when the queue was full at the moment the last frame decoded,
        // the slice ends without observing EOS — the final pop's notify
        // schedules the slice that does. Production polls atEnd() per tick,
        // so mirror that here instead of racing the worker.
        for (streams.items, 0..) |st, idx| {
            try std.testing.expectEqual(kFramesPerStream, next_expected[idx]);
            const eos_deadline = sys_clock.milliTimestamp() + 5_000;
            while (!sched.atEnd(st)) {
                try std.testing.expect(sys_clock.milliTimestamp() < eos_deadline);
                sys_clock.sleep(50 * std.time.ns_per_us);
            }
        }

        for (streams.items) |st| sched.unregisterStream(st);
        // No surface left alive; every produced surface released exactly once.
        try std.testing.expectEqual(0, live.load(.monotonic));
        try std.testing.expectEqual(total_expected, released.load(.monotonic));
    }
}

// -----------------------------------------------------------------------
// Unregister mid-decode must not leak or use-after-free. We tear streams down
// while workers are actively decoding (no draining first).
// -----------------------------------------------------------------------
test "unregister mid-decode releases buffered surfaces, no leak" {
    const alloc = std.testing.allocator;
    var live = std.atomic.Value(i32).init(0);
    var released = std.atomic.Value(i64).init(0);

    const sched = try DecodeScheduler.init(alloc, 4, false);
    defer sched.deinit();
    var streams: std.ArrayList(StreamHandle) = .empty;
    defer streams.deinit(alloc);
    var i: i32 = 0;
    while (i < 12) : (i += 1) {
        try streams.append(alloc, try sched.registerStream(
            FakeBackend.create(alloc, i, 200, &live, &released, 10).backend(),
        ));
    }

    // Let workers get busy decoding ahead.
    sys_clock.sleep(5 * std.time.ns_per_ms);

    // Pop a few frames from some streams, then tear everything down mid-flight.
    i = 0;
    while (i < 12) : (i += 1) {
        var k: usize = 0;
        while (k < 3) : (k += 1) {
            if (sched.nextFrame(streams.items[@intCast(i)])) |f| f.release();
        }
    }

    for (streams.items) |s| sched.unregisterStream(s);
    try std.testing.expectEqual(0, live.load(.monotonic));
}

// -----------------------------------------------------------------------
// request_seek (the scrub seam): flushes the queue, reseeks the backend, and
// resumes decode-ahead from the new position in order.
// -----------------------------------------------------------------------
test "request_seek flushes and resumes decode-ahead at the target" {
    const alloc = std.testing.allocator;
    var live = std.atomic.Value(i32).init(0);
    var released = std.atomic.Value(i64).init(0);

    const sched = try DecodeScheduler.init(alloc, 2, false);
    defer sched.deinit();
    const s = try sched.registerStream(FakeBackend.create(alloc, 0, 300, &live, &released, 0).backend());

    // Drain a few frames from the start.
    var k: usize = 0;
    while (k < 5) : (k += 1) {
        var f = sched.nextFrame(s);
        while (f == null) {
            sys_clock.sleep(50 * std.time.ns_per_us);
            f = sched.nextFrame(s);
        }
        f.?.release();
    }

    // Seek to frame 150 (5.0s @ 30fps).
    sched.requestSeek(s, 5.0);

    // The next frame delivered must be frame 150 (FakeBackend's exact seek).
    var f = sched.nextFrame(s);
    const deadline = sys_clock.milliTimestamp() + 5_000;
    while (f == null) {
        sys_clock.sleep(50 * std.time.ns_per_us);
        f = sched.nextFrame(s);
        try std.testing.expect(sys_clock.milliTimestamp() < deadline);
    }
    try std.testing.expectEqual(150, f.?.height);
    f.?.release();

    sched.unregisterStream(s);
    try std.testing.expectEqual(0, live.load(.monotonic));
}

// -----------------------------------------------------------------------
// Force-synchronous mode (debug only): no worker threads; decode runs on the
// caller's thread so lifetime bugs reproduce deterministically. Same external
// behaviour — order preserved, exactly-once release.
// -----------------------------------------------------------------------
test "force-synchronous mode: no workers, deterministic in-order decode" {
    if (!ds.force_sync_available) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var live = std.atomic.Value(i32).init(0);
    var released = std.atomic.Value(i64).init(0);

    const sched = try DecodeScheduler.init(alloc, 4, true);
    defer sched.deinit();
    try std.testing.expect(sched.isSynchronous());
    try std.testing.expectEqual(0, sched.workerCount()); // no threads spawned

    const kStreams = 6;
    const kFrames = 50;
    var streams: std.ArrayList(StreamHandle) = .empty;
    defer streams.deinit(alloc);
    var i: i32 = 0;
    while (i < kStreams) : (i += 1) {
        try streams.append(alloc, try sched.registerStream(
            FakeBackend.create(alloc, i, kFrames, &live, &released, 0).backend(),
        ));
    }

    var expected = [_]i32{0} ** kStreams;
    var consumed: i32 = 0;
    const total: i32 = kStreams * kFrames;
    while (consumed < total) {
        var progressed = false;
        var s: usize = 0;
        while (s < kStreams) : (s += 1) {
            const f = sched.nextFrame(streams.items[s]) orelse continue;
            progressed = true;
            try std.testing.expectEqual(@as(i32, @intCast(s)), f.width);
            try std.testing.expectEqual(expected[s], f.height);
            expected[s] += 1;
            consumed += 1;
            f.release();
        }
        // Synchronous: nextFrame re-pumps inline, so progress is guaranteed.
        try std.testing.expect(progressed);
    }

    for (streams.items) |s| sched.unregisterStream(s);
    try std.testing.expectEqual(0, live.load(.monotonic));
    try std.testing.expectEqual(total, released.load(.monotonic));
}

// -----------------------------------------------------------------------
// Monotonicity guard at the FrameQueue producer boundary. The guard is purely
// diagnostic (it latches a one-shot warning; it never reorders or drops), so we
// exercise the state machine directly on a bare DecodeStream rather than through
// the pool. NOTE: the backward-step case intentionally emits one log.warn line
// to stderr — that is the guard doing its job, not a test failure.
// -----------------------------------------------------------------------
test "monotonicity guard latches once on a backward PTS, resets across a seek" {
    var stream: ds.DecodeStream = .{};

    // Ascending PTS: baseline advances, nothing latched.
    ds.checkEnqueueMonotonic(&stream, 0.000);
    ds.checkEnqueueMonotonic(&stream, 0.033);
    ds.checkEnqueueMonotonic(&stream, 0.066);
    try std.testing.expect(!stream.pts_regressed_warned);
    try std.testing.expectEqual(@as(?f64, 0.066), stream.last_enqueued_pts);

    // A backward step (0.050 < 0.066) latches the one-shot warning.
    ds.checkEnqueueMonotonic(&stream, 0.050);
    try std.testing.expect(stream.pts_regressed_warned);
    try std.testing.expectEqual(@as(?f64, 0.050), stream.last_enqueued_pts);

    // A seek resets the baseline (null); a legitimately lower post-seek PTS must
    // NOT re-warn — the latch is one-shot per stream/open and already set.
    stream.last_enqueued_pts = null;
    ds.checkEnqueueMonotonic(&stream, 0.010);
    try std.testing.expect(stream.pts_regressed_warned); // still just the one latch
    try std.testing.expectEqual(@as(?f64, 0.010), stream.last_enqueued_pts);
}

test "monotonicity guard stays quiet for a clean ascending sequence" {
    var stream: ds.DecodeStream = .{};
    var pts: f64 = 0.0;
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        ds.checkEnqueueMonotonic(&stream, pts);
        pts += 1.0 / 30.0;
    }
    try std.testing.expect(!stream.pts_regressed_warned);
}

// -----------------------------------------------------------------------
// ReselectFakeBackend — a multi-track backend for testing reselect. Two audio
// "tracks" (0 and 1) with different sample counts per-frame. reselect switches
// between them, and next_audio_chunk produces chunks whose frame_count
// identifies the active track. Video is the same deterministic sequence as
// FakeBackend.
// -----------------------------------------------------------------------
const ReselectFakeBackend = struct {
    allocator: std.mem.Allocator,
    stream_id: i32,
    frame_count: i32,
    next_index: i32 = 0,
    live: ?*std.atomic.Value(i32),
    total: ?*std.atomic.Value(i64),
    surfaces: std.ArrayList(*Surface) = .empty,

    active_track: i32 = 0,
    reselect_count: i32 = 0,
    audio_scratch: []f32 = &.{},

    fn create(
        allocator: std.mem.Allocator,
        stream_id: i32,
        frame_count: i32,
        live: ?*std.atomic.Value(i32),
        total: ?*std.atomic.Value(i64),
    ) *ReselectFakeBackend {
        const self = allocator.create(ReselectFakeBackend) catch @panic("oom");
        self.* = .{
            .allocator = allocator,
            .stream_id = stream_id,
            .frame_count = frame_count,
            .live = live,
            .total = total,
        };
        return self;
    }

    pub fn deinit(self: *ReselectFakeBackend) void {
        for (self.surfaces.items) |s| self.allocator.destroy(s);
        self.surfaces.deinit(self.allocator);
        if (self.audio_scratch.len > 0) self.allocator.free(self.audio_scratch);
        self.allocator.destroy(self);
    }
    pub fn durationSeconds(self: *ReselectFakeBackend) f64 {
        return @as(f64, @floatFromInt(self.frame_count)) / 30.0;
    }
    pub fn videoWidth(self: *ReselectFakeBackend) i32 {
        return self.stream_id;
    }
    pub fn videoHeight(_: *ReselectFakeBackend) i32 {
        return 1;
    }
    pub fn audioTrackCount(_: *ReselectFakeBackend) i32 {
        return 2;
    }
    pub fn audioTrackInfo(_: *ReselectFakeBackend, index: i32) AudioTrackInfo {
        return .{ .channels = 2, .sample_rate = 48000, .is_default = index == 0 };
    }
    pub fn selectAudioTrack(self: *ReselectFakeBackend, index: i32) void {
        if (index >= 0 and index < 2) self.active_track = index;
    }
    pub fn reselectAudioTrack(self: *ReselectFakeBackend, index: i32, _: f64) bool {
        if (index < 0 or index >= 2) return false;
        self.active_track = index;
        self.reselect_count += 1;
        return true;
    }
    pub fn seek(self: *ReselectFakeBackend, pts_seconds: f64) bool {
        var idx: i32 = @intFromFloat(pts_seconds * 30.0);
        if (idx < 0) idx = 0;
        self.next_index = idx;
        return true;
    }
    pub fn nextVideoFrame(self: *ReselectFakeBackend) ?VideoFrame {
        if (self.next_index >= self.frame_count) return null;
        const idx = self.next_index;
        self.next_index += 1;
        if (self.live) |l| _ = l.fetchAdd(1, .monotonic);
        const surf = self.allocator.create(Surface) catch @panic("oom");
        surf.* = .{ .live = self.live, .total = self.total };
        self.surfaces.append(self.allocator, surf) catch @panic("oom");
        return .{
            .pts_seconds = @as(f64, @floatFromInt(idx)) / 30.0,
            .width = self.stream_id,
            .height = idx,
            .pixel_format = .nv12,
            .release_hook = surf.hook(),
        };
    }
    pub fn nextAudioChunk(self: *ReselectFakeBackend) ?AudioChunk {
        // Track 0 -> 512-frame chunks; track 1 -> 256-frame chunks.
        const frames_per_chunk: i32 = if (self.active_track == 0) 512 else 256;
        const channels: i32 = 2;
        const n: usize = @intCast(frames_per_chunk * channels);
        if (self.audio_scratch.len < n) {
            if (self.audio_scratch.len > 0) self.allocator.free(self.audio_scratch);
            self.audio_scratch = self.allocator.alloc(f32, n) catch @panic("oom");
        }
        @memset(self.audio_scratch[0..n], 0.0);
        // Tag the first sample with the active track so a test can assert.
        self.audio_scratch[0] = @floatFromInt(self.active_track);
        return .{
            .samples = self.audio_scratch[0..n],
            .frame_count = frames_per_chunk,
            .channel_count = channels,
            .sample_rate = 48000,
        };
    }

    fn backend(self: *ReselectFakeBackend) Backend {
        return ts.backend(self);
    }
};

// Context helpers for withBackend.
const AudioProbe = struct {
    frame_count: i32 = -1,
    tag: i32 = -1,
    fn run(self: *AudioProbe, b: *Backend) void {
        if (b.nextAudioChunk()) |ch| {
            self.frame_count = ch.frame_count;
            self.tag = @intFromFloat(ch.samples[0]);
        }
    }
};

const ReselectProbe = struct {
    index: i32,
    ok: bool = false,
    fn run(self: *ReselectProbe, b: *Backend) void {
        self.ok = b.reselectAudioTrack(self.index, 0.0);
    }
};

test "reselect_audio_track switches audio and preserves video flow" {
    const alloc = std.testing.allocator;
    var live = std.atomic.Value(i32).init(0);
    var released = std.atomic.Value(i64).init(0);

    const sched = try DecodeScheduler.init(alloc, 2, false);
    defer sched.deinit();
    const s = try sched.registerStream(ReselectFakeBackend.create(alloc, 0, 200, &live, &released).backend());

    // Let video decode-ahead start filling the queue.
    sys_clock.sleep(20 * std.time.ns_per_ms);

    // Verify video frames flow.
    var vf = sched.nextFrame(s);
    const deadline = sys_clock.milliTimestamp() + 5_000;
    while (vf == null) {
        sys_clock.sleep(50 * std.time.ns_per_us);
        vf = sched.nextFrame(s);
        try std.testing.expect(sys_clock.milliTimestamp() < deadline);
    }
    try std.testing.expectEqual(0, vf.?.width); // stream 0
    vf.?.release();

    // Verify the initial audio track is 0.
    var probe0 = AudioProbe{};
    sched.withBackend(s, &probe0, AudioProbe.run);
    try std.testing.expectEqual(512, probe0.frame_count); // track 0 = 512
    try std.testing.expectEqual(0, probe0.tag);

    // Reselect to track 1.
    var resel = ReselectProbe{ .index = 1 };
    sched.withBackend(s, &resel, ReselectProbe.run);
    try std.testing.expect(resel.ok);

    // Verify video still flows post-reselect.
    vf = sched.nextFrame(s);
    while (vf == null) {
        sys_clock.sleep(50 * std.time.ns_per_us);
        vf = sched.nextFrame(s);
        try std.testing.expect(sys_clock.milliTimestamp() < deadline);
    }
    try std.testing.expectEqual(0, vf.?.width);
    vf.?.release();

    // Verify the active audio track is now 1.
    var probe1 = AudioProbe{};
    sched.withBackend(s, &probe1, AudioProbe.run);
    try std.testing.expectEqual(256, probe1.frame_count); // track 1 = 256
    try std.testing.expectEqual(1, probe1.tag);

    sched.unregisterStream(s);
    try std.testing.expectEqual(0, live.load(.monotonic));
}

test "with_backend is serialized against worker decode during reselect" {
    const alloc = std.testing.allocator;
    var live = std.atomic.Value(i32).init(0);
    var released = std.atomic.Value(i64).init(0);

    const sched = try DecodeScheduler.init(alloc, 2, false);
    defer sched.deinit();
    const s = try sched.registerStream(ReselectFakeBackend.create(alloc, 0, 100, &live, &released).backend());

    // Let the worker start decoding ahead.
    sys_clock.sleep(10 * std.time.ns_per_ms);

    // Call withBackend while the worker may be decoding. Passes if the reselect
    // succeeds and video still flows afterwards (no deadlock).
    var resel = ReselectProbe{ .index = 1 };
    sched.withBackend(s, &resel, ReselectProbe.run);
    try std.testing.expect(resel.ok);

    const deadline = sys_clock.milliTimestamp() + 5_000;
    var consumed: i32 = 0;
    while (consumed < 3) {
        if (sched.nextFrame(s)) |vf| {
            vf.release();
            consumed += 1;
        } else {
            sys_clock.sleep(50 * std.time.ns_per_us);
        }
        try std.testing.expect(sys_clock.milliTimestamp() < deadline);
    }
    try std.testing.expectEqual(3, consumed);

    sched.unregisterStream(s);
    try std.testing.expectEqual(0, live.load(.monotonic));
}
