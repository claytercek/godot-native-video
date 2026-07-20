//! Regression coverage for backend.Colorimetry, the single struct carrying
//! a video frame's color primaries, transfer function, matrix coefficients,
//! range, and bit depth.
//!
//! Pins the two default conventions that must coexist:
//!   - Per-frame (VideoFrame.color): Colorimetry{} defaults to all
//!     Unspecified, 8-bit — the shader treats Unspecified as BT.709 video
//!     range.
//!   - Negotiated (Backend.colorimetry() and backend impls):
//!     Colorimetry.bt709_defaults returns concrete BT709/BT709/BT709/Video/8
//!     values.
//!
//! Kept as a sibling file rather than appended to backend.zig.

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

