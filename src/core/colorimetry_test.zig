//! Tests for backend.Colorimetry defaults. Per-frame Colorimetry{} is
//! Unspecified, 8-bit; the shader interprets it as BT.709 video range.
//! Negotiated colorimetry uses bt709_defaults with explicit BT.709 primaries,
//! transfer, and matrix, video range, and 8-bit depth.

const std = @import("std");
const backend_mod = @import("backend.zig");

const ColorMatrix = backend_mod.ColorMatrix;
const ColorPrimaries = backend_mod.ColorPrimaries;
const ColorRange = backend_mod.ColorRange;
const Colorimetry = backend_mod.Colorimetry;
const TransferFunction = backend_mod.TransferFunction;

test "Colorimetry default-constructs to the per-frame Unspecified convention" {
    const color: Colorimetry = .{};
    try std.testing.expectEqual(ColorMatrix.unspecified, color.matrix);
    try std.testing.expectEqual(ColorPrimaries.unspecified, color.primaries);
    try std.testing.expectEqual(TransferFunction.unspecified, color.transfer);
    try std.testing.expectEqual(ColorRange.unspecified, color.range);
    try std.testing.expectEqual(8, color.bit_depth);
}

test "Colorimetry.bt709_defaults returns the negotiated-default convention" {
    const color: Colorimetry = Colorimetry.bt709_defaults;
    try std.testing.expectEqual(ColorMatrix.bt709, color.matrix);
    try std.testing.expectEqual(ColorPrimaries.bt709, color.primaries);
    try std.testing.expectEqual(TransferFunction.bt709, color.transfer);
    try std.testing.expectEqual(ColorRange.video, color.range);
    try std.testing.expectEqual(8, color.bit_depth);
}
