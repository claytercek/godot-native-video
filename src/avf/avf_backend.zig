//! avf_backend.zig — AVFoundation Decoder-mode Backend (macOS).
//!
//! Port of src/backends/avf/avf_backend.mm. Implements the core.Backend
//! ptr+vtable contract on top of the C-ABI shim in avf_shim.m. This file owns
//! all policy: the reader state machine, track selection/clamping, EOS/error
//! interpretation, and translation of shim results into VideoFrame /
//! AudioChunk. The shim owns the AVFoundation object graph.
//!
//! Ownership at the boundaries:
//!  - Video frames: the shim hands out a CVPixelBufferRef carrying a +1
//!    retain via native_handle; the frame's release_fn calls
//!    nv_avf_frame_release exactly once (mirrors the C++ PixelBufferRef).
//!  - Audio samples: shim-owned scratch, valid until the next
//!    nextAudioChunk()/close() — the AudioChunk slice borrows it.
//!  - AudioTrackInfo strings: duplicated into backend-owned storage at open,
//!    freed at close; slices stay valid until close().

const std = @import("std");
// Reach core through the build.zig-wired "core" named module: a module's root
// forbids cross-directory @import ("../core/backend.zig" is outside this
// module's root), and routing through the shared module makes core.Backend
// one identity across the avf backend, the engine core, and the Godot glue.
const core = @import("core").backend;

// -----------------------------------------------------------------------
// Shim C ABI — mirrors avf_shim.h by hand (gdzig projects avoid @cImport).
// -----------------------------------------------------------------------
const Shim = opaque {};

const c_colorimetry = extern struct {
    matrix: c_int,
    primaries: c_int,
    transfer: c_int,
    range: c_int,
    bit_depth: c_int,
};

const c_open_info = extern struct {
    duration_seconds: f64,
    width: c_int,
    height: c_int,
    has_video: c_int,
    audio_track_count: c_int,
    color: c_colorimetry,
};

const c_audio_track_info = extern struct {
    language: ?[*:0]const u8,
    channels: c_int,
    sample_rate: c_int,
    is_default: c_int,
};

const c_video_frame = extern struct {
    pixel_buffer: ?*anyopaque,
    pts_seconds: f64,
    width: c_int,
    height: c_int,
    pixel_format: c_int,
    color: c_colorimetry,
};

const c_audio_chunk = extern struct {
    samples: ?[*]const f32,
    pts_seconds: f64,
    frame_count: c_int,
    float_count: c_int,
};

extern fn nv_avf_create() ?*Shim;
extern fn nv_avf_destroy(h: ?*Shim) void;
extern fn nv_avf_open(h: *Shim, url_or_path: [*:0]const u8, info: *c_open_info) c_int;
extern fn nv_avf_close(h: *Shim) void;
extern fn nv_avf_get_audio_track_info(h: *Shim, index: c_int, out: *c_audio_track_info) c_int;
extern fn nv_avf_build_reader(h: *Shim, start_time: f64, audio_track_index: c_int) c_int;
extern fn nv_avf_build_audio_reader(h: *Shim, track_index: c_int, start_time: f64) c_int;
extern fn nv_avf_build_video_reader(h: *Shim, start_time: f64) c_int;
extern fn nv_avf_teardown_audio_reader(h: *Shim) void;
extern fn nv_avf_next_video_frame(h: *Shim, out: *c_video_frame) c_int;
extern fn nv_avf_next_audio_chunk(h: *Shim, out: *c_audio_chunk) c_int;
extern fn nv_avf_frame_release(pixel_buffer: ?*anyopaque) void;

// -----------------------------------------------------------------------
// Colorimetry / pixel-format translation. The shim returns integer tags that
// share numeric values with the core enums, so this is a direct @enumFromInt.
// -----------------------------------------------------------------------
fn toColorimetry(c: c_colorimetry) core.Colorimetry {
    return .{
        .matrix = @enumFromInt(@as(u8, @intCast(c.matrix))),
        .primaries = @enumFromInt(@as(u8, @intCast(c.primaries))),
        .transfer = @enumFromInt(@as(u8, @intCast(c.transfer))),
        .range = @enumFromInt(@as(u8, @intCast(c.range))),
        .bit_depth = @intCast(c.bit_depth),
    };
}

// -----------------------------------------------------------------------
// AvfBackend — the concrete implementation behind the Backend vtable.
// -----------------------------------------------------------------------
pub const AvfBackend = struct {
    allocator: std.mem.Allocator,
    shim: *Shim,

    opened: bool = false,

    // True if the most recent decode pump hit an error (as opposed to a clean
    // end-of-stream). Mirrors the C++ AvfBackend::had_error() flag; exposed via
    // hadError() (not part of the vtable) for the integration test.
    err: bool = false,

    duration: f64 = 0.0,
    width: i32 = 0,
    height: i32 = 0,
    has_video: bool = false,

    // Negotiated colorimetry parsed at open; defaults to BT.709 video range.
    color: core.Colorimetry = core.Colorimetry.bt709_defaults,

    // Per-track audio metadata. Strings point into `string_storage`.
    audio_tracks: std.ArrayList(core.AudioTrackInfo) = .empty,
    // Owned copies of the language strings backing audio_tracks[*].language;
    // valid until close().
    string_storage: std.ArrayList([]u8) = .empty,

    selected_audio_index: i32 = 0,
    audio_channels: i32 = 0,
    audio_rate: i32 = 0,

    // ---- vtable glue ----
    const vtable: core.Backend.VTable = .{
        .open = vtOpen,
        .close = vtClose,
        .deinit = vtDeinit,
        .duration_seconds = vtDuration,
        .video_width = vtWidth,
        .video_height = vtHeight,
        .audio_channel_count = vtAudioChannels,
        .audio_sample_rate = vtAudioRate,
        .colorimetry = vtColorimetry,
        .audio_track_count = vtAudioTrackCount,
        .audio_track_info = vtAudioTrackInfo,
        .select_audio_track = vtSelectAudioTrack,
        .reselect_audio_track = vtReselectAudioTrack,
        .seek = vtSeek,
        .next_video_frame = vtNextVideoFrame,
        .next_audio_chunk = vtNextAudioChunk,
    };

    fn fromPtr(p: *anyopaque) *AvfBackend {
        return @ptrCast(@alignCast(p));
    }

    /// Drop the cached track table and its backing strings.
    fn clearTracks(self: *AvfBackend) void {
        for (self.string_storage.items) |s| self.allocator.free(s);
        self.string_storage.clearRetainingCapacity();
        self.audio_tracks.clearRetainingCapacity();
    }

    // ---- lifecycle ----
    // The vtable contract is bool, so openImpl translates the error union at
    // the boundary: any failure marks err and tears back down to closed.
    fn openImpl(self: *AvfBackend, url_or_path: []const u8) bool {
        self.openInner(url_or_path) catch {
            self.err = true;
            self.closeImpl();
            return false;
        };
        return true;
    }

    fn openInner(self: *AvfBackend, url_or_path: []const u8) !void {
        self.closeImpl();
        self.err = false;

        // NUL-terminate the path for the C boundary.
        const path_z = try self.allocator.dupeZ(u8, url_or_path);
        defer self.allocator.free(path_z);

        var info: c_open_info = undefined;
        if (nv_avf_open(self.shim, path_z.ptr, &info) == 0) return error.OpenFailed;

        self.opened = true;
        self.duration = info.duration_seconds;
        self.width = @intCast(info.width);
        self.height = @intCast(info.height);
        self.has_video = info.has_video != 0;
        self.color = toColorimetry(info.color);

        // Cache per-track audio metadata, duplicating language strings into
        // backend-owned storage so the slices stay valid until close().
        const count: usize = @intCast(@max(info.audio_track_count, 0));
        for (0..count) |i| {
            var track: c_audio_track_info = undefined;
            if (nv_avf_get_audio_track_info(self.shim, @intCast(i), &track) == 0) continue;

            const lang_src: []const u8 = if (track.language) |p| std.mem.span(p) else "";
            const lang_copy = try self.allocator.dupe(u8, lang_src);
            {
                // Owned by string_storage from here; closeImpl frees it on any
                // later failure.
                errdefer self.allocator.free(lang_copy);
                try self.string_storage.append(self.allocator, lang_copy);
            }
            try self.audio_tracks.append(self.allocator, .{
                .language = lang_copy,
                .name = "", // not surfaced by AVFoundation in v1 (matches C++)
                .channels = @intCast(track.channels),
                .sample_rate = @intCast(track.sample_rate),
                .is_default = track.is_default != 0,
            });
        }

        // Initialise selection from the first (default) track, mirroring the
        // C++ apply_track_selection(0) at open.
        self.selected_audio_index = 0;
        if (self.audio_tracks.items.len > 0) {
            self.audio_channels = self.audio_tracks.items[0].channels;
            self.audio_rate = self.audio_tracks.items[0].sample_rate;
        } else {
            self.audio_channels = 0;
            self.audio_rate = 0;
        }

        // Build the combined reader from the start; C++ open() returns this.
        const audio_idx: c_int = if (self.audio_tracks.items.len > 0)
            self.selected_audio_index
        else
            -1;
        if (nv_avf_build_reader(self.shim, 0.0, audio_idx) != 1) return error.BuildReaderFailed;
    }

    fn closeImpl(self: *AvfBackend) void {
        if (self.opened) {
            nv_avf_close(self.shim);
        }
        self.clearTracks();
        self.opened = false;
        self.duration = 0.0;
        self.width = 0;
        self.height = 0;
        self.has_video = false;
        self.audio_channels = 0;
        self.audio_rate = 0;
        self.selected_audio_index = 0;
    }

    // apply_track_selection: store the index and derive channels/rate from the
    // cached track table. Returns false for an out-of-range index.
    fn applyTrackSelection(self: *AvfBackend, i: i32) bool {
        if (i < 0 or i >= @as(i32, @intCast(self.audio_tracks.items.len))) return false;
        self.selected_audio_index = i;
        self.audio_channels = self.audio_tracks.items[@intCast(i)].channels;
        self.audio_rate = self.audio_tracks.items[@intCast(i)].sample_rate;
        return true;
    }

    fn seekImpl(self: *AvfBackend, pts_seconds: f64) bool {
        if (!self.opened) return false;
        const target = @max(pts_seconds, 0.0);
        // Tear down any dedicated audio-only reader so seek builds a fresh
        // combined reader with both video and the selected audio track.
        nv_avf_teardown_audio_reader(self.shim);
        self.err = false;
        const audio_idx: c_int = if (self.audio_tracks.items.len > 0)
            self.selected_audio_index
        else
            -1;
        if (nv_avf_build_reader(self.shim, target, audio_idx) != 1) {
            self.err = true;
            return false;
        }
        return true;
    }

    fn selectAudioTrackImpl(self: *AvfBackend, index: i32) void {
        const count: i32 = @intCast(self.audio_tracks.items.len);
        if (count == 0) return; // no audio tracks to select from
        const clamped = std.math.clamp(index, 0, count - 1);
        _ = self.applyTrackSelection(clamped);
    }

    fn reselectAudioTrackImpl(self: *AvfBackend, index: i32, pts_seconds: f64) bool {
        if (!self.opened) return false;
        const count: i32 = @intCast(self.audio_tracks.items.len);
        if (count == 0) return false; // no audio tracks to select
        const clamped = std.math.clamp(index, 0, count - 1);
        const target = @max(pts_seconds, 0.0);

        // Mirrors C++ build_audio_reader() clearing the error flag at entry;
        // a hard reader failure (-1) sets it, a soft failure (0) leaves it.
        self.err = false;

        // Step 1: dedicated audio-only reader for the new track.
        const ar = nv_avf_build_audio_reader(self.shim, clamped, target);
        if (ar != 1) {
            if (ar < 0) self.err = true;
            return false;
        }
        // Step 2: rebuild the combined reader as video-only from `target` so
        // video resumes near the requested position instead of repeating from
        // the clip start, and so its audio output cannot block video decode.
        const vr = nv_avf_build_video_reader(self.shim, target);
        if (vr != 1) {
            if (vr < 0) self.err = true;
            nv_avf_teardown_audio_reader(self.shim);
            return false;
        }
        _ = self.applyTrackSelection(clamped);
        return true;
    }

    fn nextVideoFrameImpl(self: *AvfBackend) ?core.VideoFrame {
        var cf: c_video_frame = undefined;
        const rc = nv_avf_next_video_frame(self.shim, &cf);
        if (rc != 1) {
            if (rc < 0) self.err = true;
            return null;
        }
        return .{
            .pts_seconds = cf.pts_seconds,
            .native_handle = cf.pixel_buffer,
            .plane_slice = 0, // per-frame CVPixelBuffer handles
            .width = @intCast(cf.width),
            .height = @intCast(cf.height),
            .pixel_format = @enumFromInt(@as(u8, @intCast(cf.pixel_format))),
            .color = toColorimetry(cf.color),
            // The CVPixelBufferRef carries a +1 retain; release drops it once.
            .release_ctx = cf.pixel_buffer,
            .release_fn = frameRelease,
        };
    }

    fn frameRelease(ctx: ?*anyopaque) void {
        nv_avf_frame_release(ctx);
    }

    fn nextAudioChunkImpl(self: *AvfBackend) ?core.AudioChunk {
        var cc: c_audio_chunk = undefined;
        const rc = nv_avf_next_audio_chunk(self.shim, &cc);
        if (rc != 1) {
            if (rc < 0) self.err = true;
            return null;
        }
        const float_count: usize = @intCast(cc.float_count);
        const samples: []const f32 = if (cc.samples) |p| p[0..float_count] else &.{};
        // channel_count mirrors C++: the selected track's channel count, min 1.
        const channels: i32 = if (self.audio_channels > 0) self.audio_channels else 1;
        return .{
            .pts_seconds = cc.pts_seconds,
            .samples = samples,
            .frame_count = @intCast(cc.frame_count),
            .channel_count = channels,
            .sample_rate = self.audio_rate,
        };
    }

    /// True if the most recent pump hit a decode error rather than clean EOS.
    /// Not part of the Backend vtable; used by the integration test.
    pub fn hadError(self: *const AvfBackend) bool {
        return self.err;
    }

    // ---- vtable thunks ----
    fn vtOpen(p: *anyopaque, url_or_path: []const u8) bool {
        return fromPtr(p).openImpl(url_or_path);
    }
    fn vtClose(p: *anyopaque) void {
        fromPtr(p).closeImpl();
    }
    fn vtDeinit(p: *anyopaque) void {
        const self = fromPtr(p);
        self.closeImpl();
        nv_avf_destroy(self.shim);
        self.audio_tracks.deinit(self.allocator);
        self.string_storage.deinit(self.allocator);
        const allocator = self.allocator;
        allocator.destroy(self);
    }
    fn vtDuration(p: *anyopaque) f64 {
        return fromPtr(p).duration;
    }
    fn vtWidth(p: *anyopaque) i32 {
        return fromPtr(p).width;
    }
    fn vtHeight(p: *anyopaque) i32 {
        return fromPtr(p).height;
    }
    fn vtAudioChannels(p: *anyopaque) i32 {
        return fromPtr(p).audio_channels;
    }
    fn vtAudioRate(p: *anyopaque) i32 {
        return fromPtr(p).audio_rate;
    }
    fn vtColorimetry(p: *anyopaque) core.Colorimetry {
        return fromPtr(p).color;
    }
    fn vtAudioTrackCount(p: *anyopaque) i32 {
        return @intCast(fromPtr(p).audio_tracks.items.len);
    }
    fn vtAudioTrackInfo(p: *anyopaque, index: i32) core.AudioTrackInfo {
        const self = fromPtr(p);
        if (index < 0 or index >= @as(i32, @intCast(self.audio_tracks.items.len))) {
            return .{};
        }
        return self.audio_tracks.items[@intCast(index)];
    }
    fn vtSelectAudioTrack(p: *anyopaque, index: i32) void {
        fromPtr(p).selectAudioTrackImpl(index);
    }
    fn vtReselectAudioTrack(p: *anyopaque, index: i32, pts_seconds: f64) bool {
        return fromPtr(p).reselectAudioTrackImpl(index, pts_seconds);
    }
    fn vtSeek(p: *anyopaque, pts_seconds: f64) bool {
        return fromPtr(p).seekImpl(pts_seconds);
    }
    fn vtNextVideoFrame(p: *anyopaque) ?core.VideoFrame {
        return fromPtr(p).nextVideoFrameImpl();
    }
    fn vtNextAudioChunk(p: *anyopaque) ?core.AudioChunk {
        return fromPtr(p).nextAudioChunkImpl();
    }
};

/// Construct an AVFoundation backend and return it as the core.Backend
/// ptr+vtable interface. The returned Backend owns its heap allocation and the
/// shim handle; Backend.deinit() releases both.
pub fn create(allocator: std.mem.Allocator) !core.Backend {
    const shim = nv_avf_create() orelse return error.ShimCreateFailed;
    errdefer nv_avf_destroy(shim);

    const self = try allocator.create(AvfBackend);
    self.* = .{
        .allocator = allocator,
        .shim = shim,
    };
    return .{ .ptr = self, .vtable = &AvfBackend.vtable };
}
