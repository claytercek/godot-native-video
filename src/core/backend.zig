//! backend.zig — port of src/core/backend.h/.cpp.
//!
//! Backend wraps one OS media framework (AVFoundation, MF, GStreamer) as a
//! pure hardware decoder: opened on a source, configured to a track, then
//! polled for the next decoded frame / audio chunk.
//!
//! Design rules (unchanged from C++):
//!  - No Godot / RenderingDevice types — Godot-independent.
//!  - No player-mode callbacks — we own the clock; the Backend is a dumb
//!    decode pump.
//!  - Thread safety: implementations decide; callers serialise per-stream
//!    access.
//!
//! The C++ pure-virtual class becomes a ptr+vtable interface (composition,
//! not inheritance). Optional vtable entries carry the C++ base-class
//! default implementations.

const std = @import("std");

/// Platform-neutral tags for YCbCr matrix, primaries, transfer, and range.
/// Populated per-frame from the decoder surface's color attachments.
/// Unspecified defaults to BT.709 video range (the v1 assumption, matching
/// today's hard-coded shader constants).
pub const ColorMatrix = enum(u8) {
    unspecified = 0,
    bt709 = 1, // ITU-R BT.709 (HD)
    bt601 = 2, // ITU-R BT.601 (SD)
    bt2020 = 3, // ITU-R BT.2020 (UHD)
};

pub const ColorPrimaries = enum(u8) {
    unspecified = 0,
    bt709 = 1,
    bt601_625 = 2, // EBU 3213-E (PAL)
    bt601_525 = 3, // SMPTE C (NTSC)
    bt2020 = 4,
    dci_p3 = 5,
};

pub const TransferFunction = enum(u8) {
    unspecified = 0,
    bt709 = 1, // Also used for sRGB-ish SDR
    pq = 2, // SMPTE ST 2084 (HDR10)
    hlg = 3, // ITU-R BT.2100 HLG
};

pub const ColorRange = enum(u8) {
    unspecified = 0,
    video = 1, // Limited range: Y [16,235], CbCr [16,240]
    full = 2, // Full range: Y/CbCr [0,255]
};

/// The five colorimetry fields bundled into one value type.
///
/// Two default conventions, both preserved from C++:
///  - Per-frame (VideoFrame.color): all-Unspecified; the shader treats
///    Unspecified as BT.709 video range.
///  - Negotiated (Backend.colorimetry() and backend impls): concrete BT.709
///    video-range values — use `bt709_defaults`.
pub const Colorimetry = struct {
    matrix: ColorMatrix = .unspecified,
    primaries: ColorPrimaries = .unspecified,
    transfer: TransferFunction = .unspecified,
    range: ColorRange = .unspecified,
    bit_depth: i32 = 8,

    pub const bt709_defaults: Colorimetry = .{
        .matrix = .bt709,
        .primaries = .bt709,
        .transfer = .bt709,
        .range = .video,
        .bit_depth = 8,
    };
};

/// Surface types produced by a hardware decoder. In scope for v1: 8-bit NV12
/// semi-planar, 10-bit x420/P010 semi-planar (imported as 16-bit R16/RG16
/// plane views), and the BGRA8 software fallback.
pub const PixelFormat = enum(u8) {
    unknown = 0,
    nv12, // YUV 4:2:0 semi-planar, 8-bit (luma plane + interleaved UV plane)
    x420, // YUV 4:2:0 semi-planar, 10-bit (16-bit containers: R16 + RG16)
    bgra8, // Packed BGRA, 8 bpc — fallback software path
};

/// One decoded video surface returned from the Backend.
///
/// In Decoder mode the Backend hands us a native surface handle whose
/// lifetime is managed by the hardware decode pool. The Engine Core imports
/// it via RenderingDevice.texture_create_from_extension; it never copies the
/// pixel data to CPU RAM.
pub const VideoFrame = struct {
    /// Presentation timestamp in seconds.
    pts_seconds: f64 = 0.0,

    /// Native surface handle (e.g. CVPixelBufferRef on Apple). The Backend
    /// retains ownership; the caller must call release() when done.
    native_handle: ?*anyopaque = null,

    /// The decoder texture-array slice holding THIS frame. 0 on platforms
    /// whose handles are per-frame (e.g. macOS CVPixelBuffer).
    plane_slice: u32 = 0,

    width: i32 = 0,
    height: i32 = 0,
    pixel_format: PixelFormat = .unknown,

    /// Populated from the decoder surface's color attachments by the Backend.
    color: Colorimetry = .{},

    /// C++ std::function<void()> release → context + fn pointer.
    release_ctx: ?*anyopaque = null,
    release_fn: ?*const fn (?*anyopaque) void = null,

    /// Call when the consumer is done with this frame so the decode pool can
    /// recycle the surface.
    pub fn release(self: VideoFrame) void {
        if (self.release_fn) |f| f(self.release_ctx);
    }
};

/// Per-track metadata returned by audioTrackInfo(). Array position is the
/// index used by the stock VideoStreamPlayer audio_track property.
/// String slices are owned by the Backend and valid until close().
pub const AudioTrackInfo = struct {
    language: []const u8 = "", // BCP 47 language tag, may be empty
    name: []const u8 = "", // Human-readable display name, may be empty
    channels: i32 = 0,
    sample_rate: i32 = 0,
    is_default: bool = false, // Container's default track flag
};

/// One decoded audio packet returned from the Backend. `samples` is
/// interleaved PCM float32, channel-major; valid until the next
/// nextAudioChunk() call on the same backend.
pub const AudioChunk = struct {
    /// Presentation timestamp of the first sample in seconds.
    pts_seconds: f64 = 0.0,
    samples: []const f32 = &.{},
    frame_count: i32 = 0, // per-channel sample count
    channel_count: i32 = 0,
    sample_rate: i32 = 0,
};

/// Pure-virtual C++ Backend → ptr + vtable. Optional entries default to the
/// C++ base-class behavior (single-track compat).
pub const Backend = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        open: *const fn (*anyopaque, url_or_path: []const u8) bool,
        close: *const fn (*anyopaque) void,
        /// Virtual destructor equivalent: close + free the implementation.
        deinit: *const fn (*anyopaque) void,

        duration_seconds: *const fn (*anyopaque) f64,
        video_width: *const fn (*anyopaque) i32,
        video_height: *const fn (*anyopaque) i32,
        audio_channel_count: *const fn (*anyopaque) i32,
        audio_sample_rate: *const fn (*anyopaque) i32,

        /// Negotiated colorimetry for the stream as a whole; null → BT.709
        /// defaults.
        colorimetry: ?*const fn (*anyopaque) Colorimetry = null,

        /// null → 1 when audio_channel_count() > 0, else 0.
        audio_track_count: ?*const fn (*anyopaque) i32 = null,
        /// null → default-constructed info with the backend's channel
        /// count/rate at index 0. Implementations bounds-check.
        audio_track_info: ?*const fn (*anyopaque, index: i32) AudioTrackInfo = null,
        /// null → no-op (single-track compat).
        select_audio_track: ?*const fn (*anyopaque, index: i32) void = null,
        /// null → false (unimplemented for single-track backends).
        reselect_audio_track: ?*const fn (*anyopaque, index: i32, pts_seconds: f64) bool = null,

        seek: *const fn (*anyopaque, pts_seconds: f64) bool,
        next_video_frame: *const fn (*anyopaque) ?VideoFrame,
        next_audio_chunk: *const fn (*anyopaque) ?AudioChunk,
    };

    pub fn open(self: Backend, url_or_path: []const u8) bool {
        return self.vtable.open(self.ptr, url_or_path);
    }
    pub fn close(self: Backend) void {
        self.vtable.close(self.ptr);
    }
    pub fn deinit(self: Backend) void {
        self.vtable.deinit(self.ptr);
    }
    pub fn durationSeconds(self: Backend) f64 {
        return self.vtable.duration_seconds(self.ptr);
    }
    pub fn videoWidth(self: Backend) i32 {
        return self.vtable.video_width(self.ptr);
    }
    pub fn videoHeight(self: Backend) i32 {
        return self.vtable.video_height(self.ptr);
    }
    pub fn audioChannelCount(self: Backend) i32 {
        return self.vtable.audio_channel_count(self.ptr);
    }
    pub fn audioSampleRate(self: Backend) i32 {
        return self.vtable.audio_sample_rate(self.ptr);
    }

    pub fn colorimetry(self: Backend) Colorimetry {
        if (self.vtable.colorimetry) |f| return f(self.ptr);
        return .bt709_defaults;
    }

    /// Number of audio tracks in the media; 0 when no audio is present.
    pub fn audioTrackCount(self: Backend) i32 {
        if (self.vtable.audio_track_count) |f| return f(self.ptr);
        return if (self.audioChannelCount() > 0) 1 else 0;
    }

    /// Per-track metadata; out-of-range indices return a default-constructed
    /// AudioTrackInfo.
    pub fn audioTrackInfo(self: Backend, index: i32) AudioTrackInfo {
        if (self.vtable.audio_track_info) |f| return f(self.ptr, index);
        if (index == 0 and self.audioTrackCount() > 0) {
            return .{
                .channels = self.audioChannelCount(),
                .sample_rate = self.audioSampleRate(),
                .is_default = true,
            };
        }
        return .{};
    }

    /// Select which audio track to decode; takes effect on the next seek()
    /// or open(). Out-of-range indices are clamped by implementations.
    pub fn selectAudioTrack(self: Backend, index: i32) void {
        if (self.vtable.select_audio_track) |f| f(self.ptr, index);
    }

    /// Reselect the audio track mid-decode without disturbing video decode.
    /// Returns true on success; on failure the caller should seek() to
    /// recover.
    pub fn reselectAudioTrack(self: Backend, index: i32, pts_seconds: f64) bool {
        if (self.vtable.reselect_audio_track) |f| return f(self.ptr, index, pts_seconds);
        return false;
    }

    /// Seek to the nearest keyframe at or before pts_seconds. After seek,
    /// call nextVideoFrame() / nextAudioChunk() to pump.
    pub fn seek(self: Backend, pts_seconds: f64) bool {
        return self.vtable.seek(self.ptr, pts_seconds);
    }

    /// Decode and return the next video frame; null at end-of-stream or on
    /// decode error.
    pub fn nextVideoFrame(self: Backend) ?VideoFrame {
        return self.vtable.next_video_frame(self.ptr);
    }

    /// Decode and return the next audio chunk; null at end-of-stream or on
    /// decode error.
    pub fn nextAudioChunk(self: Backend) ?AudioChunk {
        return self.vtable.next_audio_chunk(self.ptr);
    }
};

test "default audio track helpers mirror C++ base class" {
    const Fake = struct {
        channels: i32,
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
        fn chFn(p: *anyopaque) i32 {
            const self: *@This() = @ptrCast(@alignCast(p));
            return self.channels;
        }
        fn rateFn(_: *anyopaque) i32 {
            return 48000;
        }
        fn seekFn(_: *anyopaque, _: f64) bool {
            return true;
        }
        fn nvfFn(_: *anyopaque) ?VideoFrame {
            return null;
        }
        fn nacFn(_: *anyopaque) ?AudioChunk {
            return null;
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
        };
    };

    var with_audio: Fake = .{ .channels = 2 };
    const b: Backend = .{ .ptr = &with_audio, .vtable = &Fake.vtable };
    try std.testing.expectEqual(@as(i32, 1), b.audioTrackCount());
    try std.testing.expectEqual(@as(i32, 2), b.audioTrackInfo(0).channels);
    try std.testing.expect(b.audioTrackInfo(0).is_default);
    try std.testing.expectEqual(@as(i32, 0), b.audioTrackInfo(1).channels);
    try std.testing.expect(!b.reselectAudioTrack(0, 0.0));

    var no_audio: Fake = .{ .channels = 0 };
    const b2: Backend = .{ .ptr = &no_audio, .vtable = &Fake.vtable };
    try std.testing.expectEqual(@as(i32, 0), b2.audioTrackCount());
}
