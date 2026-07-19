//! colorimetry_test.zig — port of tests/core/test_colorimetry.cpp.
//!
//! Regression coverage for backend.Colorimetry, the single struct that
//! replaced the five parallel scalar colorimetry fields on backend.VideoFrame
//! and the five separate virtuals on backend.Backend.
//!
//! Pins the two default conventions that must coexist:
//!   - Per-frame (VideoFrame.color): Colorimetry{} defaults to all
//!     Unspecified, 8-bit — the shader treats Unspecified as BT.709 video
//!     range.
//!   - Negotiated (Backend.colorimetry() and backend impls):
//!     Colorimetry.bt709_defaults returns concrete BT709/BT709/BT709/Video/8
//!     values.
//!
//! Sibling file per PORTING.md (test_colorimetry.cpp depends solely on
//! backend.h, whose module file is not to be edited): kept separate from
//! backend.zig rather than appended to it.

const std = @import("std");
const backend_mod = @import("backend.zig");

const Backend = backend_mod.Backend;
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

// Minimal stub implementing only the required vtable entries of
// backend.Backend (colorimetry left null), so the interface's default
// colorimetry() implementation is exercised untouched — mirroring the C++
// StubBackend that overrides only the pure virtuals.
const StubBackend = struct {
    fn openFn(_: *anyopaque, _: []const u8) bool {
        return true;
    }
    fn closeFn(_: *anyopaque) void {}
    fn deinitFn(_: *anyopaque) void {}
    fn durFn(_: *anyopaque) f64 {
        return 0.0;
    }
    fn dimFn(_: *anyopaque) i32 {
        return 0;
    }
    fn chFn(_: *anyopaque) i32 {
        return 0;
    }
    fn rateFn(_: *anyopaque) i32 {
        return 0;
    }
    fn seekFn(_: *anyopaque, _: f64) bool {
        return true;
    }
    fn nvfFn(_: *anyopaque) ?backend_mod.VideoFrame {
        return null;
    }
    fn nacFn(_: *anyopaque) ?backend_mod.AudioChunk {
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

test "Backend.colorimetry() base implementation returns the negotiated defaults" {
    var stub: u8 = 0; // no state needed; StubBackend fns are all stateless
    const b: Backend = .{ .ptr = &stub, .vtable = &StubBackend.vtable };
    const color = b.colorimetry();
    try std.testing.expectEqual(ColorMatrix.bt709, color.matrix);
    try std.testing.expectEqual(ColorPrimaries.bt709, color.primaries);
    try std.testing.expectEqual(TransferFunction.bt709, color.transfer);
    try std.testing.expectEqual(ColorRange.video, color.range);
    try std.testing.expectEqual(8, color.bit_depth);
}
