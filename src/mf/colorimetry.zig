//! colorimetry.zig — pure colorimetry / time-base translation for the Media
//! Foundation backend.
//!
//! Everything here is a pure function of its inputs (no MfBackend state): the
//! MF_MT_YUV_MATRIX / _VIDEO_PRIMARIES / _TRANSFER_FUNCTION / _VIDEO_NOMINAL_RANGE
//! attribute parsers, source bit-depth detection, and the 100ns tick <-> seconds
//! conversion. Split out of mf_backend.zig so the policy core stays small and so
//! these branches can carry their own unit tests (the backend proper needs live
//! MF objects to exercise). Structural mirror of the C++ parsers.

const std = @import("std");
const core = @import("core").backend;

const win = @import("win.zig");
const com = win.com;
const mf = win.mf;

// ---------------------------------------------------------------------------
// Time base. MF sample/duration times are in 100-nanosecond units (10^7 per
// second), the Media Foundation time base. PTS in seconds = ticks / 1e7.
// ---------------------------------------------------------------------------
pub const ticks_per_second: f64 = 10_000_000.0;

pub fn ticksToSeconds(ticks: i64) f64 {
    return @as(f64, @floatFromInt(ticks)) / ticks_per_second;
}
pub fn secondsToTicks(seconds: f64) i64 {
    return @intFromFloat(seconds * ticks_per_second + 0.5);
}

// ---------------------------------------------------------------------------
// Colorimetry translation — map MF attribute values to the core enums.
// Unrecognised/absent values map to Unspecified so the caller's BT.709
// video-range defaults stay in effect.
// ---------------------------------------------------------------------------
pub fn parseMatrix(v: u32) core.ColorMatrix {
    return switch (v) {
        mf.MFVideoTransferMatrix_BT709 => .bt709,
        mf.MFVideoTransferMatrix_BT601 => .bt601,
        mf.MFVideoTransferMatrix_BT2020_10, mf.MFVideoTransferMatrix_BT2020_12 => .bt2020,
        else => .unspecified,
    };
}

pub fn parsePrimaries(v: u32) core.ColorPrimaries {
    return switch (v) {
        mf.MFVideoPrimaries_BT709 => .bt709,
        mf.MFVideoPrimaries_BT470_2_SysBG, mf.MFVideoPrimaries_EBU3213 => .bt601_625,
        mf.MFVideoPrimaries_SMPTE170M, mf.MFVideoPrimaries_SMPTE_C => .bt601_525,
        mf.MFVideoPrimaries_BT2020 => .bt2020,
        mf.MFVideoPrimaries_DCI_P3 => .dci_p3,
        else => .unspecified,
    };
}

pub fn parseTransfer(v: u32) core.TransferFunction {
    return switch (v) {
        mf.MFVideoTransFunc_709, mf.MFVideoTransFunc_sRGB => .bt709,
        mf.MFVideoTransFunc_2084 => .pq,
        mf.MFVideoTransFunc_HLG => .hlg,
        else => .unspecified,
    };
}

pub fn parseRange(v: u32) core.ColorRange {
    return switch (v) {
        mf.MFNominalRange_0_255 => .full,
        mf.MFNominalRange_16_235 => .video,
        else => .unspecified,
    };
}

// Detect the source's bit depth from the native (pre-conversion) video media
// type. MF_MT_MPEG2_PROFILE carries the demuxer-parsed HEVC general_profile_idc;
// profile 2 (eAVEncH265VProfile_Main_420_10) identifies a 10-bit 4:2:0 source.
// Absent or any other value defaults to 8-bit.
pub fn detectBitDepth(native: *mf.IMFMediaType) i32 {
    var profile: u32 = 0;
    if (com.SUCCEEDED(native.asAttributes().GetUINT32(&mf.MF_MT_MPEG2_PROFILE, &profile))) {
        if (profile == mf.eAVEncH265VProfile_Main_420_10) return 10;
    }
    return 8;
}

// ---------------------------------------------------------------------------
// Tests. These parsers had zero coverage; exercise every real GUID/enum branch
// plus the unmapped fallthrough, and round-trip the tick helpers.
// ---------------------------------------------------------------------------
const testing = std.testing;

test parseMatrix {
    try testing.expectEqual(core.ColorMatrix.bt709, parseMatrix(mf.MFVideoTransferMatrix_BT709));
    try testing.expectEqual(core.ColorMatrix.bt601, parseMatrix(mf.MFVideoTransferMatrix_BT601));
    try testing.expectEqual(core.ColorMatrix.bt2020, parseMatrix(mf.MFVideoTransferMatrix_BT2020_10));
    try testing.expectEqual(core.ColorMatrix.bt2020, parseMatrix(mf.MFVideoTransferMatrix_BT2020_12));
    try testing.expectEqual(core.ColorMatrix.unspecified, parseMatrix(0));
    try testing.expectEqual(core.ColorMatrix.unspecified, parseMatrix(9999));
}

test parsePrimaries {
    try testing.expectEqual(core.ColorPrimaries.bt709, parsePrimaries(mf.MFVideoPrimaries_BT709));
    try testing.expectEqual(core.ColorPrimaries.bt601_625, parsePrimaries(mf.MFVideoPrimaries_BT470_2_SysBG));
    try testing.expectEqual(core.ColorPrimaries.bt601_625, parsePrimaries(mf.MFVideoPrimaries_EBU3213));
    try testing.expectEqual(core.ColorPrimaries.bt601_525, parsePrimaries(mf.MFVideoPrimaries_SMPTE170M));
    try testing.expectEqual(core.ColorPrimaries.bt601_525, parsePrimaries(mf.MFVideoPrimaries_SMPTE_C));
    try testing.expectEqual(core.ColorPrimaries.bt2020, parsePrimaries(mf.MFVideoPrimaries_BT2020));
    try testing.expectEqual(core.ColorPrimaries.dci_p3, parsePrimaries(mf.MFVideoPrimaries_DCI_P3));
    try testing.expectEqual(core.ColorPrimaries.unspecified, parsePrimaries(0));
    try testing.expectEqual(core.ColorPrimaries.unspecified, parsePrimaries(9999));
}

test parseTransfer {
    try testing.expectEqual(core.TransferFunction.bt709, parseTransfer(mf.MFVideoTransFunc_709));
    try testing.expectEqual(core.TransferFunction.bt709, parseTransfer(mf.MFVideoTransFunc_sRGB));
    try testing.expectEqual(core.TransferFunction.pq, parseTransfer(mf.MFVideoTransFunc_2084));
    try testing.expectEqual(core.TransferFunction.hlg, parseTransfer(mf.MFVideoTransFunc_HLG));
    try testing.expectEqual(core.TransferFunction.unspecified, parseTransfer(0));
    try testing.expectEqual(core.TransferFunction.unspecified, parseTransfer(9999));
}

test parseRange {
    try testing.expectEqual(core.ColorRange.full, parseRange(mf.MFNominalRange_0_255));
    try testing.expectEqual(core.ColorRange.video, parseRange(mf.MFNominalRange_16_235));
    try testing.expectEqual(core.ColorRange.unspecified, parseRange(0));
    try testing.expectEqual(core.ColorRange.unspecified, parseRange(9999));
}

test "tick <-> seconds round-trip" {
    try testing.expectEqual(@as(f64, 1.0), ticksToSeconds(10_000_000));
    try testing.expectEqual(@as(f64, 0.0), ticksToSeconds(0));
    try testing.expectEqual(@as(i64, 10_000_000), secondsToTicks(1.0));
    try testing.expectEqual(@as(i64, 0), secondsToTicks(0.0));
    // secondsToTicks rounds to the nearest tick.
    try testing.expectEqual(@as(i64, 5_000_000), secondsToTicks(0.5));
    // Round-trip a representative PTS.
    const ticks: i64 = 33_366_666; // ~one frame at 29.97 fps
    try testing.expectEqual(ticks, secondsToTicks(ticksToSeconds(ticks)));
}
