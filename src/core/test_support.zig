//! test_support.zig — shared helpers for the core unit tests. Not part of the
//! library's public API; imported only from test code.

const std = @import("std");
const backend_mod = @import("backend.zig");
const scrubber_mod = @import("scrubber.zig");
const present_selector = @import("present_selector.zig");

const Backend = backend_mod.Backend;
const VideoFrame = backend_mod.VideoFrame;
const AudioChunk = backend_mod.AudioChunk;
const AudioTrackInfo = backend_mod.AudioTrackInfo;
const Colorimetry = backend_mod.Colorimetry;
const VoidClosure = backend_mod.VoidClosure;

/// Comptime-generated Backend.VTable for a plain-method fake backend.
///
/// T declares only the methods its scenario cares about (named after Backend's
/// wrapper methods: `pub fn seek(self: *T, pts_seconds: f64) bool`,
/// `pub fn nextVideoFrame(self: *T) ?VideoFrame`, ...); this generates the
/// type-erased shims and fills every omitted method with a stub:
///
///   open -> true, close/deinit/selectAudioTrack -> no-op, seek -> true,
///   durationSeconds -> 10.0, videoWidth x videoHeight -> 640 x 360,
///   colorimetry -> BT.709 defaults, nextVideoFrame/nextAudioChunk -> null,
///   reselectAudioTrack -> false, audioChannelCount/audioSampleRate -> 0
///   (no audio), audioTrackCount -> 1 when the channel count is positive
///   else 0, audioTrackInfo -> one default track mirroring the channel
///   count/rate.
pub fn backendVTable(comptime T: type) Backend.VTable {
    const S = struct {
        fn cast(p: *anyopaque) *T {
            return @ptrCast(@alignCast(p));
        }
        fn open(p: *anyopaque, url_or_path: []const u8) bool {
            return if (@hasDecl(T, "open")) cast(p).open(url_or_path) else true;
        }
        fn close(p: *anyopaque) void {
            if (@hasDecl(T, "close")) cast(p).close();
        }
        fn deinit(p: *anyopaque) void {
            if (@hasDecl(T, "deinit")) cast(p).deinit();
        }
        fn durationSeconds(p: *anyopaque) f64 {
            return if (@hasDecl(T, "durationSeconds")) cast(p).durationSeconds() else 10.0;
        }
        fn videoWidth(p: *anyopaque) i32 {
            return if (@hasDecl(T, "videoWidth")) cast(p).videoWidth() else 640;
        }
        fn videoHeight(p: *anyopaque) i32 {
            return if (@hasDecl(T, "videoHeight")) cast(p).videoHeight() else 360;
        }
        fn audioChannelCount(p: *anyopaque) i32 {
            return if (@hasDecl(T, "audioChannelCount")) cast(p).audioChannelCount() else 0;
        }
        fn audioSampleRate(p: *anyopaque) i32 {
            return if (@hasDecl(T, "audioSampleRate")) cast(p).audioSampleRate() else 0;
        }
        fn colorimetry(p: *anyopaque) Colorimetry {
            return if (@hasDecl(T, "colorimetry")) cast(p).colorimetry() else .bt709_defaults;
        }
        fn audioTrackCount(p: *anyopaque) i32 {
            if (@hasDecl(T, "audioTrackCount")) return cast(p).audioTrackCount();
            return if (audioChannelCount(p) > 0) 1 else 0;
        }
        fn audioTrackInfo(p: *anyopaque, index: i32) AudioTrackInfo {
            if (@hasDecl(T, "audioTrackInfo")) return cast(p).audioTrackInfo(index);
            if (index == 0 and audioTrackCount(p) > 0) {
                return .{
                    .channels = audioChannelCount(p),
                    .sample_rate = audioSampleRate(p),
                    .is_default = true,
                };
            }
            return .{};
        }
        fn selectAudioTrack(p: *anyopaque, index: i32) void {
            if (@hasDecl(T, "selectAudioTrack")) cast(p).selectAudioTrack(index);
        }
        fn reselectAudioTrack(p: *anyopaque, index: i32, pts_seconds: f64) bool {
            return if (@hasDecl(T, "reselectAudioTrack"))
                cast(p).reselectAudioTrack(index, pts_seconds)
            else
                false;
        }
        fn seek(p: *anyopaque, pts_seconds: f64) bool {
            return if (@hasDecl(T, "seek")) cast(p).seek(pts_seconds) else true;
        }
        fn nextVideoFrame(p: *anyopaque) ?VideoFrame {
            return if (@hasDecl(T, "nextVideoFrame")) cast(p).nextVideoFrame() else null;
        }
        fn nextAudioChunk(p: *anyopaque) ?AudioChunk {
            return if (@hasDecl(T, "nextAudioChunk")) cast(p).nextAudioChunk() else null;
        }
    };
    return .{
        .open = S.open,
        .close = S.close,
        .deinit = S.deinit,
        .duration_seconds = S.durationSeconds,
        .video_width = S.videoWidth,
        .video_height = S.videoHeight,
        .audio_channel_count = S.audioChannelCount,
        .audio_sample_rate = S.audioSampleRate,
        .colorimetry = S.colorimetry,
        .audio_track_count = S.audioTrackCount,
        .audio_track_info = S.audioTrackInfo,
        .select_audio_track = S.selectAudioTrack,
        .reselect_audio_track = S.reselectAudioTrack,
        .seek = S.seek,
        .next_video_frame = S.nextVideoFrame,
        .next_audio_chunk = S.nextAudioChunk,
    };
}

/// Wrap a pointer to a plain-method fake backend in a Backend interface.
pub fn backend(t: anytype) Backend {
    const T = @typeInfo(@TypeOf(t)).pointer.child;
    const S = struct {
        const vtable: Backend.VTable = backendVTable(T);
    };
    return .{ .ptr = t, .vtable = &S.vtable };
}

/// Per-frame release tracker for fake decoded surfaces: marks release exactly
/// once (asserted), decrements a shared live-surface counter and bumps a
/// shared total-released counter when wired. Fake backends keep every Surface
/// they hand out and free them all in deinit(), so nothing leaks whether or
/// not each frame's release ran.
pub const Surface = struct {
    released: std.atomic.Value(bool) = .init(false),
    live: ?*std.atomic.Value(i32) = null,
    total: ?*std.atomic.Value(i64) = null,

    pub fn releaseImpl(p: ?*anyopaque) void {
        const s: *Surface = @ptrCast(@alignCast(p.?));
        const was = s.released.swap(true, .acq_rel);
        std.debug.assert(!was); // exactly-once release
        if (s.live) |l| _ = l.fetchSub(1, .monotonic);
        if (s.total) |t| _ = t.fetchAdd(1, .monotonic);
    }

    /// The release closure to attach to the frame carrying this surface.
    pub fn hook(self: *Surface) VoidClosure {
        return .{ .ctx = self, .func = releaseImpl };
    }
};

/// A release hook that only counts invocations — for tests that assert how
/// many frames a code path dropped/released without tracking each surface.
pub fn countingRelease(counter: *std.atomic.Value(i32)) VoidClosure {
    const S = struct {
        fn run(p: ?*anyopaque) void {
            const c: *std.atomic.Value(i32) = @ptrCast(@alignCast(p.?));
            _ = c.fetchAdd(1, .monotonic);
        }
    };
    return .{ .ctx = counter, .func = S.run };
}

/// Apply the present selector (drop-late / hold-early) to a decode-ahead PTS
/// buffer for clock time `now` and return the PTS on screen afterwards (the
/// held value if nothing new was due). Drop pops the stale head and
/// re-evaluates; Show pops and presents the head; Hold ends the tick.
pub fn runPresent(buf: *std.ArrayList(f64), now: f64, held_pts: f64, frame_interval: f64) f64 {
    var shown = held_pts;
    while (true) {
        const head: ?f64 = if (buf.items.len == 0) null else buf.items[0];
        const next: ?f64 = if (buf.items.len >= 2) buf.items[1] else null;

        const a = present_selector.selectPresentAction(head, next, now, frame_interval);
        if (a == .drop) {
            _ = buf.orderedRemove(0); // discard stale head, re-evaluate
            continue;
        }
        if (a == .show) {
            shown = buf.items[0];
            _ = buf.orderedRemove(0);
        }
        // Hold or Show both terminate the tick.
        break;
    }
    return shown;
}

/// The scrub thresholds shared by the scrubber unit and integration tests: a
/// seek is "fast" (a drag burst) when successive seeks arrive within the
/// burst window AND move the target at/above the velocity threshold; the
/// scrub is "settled" once settle_debounce_ms elapse with no new seek.
pub fn makeScrubConfig() scrubber_mod.ScrubConfig {
    return .{
        .settle_debounce_ms = 100.0, // middle of the ~80-120ms guidance band
        .burst_window_ms = 120.0, // two seeks within this gap can form a burst
        .velocity_threshold = 2.0, // media-seconds per wall-second = fast drag
    };
}

test "adapter defaults provide single-track compat for minimal fakes" {
    const Fake = struct {
        channels: i32,
        pub fn audioChannelCount(self: *@This()) i32 {
            return self.channels;
        }
        pub fn audioSampleRate(_: *@This()) i32 {
            return 48000;
        }
    };

    var with_audio: Fake = .{ .channels = 2 };
    const b = backend(&with_audio);
    try std.testing.expect(b.open("x"));
    try std.testing.expectEqual(1, b.audioTrackCount());
    try std.testing.expectEqual(2, b.audioTrackInfo(0).channels);
    try std.testing.expect(b.audioTrackInfo(0).is_default);
    try std.testing.expectEqual(0, b.audioTrackInfo(1).channels);
    try std.testing.expect(!b.reselectAudioTrack(0, 0.0));
    try std.testing.expect(b.nextVideoFrame() == null);
    try std.testing.expect(b.nextAudioChunk() == null);
    try std.testing.expectEqual(Colorimetry.bt709_defaults, b.colorimetry());

    var no_audio: Fake = .{ .channels = 0 };
    const b2 = backend(&no_audio);
    try std.testing.expectEqual(0, b2.audioTrackCount());
    try std.testing.expectEqual(0, b2.audioTrackInfo(0).channels);
}
