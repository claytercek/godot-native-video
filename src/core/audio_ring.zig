//! audio_ring.zig — port of src/core/audio_ring.h.
//!
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

    /// Drain up to `frame_count` frames into `out` (frame_count * channels
    /// floats). Frames not available are written as silence (0.0). Returns
    /// the number of REAL (non-silence) frames produced — the caller uses
    /// this to advance the master clock by exactly what the listener will
    /// hear.
    pub fn readFrames(self: *AudioRing, out: []f32, frame_count: usize) usize {
        const ch: usize = @intCast(self.channels);
        const real = @min(frame_count, self.availableFrames());
        const floats = real * ch;
        // Bulk copy out in at most two segments (before/after the wrap point).
        const first = @min(floats, self.capacity_floats - self.head);
        @memcpy(out[0..first], self.buffer[self.head..][0..first]);
        @memcpy(out[first..floats], self.buffer[0 .. floats - first]);
        self.head = (self.head + floats) % self.capacity_floats;
        // Zero-fill the underrun tail.
        @memset(out[floats .. frame_count * ch], 0.0);
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
