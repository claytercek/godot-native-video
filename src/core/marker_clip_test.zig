//! marker_clip_test.zig — port of tests/core/test_marker_clip.cpp.
//!
//! MarkerClipBackend — simulates a clip with mixed audio track channel counts
//! (a stereo commentary track + a 5.1 surround main track):
//!   Track 0: stereo (2 ch, 48000 Hz)
//!   Track 1: 5.1    (6 ch, 48000 Hz)
//! Verifies that after track selection the canonical channel count is
//! independent of which track is selected — the channel mixer converts whichever
//! native format the backend emits.

const std = @import("std");

const backend_mod = @import("backend.zig");
const channel_mixer = @import("channel_mixer.zig");
const ts = @import("test_support.zig");

const Backend = backend_mod.Backend;
const AudioChunk = backend_mod.AudioChunk;
const AudioTrackInfo = backend_mod.AudioTrackInfo;

const kTrackCount: i32 = 2;

const TrackInfoLocal = struct { channels: i32, sample_rate: i32 };

const MarkerClipBackend = struct {
    allocator: std.mem.Allocator,
    tracks: [2]TrackInfoLocal = .{
        .{ .channels = 2, .sample_rate = 48000 }, // Track 0: stereo
        .{ .channels = 6, .sample_rate = 48000 }, // Track 1: 5.1
    },
    selected: i32 = 0,
    chunks_pumped: i32 = 0,
    scratch: []f32 = &.{},

    fn create(allocator: std.mem.Allocator) *MarkerClipBackend {
        const self = allocator.create(MarkerClipBackend) catch @panic("oom");
        self.* = .{ .allocator = allocator };
        return self;
    }

    pub fn deinit(self: *MarkerClipBackend) void {
        if (self.scratch.len > 0) self.allocator.free(self.scratch);
        self.allocator.destroy(self);
    }
    pub fn videoWidth(_: *MarkerClipBackend) i32 {
        return 1920;
    }
    pub fn videoHeight(_: *MarkerClipBackend) i32 {
        return 1080;
    }
    // Single-track compat fields return track 0 (stereo).
    pub fn audioChannelCount(self: *MarkerClipBackend) i32 {
        return self.tracks[0].channels;
    }
    pub fn audioSampleRate(self: *MarkerClipBackend) i32 {
        return self.tracks[0].sample_rate;
    }
    pub fn audioTrackCount(_: *MarkerClipBackend) i32 {
        return kTrackCount;
    }
    pub fn audioTrackInfo(self: *MarkerClipBackend, index: i32) AudioTrackInfo {
        if (index < 0 or index >= kTrackCount) return .{};
        return .{
            .channels = self.tracks[@intCast(index)].channels,
            .sample_rate = self.tracks[@intCast(index)].sample_rate,
            .language = "en",
            .name = if (index == 0) "Commentary (Stereo)" else "Main (5.1)",
            .is_default = index == 0,
        };
    }
    pub fn selectAudioTrack(self: *MarkerClipBackend, index: i32) void {
        self.selected = index;
    }
    pub fn seek(self: *MarkerClipBackend, _: f64) bool {
        self.chunks_pumped = 0;
        return true;
    }
    pub fn nextAudioChunk(self: *MarkerClipBackend) ?AudioChunk {
        const track = self.selected;
        if (track < 0 or track >= kTrackCount) return null;
        const ch = self.tracks[@intCast(track)].channels;
        const rate = self.tracks[@intCast(track)].sample_rate;
        const frames: i32 = 256; // arbitrary chunk size

        // Deterministic, recognisable pattern: each channel gets a distinct value.
        const n: usize = @as(usize, @intCast(frames)) * @as(usize, @intCast(ch));
        if (self.scratch.len < n) {
            if (self.scratch.len > 0) self.allocator.free(self.scratch);
            self.scratch = self.allocator.alloc(f32, n) catch @panic("oom");
        }
        var f: usize = 0;
        while (f < @as(usize, @intCast(frames))) : (f += 1) {
            var c: usize = 0;
            while (c < @as(usize, @intCast(ch))) : (c += 1) {
                // Encode channel number in the lowest bits so the mixer's output
                // channel assignment is verifiable.
                self.scratch[f * @as(usize, @intCast(ch)) + c] =
                    0.1 * @as(f32, @floatFromInt(c + 1)) + 0.01 * @as(f32, @floatFromInt(self.chunks_pumped));
            }
        }
        self.chunks_pumped += 1;

        return .{
            .samples = self.scratch[0..n],
            .frame_count = frames,
            .channel_count = ch,
            .sample_rate = rate,
            .pts_seconds = @as(f64, @floatFromInt(self.chunks_pumped)) * 0.01,
        };
    }

    fn backend(self: *MarkerClipBackend) Backend {
        return ts.backend(self);
    }
};

test "MarkerClip canonical channels is max across tracks" {
    const be = MarkerClipBackend.create(std.testing.allocator);
    defer be.backend().deinit();
    const b = be.backend();
    try std.testing.expect(b.open("dummy"));

    var max_ch: i32 = 0;
    var max_rate: i32 = 0;
    var i: i32 = 0;
    while (i < b.audioTrackCount()) : (i += 1) {
        const info = b.audioTrackInfo(i);
        if (info.channels > max_ch) max_ch = info.channels;
        if (info.sample_rate > max_rate) max_rate = info.sample_rate;
    }

    // The canonical format is the max across all tracks.
    try std.testing.expectEqual(6, max_ch); // 5.1 track
    try std.testing.expectEqual(48000, max_rate);

    // The mixer knows how to handle this.
    try std.testing.expect(max_ch <= channel_mixer.max_mix_source_channels);
}

test "MarkerClip stereo track pumps 2ch chunks; mixer converts to 6ch" {
    const be = MarkerClipBackend.create(std.testing.allocator);
    defer be.backend().deinit();
    const b = be.backend();
    try std.testing.expect(b.open("dummy"));

    const canonical: i32 = 6; // max across tracks

    b.selectAudioTrack(0); // stereo
    _ = b.seek(0.0);

    // Pump a chunk from the backend (native stereo).
    const chunk = b.nextAudioChunk();
    try std.testing.expect(chunk != null);
    try std.testing.expectEqual(2, chunk.?.channel_count);
    try std.testing.expectEqual(256, chunk.?.frame_count);
    try std.testing.expectEqual(48000, chunk.?.sample_rate);

    // Mix from native (2ch) to canonical (6ch).
    const n: usize = @as(usize, @intCast(chunk.?.frame_count)) * @as(usize, @intCast(canonical));
    const mixed = try std.testing.allocator.alloc(f32, n);
    defer std.testing.allocator.free(mixed);
    @memset(mixed, 0.0);
    channel_mixer.mixChannels(chunk.?.samples, chunk.?.channel_count, mixed, canonical, chunk.?.frame_count);

    // Stereo -> 5.1: L -> L, R -> R; C, LFE, Ls, Rs should be silence.
    // For the first chunk (chunks_pumped_ = 0), values are 0.1 and 0.2.
    try std.testing.expectApproxEqAbs(0.1, mixed[0], 1e-5); // L
    try std.testing.expectApproxEqAbs(0.2, mixed[1], 1e-5); // R
    try std.testing.expectApproxEqAbs(0.0, mixed[2], 1e-5); // C
    try std.testing.expectApproxEqAbs(0.0, mixed[3], 1e-5); // LFE
    try std.testing.expectApproxEqAbs(0.0, mixed[4], 1e-5); // Ls
    try std.testing.expectApproxEqAbs(0.0, mixed[5], 1e-5); // Rs
}

test "MarkerClip 5.1 track pumps 6ch chunks; mixer passes through" {
    const be = MarkerClipBackend.create(std.testing.allocator);
    defer be.backend().deinit();
    const b = be.backend();
    try std.testing.expect(b.open("dummy"));

    const canonical: i32 = 6; // max across tracks

    b.selectAudioTrack(1); // 5.1
    _ = b.seek(0.0);

    // Pump a chunk from the backend (native 6ch).
    const chunk = b.nextAudioChunk();
    try std.testing.expect(chunk != null);
    try std.testing.expectEqual(6, chunk.?.channel_count);
    try std.testing.expectEqual(256, chunk.?.frame_count);

    // Mix from native (6ch) to canonical (6ch) — this is identity.
    const n: usize = @as(usize, @intCast(chunk.?.frame_count)) * @as(usize, @intCast(canonical));
    const mixed = try std.testing.allocator.alloc(f32, n);
    defer std.testing.allocator.free(mixed);
    @memset(mixed, 0.0);
    channel_mixer.mixChannels(chunk.?.samples, chunk.?.channel_count, mixed, canonical, chunk.?.frame_count);

    // For the first chunk, values are 0.1, 0.2, 0.3, 0.4, 0.5, 0.6.
    try std.testing.expectApproxEqAbs(0.1, mixed[0], 1e-5); // L
    try std.testing.expectApproxEqAbs(0.2, mixed[1], 1e-5); // R
    try std.testing.expectApproxEqAbs(0.3, mixed[2], 1e-5); // C
    try std.testing.expectApproxEqAbs(0.4, mixed[3], 1e-5); // LFE
    try std.testing.expectApproxEqAbs(0.5, mixed[4], 1e-5); // Ls
    try std.testing.expectApproxEqAbs(0.6, mixed[5], 1e-5); // Rs

    // Verify the second frame as well.
    try std.testing.expectApproxEqAbs(0.1, mixed[6], 1e-5);
    try std.testing.expectApproxEqAbs(0.2, mixed[7], 1e-5);
    try std.testing.expectApproxEqAbs(0.3, mixed[8], 1e-5);
    try std.testing.expectApproxEqAbs(0.4, mixed[9], 1e-5);
    try std.testing.expectApproxEqAbs(0.5, mixed[10], 1e-5);
    try std.testing.expectApproxEqAbs(0.6, mixed[11], 1e-5);
}

test "MarkerClip track selection changes native channel count" {
    const be = MarkerClipBackend.create(std.testing.allocator);
    defer be.backend().deinit();
    const b = be.backend();
    try std.testing.expect(b.open("dummy"));

    // Track 0 (stereo) -> 2ch chunks
    b.selectAudioTrack(0);
    _ = b.seek(0.0);
    const ch0 = b.nextAudioChunk();
    try std.testing.expect(ch0 != null);
    try std.testing.expectEqual(2, ch0.?.channel_count);

    // Track 1 (5.1) -> 6ch chunks
    b.selectAudioTrack(1);
    _ = b.seek(0.0);
    const ch1 = b.nextAudioChunk();
    try std.testing.expect(ch1 != null);
    try std.testing.expectEqual(6, ch1.?.channel_count);
}
