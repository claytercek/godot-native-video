//! GStreamer Backend. Independent video-only/audio-only graphs deliberately
//! permit serialized callers to drain either stream completely before the other.
//! C owns framework objects/macros; Zig owns state, selection, and frame copies.
const std = @import("std");
const core = @import("core").backend;
const log = std.log.scoped(.gst_backend);
const Asset = opaque {};
const Reader = opaque {};
const Color = extern struct { matrix: c_int, primaries: c_int, transfer: c_int, range: c_int, bit_depth: c_int };
const Info = extern struct { duration: f64, width: c_int, height: c_int, audio_count: c_int, ten_bit: c_int, color: Color };
const Track = extern struct { language: ?[*:0]const u8, name: ?[*:0]const u8, channels: c_int, rate: c_int, is_default: c_int };
const Video = extern struct {
    planes: [2]?[*]const u8,
    strides: [2]isize,
    width: c_int,
    height: c_int,
    format: c_int,
    crop_x: c_int,
    crop_y: c_int,
    crop_width: c_int,
    crop_height: c_int,
    pts: f64,
    color: Color,
};
const Audio = extern struct { samples: ?[*]align(1) const f32, count: usize, channels: c_int, rate: c_int, pts: f64 };
extern fn nv_gst_discover([*:0]const u8) ?*Asset;
extern fn nv_gst_asset_info(*Asset, *Info) c_int;
extern fn nv_gst_asset_track(*Asset, c_int, *Track) c_int;
extern fn nv_gst_asset_error(?*Asset) ?[*:0]const u8;
extern fn nv_gst_asset_destroy(?*Asset) void;
extern fn nv_gst_reader_create(*Asset, c_int, c_int) ?*Reader;
extern fn nv_gst_reader_ready(?*Reader) c_int;
extern fn nv_gst_reader_seek(*Reader, f64) c_int;
extern fn nv_gst_reader_video(*Reader, *Video) c_int;
extern fn nv_gst_reader_audio(*Reader, *Audio) c_int;
extern fn nv_gst_reader_unmap(*Reader) void;
extern fn nv_gst_reader_error(?*Reader) ?[*:0]const u8;
extern fn nv_gst_reader_destroy(?*Reader) void;
extern fn nv_gst_reader_video_info(*Reader, *Info) c_int;
extern fn nv_gst_abi_layout() *const [37]usize;

pub const FrameView = struct { planes: [2][]const u8, strides: [2]usize };
const Payload = struct { view: FrameView };
/// Borrow plane bytes until VideoFrame.release(). Handles never borrow backend
/// storage. P010 words are little-endian and retain their high-bit justification.
pub fn frameView(native_handle: *anyopaque) FrameView {
    const payload: *const Payload = @ptrCast(@alignCast(native_handle));
    return payload.view;
}
fn releaseFrame(ctx: ?*anyopaque) void {
    const payload: *Payload = @ptrCast(@alignCast(ctx.?));
    for (payload.view.planes) |plane| std.heap.c_allocator.free(plane);
    std.heap.c_allocator.destroy(payload);
}
fn color(c: Color) core.Colorimetry {
    return .{
        .matrix = switch (c.matrix) {
            1 => .bt709,
            2 => .bt601,
            3 => .bt2020,
            else => .unspecified,
        },
        .primaries = switch (c.primaries) {
            1 => .bt709,
            2 => .bt601_625,
            3 => .bt601_525,
            4 => .bt2020,
            5 => .dci_p3,
            else => .unspecified,
        },
        .transfer = switch (c.transfer) {
            1 => .bt709,
            2 => .pq,
            3 => .hlg,
            else => .unspecified,
        },
        .range = switch (c.range) {
            1 => .video,
            2 => .full,
            else => .unspecified,
        },
        .bit_depth = c.bit_depth,
    };
}
fn message(p: ?[*:0]const u8) []const u8 {
    return if (p) |z| std.mem.span(z) else "unknown failure";
}

/// Copy full backing planes into tightly packed positive-stride storage.
/// Negative source strides are followed from the mapped top-left pointer.
/// Preserve explicit crop metadata so consumers apply core's floor chroma
/// offset/extent policy. Only uncropped backing geometry uses ceil chroma.
fn copyFrame(v: Video) !core.VideoFrame {
    if (v.width <= 0 or v.height <= 0 or (v.format != 1 and v.format != 2) or !std.math.isFinite(v.pts)) return error.InvalidVideo;
    if (v.crop_x < 0 or v.crop_y < 0 or v.crop_width < 0 or v.crop_height < 0) return error.InvalidCrop;
    const w: usize = @intCast(v.width);
    const h: usize = @intCast(v.height);
    if (v.crop_width > 0 and (v.crop_height == 0 or
        @as(u64, @intCast(v.crop_x)) + @as(u64, @intCast(v.crop_width)) > w or
        @as(u64, @intCast(v.crop_y)) + @as(u64, @intCast(v.crop_height)) > h)) return error.InvalidCrop;
    const bytes: usize = if (v.format == 2) 2 else 1;
    const strides: [2]usize = .{ w * bytes, ((w + 1) / 2) * 2 * bytes };
    const rows: [2]usize = .{ h, (h + 1) / 2 };
    const a = std.heap.c_allocator;
    const p = try a.create(Payload);
    errdefer a.destroy(p);
    const luma = try a.alloc(u8, strides[0] * rows[0]);
    errdefer a.free(luma);
    const chroma = try a.alloc(u8, strides[1] * rows[1]);
    errdefer a.free(chroma);
    p.view = .{ .planes = .{ luma, chroma }, .strides = strides };
    const dests = .{ luma, chroma };
    inline for (0..2) |plane| {
        const base = v.planes[plane] orelse return error.InvalidVideo;
        if (v.strides[plane] == std.math.minInt(isize) or @abs(v.strides[plane]) < strides[plane]) return error.InvalidStride;
        for (0..rows[plane]) |row| {
            const offset = @as(isize, @intCast(row)) * v.strides[plane];
            const address = @as(isize, @intCast(@intFromPtr(base))) + offset;
            const src: [*]const u8 = @ptrFromInt(@as(usize, @intCast(address)));
            @memcpy(dests[plane][row * strides[plane] ..][0..strides[plane]], src[0..strides[plane]]);
        }
    }
    return .{
        .pts_seconds = v.pts,
        .native_handle = p,
        .width = @intCast(w),
        .height = @intCast(h),
        .pixel_format = if (v.format == 2) .x420 else .nv12,
        .crop = .{ .x = @intCast(v.crop_x), .y = @intCast(v.crop_y), .width = @intCast(v.crop_width), .height = @intCast(v.crop_height) },
        .color = color(v.color),
        .release_hook = .{ .ctx = p, .func = releaseFrame },
    };
}

const GstBackend = struct {
    allocator: std.mem.Allocator,
    asset: ?*Asset = null,
    video: ?*Reader = null,
    audio: ?*Reader = null,
    tracks: std.ArrayList(core.AudioTrackInfo) = .empty,
    pcm: std.ArrayList(f32) = .empty,
    duration: f64 = 0,
    width: i32 = 0,
    height: i32 = 0,
    negotiated_color: core.Colorimetry = .bt709_defaults,
    selected: i32 = 0,
    applied: i32 = 0,
    channels: i32 = 0,
    rate: i32 = 0,
    video_done: bool = true,
    audio_done: bool = true,

    fn cast(p: *anyopaque) *GstBackend {
        return @ptrCast(@alignCast(p));
    }
    fn close(p: *anyopaque) void {
        const s = cast(p);
        nv_gst_reader_destroy(s.video);
        s.video = null;
        nv_gst_reader_destroy(s.audio);
        s.audio = null;
        nv_gst_asset_destroy(s.asset);
        s.asset = null;
        s.tracks.clearRetainingCapacity();
        s.pcm.clearRetainingCapacity();
        s.duration = 0;
        s.width = 0;
        s.height = 0;
        s.channels = 0;
        s.rate = 0;
        s.selected = 0;
        s.applied = 0;
        s.negotiated_color = .bt709_defaults;
        s.video_done = true;
        s.audio_done = true;
    }
    fn open(p: *anyopaque, path: []const u8) bool {
        const s = cast(p);
        close(p);
        s.openInner(path) catch |err| {
            log.err("open '{s}': {t}", .{ path, err });
            close(p);
            return false;
        };
        return true;
    }
    fn openInner(s: *GstBackend, path: []const u8) !void {
        if (std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
        const z = try s.allocator.dupeSentinel(u8, path, 0);
        defer s.allocator.free(z);
        s.asset = nv_gst_discover(z.ptr) orelse return error.OutOfMemory;
        var info: Info = undefined;
        if (nv_gst_asset_info(s.asset.?, &info) == 0) {
            log.err("discovery: {s}", .{message(nv_gst_asset_error(s.asset))});
            return error.DiscoveryFailed;
        }
        s.duration = info.duration;
        s.width = info.width;
        s.height = info.height;
        s.negotiated_color = color(info.color);
        for (0..@intCast(@max(info.audio_count, 0))) |i| {
            var track: Track = undefined;
            if (nv_gst_asset_track(s.asset.?, @intCast(i), &track) == 0) return error.InvalidTrack;
            try s.tracks.append(s.allocator, .{ .language = if (track.language) |v| std.mem.span(v) else "", .name = if (track.name) |v| std.mem.span(v) else "", .channels = track.channels, .sample_rate = track.rate, .is_default = track.is_default != 0 });
        }
        if (s.width > 0) {
            s.video = try s.makeReader(true, 0, 0);
            // Read raw negotiated caps, not codec/container guesses.
            if (nv_gst_reader_video_info(s.video.?, &info) != 0) {
                s.width = info.width;
                s.height = info.height;
                s.negotiated_color = color(info.color);
            }
            s.video_done = false;
        }
        if (s.tracks.items.len > 0) {
            s.audio = try s.makeReader(false, 0, 0);
            s.apply(0);
            s.audio_done = false;
        }
    }
    fn makeReader(s: *GstBackend, video: bool, index: i32, pts: f64) !*Reader {
        const r = nv_gst_reader_create(s.asset.?, @intFromBool(video), index) orelse return error.OutOfMemory;
        errdefer nv_gst_reader_destroy(r);
        if (nv_gst_reader_ready(r) == 0 or (pts > 0 and nv_gst_reader_seek(r, pts) == 0)) {
            log.err("{s} reader: {s}", .{ if (video) "video" else "audio", message(nv_gst_reader_error(r)) });
            return error.ReaderFailed;
        }
        return r;
    }
    fn apply(s: *GstBackend, index: i32) void {
        s.selected = index;
        s.applied = index;
        const t = s.tracks.items[@intCast(index)];
        s.channels = t.channels;
        s.rate = t.sample_rate;
    }
    fn clamp(s: *GstBackend, index: i32) i32 {
        return std.math.clamp(index, 0, @as(i32, @intCast(s.tracks.items.len)) - 1);
    }
    fn target(pts: f64) ?f64 {
        return if (std.math.isFinite(pts) and pts < 9.22e9) @max(pts, 0) else null;
    }
    fn seek(p: *anyopaque, pts: f64) bool {
        const s = cast(p);
        if (s.asset == null) return false;
        const t = target(pts) orelse return false;
        // Build replacements before retiring either old graph: seek/reset is
        // transactional, and also recovers EOS or terminal decode failures.
        var video: ?*Reader = null;
        var audio: ?*Reader = null;
        if (s.width > 0) video = s.makeReader(true, 0, t) catch return false;
        if (s.tracks.items.len > 0) audio = s.makeReader(false, s.selected, t) catch {
            nv_gst_reader_destroy(video);
            return false;
        };
        nv_gst_reader_destroy(s.video);
        nv_gst_reader_destroy(s.audio);
        s.video = video;
        s.audio = audio;
        s.video_done = video == null;
        s.audio_done = audio == null;
        if (audio != null) s.apply(s.selected);
        return true;
    }
    fn select(p: *anyopaque, index: i32) void {
        const s = cast(p);
        if (s.tracks.items.len > 0) s.selected = s.clamp(index);
    }
    fn reselect(p: *anyopaque, index: i32, pts: f64) bool {
        const s = cast(p);
        if (s.asset == null or s.tracks.items.len == 0) return false;
        const t = target(pts) orelse return false;
        const i = s.clamp(index);
        const reader = s.makeReader(false, i, t) catch return false;
        nv_gst_reader_destroy(s.audio);
        s.audio = reader;
        s.audio_done = false;
        s.apply(i);
        return true;
    }
    fn nextVideo(p: *anyopaque) ?core.VideoFrame {
        const s = cast(p);
        if (s.video_done) return null;
        const r = s.video orelse return null;
        var v: Video = undefined;
        const result = nv_gst_reader_video(r, &v);
        defer nv_gst_reader_unmap(r);
        if (result != 1) {
            s.video_done = true;
            if (result < 0) log.err("video terminal failure: {s}", .{message(nv_gst_reader_error(r))});
            return null;
        }
        return copyFrame(v) catch |err| {
            log.err("video terminal copy failure: {t}", .{err});
            s.video_done = true;
            return null;
        };
    }
    fn nextAudio(p: *anyopaque) ?core.AudioChunk {
        const s = cast(p);
        if (s.audio_done) return null;
        const r = s.audio orelse return null;
        var a: Audio = undefined;
        const result = nv_gst_reader_audio(r, &a);
        defer nv_gst_reader_unmap(r);
        if (result != 1) {
            s.audio_done = true;
            if (result < 0) log.err("audio terminal failure: {s}", .{message(nv_gst_reader_error(r))});
            return null;
        }
        if (a.samples == null or a.count == 0 or a.channels <= 0 or a.rate <= 0 or a.count / @as(usize, @intCast(a.channels)) > std.math.maxInt(i32)) {
            log.err("audio terminal failure: invalid PCM geometry", .{});
            s.audio_done = true;
            return null;
        }
        s.pcm.resize(s.allocator, a.count) catch {
            log.err("audio terminal failure: PCM allocation", .{});
            s.audio_done = true;
            return null;
        };
        for (s.pcm.items, a.samples.?[0..a.count]) |*dst, src| dst.* = src;
        s.channels = a.channels;
        s.rate = a.rate;
        return .{ .pts_seconds = a.pts, .samples = s.pcm.items, .frame_count = @intCast(a.count / @as(usize, @intCast(a.channels))), .channel_count = a.channels, .sample_rate = a.rate };
    }
    fn deinit(p: *anyopaque) void {
        const s = cast(p);
        close(p);
        s.tracks.deinit(s.allocator);
        s.pcm.deinit(s.allocator);
        s.allocator.destroy(s);
    }
    fn getDuration(p: *anyopaque) f64 {
        return cast(p).duration;
    }
    fn getWidth(p: *anyopaque) i32 {
        return cast(p).width;
    }
    fn getHeight(p: *anyopaque) i32 {
        return cast(p).height;
    }
    fn getChannels(p: *anyopaque) i32 {
        return cast(p).channels;
    }
    fn getRate(p: *anyopaque) i32 {
        return cast(p).rate;
    }
    fn getColor(p: *anyopaque) core.Colorimetry {
        return cast(p).negotiated_color;
    }
    fn trackCount(p: *anyopaque) i32 {
        return @intCast(cast(p).tracks.items.len);
    }
    fn trackInfo(p: *anyopaque, i: i32) core.AudioTrackInfo {
        const s = cast(p);
        return if (i >= 0 and i < s.tracks.items.len) s.tracks.items[@intCast(i)] else .{};
    }
    const vtable: core.Backend.VTable = .{
        .open = open,
        .close = close,
        .deinit = deinit,
        .duration_seconds = getDuration,
        .video_width = getWidth,
        .video_height = getHeight,
        .audio_channel_count = getChannels,
        .audio_sample_rate = getRate,
        .colorimetry = getColor,
        .audio_track_count = trackCount,
        .audio_track_info = trackInfo,
        .select_audio_track = select,
        .reselect_audio_track = reselect,
        .seek = seek,
        .next_video_frame = nextVideo,
        .next_audio_chunk = nextAudio,
    };
};

pub fn create(allocator: std.mem.Allocator) !core.Backend {
    const self = try allocator.create(GstBackend);
    self.* = .{ .allocator = allocator };
    return .{ .ptr = self, .vtable = &GstBackend.vtable };
}

test {
    _ = @import("gst_backend_tests.zig");
}

test "C ABI sizes and every field offset match Zig declarations" {
    const layout = nv_gst_abi_layout();
    var i: usize = 0;
    inline for (.{ Color, Info, Track, Video, Audio }) |T| {
        try std.testing.expectEqual(@sizeOf(T), layout[i]);
        i += 1;
        inline for (@typeInfo(T).@"struct".field_names) |name| {
            try std.testing.expectEqual(@offsetOf(T, name), layout[i]);
            i += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 37), i);
}

test "invalid and missing media discovery owns its error until destruction" {
    const t = std.testing;
    for ([_][*:0]const u8{ "/definitely-missing/gnv-invalid.mp4", "src/gst/gst_shim.h", "src/gst", "/dev/zero", "https://example.invalid/video.mp4" }) |path| {
        const a = nv_gst_discover(path) orelse return error.OutOfMemory;
        defer nv_gst_asset_destroy(a);
        var info: Info = undefined;
        try t.expectEqual(@as(c_int, 0), nv_gst_asset_info(a, &info));
        try t.expect(message(nv_gst_asset_error(a)).len > 0);
    }
}

test "frame copy normalizes padding, negative stride, odd extent and crop" {
    const t = std.testing;
    const y = [_]u8{ 7, 8, 9, 0, 4, 5, 6, 0, 1, 2, 3, 0 };
    const uv = [_]u8{ 30, 31, 32, 33, 0, 0, 20, 21, 22, 23, 0, 0 };
    const v: Video = .{
        .planes = .{ y[8..].ptr, uv[6..].ptr },
        .strides = .{ -4, -6 },
        .width = 3,
        .height = 3,
        .format = 1,
        .crop_x = 0,
        .crop_y = 0,
        .crop_width = 0,
        .crop_height = 0,
        .pts = 0.5,
        .color = .{ .matrix = 1, .primaries = 1, .transfer = 1, .range = 1, .bit_depth = 8 },
    };
    const frame = try copyFrame(v);
    defer frame.release();
    const view = frameView(frame.native_handle.?);
    try t.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9 }, view.planes[0]);
    try t.expectEqualSlices(u8, &.{ 20, 21, 22, 23, 30, 31, 32, 33 }, view.planes[1]);
    try t.expectEqual([2]usize{ 3, 4 }, view.strides);
    var cropped = v;
    cropped.crop_x = 1;
    cropped.crop_y = 1;
    cropped.crop_width = 2;
    cropped.crop_height = 2;
    const cf = try copyFrame(cropped);
    defer cf.release();
    const cv = frameView(cf.native_handle.?);
    try t.expectEqualSlices(u8, view.planes[0], cv.planes[0]);
    try t.expectEqualSlices(u8, view.planes[1], cv.planes[1]);
    try t.expectEqual(@as(i32, 3), cf.width);
    try t.expectEqual(core.CropRect{ .x = 1, .y = 1, .width = 2, .height = 2 }, cf.crop);
    cropped.crop_width = 3;
    try t.expectError(error.InvalidCrop, copyFrame(cropped));
    cropped = v;
    cropped.crop_x = -1;
    try t.expectError(error.InvalidCrop, copyFrame(cropped));
    cropped = v;
    cropped.strides[0] = 2;
    try t.expectError(error.InvalidStride, copyFrame(cropped));
}

test "odd explicit crop remains metadata on full backing planes" {
    const t = std.testing;
    const y = [_]u8{ 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 };
    const uv = [_]u8{ 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2 };
    const frame = try copyFrame(.{
        .planes = .{ &y, &uv },
        .strides = .{ 5, 6 },
        .width = 5,
        .height = 4,
        .format = 1,
        .crop_x = 1,
        .crop_y = 1,
        .crop_width = 3,
        .crop_height = 3,
        .pts = 0,
        .color = .{ .matrix = 1, .primaries = 1, .transfer = 1, .range = 1, .bit_depth = 8 },
    });
    defer frame.release();
    try t.expectEqual(@as(i32, 5), frame.width);
    try t.expectEqual(@as(i32, 4), frame.height);
    try t.expectEqual(core.CropRect{ .x = 1, .y = 1, .width = 3, .height = 3 }, frame.crop);
    const view = frameView(frame.native_handle.?);
    try t.expectEqualSlices(u8, &y, view.planes[0]);
    try t.expectEqualSlices(u8, &uv, view.planes[1]);
    // Crop is intentionally not normalized into a ceil-sized UV payload.
    // Importers apply the explicit crop's floor extent: exactly 1x1 chroma.
    try t.expectEqual(@as(u32, 1), frame.crop.width / 2);
    try t.expectEqual(@as(u32, 1), frame.crop.height / 2);
}

test "P010 retained payload preserves left justified words and HDR metadata" {
    const t = std.testing;
    const y = [_]u8{ 0, 0, 0xc0, 0xff, 0, 0x80, 0, 0x40 };
    const uv = [_]u8{ 0, 0x80, 0, 0x80 };
    const frame = try copyFrame(.{
        .planes = .{ &y, &uv },
        .strides = .{ 4, 4 },
        .width = 2,
        .height = 2,
        .format = 2,
        .crop_x = 0,
        .crop_y = 0,
        .crop_width = 0,
        .crop_height = 0,
        .pts = 1,
        .color = .{ .matrix = 3, .primaries = 4, .transfer = 2, .range = 1, .bit_depth = 10 },
    });
    defer frame.release();
    try t.expectEqual(core.PixelFormat.x420, frame.pixel_format);
    try t.expectEqual(@as(i32, 10), frame.color.bit_depth);
    try t.expectEqual(core.ColorMatrix.bt2020, frame.color.matrix);
    try t.expectEqual(core.TransferFunction.pq, frame.color.transfer);
    try t.expectEqualSlices(u8, &y, frameView(frame.native_handle.?).planes[0]);
}
