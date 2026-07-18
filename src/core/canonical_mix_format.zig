//! canonical_mix_format.zig — port of src/core/canonical_mix_format.h/.cpp.
//!
//! Pure derivation of a playback's Canonical Mix Format from a Backend's
//! audio tracks.
//!
//! The Canonical Mix Format (channel count + sample rate) is fixed for a
//! playback's entire lifetime once load() returns. Deriving it is a pure
//! function of a Backend's audioTrackCount()/audioTrackInfo() queries — no
//! DecodeScheduler, no clock, no state. Pulling it out of
//! PlaybackController::load() lets the mixed-sample-rate / channel-clamp
//! logic be unit-tested without spinning up the process-wide scheduler
//! singleton the controller registers with.
//!
//! channels       — max channel count across all audio tracks, clamped to
//!                   channel_mixer.max_mix_source_channels.
//! sample_rate    — the FIRST audio-bearing track's rate (NOT a shared rate
//!                   across tracks). Mixed-sample-rate clips are a documented
//!                   limitation: the default track's rate wins, and a later
//!                   track with a differing rate gets exactly one warning
//!                   here.
//! has_audio      — true when any track carries audio.
//! track_infos    — per-track metadata cached for mid-stream switch
//!                   sample-rate validation.
//! warnings       — mixed-sample-rate notice(s) generated during derivation;
//!                   the controller drains these into its own
//!                   take_warnings() queue.

const std = @import("std");
const backend_mod = @import("backend.zig");
const channel_mixer = @import("channel_mixer.zig");

const Backend = backend_mod.Backend;
const AudioTrackInfo = backend_mod.AudioTrackInfo;

pub const CanonicalMixFormat = struct {
    channels: i32 = 0,
    sample_rate: i32 = 0,
    has_audio: bool = false,
    track_infos: std.ArrayList(AudioTrackInfo) = .empty,
    /// Owned warning strings (allocated with the same allocator passed to
    /// deriveCanonicalMixFormat). Freed by deinit().
    warnings: std.ArrayList([]const u8) = .empty,

    pub fn deinit(self: *CanonicalMixFormat, allocator: std.mem.Allocator) void {
        self.track_infos.deinit(allocator);
        for (self.warnings.items) |w| allocator.free(w);
        self.warnings.deinit(allocator);
    }
};

/// Derive the Canonical Mix Format from a backend's audio tracks. Pure: reads
/// only audioTrackCount()/audioTrackInfo(), no scheduler, no side effects.
/// Caller owns the returned value and must call deinit() with the same
/// allocator.
pub fn deriveCanonicalMixFormat(allocator: std.mem.Allocator, backend: Backend) !CanonicalMixFormat {
    var fmt: CanonicalMixFormat = .{};
    errdefer fmt.deinit(allocator);

    const track_count = backend.audioTrackCount();
    var warned_mixed_sample_rates = false;
    var i: i32 = 0;
    while (i < track_count) : (i += 1) {
        const info = backend.audioTrackInfo(i);
        try fmt.track_infos.append(allocator, info);
        if (info.channels > fmt.channels) {
            fmt.channels = info.channels;
        }
        if (info.channels > 0 and info.sample_rate > 0) {
            if (!fmt.has_audio) {
                fmt.sample_rate = info.sample_rate;
                fmt.has_audio = true;
            } else if (!warned_mixed_sample_rates and info.sample_rate != fmt.sample_rate) {
                const msg = try std.fmt.allocPrint(
                    allocator,
                    "Audio track {d} sample rate {d} Hz differs from the canonical rate {d} Hz. Mixed-sample-rate clips are not supported; this track will play at the canonical rate and mid-stream switches to it are refused.",
                    .{ i, info.sample_rate, fmt.sample_rate },
                );
                try fmt.warnings.append(allocator, msg);
                warned_mixed_sample_rates = true;
            }
        }
    }
    // Clamp to the max we know how to mix; larger channel counts are passed
    // through unmixed (the ring still fills and plays).
    if (fmt.channels > channel_mixer.max_mix_source_channels) {
        fmt.channels = channel_mixer.max_mix_source_channels;
    }
    return fmt;
}

// -----------------------------------------------------------------------
// Sanity coverage (no C++ test_canonical_mix_format.cpp exists to port).
// -----------------------------------------------------------------------

const FakeBackend = struct {
    tracks: []const AudioTrackInfo,

    fn openFn(_: *anyopaque, _: []const u8) bool {
        return true;
    }
    fn closeFn(_: *anyopaque) void {}
    fn deinitFn(_: *anyopaque) void {}
    fn durFn(_: *anyopaque) f64 {
        return 0;
    }
    fn dimFn(_: *anyopaque) i32 {
        return 0;
    }
    fn chFn(_: *anyopaque) i32 {
        return 0;
    }
    fn rateFn(_: *anyopaque) i32 {
        return 0;
    }
    fn seekFn(_: *anyopaque, _: f64) bool {
        return true;
    }
    fn nvfFn(_: *anyopaque) ?backend_mod.VideoFrame {
        return null;
    }
    fn nacFn(_: *anyopaque) ?backend_mod.AudioChunk {
        return null;
    }
    fn trackCountFn(p: *anyopaque) i32 {
        const self: *FakeBackend = @ptrCast(@alignCast(p));
        return @intCast(self.tracks.len);
    }
    fn trackInfoFn(p: *anyopaque, index: i32) AudioTrackInfo {
        const self: *FakeBackend = @ptrCast(@alignCast(p));
        if (index < 0 or index >= @as(i32, @intCast(self.tracks.len))) return .{};
        return self.tracks[@intCast(index)];
    }

    const vtable: Backend.VTable = .{
        .open = openFn,
        .close = closeFn,
        .deinit = deinitFn,
        .duration_seconds = durFn,
        .video_width = dimFn,
        .video_height = dimFn,
        .audio_channel_count = chFn,
        .audio_sample_rate = rateFn,
        .seek = seekFn,
        .next_video_frame = nvfFn,
        .next_audio_chunk = nacFn,
        .audio_track_count = trackCountFn,
        .audio_track_info = trackInfoFn,
    };

    fn backend(self: *FakeBackend) Backend {
        return .{ .ptr = self, .vtable = &vtable };
    }
};

test "derive_canonical_mix_format picks max channels and first track's rate" {
    var fake: FakeBackend = .{ .tracks = &.{
        .{ .channels = 2, .sample_rate = 44100 },
        .{ .channels = 6, .sample_rate = 48000 },
    } };
    var fmt = try deriveCanonicalMixFormat(std.testing.allocator, fake.backend());
    defer fmt.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(i32, 6), fmt.channels);
    try std.testing.expectEqual(@as(i32, 44100), fmt.sample_rate);
    try std.testing.expect(fmt.has_audio);
    try std.testing.expectEqual(@as(usize, 2), fmt.track_infos.items.len);
    try std.testing.expectEqual(@as(usize, 1), fmt.warnings.items.len);
}

test "derive_canonical_mix_format clamps channels to the mixer max" {
    var fake: FakeBackend = .{ .tracks = &.{
        .{ .channels = 8, .sample_rate = 48000 },
    } };
    var fmt = try deriveCanonicalMixFormat(std.testing.allocator, fake.backend());
    defer fmt.deinit(std.testing.allocator);

    try std.testing.expectEqual(channel_mixer.max_mix_source_channels, fmt.channels);
}

test "derive_canonical_mix_format with no tracks has no audio" {
    var fake: FakeBackend = .{ .tracks = &.{} };
    var fmt = try deriveCanonicalMixFormat(std.testing.allocator, fake.backend());
    defer fmt.deinit(std.testing.allocator);

    try std.testing.expect(!fmt.has_audio);
    try std.testing.expectEqual(@as(i32, 0), fmt.channels);
    try std.testing.expectEqual(@as(i32, 0), fmt.sample_rate);
    try std.testing.expectEqual(@as(usize, 0), fmt.warnings.items.len);
}
