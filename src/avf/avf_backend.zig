//! avf_backend.zig — AVFoundation Decoder-mode Backend (macOS).
//!
//! Implements the core.Backend ptr+vtable contract on top of the C-ABI shim
//! in avf_shim.m. This file owns all policy: the reader state machine, track
//! selection/clamping, EOS/error interpretation, and translation of shim
//! results into VideoFrame / AudioChunk. The shim owns the AVFoundation
//! object graph.
//!
//! Ownership at the boundaries:
//!  - Video frames: the shim hands out a CVPixelBufferRef carrying a +1
//!    retain via native_handle; the frame's release hook calls
//!    nv_avf_frame_release exactly once.
//!  - Audio samples: shim-owned scratch, valid until the next
//!    nextAudioChunk()/close() — the AudioChunk slice borrows it.
//!  - AudioTrackInfo strings: duplicated into backend-owned storage at open,
//!    freed at close; slices stay valid until close().

const std = @import("std");
const builtin = @import("builtin");
// Reach core through the build.zig-wired "core" named module: a module's root
// forbids cross-directory @import ("../core/backend.zig" is outside this
// module's root), and routing through the shared module makes core.Backend
// one identity across the avf backend, the engine core, and the Godot glue.
const core = @import("core").backend;

const log = std.log.scoped(.avf_backend);

// -----------------------------------------------------------------------
// Shim C ABI — mirrors avf_shim.h by hand (gdzig projects avoid @cImport).
// -----------------------------------------------------------------------
const Shim = opaque {};

// Tri-state result code shared by every shim entry point that can fail;
// mirrors avf_shim.h's nv_avf_result. Which of the three values a given
// function can actually produce is documented at each extern fn below.
const Result = enum(c_int) {
    fail = -1,
    none = 0,
    ok = 1,
};

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
    // Actual delivered format read off this sample buffer, diagnostic only;
    // 0 when unavailable. See logAudioNegotiation.
    channels: c_int,
    sample_rate: c_int,
};

// Mirrors avf_shim.h's nv_avf_abi_probe: the shim's actual sizeof for each
// hand-mirrored struct above, plus the offsetof for EVERY one of its fields
// (in declaration order), as its own compiler laid them out.
const AbiProbe = extern struct {
    sizeof_colorimetry: usize,
    off_colorimetry: [5]usize, // matrix, primaries, transfer, range, bit_depth

    sizeof_open_info: usize,
    off_open_info: [6]usize, // duration_seconds, width, height, has_video, audio_track_count, color

    sizeof_audio_track_info: usize,
    off_audio_track_info: [4]usize, // language, channels, sample_rate, is_default

    sizeof_video_frame: usize,
    off_video_frame: [6]usize, // pixel_buffer, pts_seconds, width, height, pixel_format, color

    sizeof_audio_chunk: usize,
    off_audio_chunk: [6]usize, // samples, pts_seconds, frame_count, float_count, channels, sample_rate
};
extern fn nv_avf_abi_probe_fill(out: *AbiProbe) void;

extern fn nv_avf_create() ?*Shim;
extern fn nv_avf_destroy(h: ?*Shim) void;
// Produces .ok or .none — never .fail.
extern fn nv_avf_open(h: *Shim, url_or_path: [*:0]const u8, info: *c_open_info) Result;
extern fn nv_avf_close(h: *Shim) void;
extern fn nv_avf_get_audio_track_info(h: *Shim, index: c_int, out: *c_audio_track_info) c_int;
// Produces .ok or .fail — never .none.
extern fn nv_avf_build_reader(h: *Shim, start_time: f64, audio_track_index: c_int) Result;
// Produces .ok, .none, or .fail.
extern fn nv_avf_reselect_audio_track(h: *Shim, track_index: c_int, start_time: f64) Result;
// Produces .ok, .none, or .fail.
extern fn nv_avf_next_video_frame(h: *Shim, out: *c_video_frame) Result;
// Produces .ok, .none, or .fail.
extern fn nv_avf_next_audio_chunk(h: *Shim, out: *c_audio_chunk) Result;
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

// The @enumFromInt calls above (and the pixel_format one in
// nextVideoFrameImpl) only work because avf_shim.h documents its
// NV_AVF_MATRIX_*/PRIM_*/TRANSFER_*/RANGE_*/PIXFMT_* tags as matching these
// core enums' numeric values bit-for-bit. Since the header's #defines
// aren't reachable from Zig (no @cImport), pin the documented values here
// so either side moving out of step is a compile error, not a silently
// wrong color on screen.
comptime {
    std.debug.assert(@intFromEnum(core.ColorMatrix.unspecified) == 0);
    std.debug.assert(@intFromEnum(core.ColorMatrix.bt709) == 1);
    std.debug.assert(@intFromEnum(core.ColorMatrix.bt601) == 2);
    std.debug.assert(@intFromEnum(core.ColorMatrix.bt2020) == 3);

    std.debug.assert(@intFromEnum(core.ColorPrimaries.unspecified) == 0);
    std.debug.assert(@intFromEnum(core.ColorPrimaries.bt709) == 1);
    std.debug.assert(@intFromEnum(core.ColorPrimaries.bt601_625) == 2);
    std.debug.assert(@intFromEnum(core.ColorPrimaries.bt601_525) == 3);
    std.debug.assert(@intFromEnum(core.ColorPrimaries.bt2020) == 4);
    std.debug.assert(@intFromEnum(core.ColorPrimaries.dci_p3) == 5);

    std.debug.assert(@intFromEnum(core.TransferFunction.unspecified) == 0);
    std.debug.assert(@intFromEnum(core.TransferFunction.bt709) == 1);
    std.debug.assert(@intFromEnum(core.TransferFunction.pq) == 2);
    std.debug.assert(@intFromEnum(core.TransferFunction.hlg) == 3);

    std.debug.assert(@intFromEnum(core.ColorRange.unspecified) == 0);
    std.debug.assert(@intFromEnum(core.ColorRange.video) == 1);
    std.debug.assert(@intFromEnum(core.ColorRange.full) == 2);

    std.debug.assert(@intFromEnum(core.PixelFormat.unknown) == 0);
    std.debug.assert(@intFromEnum(core.PixelFormat.nv12) == 1);
    std.debug.assert(@intFromEnum(core.PixelFormat.x420) == 2);
    std.debug.assert(@intFromEnum(core.PixelFormat.bgra8) == 3);
}

// Whether every field of `T` sits at the offset the shim's compiler put it
// at, and `T`'s overall size matches too. `expected_offsets` holds one
// offset per field of `T`, in declaration order — a field reorder that
// leaves sizeof unchanged (e.g. swapping two same-size scalar fields) still
// changes at least one of these offsets, so it doesn't slip through.
fn structMatchesAbi(comptime T: type, expected_size: usize, expected_offsets: []const usize) bool {
    if (expected_size != @sizeOf(T)) return false;
    const fields = @typeInfo(T).@"struct".fields;
    if (fields.len != expected_offsets.len) return false;
    inline for (fields, 0..) |field, i| {
        if (@offsetOf(T, field.name) != expected_offsets[i]) return false;
    }
    return true;
}

/// Panics if the shim's actual struct layout has drifted from the
/// hand-mirrored `c_*` extern structs above. Cheap — a few dozen integer
/// compares — but only worth paying somewhere drift is actually exercised:
/// called unconditionally from decode_smoke.zig (which CI runs on every
/// build) and from `create()` in debug builds; skipped in the release
/// extension's hot path.
pub fn assertAbi() void {
    var probe: AbiProbe = undefined;
    nv_avf_abi_probe_fill(&probe);
    const ok = structMatchesAbi(c_colorimetry, probe.sizeof_colorimetry, &probe.off_colorimetry) and
        structMatchesAbi(c_open_info, probe.sizeof_open_info, &probe.off_open_info) and
        structMatchesAbi(c_audio_track_info, probe.sizeof_audio_track_info, &probe.off_audio_track_info) and
        structMatchesAbi(c_video_frame, probe.sizeof_video_frame, &probe.off_video_frame) and
        structMatchesAbi(c_audio_chunk, probe.sizeof_audio_chunk, &probe.off_audio_chunk);
    if (!ok) @panic("avf ABI drift: shim struct layout no longer matches avf_backend.zig's c_* mirrors");
}

// -----------------------------------------------------------------------
// AvfBackend — the concrete implementation behind the Backend vtable.
// -----------------------------------------------------------------------
pub const AvfBackend = struct {
    allocator: std.mem.Allocator,
    shim: *Shim,

    opened: bool = false,

    duration: f64 = 0.0,
    width: i32 = 0,
    height: i32 = 0,

    // Negotiated colorimetry parsed at open; defaults to BT.709 video range.
    color: core.Colorimetry = core.Colorimetry.bt709_defaults,

    // Per-track audio metadata. `language` slices borrow the shim's own
    // strdup'd storage (avf_shim.h: valid until nv_avf_close/destroy), so
    // there's no separate backend-owned copy to track or free.
    audio_tracks: std.ArrayList(core.AudioTrackInfo) = .empty,

    selected_audio_index: i32 = 0,
    applied_audio_index: i32 = 0,
    audio_channels: i32 = 0,
    audio_rate: i32 = 0,

    // One-shot: whether the declared-vs-delivered divergence check has run
    // for the current open(). Reset in closeImpl so a reopen checks again.
    logged_audio_negotiation: bool = false,

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

    // ---- lifecycle ----
    // The vtable contract is bool, so openImpl translates the error union at
    // the boundary: any failure tears back down to closed.
    fn openImpl(self: *AvfBackend, url_or_path: []const u8) bool {
        self.openInner(url_or_path) catch {
            self.closeImpl();
            return false;
        };
        return true;
    }

    fn openInner(self: *AvfBackend, url_or_path: []const u8) !void {
        // The sole reset-to-closed point before opening: nv_avf_open assumes
        // an already-closed handle, so this is the only close call on the
        // reopen path.
        self.closeImpl();

        // NUL-terminate the path for the C boundary.
        const path_z = try self.allocator.dupeZ(u8, url_or_path);
        defer self.allocator.free(path_z);

        var info: c_open_info = undefined;
        if (nv_avf_open(self.shim, path_z.ptr, &info) != .ok) return error.OpenFailed;

        self.opened = true;
        self.duration = info.duration_seconds;
        self.width = @intCast(info.width);
        self.height = @intCast(info.height);
        self.color = toColorimetry(info.color);

        // Cache per-track audio metadata. `language` borrows the shim's own
        // strdup'd pointer directly (valid until close/destroy) instead of a
        // separate backend-owned copy.
        const count: usize = @intCast(@max(info.audio_track_count, 0));
        for (0..count) |i| {
            var track: c_audio_track_info = undefined;
            if (nv_avf_get_audio_track_info(self.shim, @intCast(i), &track) == 0) continue;

            const lang: []const u8 = if (track.language) |p| std.mem.span(p) else "";
            try self.audio_tracks.append(self.allocator, .{
                .language = lang,
                .name = "", // not surfaced by AVFoundation in v1
                .channels = @intCast(track.channels),
                .sample_rate = @intCast(track.sample_rate),
                .is_default = track.is_default != 0,
            });
        }

        // Initialise selection to the first (default) track at open.
        self.selected_audio_index = 0;
        self.applied_audio_index = 0;
        if (self.audio_tracks.items.len > 0) {
            self.audio_channels = self.audio_tracks.items[0].channels;
            self.audio_rate = self.audio_tracks.items[0].sample_rate;
        } else {
            self.audio_channels = 0;
            self.audio_rate = 0;
        }

        // Build the combined reader from the start; open() returns this.
        const audio_idx: c_int = if (self.audio_tracks.items.len > 0)
            self.selected_audio_index
        else
            -1;
        if (nv_avf_build_reader(self.shim, 0.0, audio_idx) != .ok) return error.BuildReaderFailed;
    }

    fn closeImpl(self: *AvfBackend) void {
        if (self.opened) {
            nv_avf_close(self.shim);
        }
        // Drop the cached track table. The language strings it points into
        // are shim-owned and freed by nv_avf_close, not here.
        self.audio_tracks.clearRetainingCapacity();
        self.opened = false;
        self.duration = 0.0;
        self.width = 0;
        self.height = 0;
        self.color = core.Colorimetry.bt709_defaults;
        self.audio_channels = 0;
        self.audio_rate = 0;
        self.selected_audio_index = 0;
        self.applied_audio_index = 0;
        self.logged_audio_negotiation = false;
    }

    // apply_track_selection: store the index and derive channels/rate from the
    // cached track table. Returns false for an out-of-range index.
    fn applyTrackSelection(self: *AvfBackend, i: i32) bool {
        if (i < 0 or i >= @as(i32, @intCast(self.audio_tracks.items.len))) return false;
        self.selected_audio_index = i;
        self.applied_audio_index = i;
        self.audio_channels = self.audio_tracks.items[@intCast(i)].channels;
        self.audio_rate = self.audio_tracks.items[@intCast(i)].sample_rate;
        return true;
    }

    fn seekImpl(self: *AvfBackend, pts_seconds: f64) bool {
        if (!self.opened) return false;
        const target = @max(pts_seconds, 0.0);
        const audio_idx: c_int = if (self.audio_tracks.items.len > 0)
            self.selected_audio_index
        else
            -1;
        if (nv_avf_build_reader(self.shim, target, audio_idx) != .ok) return false;
        if (audio_idx >= 0) _ = self.applyTrackSelection(audio_idx);
        return true;
    }

    fn selectAudioTrackImpl(self: *AvfBackend, index: i32) void {
        const count: i32 = @intCast(self.audio_tracks.items.len);
        if (count == 0) return; // no audio tracks to select from
        self.selected_audio_index = std.math.clamp(index, 0, count - 1);
    }

    fn reselectAudioTrackImpl(self: *AvfBackend, index: i32, pts_seconds: f64) bool {
        if (!self.opened) return false;
        const count: i32 = @intCast(self.audio_tracks.items.len);
        if (count == 0) return false; // no audio tracks to select
        const clamped = std.math.clamp(index, 0, count - 1);
        const target = @max(pts_seconds, 0.0);

        // The shim builds the dedicated audio-only reader and, when the asset
        // has video, rebuilds a video-only reader in one atomic step. It rolls
        // back partial construction; the reader lifecycle stays shim-side.
        if (nv_avf_reselect_audio_track(self.shim, clamped, target) != .ok) return false;
        _ = self.applyTrackSelection(clamped);
        return true;
    }

    fn nextVideoFrameImpl(self: *AvfBackend) ?core.VideoFrame {
        var cf: c_video_frame = undefined;
        if (nv_avf_next_video_frame(self.shim, &cf) != .ok) return null;
        return .{
            .pts_seconds = cf.pts_seconds,
            .native_handle = cf.pixel_buffer,
            .plane_slice = 0, // per-frame CVPixelBuffer handles
            .width = @intCast(cf.width),
            .height = @intCast(cf.height),
            .pixel_format = @enumFromInt(@as(u8, @intCast(cf.pixel_format))),
            .color = toColorimetry(cf.color),
            // The CVPixelBufferRef carries a +1 retain; release drops it once.
            .release_hook = .{ .ctx = cf.pixel_buffer, .func = frameRelease },
        };
    }

    fn frameRelease(ctx: ?*anyopaque) void {
        nv_avf_frame_release(ctx);
    }

    fn nextAudioChunkImpl(self: *AvfBackend) ?core.AudioChunk {
        var cc: c_audio_chunk = undefined;
        if (nv_avf_next_audio_chunk(self.shim, &cc) != .ok) return null;

        if (!self.logged_audio_negotiation) {
            self.logged_audio_negotiation = true;
            logAudioNegotiation(self.applied_audio_index, self.audio_channels, self.audio_rate, cc);
        }

        // The delivered sample format is the authoritative boundary. AVF is
        // asked for the declared rate/channel layout, but this readback guards
        // against a converter choosing a different valid PCM layout.
        if (cc.channels <= 0 or cc.sample_rate <= 0) return null;
        self.audio_channels = @intCast(cc.channels);
        self.audio_rate = @intCast(cc.sample_rate);
        if (self.applied_audio_index >= 0 and
            self.applied_audio_index < @as(i32, @intCast(self.audio_tracks.items.len)))
        {
            const track = &self.audio_tracks.items[@intCast(self.applied_audio_index)];
            track.channels = self.audio_channels;
            track.sample_rate = self.audio_rate;
        }
        const float_count: usize = @intCast(cc.float_count);
        const samples: []const f32 = if (cc.samples) |p| p[0..float_count] else &.{};
        // channel_count is the selected track's channel count, min 1.
        const channels = self.audio_channels;
        return .{
            .pts_seconds = cc.pts_seconds,
            .samples = samples,
            .frame_count = @intCast(cc.frame_count),
            .channel_count = channels,
            .sample_rate = self.audio_rate,
        };
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

// Diagnostic: compare the first delivered audio chunk's actual format
// (read off the CMSampleBuffer's own format description in avf_shim.m --
// `cc.channels`/`cc.sample_rate`, 0 if unavailable) against the declared
// (pre-negotiation, native-descriptor) values already cached in
// audio_channels/audio_rate at open/select time. CanonicalMixFormat
// (canonical_mix_format.zig) derives the AudioMasterClock/ring sizing/
// _getMixRate() rate from the declared values, NOT from what AVFoundation
// actually delivers, so a mismatch means audio can play at the wrong speed.
// Diagnostic only -- no behavior change.
fn logAudioNegotiation(track_index: i32, declared_channels: i32, declared_rate: i32, cc: c_audio_chunk) void {
    if (cc.channels <= 0 or cc.sample_rate <= 0) return; // no format description on this buffer
    if (declared_rate != cc.sample_rate or declared_channels != cc.channels) {
        log.warn(
            "audio track {d}: delivered PCM format diverges from declared -- declared {d} Hz/{d} ch, pcm {d} Hz/{d} ch",
            .{ track_index, declared_rate, declared_channels, cc.sample_rate, cc.channels },
        );
    }
    log.info(
        "audio negotiated: declared {d} Hz/{d} ch -> pcm {d} Hz/{d} ch",
        .{ declared_rate, declared_channels, cc.sample_rate, cc.channels },
    );
}

/// Construct an AVFoundation backend and return it as the core.Backend
/// ptr+vtable interface. The returned Backend owns its heap allocation and the
/// shim handle; Backend.deinit() releases both.
pub fn create(allocator: std.mem.Allocator) !core.Backend {
    if (builtin.mode == .Debug) assertAbi();

    const shim = nv_avf_create() orelse return error.ShimCreateFailed;
    errdefer nv_avf_destroy(shim);

    const self = try allocator.create(AvfBackend);
    self.* = .{
        .allocator = allocator,
        .shim = shim,
    };
    return .{ .ptr = self, .vtable = &AvfBackend.vtable };
}
