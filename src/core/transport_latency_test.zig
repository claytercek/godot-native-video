//! Regression coverage for #32: transport must return while a decoder is
//! blocked, not just appear fast when a fake backend happens to decode quickly.
const std = @import("std");
const backend_mod = @import("backend.zig");
const ds = @import("decode_scheduler.zig");
const pc = @import("playback_controller.zig");
const sys_clock = @import("sys_clock.zig");
const ts = @import("test_support.zig");

const alloc = std.testing.allocator;
const Frame = backend_mod.VideoFrame;

// First frame index past the fixture clip's end.
const end_index: i32 = 90;

const Gate = struct {
    closed: std.atomic.Value(bool) = .init(false),
    entered: std.atomic.Value(bool) = .init(false),

    fn wait(self: *Gate) void {
        if (!self.closed.load(.acquire)) return;
        self.entered.store(true, .release);
        while (self.closed.load(.acquire)) sys_clock.sleep(100 * std.time.ns_per_us);
    }
    fn open(self: *Gate) void {
        self.closed.store(false, .release);
    }
};

const Decoder = struct {
    cursor: i32 = 0,
    decode_gate: Gate = .{},
    seek_gate: Gate = .{},
    release_gate: Gate = .{},
    has_audio: bool = false,
    seek_succeeds: bool = true,
    block_frame: i32 = 0,
    block_decode_after_seek: bool = false,
    // Model a clip that is already past its end after any seek: the seek
    // succeeds and the first nextVideoFrame() reports EOS.
    eos_after_seek: bool = false,
    audio_pulls: std.atomic.Value(u32) = .init(0),
    destroyed: std.atomic.Value(bool) = .init(false),
    seeks: std.atomic.Value(u32) = .init(0),
    last_target: std.atomic.Value(i32) = .init(-1),
    live: std.atomic.Value(i32) = .init(0),
    releases: std.atomic.Value(i32) = .init(0),

    pub fn seek(self: *Decoder, target: f64) bool {
        _ = self.seeks.fetchAdd(1, .monotonic);
        self.last_target.store(@intFromFloat(target * 30.0), .monotonic);
        self.seek_gate.wait();
        if (!self.seek_succeeds) return false;
        self.cursor = if (self.eos_after_seek) end_index else @intFromFloat(target * 30.0);
        if (self.block_decode_after_seek) {
            self.decode_gate.entered.store(false, .release);
            self.decode_gate.closed.store(true, .release);
        }
        return true;
    }
    pub fn audioChannelCount(self: *Decoder) i32 {
        return if (self.has_audio) 2 else 0;
    }
    pub fn audioSampleRate(_: *Decoder) i32 {
        return 48000;
    }
    pub fn nextAudioChunk(self: *Decoder) ?backend_mod.AudioChunk {
        _ = self.audio_pulls.fetchAdd(1, .monotonic);
        return null;
    }
    pub fn deinit(self: *Decoder) void {
        self.destroyed.store(true, .release);
    }
    pub fn nextVideoFrame(self: *Decoder) ?Frame {
        // Capture the old result before blocking, including EOS. A seek made
        // during this call must invalidate it even if it arrives after flush.
        const index = self.cursor;
        self.cursor += 1;
        if (index >= self.block_frame) self.decode_gate.wait();
        if (index >= end_index) return null;
        _ = self.live.fetchAdd(1, .monotonic);
        return .{
            .pts_seconds = @as(f64, @floatFromInt(index)) / 30.0,
            .height = index,
            .release_hook = .{ .ctx = self, .func = release },
        };
    }
    fn release(p: ?*anyopaque) void {
        const self: *Decoder = @ptrCast(@alignCast(p.?));
        self.release_gate.wait();
        _ = self.live.fetchSub(1, .monotonic);
        _ = self.releases.fetchAdd(1, .monotonic);
    }
};

fn waitFor(flag: *std.atomic.Value(bool)) bool {
    const deadline = sys_clock.milliTimestamp() + 2000;
    while (!flag.load(.acquire)) {
        if (sys_clock.milliTimestamp() >= deadline) return false;
        sys_clock.sleep(100 * std.time.ns_per_us);
    }
    return true;
}

// Run the operation on a separate consumer thread so a regression cannot hang
// the test runner. The decoder gate stays closed until the operation returns;
// on timeout only, unblock it before joining and reporting the failed assertion.
fn callWhileBlocked(ctx: anytype, comptime run: fn (@TypeOf(ctx)) void, gate: *Gate) !void {
    const Call = struct {
        context: @TypeOf(ctx),
        done: std.atomic.Value(bool) = .init(false),
        fn invoke(self: *@This()) void {
            run(self.context);
            self.done.store(true, .release);
        }
    };
    var call: Call = .{ .context = ctx };
    const thread = try std.Thread.spawn(.{}, Call.invoke, .{&call});
    const returned_while_blocked = waitFor(&call.done);
    if (!returned_while_blocked) gate.open();
    thread.join();
    try std.testing.expect(returned_while_blocked);
}

fn nextFrame(sched: *ds.DecodeScheduler, stream: ds.StreamHandle) !Frame {
    const deadline = sys_clock.milliTimestamp() + 5000;
    while (true) {
        if (sched.nextFrame(stream)) |frame| return frame;
        if (sys_clock.milliTimestamp() >= deadline) return error.FrameTimedOut;
        sys_clock.sleep(100 * std.time.ns_per_us);
    }
}

const Sink = struct {
    calls: usize = 0,
    fn mix(p: *anyopaque, _: []const f32, _: i32) i32 {
        const self: *Sink = @ptrCast(@alignCast(p));
        self.calls += 1;
        return 0;
    }
    const vtable: pc.MixSink.VTable = .{ .mix = mix };
    fn sink(self: *Sink) pc.MixSink {
        return .{ .ptr = self, .vtable = &vtable };
    }
};

fn waitIdle(sched: *ds.DecodeScheduler, stream: ds.StreamHandle) !void {
    const deadline = sys_clock.milliTimestamp() + 5000;
    while (true) {
        sched.mu.lock();
        const idle = !stream.busy and !stream.queued;
        sched.mu.unlock();
        if (idle) return;
        if (sys_clock.milliTimestamp() >= deadline) return error.DecoderDidNotBecomeIdle;
        sys_clock.sleep(100 * std.time.ns_per_us);
    }
}

test "transport latency: a new target supersedes an in-flight backend seek" {
    var decoder: Decoder = .{};
    decoder.seek_gate.closed.store(true, .release);
    const sched = try ds.DecodeScheduler.init(alloc, 1, false);
    defer sched.deinit();
    const stream = try sched.registerStream(ts.backend(&decoder));
    defer sched.unregisterStream(stream);
    defer decoder.seek_gate.open();
    sched.requestSeek(stream, 1.0);
    try std.testing.expect(waitFor(&decoder.seek_gate.entered));
    const Replace = struct {
        sched: *ds.DecodeScheduler,
        stream: ds.StreamHandle,
        fn run(self: @This()) void {
            self.sched.requestSeek(self.stream, 2.0);
            self.sched.requestSeek(self.stream, 0.0);
        }
    };
    try callWhileBlocked(Replace{ .sched = sched, .stream = stream }, Replace.run, &decoder.seek_gate);
    try std.testing.expect(sched.seekState(stream).seeking);
    try std.testing.expect(sched.nextFrame(stream) == null);
    decoder.seek_gate.open();
    const frame = try nextFrame(sched, stream);
    defer frame.release();
    try std.testing.expectEqual(0, frame.height);
    try std.testing.expectEqual(@as(u32, 2), decoder.seeks.load(.monotonic));
}

test "transport latency: audio tick does not wait for the rest of a new video batch" {
    var decoder: Decoder = .{ .has_audio = true, .block_frame = 1, .block_decode_after_seek = true };
    const sched = try ds.DecodeScheduler.init(alloc, 1, false);
    defer sched.deinit();
    var controller: pc.PlaybackController = .init();
    defer controller.deinit();
    try controller.load(alloc, sched, ts.backend(&decoder), 0.0);
    controller.play(.{ .ms = 0 });
    defer decoder.decode_gate.open();
    try std.testing.expect(waitFor(&decoder.decode_gate.entered));
    try std.testing.expect(!sched.seekState(controller.stream.?).seeking); // frame zero is ready
    const Tick = struct {
        c: *pc.PlaybackController,
        sink: Sink = .{},
        index: i32 = -1,
        fn run(self: *@This()) void {
            if (self.c.tick(0.0, .{ .ms = 1000 }, self.sink.sink())) |frame| {
                self.index = frame.height;
                frame.release();
            }
        }
    };
    var tick: Tick = .{ .c = &controller };
    try callWhileBlocked(&tick, Tick.run, &decoder.decode_gate);
    try std.testing.expectEqual(0, tick.index);
    try std.testing.expectEqual(@as(f64, 0), controller.mediaTime());
    try std.testing.expectEqual(@as(u32, 0), decoder.audio_pulls.load(.monotonic));
    try std.testing.expect(controller.playing);
}

test "transport latency: failed async rewind stops without delivering stale audio" {
    var decoder: Decoder = .{ .has_audio = true, .seek_succeeds = false };
    const sched = try ds.DecodeScheduler.init(alloc, 1, false);
    defer sched.deinit();
    var controller: pc.PlaybackController = .init();
    defer controller.deinit();
    try controller.load(alloc, sched, ts.backend(&decoder), 0.0);
    controller.play(.{ .ms = 0 });
    var sink: Sink = .{};
    const deadline = sys_clock.milliTimestamp() + 5000;
    while (controller.playing) {
        try std.testing.expect(controller.tick(1.0, .{ .ms = 1000 }, sink.sink()) == null);
        if (sys_clock.milliTimestamp() >= deadline) return error.FailedSeekDidNotStop;
        sys_clock.sleep(100 * std.time.ns_per_us);
    }
    try std.testing.expectEqual(@as(usize, 0), sink.calls);
    try std.testing.expectEqual(@as(u32, 0), decoder.audio_pulls.load(.monotonic));
    try std.testing.expectEqual(@as(f64, 0), controller.mediaTime());
    var warnings = controller.takeWarnings();
    defer {
        for (warnings.items) |warning| alloc.free(warning);
        warnings.deinit(alloc);
    }
    try std.testing.expectEqual(@as(usize, 1), warnings.items.len);
    try std.testing.expect(std.mem.indexOf(u8, warnings.items[0], "seek failed") != null);
}

test "transport latency: seek flush release hooks keep backend alive during teardown" {
    var decoder: Decoder = .{};
    const sched = try ds.DecodeScheduler.init(alloc, 1, false);
    defer sched.deinit();
    const stream = try sched.registerStream(ts.backend(&decoder));
    try waitIdle(sched, stream);
    decoder.release_gate.closed.store(true, .release);
    const Flush = struct {
        sched: *ds.DecodeScheduler,
        stream: ds.StreamHandle,
        fn run(self: @This()) void {
            self.sched.requestSeek(self.stream, 0.0);
        }
    };
    const flush = try std.Thread.spawn(.{}, Flush.run, .{Flush{ .sched = sched, .stream = stream }});
    defer flush.join();
    defer decoder.release_gate.open();
    try std.testing.expect(waitFor(&decoder.release_gate.entered));
    // Let the new decode batch finish so busy cannot mask a missing retire claim.
    try waitIdle(sched, stream);
    const Teardown = struct {
        sched: *ds.DecodeScheduler,
        stream: ds.StreamHandle,
        entered: std.atomic.Value(bool) = .init(false),
        fn run(self: *@This()) void {
            self.entered.store(true, .release);
            self.sched.unregisterStream(self.stream);
        }
    };
    var teardown: Teardown = .{ .sched = sched, .stream = stream };
    const unregister = try std.Thread.spawn(.{}, Teardown.run, .{&teardown});
    defer unregister.join();
    // Deliberately a second open(): defers run LIFO, so this one must release the
    // flush thread's hook before unregister.join() waits on its retire claim.
    defer decoder.release_gate.open();
    try std.testing.expect(waitFor(&teardown.entered));
    // Negative assertion: teardown must stay parked in unregisterStream while the
    // release hook is mid-flight. Without a retire claim the decoder would be
    // destroyed here instead of blocking, which `destroyed` observes.
    sys_clock.sleep(10 * std.time.ns_per_ms);
    try std.testing.expect(!decoder.destroyed.load(.acquire));
}

test "transport latency: seek requests coalesce without waiting for in-flight decode" {
    var decoder: Decoder = .{};
    decoder.decode_gate.closed.store(true, .release);
    const sched = try ds.DecodeScheduler.init(alloc, 1, false);
    defer sched.deinit();
    const stream = try sched.registerStream(ts.backend(&decoder));
    defer sched.unregisterStream(stream);
    defer decoder.decode_gate.open();
    try std.testing.expect(waitFor(&decoder.decode_gate.entered));

    const Request = struct {
        sched: *ds.DecodeScheduler,
        stream: ds.StreamHandle,
        fn run(self: @This()) void {
            self.sched.requestSeek(self.stream, 1.0);
            self.sched.requestSeek(self.stream, 0.0);
            self.sched.requestSeek(self.stream, 2.0);
        }
    };
    try callWhileBlocked(Request{ .sched = sched, .stream = stream }, Request.run, &decoder.decode_gate);
    try std.testing.expect(sched.nextFrame(stream) == null);
    try std.testing.expect(!sched.atEnd(stream));
    decoder.decode_gate.open();
    const frame = try nextFrame(sched, stream);
    defer frame.release();
    try std.testing.expectEqual(60, frame.height); // never the in-flight frame 0
    try std.testing.expectEqual(@as(u32, 1), decoder.seeks.load(.monotonic));
    try std.testing.expectEqual(@as(i32, 60), decoder.last_target.load(.monotonic));
    try std.testing.expect(decoder.releases.load(.monotonic) >= 1);
}

test "transport latency: play, seek zero and repeated stop do not wait for decode" {
    var decoder: Decoder = .{};
    decoder.decode_gate.closed.store(true, .release);
    const sched = try ds.DecodeScheduler.init(alloc, 1, false);
    defer sched.deinit();
    var controller: pc.PlaybackController = .init();
    defer controller.deinit();
    try controller.load(alloc, sched, ts.backend(&decoder), 0.0);
    defer decoder.decode_gate.open();
    try std.testing.expect(waitFor(&decoder.decode_gate.entered));

    const Commands = struct {
        fn run(c: *pc.PlaybackController) void {
            c.play(.{ .ms = 0 });
            c.seek(0.0, .{ .ms = 1000 });
            c.stop();
            c.stop();
            c.play(.{ .ms = 2000 });
        }
    };
    try callWhileBlocked(&controller, Commands.run, &decoder.decode_gate);
    sched.mu.lock();
    const generation = controller.stream.?.seek_generation;
    sched.mu.unlock();
    // play, seek(0), and the first stop each request a rewind. The second
    // stop and subsequent play must reuse the already-prepared start.
    try std.testing.expectEqual(@as(u64, 3), generation);
    var sink: Sink = .{};
    try std.testing.expect(controller.tick(1.0, .{ .ms = 3000 }, sink.sink()) == null);
    try std.testing.expectEqual(@as(f64, 0), controller.mediaTime());
    try std.testing.expect(controller.playing);
    decoder.decode_gate.open();

    const deadline = sys_clock.milliTimestamp() + 5000;
    while (true) {
        if (controller.tick(0.0, .{ .ms = 3000 }, sink.sink())) |frame| {
            frame.release();
            try std.testing.expectEqual(0, frame.height);
            break;
        }
        if (sys_clock.milliTimestamp() >= deadline) return error.RestartTimedOut;
        sys_clock.sleep(100 * std.time.ns_per_us);
    }
    controller.shutdown();
    try std.testing.expectEqual(@as(i32, 0), decoder.live.load(.monotonic));
}

test "transport latency: EOS restart holds the clock while backend seek is blocked" {
    var decoder: Decoder = .{};
    const sched = try ds.DecodeScheduler.init(alloc, 1, false);
    defer sched.deinit();
    var controller: pc.PlaybackController = .init();
    defer controller.deinit();
    try controller.load(alloc, sched, ts.backend(&decoder), 0.0);
    controller.play(.{ .ms = 0 });
    var sink: Sink = .{};
    const deadline = sys_clock.milliTimestamp() + 5000;
    while (controller.playing) {
        if (controller.tick(1.0, .{ .ms = 1000 }, sink.sink())) |frame| frame.release();
        if (sys_clock.milliTimestamp() >= deadline) return error.EosTimedOut;
        sys_clock.sleep(100 * std.time.ns_per_us);
    }

    decoder.seek_gate.closed.store(true, .release);
    defer decoder.seek_gate.open();
    const Replay = struct {
        fn run(c: *pc.PlaybackController) void {
            c.play(.{ .ms = 2000 });
        }
    };
    try callWhileBlocked(&controller, Replay.run, &decoder.seek_gate);
    try std.testing.expect(waitFor(&decoder.seek_gate.entered));
    for (0..5) |_| {
        try std.testing.expect(controller.tick(0.5, .{ .ms = 3000 }, sink.sink()) == null);
        try std.testing.expectEqual(@as(f64, 0), controller.mediaTime());
        try std.testing.expect(controller.playing);
    }
    decoder.seek_gate.open();
    const frame = try nextFrame(sched, controller.stream.?);
    frame.release();
    try std.testing.expectEqual(0, frame.height);
    controller.shutdown();
    try std.testing.expectEqual(@as(i32, 0), decoder.live.load(.monotonic));
}

test "transport latency: superseded decoder EOS cannot end a pending rewind" {
    var decoder: Decoder = .{ .cursor = 90 };
    decoder.decode_gate.closed.store(true, .release);
    decoder.seek_gate.closed.store(true, .release);
    const sched = try ds.DecodeScheduler.init(alloc, 1, false);
    defer sched.deinit();
    const stream = try sched.registerStream(ts.backend(&decoder));
    defer sched.unregisterStream(stream);
    defer decoder.seek_gate.open();
    defer decoder.decode_gate.open();
    try std.testing.expect(waitFor(&decoder.decode_gate.entered));
    const Rewind = struct {
        sched: *ds.DecodeScheduler,
        stream: ds.StreamHandle,
        fn run(self: @This()) void {
            self.sched.requestSeek(self.stream, 0.0);
        }
    };
    try callWhileBlocked(Rewind{ .sched = sched, .stream = stream }, Rewind.run, &decoder.decode_gate);
    decoder.decode_gate.open();
    try std.testing.expect(waitFor(&decoder.seek_gate.entered));
    try std.testing.expect(!sched.atEnd(stream));
    decoder.seek_gate.open();
    const frame = try nextFrame(sched, stream);
    defer frame.release();
    try std.testing.expectEqual(0, frame.height);
}

test "transport latency: rewind into immediate EOS clears seeking and ends playback" {
    // cursor starts past the decoder's end, so the rewind's seek succeeds and
    // the very first nextVideoFrame() reports EOS. `seeking` must clear through
    // that branch too -- otherwise the controller would hold a frozen clock.
    var decoder: Decoder = .{ .cursor = end_index, .eos_after_seek = true };
    const sched = try ds.DecodeScheduler.init(alloc, 1, false);
    defer sched.deinit();
    var controller: pc.PlaybackController = .init();
    defer controller.deinit();
    try controller.load(alloc, sched, ts.backend(&decoder), 0.0);
    controller.play(.{ .ms = 0 });

    var sink: Sink = .{};
    const deadline = sys_clock.milliTimestamp() + 5000;
    while (controller.playing) {
        try std.testing.expect(controller.tick(1.0, .{ .ms = 1000 }, sink.sink()) == null);
        if (sys_clock.milliTimestamp() >= deadline) return error.EosLoopDidNotStop;
        sys_clock.sleep(100 * std.time.ns_per_us);
    }
    const seek = sched.seekState(controller.stream.?);
    try std.testing.expect(!seek.seeking and !seek.failed);
    try std.testing.expect(sched.atEnd(controller.stream.?));
    try std.testing.expectEqual(@as(f64, 0), controller.position); // nothing presented
    try std.testing.expectEqual(@as(usize, 0), sink.calls);
    controller.shutdown();
    try std.testing.expectEqual(@as(i32, 0), decoder.live.load(.monotonic));
}

test "transport latency: a failed prepared rewind does not swallow the next play" {
    // stop() arms the rewind; when it fails the scheduler latches seek_failed
    // until the next seek. play() must not reuse that dead rewind, or the first
    // play after a failed rewind silently ends playback with nothing restarting.
    var decoder: Decoder = .{ .seek_succeeds = false };
    const sched = try ds.DecodeScheduler.init(alloc, 1, false);
    defer sched.deinit();
    var controller: pc.PlaybackController = .init();
    defer controller.deinit();
    try controller.load(alloc, sched, ts.backend(&decoder), 0.0);
    controller.play(.{ .ms = 0 });

    controller.stop(); // arms the rewind, which fails
    const deadline = sys_clock.milliTimestamp() + 5000;
    while (sched.seekState(controller.stream.?).seeking) {
        if (sys_clock.milliTimestamp() >= deadline) return error.FailedSeekDidNotSettle;
        sys_clock.sleep(100 * std.time.ns_per_us);
    }
    try std.testing.expect(sched.seekState(controller.stream.?).failed);
    sched.mu.lock();
    const armed_generation = controller.stream.?.seek_generation;
    sched.mu.unlock();

    // The next play() must re-resolve: that clears the latch and queues a fresh
    // rewind instead of ticking against a permanently failed stream.
    controller.play(.{ .ms = 1000 });
    try std.testing.expect(!sched.seekState(controller.stream.?).failed);
    sched.mu.lock();
    const replayed_generation = controller.stream.?.seek_generation;
    sched.mu.unlock();
    try std.testing.expectEqual(armed_generation + 1, replayed_generation);

    controller.shutdown();
    try std.testing.expectEqual(@as(i32, 0), decoder.live.load(.monotonic));
}

test "transport latency: a seek that never completes is abandoned, not frozen" {
    // Frame 0 arrives (so the rewind itself lands), then the worker wedges in
    // nextVideoFrame(). The render loop must warn and stop delivery rather than
    // hold the last image and clock forever with no diagnostic.
    var decoder: Decoder = .{ .block_frame = 1 };
    decoder.decode_gate.closed.store(true, .release);
    const sched = try ds.DecodeScheduler.init(alloc, 1, false);
    defer sched.deinit();
    var controller: pc.PlaybackController = .init();
    defer controller.deinit();
    try controller.load(alloc, sched, ts.backend(&decoder), 0.0);
    defer decoder.decode_gate.open();
    controller.play(.{ .ms = 0 });
    try std.testing.expect(waitFor(&decoder.decode_gate.entered));

    // A rewind requested while the decoder is wedged can only sit pending, and
    // the request itself must still return immediately.
    const Seek = struct {
        fn run(c: *pc.PlaybackController) void {
            c.seek(0.0, .{ .ms = 1000 });
        }
    };
    try callWhileBlocked(&controller, Seek.run, &decoder.decode_gate);
    try std.testing.expect(sched.seekState(controller.stream.?).seeking);

    var sink: Sink = .{};
    // Inside the stall window: hold the image, keep playing.
    try std.testing.expect(controller.tick(0.0, .{ .ms = 2000 }, sink.sink()) == null);
    try std.testing.expect(controller.playing);
    // Past it: delivery is abandoned, once.
    try std.testing.expect(controller.tick(0.0, .{ .ms = 2000 + 5001 }, sink.sink()) == null);
    try std.testing.expect(!controller.playing);
    try std.testing.expect(controller.tick(0.0, .{ .ms = 12000 }, sink.sink()) == null);

    var warnings = controller.takeWarnings();
    defer {
        for (warnings.items) |warning| alloc.free(warning);
        warnings.deinit(alloc);
    }
    try std.testing.expectEqual(@as(usize, 1), warnings.items.len);
    try std.testing.expect(std.mem.indexOf(u8, warnings.items[0], "did not complete") != null);

    decoder.decode_gate.open(); // unblock the worker before teardown
    controller.shutdown();
    try std.testing.expectEqual(@as(i32, 0), decoder.live.load(.monotonic));
}

test "transport latency: audio fill takes one blocking claim only when the ring runs low" {
    // Frame 0 is ready and the worker wedges on frame 1 holding the claim, so
    // every audio fill misses. A miss is harmless while the ring is buffered;
    // once it has drained, one bounded wait beats an audible gap.
    var decoder: Decoder = .{ .has_audio = true, .block_frame = 1, .block_decode_after_seek = true };
    const sched = try ds.DecodeScheduler.init(alloc, 1, false);
    defer sched.deinit();
    var controller: pc.PlaybackController = .init();
    defer controller.deinit();
    try controller.load(alloc, sched, ts.backend(&decoder), 0.0);
    defer decoder.decode_gate.open();
    try std.testing.expect(controller.has_audio);
    controller.play(.{ .ms = 0 });
    // The rewind's seek closes the decode gate, so the worker is wedged on the
    // frame after the first published one and holds the claim.
    try std.testing.expect(waitFor(&decoder.decode_gate.entered));
    try std.testing.expect(!sched.seekState(controller.stream.?).seeking);

    var sink: Sink = .{};
    // The ring is empty but the miss budget is unspent, so these ticks must not
    // wait for the decoder.
    for (0..3) |_| {
        if (controller.tick(0.0, .{ .ms = 1000 }, sink.sink())) |frame| frame.release();
    }
    try std.testing.expectEqual(@as(u32, 0), decoder.audio_pulls.load(.monotonic));

    // The next miss exhausts the budget, so the fill falls back to a blocking
    // claim: it cannot return until the worker releases busy.
    const Fallback = struct {
        c: *pc.PlaybackController,
        sink: Sink = .{},
        done: std.atomic.Value(bool) = .init(false),
        fn run(self: *@This()) void {
            if (self.c.tick(0.0, .{ .ms = 1000 }, self.sink.sink())) |frame| frame.release();
            self.done.store(true, .release);
        }
    };
    var fallback: Fallback = .{ .c = &controller };
    const thread = try std.Thread.spawn(.{}, Fallback.run, .{&fallback});
    sys_clock.sleep(50 * std.time.ns_per_ms);
    const waited = !fallback.done.load(.acquire);
    decoder.decode_gate.open();
    thread.join();
    try std.testing.expect(waited);
    try std.testing.expect(fallback.done.load(.acquire));
    // The blocking claim did run the closure; this fixture then reports audio EOS.
    try std.testing.expectEqual(@as(u32, 1), decoder.audio_pulls.load(.monotonic));
    try std.testing.expect(controller.audio_eos);

    controller.shutdown();
    try std.testing.expectEqual(@as(i32, 0), decoder.live.load(.monotonic));
}
