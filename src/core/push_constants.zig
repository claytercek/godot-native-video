//! push_constants.zig — port of src/common/push_constants.h.
//!
//! Byte-packing for the NV12-to-RGB compute shader's push-constant block.
//!
//! The GLSL shader declares a std430 push-constant block with seven uint32
//! and one float (32 bytes total). This file provides the CPU side of that
//! contract: a single pack function that writes the correct bytes so the
//! shader reads them back in the expected layout.
//!
//! Layout (std430, little-endian assumed — x86-64 and ARM64 both are):
//!   offset 0: out_width       (uint32)
//!   offset 4: out_height      (uint32)
//!   offset 8: matrix_select   (uint32) — core::ColorMatrix
//!   offset 12: range_select   (uint32) — core::ColorRange
//!   offset 16: bit_depth      (uint32) — 8 or 10
//!   offset 20: transfer_select (uint32) — core::TransferFunction
//!   offset 24: primaries_select (uint32) — core::ColorPrimaries
//!   offset 28: sample_scale   (float)
//!   Total: push_constant_size (32) bytes
//!
//! A 16-byte multiple is required because pre-4.7 Godot rounds the required
//! push-constant size up to 32 and 4.7+ validates the exact declared size of
//! 32 bytes — this layout satisfies both.

const std = @import("std");
const backend = @import("backend.zig");

/// Size in bytes of the packed push-constant block (see layout above).
pub const push_constant_size: u32 = 32;

/// Exact GPU memory layout of the push-constant block. Field order and
/// widths must match the GLSL std430 declaration in nv12_to_rgb.glsl.
pub const PushConstants = extern struct {
    out_width: u32 = 0,
    out_height: u32 = 0,
    matrix_select: u32 = 0,
    range_select: u32 = 0,
    bit_depth: u32 = 0,
    transfer_select: u32 = 0,
    primaries_select: u32 = 0,
    sample_scale: f32 = 0.0,
};

comptime {
    if (@sizeOf(PushConstants) != push_constant_size) {
        @compileError("push-constant block must stay 32 bytes");
    }
    if (@offsetOf(PushConstants, "out_width") != 0) @compileError("out_width offset must be 0");
    if (@offsetOf(PushConstants, "out_height") != 4) @compileError("out_height offset must be 4");
    if (@offsetOf(PushConstants, "matrix_select") != 8) @compileError("matrix_select offset must be 8");
    if (@offsetOf(PushConstants, "range_select") != 12) @compileError("range_select offset must be 12");
    if (@offsetOf(PushConstants, "bit_depth") != 16) @compileError("bit_depth offset must be 16");
    if (@offsetOf(PushConstants, "transfer_select") != 20) @compileError("transfer_select offset must be 20");
    if (@offsetOf(PushConstants, "primaries_select") != 24) @compileError("primaries_select offset must be 24");
    if (@offsetOf(PushConstants, "sample_scale") != 28) @compileError("sample_scale offset must be 28");
}

/// Pack the frame's colorimetry and output dimensions into the
/// push_constant_size-byte buffer `dst`. `dst` must be at least
/// push_constant_size bytes; only the first push_constant_size bytes are
/// written (anything beyond that in the slice is untouched). The encoding
/// matches the GLSL std430 layout declared in nv12_to_rgb.glsl.
///
/// This is a pure function: no side effects on anything outside `dst`,
/// no heap allocation, no Godot API calls.
pub fn packPushConstants(
    dst: []u8,
    width: u32,
    height: u32,
    color: backend.Colorimetry,
    sample_scale: f32,
) void {
    std.debug.assert(dst.len >= push_constant_size);
    const region = dst[0..push_constant_size];
    @memset(region, 0);
    const pc: PushConstants = .{
        .out_width = width,
        .out_height = height,
        .matrix_select = @intFromEnum(color.matrix),
        .range_select = @intFromEnum(color.range),
        .bit_depth = @bitCast(color.bit_depth),
        .transfer_select = @intFromEnum(color.transfer),
        .primaries_select = @intFromEnum(color.primaries),
        .sample_scale = sample_scale,
    };
    @memcpy(region, std.mem.asBytes(&pc));
}

// =========================================================================
// Tests — ported from tests/core/test_push_constant.cpp.
// =========================================================================

const testing = std.testing;

comptime {
    if (push_constant_size != 32) @compileError("push-constant block must stay 32 bytes");
}

fn checkPackedBytes(
    width: u32,
    height: u32,
    color: backend.Colorimetry,
    sample_scale: f32,
    expected: []const u8,
) !void {
    var buf: [push_constant_size]u8 = undefined;
    packPushConstants(&buf, width, height, color, sample_scale);
    try testing.expectEqualSlices(u8, expected, &buf);
}

test "Push constant: all-zero inputs produce zero-filled buffer (float(0) is also zero)" {
    // width=height=0, all enums=Unspecified(0), bit_depth=0, sample_scale=0.0
    // float 0.0 is bytes 00 00 00 00, so the whole 32 bytes are zeros.
    const color: backend.Colorimetry = .{
        .matrix = .unspecified,
        .primaries = .unspecified,
        .transfer = .unspecified,
        .range = .unspecified,
        .bit_depth = 0,
    };

    const expected = [_]u8{0} ** push_constant_size;
    try checkPackedBytes(0, 0, color, 0.0, &expected);
}

test "Push constant: 1920x1080, BT.709, Video, 8-bit, sample_scale=1.0" {
    const color: backend.Colorimetry = .{
        .matrix = .bt709,
        .range = .video,
        .bit_depth = 8,
        .transfer = .bt709,
        .primaries = .bt709,
    };

    const expected = [_]u8{
        // out_width = 1920 = 0x780 (little-endian)
        0x80, 0x07, 0x00, 0x00,
        // out_height = 1080 = 0x438 (little-endian)
        0x38, 0x04, 0x00, 0x00,
        // matrix_select = BT709 = 1
        0x01, 0x00, 0x00, 0x00,
        // range_select = Video = 1
        0x01, 0x00, 0x00, 0x00,
        // bit_depth = 8
        0x08, 0x00, 0x00, 0x00,
        // transfer_select = BT709 = 1
        0x01, 0x00, 0x00, 0x00,
        // primaries_select = BT709 = 1
        0x01, 0x00, 0x00, 0x00,
        // sample_scale = 1.0f
        0x00, 0x00, 0x80, 0x3f,
    };
    try checkPackedBytes(1920, 1080, color, 1.0, &expected);
}

test "Push constant: 3840x2160, BT.2020, PQ, Full, 10-bit, sample_scale=1.0" {
    const color: backend.Colorimetry = .{
        .matrix = .bt2020,
        .range = .full,
        .bit_depth = 10,
        .transfer = .pq,
        .primaries = .bt2020,
    };

    const expected = [_]u8{
        // out_width = 3840 = 0xF00
        0x00, 0x0F, 0x00, 0x00,
        // out_height = 2160 = 0x870
        0x70, 0x08, 0x00, 0x00,
        // matrix_select = BT2020 = 3
        0x03, 0x00, 0x00, 0x00,
        // range_select = Full = 2
        0x02, 0x00, 0x00, 0x00,
        // bit_depth = 10
        0x0A, 0x00, 0x00, 0x00,
        // transfer_select = PQ = 2
        0x02, 0x00, 0x00, 0x00,
        // primaries_select = BT2020 = 4
        0x04, 0x00, 0x00, 0x00,
        // sample_scale = 1.0f
        0x00, 0x00, 0x80, 0x3f,
    };
    try checkPackedBytes(3840, 2160, color, 1.0, &expected);
}

test "Push constant: 720x576, BT.601, BT.601_625, HLG, Video, 8-bit" {
    const color: backend.Colorimetry = .{
        .matrix = .bt601,
        .range = .video,
        .bit_depth = 8,
        .transfer = .hlg,
        .primaries = .bt601_625,
    };

    const expected = [_]u8{
        // out_width = 720 = 0x2D0
        0xD0, 0x02, 0x00, 0x00,
        // out_height = 576 = 0x240
        0x40, 0x02, 0x00, 0x00,
        // matrix_select = BT601 = 2
        0x02, 0x00, 0x00, 0x00,
        // range_select = Video = 1
        0x01, 0x00, 0x00, 0x00,
        // bit_depth = 8
        0x08, 0x00, 0x00, 0x00,
        // transfer_select = HLG = 3
        0x03, 0x00, 0x00, 0x00,
        // primaries_select = BT601_625 = 2
        0x02, 0x00, 0x00, 0x00,
        // sample_scale = 1.0f
        0x00, 0x00, 0x80, 0x3f,
    };
    try checkPackedBytes(720, 576, color, 1.0, &expected);
}

test "Push constant: sample_scale=1/64 from DXGI left-justified P010" {
    const color: backend.Colorimetry = .{
        .matrix = .bt2020,
        .range = .full,
        .bit_depth = 10,
        .transfer = .pq,
        .primaries = .dci_p3,
    };

    const expected = [_]u8{
        // out_width = 1920
        0x80, 0x07, 0x00, 0x00,
        // out_height = 1080
        0x38, 0x04, 0x00, 0x00,
        // matrix_select = BT2020 = 3
        0x03, 0x00, 0x00, 0x00,
        // range_select = Full = 2
        0x02, 0x00, 0x00, 0x00,
        // bit_depth = 10
        0x0A, 0x00, 0x00, 0x00,
        // transfer_select = PQ = 2
        0x02, 0x00, 0x00, 0x00,
        // primaries_select = DCI_P3 = 5
        0x05, 0x00, 0x00, 0x00,
        // sample_scale = 1/64 ~= 0.015625
        0x00, 0x00, 0x80, 0x3C,
    };
    try checkPackedBytes(1920, 1080, color, 1.0 / 64.0, &expected);
}

test "Push constant: does not write past byte 31" {
    // Write region + 4 guard bytes: buf[0..2] and buf[34..36] must stay 0xAB.
    var buf: [push_constant_size + 4]u8 = undefined;
    @memset(&buf, 0xAB);
    const color: backend.Colorimetry = .{}; // default/zero Colorimetry
    packPushConstants(buf[2..], 0, 0, color, 0.0);
    // Guard bytes before the written region must stay untouched.
    try testing.expectEqual(@as(u8, 0xAB), buf[0]);
    try testing.expectEqual(@as(u8, 0xAB), buf[1]);
    // Guard bytes after the written region must stay untouched.
    try testing.expectEqual(@as(u8, 0xAB), buf[push_constant_size + 2]);
    try testing.expectEqual(@as(u8, 0xAB), buf[push_constant_size + 3]);
    // The written region (buf[2..34]) is zeroed by memset inside
    // packPushConstants. Spot-check the first and last written bytes.
    try testing.expectEqual(@as(u8, 0), buf[2]);
    try testing.expectEqual(@as(u8, 0), buf[2 + push_constant_size - 1]);
}
