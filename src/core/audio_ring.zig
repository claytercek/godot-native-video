//! AudioRing — Godot-free interleaved-PCM ring buffer for the audio path.
//!
//! The decode side pushes interleaved float32 samples decoded from the
//! backend (backend.AudioChunk.samples) into the ring; the mix side drains
//! them into the buffer Godot hands us. Keeping this here (no Godot types)
//! makes the partial-read / underrun behaviour unit-testable without an
//! AudioServer.
//!
//! Units: a "frame" is one sample per channel. The ring stores raw
//! interleaved floats and tracks channel count so frame<->float arithmetic
//! stays correct.
//!
//! Threading: this is intended for a single producer (decode pump) and single
//! consumer (mix), but unlike FrameQueue it is NOT lock-free — in the
//! binding, audio is pumped and drained from the same place inside _update on
//! the main thread for this slice (the shared decode-worker pool is a later
//! slice). A small ring of plain floats is enough; we guard nothing here and
//! document the single-thread assumption.
//!
//! Behaviour contract (the acceptance criterion: "handle partial
//! reads/underrun gracefully, output silence on underrun, never block"):
//!   * write() drops samples that don't fit (returns the count actually
//!     stored) rather than blocking or growing unboundedly.
//!   * readFrames() fills as many frames as are available, ZERO-FILLS the
//!     rest (silence on underrun), and reports how many real frames it
//!     produced.

const std = @import("std");

pub const AudioRing = struct {
    channels: i32,
    capacity_floats: usize,
    buffer: []f32,
    head: usize,
    tail: usize,
    allocator: std.mem.Allocator,

    /// `channel_count` interleaved channels; `frame_capacity` frames of
    /// head-room.
    pub fn init(allocator: std.mem.Allocator, channel_count: i32, frame_capacity: usize) !AudioRing {
        const channels: i32 = @max(channel_count, 1);
        const capacity_floats = (frame_capacity + 1) * @as(usize, @intCast(channels));
        const buffer = try allocator.alloc(f32, capacity_floats);
        @memset(buffer, 0.0);
        return .{
            .channels = channels,
            .capacity_floats = capacity_floats,
            .buffer = buffer,
            .head = 0,
            .tail = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *AudioRing) void {
        self.allocator.free(self.buffer);
    }

    pub fn channelCount(self: AudioRing) i32 {
        return self.channels;
    }

    fn floatsAvailable(self: AudioRing) usize {
        return (self.tail + self.capacity_floats - self.head) % self.capacity_floats;
    }

    /// Number of whole frames currently buffered.
    pub fn availableFrames(self: AudioRing) usize {
        return self.floatsAvailable() / @as(usize, @intCast(self.channels));
    }

    /// Free frames before the ring is full.
    pub fn freeFrames(self: AudioRing) usize {
        // capacity_floats includes one sentinel frame to distinguish full/empty.
        const free_floats = self.capacity_floats - 1 - self.floatsAvailable();
        return free_floats / @as(usize, @intCast(self.channels));
    }

    pub fn empty(self: AudioRing) bool {
        return self.head == self.tail;
    }

    /// Drop everything (e.g. on seek / stop) so stale audio never plays.
    pub fn clear(self: *AudioRing) void {
        self.head = 0;
        self.tail = 0;
    }

    /// Write `frame_count` frames of interleaved samples (frame_count *
    /// channels floats). Stores as many whole frames as fit; returns frames
    /// stored.
    pub fn write(self: *AudioRing, interleaved: []const f32, frame_count: usize) usize {
        const n = @min(frame_count, self.freeFrames());
        const floats = n * @as(usize, @intCast(self.channels));
        const src = interleaved[0..floats];
        // Bulk copy in at most two segments (before/after the wrap point).
        const first = @min(src.len, self.capacity_floats - self.tail);
        @memcpy(self.buffer[self.tail..][0..first], src[0..first]);
        @memcpy(self.buffer[0 .. src.len - first], src[first..]);
        self.tail = (self.tail + floats) % self.capacity_floats;
        return n;
    }

    /// Copy up to `frame_count` frames into `out` (frame_count * channels
    /// floats) WITHOUT consuming them — the read cursor is left untouched.
    /// Frames not available are written as silence (0.0). Returns the number
    /// of REAL (non-silence) frames copied.
    ///
    /// Pairs with consume(): a caller offers the peeked frames to a
    /// back-pressured sink, then consumes exactly the count the sink accepted,
    /// so frames the sink rejects stay buffered instead of being dropped.
    pub fn peekFrames(self: *AudioRing, out: []f32, frame_count: usize) usize {
        const ch: usize = @intCast(self.channels);
        const real = @min(frame_count, self.availableFrames());
        const floats = real * ch;
        // Bulk copy out in at most two segments (before/after the wrap point).
        const first = @min(floats, self.capacity_floats - self.head);
        @memcpy(out[0..first], self.buffer[self.head..][0..first]);
        @memcpy(out[first..floats], self.buffer[0 .. floats - first]);
        // Zero-fill the underrun tail.
        @memset(out[floats .. frame_count * ch], 0.0);
        return real;
    }

    /// Advance the read cursor by up to `frame_count` frames, dropping them
    /// from the ring. Returns the number of frames actually consumed
    /// (min(frame_count, availableFrames)).
    pub fn consume(self: *AudioRing, frame_count: usize) usize {
        const ch: usize = @intCast(self.channels);
        const n = @min(frame_count, self.availableFrames());
        self.head = (self.head + n * ch) % self.capacity_floats;
        return n;
    }

    /// Drain up to `frame_count` frames into `out` (frame_count * channels
    /// floats): a peekFrames() followed by consuming every real frame it
    /// produced. Frames not available are written as silence (0.0). Returns
    /// the number of REAL (non-silence) frames produced.
    pub fn readFrames(self: *AudioRing, out: []f32, frame_count: usize) usize {
        const real = self.peekFrames(out, frame_count);
        _ = self.consume(real);
        return real;
    }
};

test "AudioRing starts empty" {
    var r = try AudioRing.init(std.testing.allocator, 2, 1024);
    defer r.deinit();
    try std.testing.expectEqual(2, r.channelCount());
    try std.testing.expect(r.empty());
    try std.testing.expectEqual(0, r.availableFrames());
}

test "AudioRing round-trips interleaved stereo frames" {
    var r = try AudioRing.init(std.testing.allocator, 2, 64);
    defer r.deinit();
    // 3 stereo frames: L,R per frame.
    const in = [_]f32{ 1, 2, 3, 4, 5, 6 };
    try std.testing.expectEqual(3, r.write(&in, 3));
    try std.testing.expectEqual(3, r.availableFrames());

    var out = [_]f32{-1.0} ** 6;
    try std.testing.expectEqual(3, r.readFrames(&out, 3));
    try std.testing.expectEqualSlices(f32, &in, &out);
    try std.testing.expect(r.empty());
}

test "AudioRing underrun produces silence and reports real frame count" {
    var r = try AudioRing.init(std.testing.allocator, 1, 64);
    defer r.deinit();
    const in = [_]f32{ 7, 8 };
    try std.testing.expectEqual(2, r.write(&in, 2));

    var out = [_]f32{99.0} ** 5;
    // Ask for 5 mono frames but only 2 are available.
    const real = r.readFrames(&out, 5);
    try std.testing.expectEqual(2, real);
    try std.testing.expectApproxEqAbs(7.0, out[0], 1e-6);
    try std.testing.expectApproxEqAbs(8.0, out[1], 1e-6);
    // Underrun tail is silence.
    try std.testing.expectApproxEqAbs(0.0, out[2], 1e-6);
    try std.testing.expectApproxEqAbs(0.0, out[3], 1e-6);
    try std.testing.expectApproxEqAbs(0.0, out[4], 1e-6);
}

test "AudioRing full read on empty ring is all silence" {
    var r = try AudioRing.init(std.testing.allocator, 2, 16);
    defer r.deinit();
    var out = [_]f32{1.0} ** 8;
    try std.testing.expectEqual(0, r.readFrames(&out, 4));
    for (out) |v| {
        try std.testing.expectApproxEqAbs(0.0, v, 1e-6);
    }
}

test "AudioRing write drops samples that do not fit (never grows/blocks)" {
    var r = try AudioRing.init(std.testing.allocator, 1, 4); // 4 frames of head-room
    defer r.deinit();
    const in = [_]f32{ 1, 2, 3, 4, 5, 6 };
    const stored = r.write(&in, 6);
    try std.testing.expect(stored <= 4);
    try std.testing.expectEqual(stored, r.availableFrames());
}

test "AudioRing clear discards buffered audio" {
    var r = try AudioRing.init(std.testing.allocator, 2, 32);
    defer r.deinit();
    const in = [_]f32{ 1, 2, 3, 4 };
    _ = r.write(&in, 2);
    try std.testing.expectEqual(2, r.availableFrames());
    r.clear();
    try std.testing.expect(r.empty());
    try std.testing.expectEqual(0, r.availableFrames());
}

// -----------------------------------------------------------------------
// Fuzz: arbitrary write/read/clear sequences against a simple frame-count
// oracle. Pins the whole behaviour contract: stored == min(requested, free),
// real == min(requested, available), real frames come back as written,
// the underrun tail is silence, and accounting never drifts. Run with
// `zig build test --fuzz` for real fuzzing; a normal run does a smoke pass.
// -----------------------------------------------------------------------

test "fuzz: AudioRing accounting matches a frame-count oracle" {
    try std.testing.fuzz({}, fuzzAudioRing, .{});
}

fn fuzzAudioRing(_: void, smith: *std.testing.Smith) anyerror!void {
    const max_op_frames = 64;
    const max_channels = 8;

    const channels = smith.valueRangeAtMost(i32, 1, max_channels);
    const frame_capacity = @as(usize, smith.valueRangeAtMost(u8, 0, 200));
    var ring = try AudioRing.init(std.testing.allocator, channels, frame_capacity);
    defer ring.deinit();

    const ch: usize = @intCast(channels);
    const in: [max_op_frames * max_channels]f32 = @splat(1.0); // real == 1.0, silence == 0.0
    var out: [max_op_frames * max_channels]f32 = undefined;

    const Action = enum { write, read, clear };
    var model_frames: usize = 0; // oracle: frames the ring must be holding

    while (!smith.eosWeightedSimple(15, 1)) {
        switch (smith.value(Action)) {
            .write => {
                const n = @as(usize, smith.valueRangeAtMost(u8, 0, max_op_frames));
                const free = ring.freeFrames();
                const stored = ring.write(in[0 .. n * ch], n);
                try std.testing.expectEqual(@min(n, free), stored);
                model_frames += stored;
            },
            .read => {
                const n = @as(usize, smith.valueRangeAtMost(u8, 0, max_op_frames));
                @memset(out[0 .. n * ch], -1.0);
                const real = ring.readFrames(out[0 .. n * ch], n);
                try std.testing.expectEqual(@min(n, model_frames), real);
                model_frames -= real;
                // Real frames come back exactly as written...
                for (out[0 .. real * ch]) |v| try std.testing.expectEqual(1.0, v);
                // ...and the underrun tail is silence, never stale data.
                for (out[real * ch .. n * ch]) |v| try std.testing.expectEqual(0.0, v);
            },
            .clear => {
                ring.clear();
                model_frames = 0;
            },
        }
        try std.testing.expectEqual(model_frames, ring.availableFrames());
        try std.testing.expectEqual(model_frames == 0, ring.empty());
    }
}

test "AudioRing peekFrames copies without consuming; consume advances exactly" {
    var r = try AudioRing.init(std.testing.allocator, 6, 64);
    defer r.deinit();
    // 2 six-channel frames.
    const in = [_]f32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 };
    try std.testing.expectEqual(2, r.write(&in, 2));

    // Peek both frames — the cursor must not move.
    var out = [_]f32{-1.0} ** 12;
    try std.testing.expectEqual(2, r.peekFrames(&out, 2));
    try std.testing.expectEqualSlices(f32, &in, &out);
    try std.testing.expectEqual(2, r.availableFrames());

    // A second peek returns identical data (proves non-destructive).
    var out2 = [_]f32{0.0} ** 12;
    try std.testing.expectEqual(2, r.peekFrames(&out2, 2));
    try std.testing.expectEqualSlices(f32, &in, &out2);

    // Consume ONE frame; the second must remain buffered and readable.
    try std.testing.expectEqual(1, r.consume(1));
    try std.testing.expectEqual(1, r.availableFrames());
    var out3 = [_]f32{0.0} ** 6;
    try std.testing.expectEqual(1, r.peekFrames(&out3, 1));
    try std.testing.expectEqualSlices(f32, in[6..12], &out3);
}

test "AudioRing consume never advances past what is available" {
    var r = try AudioRing.init(std.testing.allocator, 2, 16);
    defer r.deinit();
    const in = [_]f32{ 1, 2, 3, 4 }; // 2 stereo frames
    _ = r.write(&in, 2);
    // Asking to consume more than buffered drains only the 2 available.
    try std.testing.expectEqual(2, r.consume(100));
    try std.testing.expect(r.empty());
    try std.testing.expectEqual(0, r.consume(10)); // nothing left
}

test "AudioRing 6ch chunked fill + back-pressure conserves every decoded frame" {
    // Ring-level reproduction of the cross-platform "audio too fast + choppy"
    // bug. A 6-channel ring is topped up to a half-fill target in 1024-frame
    // chunks (exactly fillAudioClosure's `while freeFrames() > availableFrames()`
    // loop), then a back-pressured sink accepts only ~1/6 of the offered frames
    // each round (the 6-channel case). The fixed drain path — peekFrames() then
    // consume() ONLY the accepted count — must never drop a decoded frame:
    // everything pulled is stored, and everything stored is either consumed or
    // still buffered. The ring must also stay bounded and the fill loop must
    // stop below capacity.
    const channels = 6;
    const capacity_frames = 24000; // canonical_sample_rate/2, as sized in load()
    var r = try AudioRing.init(std.testing.allocator, channels, capacity_frames);
    defer r.deinit();

    const chunk_frames = 1024;
    const chunk: [chunk_frames * channels]f32 = @splat(0.25);

    var total_pulled: usize = 0; // frames the "reader" produced (== stored, no drops)
    var total_consumed: usize = 0; // frames the sink accepted

    var drain: [4096 * channels]f32 = undefined;

    var round: usize = 0;
    while (round < 500) : (round += 1) {
        // Fill side: top up to the half-fill target in whole chunks. The loop
        // stops before the ring is full, so every chunk is stored intact — the
        // fill loop never pulls more than the ring can hold.
        while (r.freeFrames() > r.availableFrames()) {
            const stored = r.write(&chunk, chunk_frames);
            try std.testing.expectEqual(chunk_frames, stored); // no partial/dropped chunk
            total_pulled += stored;
        }
        // Stopped at the half-fill target: bounded, and below capacity.
        try std.testing.expect(r.availableFrames() <= capacity_frames);
        try std.testing.expect(r.freeFrames() <= r.availableFrames());

        // Drive side: offer up to 4096 frames; the sink accepts only ~1/6.
        // Consume ONLY the accepted count — the surplus stays buffered.
        const request = @min(r.availableFrames(), 4096);
        const real = r.peekFrames(drain[0 .. request * channels], request);
        try std.testing.expectEqual(request, real);
        const accepted = real / 6; // per-channel back-pressure
        try std.testing.expectEqual(accepted, r.consume(accepted));
        total_consumed += accepted;
    }

    // Conservation: every pulled frame is accounted for — consumed or buffered.
    // Nothing vanished (the defect dropped ~5/6 of every offered block here).
    try std.testing.expectEqual(total_pulled, total_consumed + r.availableFrames());
}

test "AudioRing wraps around correctly" {
    var r = try AudioRing.init(std.testing.allocator, 1, 8);
    defer r.deinit();
    const a = [_]f32{ 1, 2, 3, 4, 5, 6 };
    _ = r.write(&a, 6);
    var out = [_]f32{0.0} ** 4;
    _ = r.readFrames(&out, 4); // consume 4 -> head advances
    // Now write 6 more, forcing wrap-around past the buffer end.
    const b = [_]f32{ 10, 11, 12, 13, 14, 15 };
    const stored = r.write(&b, 6);
    // remaining: {5,6} + as many of b as fit.
    var drained = [_]f32{0.0} ** 16;
    const real = r.readFrames(&drained, 2 + stored);
    try std.testing.expectEqual(2 + stored, real);
    try std.testing.expectApproxEqAbs(5.0, drained[0], 1e-6);
    try std.testing.expectApproxEqAbs(6.0, drained[1], 1e-6);
    try std.testing.expectApproxEqAbs(10.0, drained[2], 1e-6);
}
