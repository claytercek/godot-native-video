//! Pure biplanar CPU upload packing (NV12, P010 LE, and x420 LE). No Godot or GStreamer dependencies.
//! The source planes may have independent strides and no trailing padding on
//! their last row. P010 words are read and written explicitly little-endian.
const std = @import("std");

/// Storage encoding, not the backend pixel-format tag: Linux and Windows
/// carry left-justified P010 under x420, whereas CoreVideo x420 is already
/// right-justified. Never infer this distinction from bit depth alone.
pub const SampleFormat = enum {
    nv12,
    p010_le,
    x420_le,

    pub fn is10Bit(self: SampleFormat) bool {
        return self != .nv12;
    }
};

pub const PackError = error{
    InvalidDimensions,
    InvalidCrop,
    InvalidPlane,
    Overflow,
    BufferTooSmall,
    InvalidDestination,
};

/// Mirrors core.backend.CropRect without making the standalone tests depend
/// on the core module. A zero width means the full declared frame.
pub const Crop = struct {
    x: u32 = 0,
    y: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
};

pub const PlaneRegion = struct {
    source_row_bytes: usize,
    source_rows: usize,
    x_bytes: usize,
    y: usize,
    row_bytes: usize,
    rows: usize,
    shift_p010: bool,

    pub fn packedSize(self: PlaneRegion) PackError!usize {
        return multiply(self.row_bytes, self.rows);
    }
};

pub const Layout = struct {
    format: SampleFormat,
    width: usize,
    height: usize,
    chroma_width: usize,
    chroma_height: usize,
    planes: [2]PlaneRegion,
};

/// Uncropped odd-sized 4:2:0 frames need ceil(width/2) x ceil(height/2)
/// chroma texels. Explicit crops follow CropRect's conservative policy:
/// floor the chroma offset and extent. Reject invalid/empty crops rather
/// than reading padding or silently substituting unrelated pixels.
pub fn frameLayout(width: i32, height: i32, crop: Crop, format: SampleFormat) PackError!Layout {
    if (width <= 0 or height <= 0) return error.InvalidDimensions;
    const source_width: usize = @intCast(width);
    const source_height: usize = @intCast(height);
    const source_chroma_width = halfCeil(source_width);
    const source_chroma_height = halfCeil(source_height);
    const bytes: usize = if (format.is10Bit()) 2 else 1;
    var x: usize = 0;
    var y: usize = 0;
    var w = source_width;
    var h = source_height;
    var cw = source_chroma_width;
    var ch = source_chroma_height;
    if (crop.width != 0) {
        x = crop.x;
        y = crop.y;
        w = crop.width;
        h = crop.height;
        if (h == 0 or w > source_width or h > source_height or
            x > source_width - w or y > source_height - h) return error.InvalidCrop;
        cw = w / 2;
        ch = h / 2;
        if (cw == 0 or ch == 0) return error.InvalidCrop;
    }
    const chroma_bytes = try multiply(2, bytes);
    return .{
        .format = format,
        .width = w,
        .height = h,
        .chroma_width = cw,
        .chroma_height = ch,
        .planes = .{
            .{
                .source_row_bytes = try multiply(source_width, bytes),
                .source_rows = source_height,
                .x_bytes = try multiply(x, bytes),
                .y = y,
                .row_bytes = try multiply(w, bytes),
                .rows = h,
                .shift_p010 = format == .p010_le,
            },
            .{
                .source_row_bytes = try multiply(source_chroma_width, chroma_bytes),
                .source_rows = source_chroma_height,
                .x_bytes = try multiply(x / 2, chroma_bytes),
                .y = y / 2,
                .row_bytes = try multiply(cw, chroma_bytes),
                .rows = ch,
                .shift_p010 = format == .p010_le,
            },
        },
    };
}

/// Independently bounded CPU planes, checked together before any packing or
/// upload allocation. The view borrows its source; platform mapping/retention
/// must stay alive until both planes have been packed.
pub const BiplanarView = struct {
    planes: [2][]const u8,
    strides: [2]usize,
    layout: Layout,

    pub fn init(planes: [2][]const u8, strides: [2]usize, layout: Layout) PackError!BiplanarView {
        for (0..2) |i| try validatePlane(planes[i], strides[i], layout.planes[i]);
        return .{ .planes = planes, .strides = strides, .layout = layout };
    }
};

/// Validate the complete declared source plane before allocating/uploading.
/// In particular, len need not include unused padding after the last row.
pub fn validatePlane(src: []const u8, stride: usize, region: PlaneRegion) PackError!void {
    if (region.source_rows == 0 or region.rows == 0 or region.row_bytes == 0 or
        stride < region.source_row_bytes or region.x_bytes > region.source_row_bytes or
        region.row_bytes > region.source_row_bytes - region.x_bytes or
        region.rows > region.source_rows or region.y > region.source_rows - region.rows)
        return error.InvalidPlane;
    if (region.shift_p010 and (region.x_bytes % 2 != 0 or region.row_bytes % 2 != 0))
        return error.InvalidPlane;
    const last_row = try multiply(region.source_rows - 1, stride);
    const required = try add(last_row, region.source_row_bytes);
    if (src.len < required) return error.BufferTooSmall;
    _ = try region.packedSize();
}

/// Copy a validated crop into tightly packed upload bytes. The destination
/// must have exactly packedSize() bytes. No pointer alignment is assumed.
pub fn packPlane(dst: []u8, src: []const u8, stride: usize, region: PlaneRegion) PackError!void {
    try validatePlane(src, stride, region);
    if (dst.len != try region.packedSize()) return error.InvalidDestination;
    for (0..region.rows) |row| {
        const start = (region.y + row) * stride + region.x_bytes;
        const input = src[start..][0..region.row_bytes];
        const output = dst[row * region.row_bytes ..][0..region.row_bytes];
        if (!region.shift_p010) {
            @memcpy(output, input);
        } else {
            var x: usize = 0;
            while (x < region.row_bytes) : (x += 2) {
                const word = @as(u16, input[x]) | (@as(u16, input[x + 1]) << 8);
                const code = word >> 6;
                output[x] = @truncate(code);
                output[x + 1] = @truncate(code >> 8);
            }
        }
    }
}

fn halfCeil(value: usize) usize {
    return value / 2 + value % 2;
}

fn multiply(a: usize, b: usize) PackError!usize {
    return std.math.mul(usize, a, b) catch error.Overflow;
}

fn add(a: usize, b: usize) PackError!usize {
    return std.math.add(usize, a, b) catch error.Overflow;
}

test "NV12 odd dimensions preserve final chroma texels and independent padding" {
    const layout = try frameLayout(3, 3, .{}, .nv12);
    try std.testing.expectEqual(@as(usize, 2), layout.chroma_width);
    try std.testing.expectEqual(@as(usize, 2), layout.chroma_height);
    const y = [_]u8{ 1, 2, 3, 99, 4, 5, 6, 99, 7, 8, 9 };
    const uv = [_]u8{ 10, 11, 12, 13, 99, 99, 14, 15, 16, 17 };
    var packed_y: [9]u8 = undefined;
    var packed_uv: [8]u8 = undefined;
    try packPlane(&packed_y, &y, 4, layout.planes[0]);
    try packPlane(&packed_uv, &uv, 6, layout.planes[1]);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9 }, &packed_y);
    try std.testing.expectEqualSlices(u8, &.{ 10, 11, 12, 13, 14, 15, 16, 17 }, &packed_uv);
}

test "one pixel NV12 still has a full UV pair" {
    const layout = try frameLayout(1, 1, .{}, .nv12);
    var uv: [2]u8 = undefined;
    try packPlane(&uv, &.{ 128, 129 }, 2, layout.planes[1]);
    try std.testing.expectEqualSlices(u8, &.{ 128, 129 }, &uv);
}

test "P010 shifts unaligned little-endian samples without copying row padding" {
    const layout = try frameLayout(3, 1, .{}, .p010_le);
    // Deliberately start at an odd address; low six bits must be discarded.
    const y = [_]u8{ 99, 0, 0, 0x3f, 0x80, 0xff, 0xff, 99 };
    const uv = [_]u8{ 0, 0x10, 0, 0x80, 0, 0xeb, 0xc0, 0xff };
    var packed_y: [6]u8 = undefined;
    var packed_uv: [8]u8 = undefined;
    try packPlane(&packed_y, y[1..7], 8, layout.planes[0]);
    try packPlane(&packed_uv, &uv, 10, layout.planes[1]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 2, 0xff, 3 }, &packed_y);
    try std.testing.expectEqualSlices(u8, &.{ 64, 0, 0, 2, 0xac, 3, 0xff, 3 }, &packed_uv);
}

test "P010 packs multiple rows with odd byte stride" {
    const layout = try frameLayout(1, 2, .{}, .p010_le);
    var output: [4]u8 = undefined;
    try packPlane(&output, &.{ 0, 0x10, 99, 0, 0x80 }, 3, layout.planes[0]);
    try std.testing.expectEqualSlices(u8, &.{ 64, 0, 0, 2 }, &output);
}

test "explicit crop floors odd chroma offsets and extents" {
    const layout = try frameLayout(5, 4, .{ .x = 1, .y = 1, .width = 3, .height = 3 }, .nv12);
    try std.testing.expectEqual(@as(usize, 1), layout.chroma_width);
    try std.testing.expectEqual(@as(usize, 1), layout.chroma_height);
    var output: [9]u8 = undefined;
    const source = [_]u8{ 0, 1, 2, 3, 4, 99, 10, 11, 12, 13, 14, 99, 20, 21, 22, 23, 24, 99, 30, 31, 32, 33, 34 };
    try packPlane(&output, &source, 6, layout.planes[0]);
    try std.testing.expectEqualSlices(u8, &.{ 11, 12, 13, 21, 22, 23, 31, 32, 33 }, &output);
    var uv: [2]u8 = undefined;
    try packPlane(&uv, &.{ 50, 51, 52, 53, 54, 55, 60, 61, 62, 63, 64, 65 }, 6, layout.planes[1]);
    try std.testing.expectEqualSlices(u8, &.{ 50, 51 }, &uv);
}

test "P010 crop offsets count bytes rather than samples" {
    const layout = try frameLayout(4, 2, .{ .x = 2, .width = 2, .height = 2 }, .p010_le);
    var y: [8]u8 = undefined;
    var uv: [4]u8 = undefined;
    try packPlane(&y, &.{ 0, 0, 0, 0, 0, 0x10, 0, 0x80, 0, 0, 0, 0, 0, 0x10, 0, 0x80 }, 8, layout.planes[0]);
    try packPlane(&uv, &.{ 0, 0, 0, 0, 0, 0x10, 0, 0x80 }, 8, layout.planes[1]);
    try std.testing.expectEqualSlices(u8, &.{ 64, 0, 0, 2, 64, 0, 0, 2 }, &y);
    try std.testing.expectEqualSlices(u8, &.{ 64, 0, 0, 2 }, &uv);
}

test "zero crop width ignores unused crop fields" {
    const layout = try frameLayout(3, 3, .{ .x = 999, .y = 999, .height = 999 }, .nv12);
    try std.testing.expectEqual(@as(usize, 3), layout.width);
    try std.testing.expectEqual(@as(usize, 2), layout.chroma_width);
}

test "reject malformed dimensions and crops" {
    try std.testing.expectError(error.InvalidDimensions, frameLayout(0, 2, .{}, .nv12));
    try std.testing.expectError(error.InvalidDimensions, frameLayout(2, -1, .{}, .nv12));
    try std.testing.expectError(error.InvalidCrop, frameLayout(4, 4, .{ .x = 3, .width = 2, .height = 2 }, .nv12));
    try std.testing.expectError(error.InvalidCrop, frameLayout(4, 4, .{ .width = 2 }, .nv12));
    try std.testing.expectError(error.InvalidCrop, frameLayout(4, 4, .{ .width = 1, .height = 2 }, .nv12));
}

test "reject short planes and bad strides before writing destination" {
    const layout = try frameLayout(3, 3, .{}, .nv12);
    var output: [9]u8 = @splat(77);
    try std.testing.expectError(error.InvalidPlane, packPlane(&output, &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9 }, 0, layout.planes[0]));
    try std.testing.expectError(error.InvalidPlane, packPlane(&output, &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9 }, 2, layout.planes[0]));
    try std.testing.expectError(error.BufferTooSmall, packPlane(&output, &.{ 1, 2, 3, 4, 5, 6, 7, 8 }, 3, layout.planes[0]));
    try std.testing.expectEqualSlices(u8, &@as([9]u8, @splat(77)), &output);
    try std.testing.expectError(error.InvalidDestination, packPlane(output[0..8], &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9 }, 3, layout.planes[0]));
}

test "reject overflowing stride arithmetic" {
    const layout = try frameLayout(1, 3, .{}, .nv12);
    try std.testing.expectError(error.Overflow, validatePlane(&.{}, std.math.maxInt(usize), layout.planes[0]));
}

test "biplanar view checks independently bounded chroma even when luma is valid" {
    const layout = try frameLayout(2, 2, .{}, .nv12);
    const y = [_]u8{ 1, 2, 99, 3, 4 };
    const uv = [_]u8{ 5, 6 };
    const view = try BiplanarView.init(.{ &y, &uv }, .{ 3, 2 }, layout);
    try std.testing.expectEqual(@as(usize, 3), view.strides[0]);
    try std.testing.expectEqual(@as(usize, 2), view.strides[1]);
    try std.testing.expectError(error.BufferTooSmall, BiplanarView.init(.{ &y, uv[0..1] }, .{ 3, 2 }, layout));
    try std.testing.expectError(error.InvalidPlane, BiplanarView.init(.{ &y, &uv }, .{ 3, 1 }, layout));
    try std.testing.expectError(error.BufferTooSmall, BiplanarView.init(.{ y[0..4], &uv }, .{ 3, 2 }, layout));
}

test "right-justified x420 is not shifted like P010" {
    const layout = try frameLayout(2, 2, .{}, .x420_le);
    const y = [_]u8{ 64, 0, 0, 2, 0xac, 3, 0xff, 3 };
    const uv = [_]u8{ 0, 2, 0xff, 3 };
    const view = try BiplanarView.init(.{ &y, &uv }, .{ 4, 4 }, layout);
    var out_y: [8]u8 = undefined;
    var out_uv: [4]u8 = undefined;
    try packPlane(&out_y, view.planes[0], view.strides[0], view.layout.planes[0]);
    try packPlane(&out_uv, view.planes[1], view.strides[1], view.layout.planes[1]);
    try std.testing.expectEqualSlices(u8, &y, &out_y);
    try std.testing.expectEqualSlices(u8, &uv, &out_uv);
    try std.testing.expect(layout.format.is10Bit());
}

test "Windows resolved odd crop packs delayed-slot geometry with padded source rows" {
    // resolveCrop has already clamped the display aperture to (1,1,3,3)
    // inside an aligned 6x4 staging texture. Chroma keeps the Windows floor.
    const layout = try frameLayout(6, 4, .{ .x = 1, .y = 1, .width = 3, .height = 3 }, .nv12);
    const y = [_]u8{ 0, 1, 2, 3, 4, 5, 99, 99, 10, 11, 12, 13, 14, 15, 99, 99, 20, 21, 22, 23, 24, 25, 99, 99, 30, 31, 32, 33, 34, 35 };
    const uv = [_]u8{ 40, 41, 42, 43, 44, 45, 99, 99, 50, 51, 52, 53, 54, 55 };
    const view = try BiplanarView.init(.{ &y, &uv }, .{ 8, 8 }, layout);
    var out_y: [9]u8 = undefined;
    var out_uv: [2]u8 = undefined;
    try packPlane(&out_y, view.planes[0], view.strides[0], view.layout.planes[0]);
    try packPlane(&out_uv, view.planes[1], view.strides[1], view.layout.planes[1]);
    try std.testing.expectEqualSlices(u8, &.{ 11, 12, 13, 21, 22, 23, 31, 32, 33 }, &out_y);
    try std.testing.expectEqualSlices(u8, &.{ 40, 41 }, &out_uv);
}

test "Windows aligned P010 mapping splits Y and UV at RowPitch times height" {
    const layout = try frameLayout(4, 2, .{ .x = 2, .width = 2, .height = 2 }, .p010_le);
    const mapped = [_]u8{
        0, 0, 0, 0, 0, 0x10, 0,    0x80, 99, 99,
        0, 0, 0, 0, 0, 0xeb, 0xc0, 0xff, 99, 99,
        0, 0, 0, 0, 0, 0x10, 0,    0x80, 99, 99,
    };
    const view = try BiplanarView.init(.{ mapped[0..20], mapped[20..30] }, .{ 10, 10 }, layout);
    var y: [8]u8 = undefined;
    var uv: [4]u8 = undefined;
    try packPlane(&y, view.planes[0], view.strides[0], view.layout.planes[0]);
    try packPlane(&uv, view.planes[1], view.strides[1], view.layout.planes[1]);
    try std.testing.expectEqualSlices(u8, &.{ 64, 0, 0, 2, 0xac, 3, 0xff, 3 }, &y);
    try std.testing.expectEqualSlices(u8, &.{ 64, 0, 0, 2 }, &uv);
}
