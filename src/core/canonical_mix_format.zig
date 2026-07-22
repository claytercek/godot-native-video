//! Pure derivation of a playback's Canonical Mix Format from a Backend's
//! audio tracks.
//!
//! The Canonical Mix Format (channel count + sample rate) is fixed for a
//! playback's entire lifetime once load() returns. Deriving it is a pure
//! function of a Backend's audioTrackCount()/audioTrackInfo() queries — no
//! DecodeScheduler, no clock, no state. Pulling it out of
//! PlaybackController.load() lets the mixed-sample-rate / channel-clamp
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

    const track_count: usize = @intCast(@max(backend.audioTrackCount(), 0));
    var warned_mixed_sample_rates = false;
    for (0..track_count) |i| {
        const info = backend.audioTrackInfo(@intCast(i));
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
// Sanity coverage.
// -----------------------------------------------------------------------

const FakeBackend = struct {
    tracks: []const AudioTrackInfo,

    pub fn audioTrackCount(self: *FakeBackend) i32 {
        return @intCast(self.tracks.len);
    }
    pub fn audioTrackInfo(self: *FakeBackend, index: i32) AudioTrackInfo {
        if (index < 0 or index >= @as(i32, @intCast(self.tracks.len))) return .{};
        return self.tracks[@intCast(index)];
    }

    fn backend(self: *FakeBackend) Backend {
        return @import("test_support.zig").backend(self);
    }
};

test "derive_canonical_mix_format picks max channels and first track's rate" {
    var fake: FakeBackend = .{ .tracks = &.{
        .{ .channels = 2, .sample_rate = 44100 },
        .{ .channels = 6, .sample_rate = 48000 },
    } };
    var fmt = try deriveCanonicalMixFormat(std.testing.allocator, fake.backend());
    defer fmt.deinit(std.testing.allocator);

    try std.testing.expectEqual(6, fmt.channels);
    try std.testing.expectEqual(44100, fmt.sample_rate);
    try std.testing.expect(fmt.has_audio);
    try std.testing.expectEqual(2, fmt.track_infos.items.len);
    try std.testing.expectEqual(1, fmt.warnings.items.len);
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
    try std.testing.expectEqual(0, fmt.channels);
    try std.testing.expectEqual(0, fmt.sample_rate);
    try std.testing.expectEqual(0, fmt.warnings.items.len);
}

test "derive_canonical_mix_format warns exactly once on mixed sample rates; later matching tracks stay silent" {
    var fake: FakeBackend = .{ .tracks = &.{
        .{ .channels = 1, .sample_rate = 44100 }, .{ .channels = 2, .sample_rate = 48000 },
        .{ .channels = 6, .sample_rate = 44100 }, .{ .channels = 2, .sample_rate = 48000 },
    } };
    var fmt = try deriveCanonicalMixFormat(std.testing.allocator, fake.backend());
    defer fmt.deinit(std.testing.allocator);

    try std.testing.expectEqual(1, fmt.warnings.items.len);
    try std.testing.expect(std.mem.indexOf(u8, fmt.warnings.items[0], "differs from the canonical rate") != null);
}

test "derive_canonical_mix_format still collects track metadata without sample-rate audio" {
    var fake: FakeBackend = .{ .tracks = &.{.{ .channels = 2, .sample_rate = 0 }} };
    var fmt = try deriveCanonicalMixFormat(std.testing.allocator, fake.backend());
    defer fmt.deinit(std.testing.allocator);

    try std.testing.expect(!fmt.has_audio);
    try std.testing.expectEqual(0, fmt.sample_rate);
    try std.testing.expectEqual(2, fmt.channels); // channel count is still tracked
    try std.testing.expectEqual(1, fmt.track_infos.items.len);
}
