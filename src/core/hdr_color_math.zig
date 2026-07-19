//! hdr_color_math.zig — port of src/common/hdr_color_math.h.
//!
//! Shared HDR color conversion math functions.
//!
//! Matches ITU-R BT.2100 (PQ/HLG EOTFs), SMPTE ST 2084, BT.2390-4 EETF,
//! and BT.2020->BT.709 primary-matrix conversion. The same mathematical
//! constants appear in src/common/hdr_color_math.glsl for the GPU path; the
//! tests below verify both against published ITU reference values so the
//! constants cannot drift independently.
//!
//! All luminance values are in candelas per square metre (cd/m^2).
//! All normalized signal values are in [0, 1] unless noted.

const std = @import("std");
const backend = @import("backend.zig");

// =======================================================================
// Reference white (SDR target) — 203 cd/m^2 per BT.2408-2 §4.1.
// =======================================================================
pub const reference_white: f64 = 203.0;

// =======================================================================
// PQ EOTF — SMPTE ST 2084 / BT.2100-2 §5.1.1 (Table 5).
//
// Maps non-linear signal N in [0, 1] -> linear luminance L in [0, 10000] cd/m^2.
// =======================================================================
pub const pq_m1: f64 = 2610.0 / 16384.0; // 0.159301757812500
pub const pq_m2: f64 = 2523.0 / 4096.0 * 128.0; // 78.843750000000000
pub const pq_c1: f64 = 3424.0 / 4096.0; // 0.835937500000000
pub const pq_c2: f64 = 2413.0 / 4096.0 * 32.0; // 18.851562500000000
pub const pq_c3: f64 = 2392.0 / 4096.0 * 32.0; // 18.687500000000000
pub const pq_peak: f64 = 10000.0;

pub fn pqEotf(n: f64) f64 {
    if (n <= 0.0) {
        return 0.0;
    }
    const v = std.math.pow(f64, n, 1.0 / pq_m2);
    const num = @max(v - pq_c1, 0.0);
    if (num <= 0.0) {
        return 0.0;
    }
    const den = pq_c2 - pq_c3 * v;
    if (den < 1e-12) {
        return pq_peak;
    }
    return pq_peak * std.math.pow(f64, num / den, 1.0 / pq_m1);
}

// =======================================================================
// HLG Inverse OETF (scene-light EOTF) — BT.2100-2 §5.1.2 (Table 5).
//
// Maps non-linear signal N in [0, 1] -> relative scene luminance L_s,
// normalized so L_s in [0, 1] represents scene light.
// =======================================================================
pub const hlg_a: f64 = 0.17883277;
pub const hlg_b: f64 = 0.28466892; // 1 - 4*a
pub const hlg_c: f64 = 0.55991073; // 0.5 - a*ln(4*a)

pub fn hlgInvOetf(n: f64) f64 {
    if (n <= 0.0) {
        return 0.0;
    }
    if (n <= 0.5) {
        // Linear segment: V' = sqrt(3*E) -> E = V'^2 / 3
        return (n * n) / 3.0;
    }
    // Log segment: V' = a*ln(12*E - b) + c -> E = (exp((V' - c)/a) + b) / 12
    return (@exp((n - hlg_c) / hlg_a) + hlg_b) / 12.0;
}

// =======================================================================
// HLG Reference Display EOTF — BT.2100-2 §5.3.
//
// Drives a hypothetical 1000 cd/m^2 display with system gamma gamma = 1.2.
// Maps scene light L_s -> display luminance L_d in [0, 1000] cd/m^2.
// =======================================================================
pub fn hlgDisplayEotf(n: f64) f64 {
    const l_s = hlgInvOetf(n);
    return 1000.0 * std.math.pow(f64, l_s, 1.2);
}

// =======================================================================
// Tone mapper — maps absolute luminance to SDR display-normalized [0, 1].
//
// Uses a Reinhard-style mapping normalized to the reference white level:
//   L_display = L_abs / (L_abs + L_tw)
//
// This preserves reference white at a visible mid-range level (~0.5 in
// linear space, ~0.73 after OETF) and compresses highlights smoothly
// so full peak maps to ~0.99 — never clipping.
//
// Reference: BT.2390-4 §5.2 (simplified global tone mapping operator).
// =======================================================================
pub fn toneMap(l_abs: f64, l_tw: f64) f64 {
    if (l_abs <= 0.0) {
        return 0.0;
    }
    const l_n = l_abs / l_tw;
    return l_n / (1.0 + l_n);
}

// =======================================================================
// BT.2020 -> BT.709 primary matrix conversion.
//
// Converts linear RGB in BT.2020 primaries to linear RGB in BT.709
// primaries. The matrix is derived from the CIE xy chromaticities of
// the two colour spaces (BT.2020 Table 4, BT.709 Table 2) using
// the standard XYZ intermediary transform.
//
// Coefficients from ITU-R BT.2087-0 §2 (colour conversion).
// =======================================================================
pub const Rgb = struct { r: f64, g: f64, b: f64 };

pub fn bt2020ToBt709(r2020: f64, g2020: f64, b2020: f64) Rgb {
    return .{
        .r = 1.6605 * r2020 - 0.5876 * g2020 - 0.0728 * b2020,
        .g = -0.1249 * r2020 + 1.1330 * g2020 - 0.0081 * b2020,
        .b = -0.0182 * r2020 - 0.0996 * g2020 + 1.1178 * b2020,
    };
}

// =======================================================================
// BT.709 OETF (opto-electronic transfer function).
//
// Maps linear R'G'B' in [0, 1] to non-linear R'G'B' for SDR display
// per BT.709-6 §2.1 (sRGB-approximate piecewise curve).
// =======================================================================
pub fn bt709Oetf(l: f64) f64 {
    if (l < 0.0031308) {
        return 12.92 * l;
    }
    return 1.055 * std.math.pow(f64, l, 1.0 / 2.4) - 0.055;
}

// =======================================================================
// BT.709 EOTF (inverse OETF) — BT.709-6 §2.1 / sRGB.
//
// Maps non-linear signal V in [0, 1] -> linear luminance L in [0, 1].
// =======================================================================
pub fn bt709Eotf(v: f64) f64 {
    if (v < 0.04045) {
        return v / 12.92;
    }
    return std.math.pow(f64, (v + 0.055) / 1.055, 2.4);
}

// =======================================================================
// Convenience: full HDR -> SDR pixel conversion for one RGB triple.
//
// Input:  R, G, B in non-linear PQ or HLG encoded domain, BT.2020 primaries.
// Output: R, G, B in non-linear BT.709 domain, clamped to [0, 1].
//
// transfer: backend.TransferFunction.pq or .hlg, packed as the raw int this
// mirrors in the compute shader's push constants (see push_constants.zig).
// =======================================================================
const transfer_pq: i32 = @intFromEnum(backend.TransferFunction.pq);

pub fn hdrToSdr(r: *f64, g: *f64, b: *f64, transfer: i32) void {
    // Step 1: EOTF (non-linear -> linear absolute luminance)
    var lr: f64 = undefined;
    var lg: f64 = undefined;
    var lb: f64 = undefined;
    if (transfer == transfer_pq) {
        lr = pqEotf(r.*);
        lg = pqEotf(g.*);
        lb = pqEotf(b.*);
    } else {
        lr = hlgDisplayEotf(r.*);
        lg = hlgDisplayEotf(g.*);
        lb = hlgDisplayEotf(b.*);
    }

    // Step 2: Tone-map each channel to SDR-normalized [0, 1].
    lr = toneMap(lr, reference_white);
    lg = toneMap(lg, reference_white);
    lb = toneMap(lb, reference_white);

    // Step 3: BT.2020 -> BT.709 primary conversion.
    const rgb709 = bt2020ToBt709(lr, lg, lb);

    // Step 4: Apply BT.709 OETF (linear -> non-linear for display).
    r.* = bt709Oetf(std.math.clamp(rgb709.r, 0.0, 1.0));
    g.* = bt709Oetf(std.math.clamp(rgb709.g, 0.0, 1.0));
    b.* = bt709Oetf(std.math.clamp(rgb709.b, 0.0, 1.0));

    // Final clamp (OETF can produce very slightly > 1 or < 0 in extreme cases).
    r.* = std.math.clamp(r.*, 0.0, 1.0);
    g.* = std.math.clamp(g.*, 0.0, 1.0);
    b.* = std.math.clamp(b.*, 0.0, 1.0);
}

// =========================================================================
// Tests — ported from tests/core/test_hdr_color_math.cpp.
// =========================================================================

const testing = std.testing;
const ref_tol: f64 = 0.001;

test "PQ EOTF: dark signal" {
    try testing.expect(@abs(pqEotf(0.0) - 0.0) < 1e-10);
    try testing.expect(pqEotf(0.1) > 0.3);
    try testing.expect(pqEotf(0.1) < 0.35);
    try testing.expect(pqEotf(0.25) > 4.0);
    try testing.expect(pqEotf(0.25) < 6.0);
}

test "PQ EOTF: mid range" {
    var l = pqEotf(0.5);
    try testing.expect(l > 80.0);
    try testing.expect(l < 100.0);
    l = pqEotf(0.75);
    try testing.expect(l > 900.0);
    try testing.expect(l < 1050.0);
    l = pqEotf(0.9);
    try testing.expect(l > 3800.0);
    try testing.expect(l < 4000.0);
}

test "PQ EOTF: bright range" {
    const l = pqEotf(0.95);
    try testing.expect(l > 6100.0);
    try testing.expect(l < 6400.0);
    try testing.expect(@abs(pqEotf(1.0) - pq_peak) < 0.1);
}

test "PQ EOTF: reference white level" {
    // PQ signal N~0.58 produces ~203 cd/m^2 (reference white).
    const l_203 = pqEotf(0.58);
    try testing.expect(l_203 > 190.0);
    try testing.expect(l_203 < 210.0);
}

test "PQ constants match ITU-R BT.2100-2 Table 5" {
    try testing.expect(@abs(pq_m1 - 0.159301757812500) < 1e-12);
    try testing.expect(@abs(pq_m2 - 78.84375) < 1e-10);
    try testing.expect(@abs(pq_c1 - 0.83593750) < 1e-8);
    try testing.expect(@abs(pq_c2 - 18.85156250) < 1e-8);
    try testing.expect(@abs(pq_c3 - 18.68750000) < 1e-8);
}

test "HLG constants match ITU-R BT.2100-2 Table 5" {
    try testing.expect(@abs(hlg_a - 0.17883277) < 1e-8);
    try testing.expect(@abs(hlg_b - 0.28466892) < 1e-8);
    try testing.expect(@abs(hlg_c - 0.55991073) < 1e-8);
}

test "HLG inverse OETF: zero signal" {
    try testing.expect(@abs(hlgInvOetf(0.0) - 0.0) < 1e-10);
}

test "HLG inverse OETF: linear segment" {
    // N = 0.25 -> L_s = 0.25^2/3 = 0.02083
    var l = hlgInvOetf(0.25);
    try testing.expect(@abs(l - 0.0208333) < 0.001);
    // N = 0.5 -> L_s = 0.25/3 = 0.08333
    l = hlgInvOetf(0.5);
    try testing.expect(@abs(l - 0.0833333) < 0.001);
}

test "HLG inverse OETF: log segment" {
    // N = 0.75 -> L_s ~ 0.26496
    var l = hlgInvOetf(0.75);
    try testing.expect(l > 0.20);
    try testing.expect(l < 0.30);
    // N = 1.0 -> L_s ~ 1.0
    l = hlgInvOetf(1.0);
    try testing.expect(@abs(l - 1.0) < 0.001);
}

test "HLG display EOTF scales to 1000 cd/m^2" {
    const l = hlgDisplayEotf(1.0);
    try testing.expect(@abs(l - 1000.0) < 20.0);
}

test "HLG display EOTF: reference white level" {
    // HLG signal ~0.75 ~= 203 cd/m^2 on reference display.
    const l_203 = hlgDisplayEotf(0.75);
    try testing.expect(l_203 > 195.0);
    try testing.expect(l_203 < 210.0);
}

test "tone_map: zero maps to zero" {
    try testing.expect(@abs(toneMap(0.0, reference_white)) < 1e-10);
}

test "tone_map: reference white maps to 0.5 linear" {
    // L_abs = L_tw -> L_n = 1.0 -> 1.0/(1+1) = 0.5
    const t = toneMap(reference_white, reference_white);
    try testing.expect(@abs(t - 0.5) < ref_tol);
}

test "tone_map: output in [0, 1) for all finite inputs" {
    var l: f64 = 0.0;
    while (l <= 100000.0) : (l += 1000.0) {
        const t = toneMap(l, reference_white);
        try testing.expect(t >= 0.0);
        try testing.expect(t < 1.0);
    }
}

test "tone_map: monotonic" {
    var l: f64 = 1.0;
    while (l < 9000.0) : (l += 100.0) {
        const t_lo = toneMap(l, reference_white);
        const t_hi = toneMap(l + 5.0, reference_white);
        try testing.expect(t_hi > t_lo);
    }
}

test "tone_map: characteristic values" {
    // PQ: reference white (203) -> 0.5, peak (10000) -> ~0.98
    const tw = toneMap(reference_white, reference_white);
    try testing.expect(@abs(tw - 0.5) < 0.01);
    const peak = toneMap(pq_peak, reference_white);
    try testing.expect(peak > 0.95);
    try testing.expect(peak < 1.0);

    // HLG: reference white -> 0.5, peak (1000) -> ~0.83
    const hlg_tw = toneMap(reference_white, reference_white);
    try testing.expect(@abs(hlg_tw - 0.5) < 0.01);
    const hlg_peak = toneMap(1000.0, reference_white);
    try testing.expect(hlg_peak > 0.80);
    try testing.expect(hlg_peak < 0.85);
}

test "BT.2020 -> BT.709: white remains white" {
    const rgb = bt2020ToBt709(1.0, 1.0, 1.0);
    try testing.expect(@abs(rgb.r - 1.0) < ref_tol);
    try testing.expect(@abs(rgb.g - 1.0) < ref_tol);
    try testing.expect(@abs(rgb.b - 1.0) < ref_tol);
}

test "BT.2020 -> BT.709: black remains black" {
    const rgb = bt2020ToBt709(0.0, 0.0, 0.0);
    try testing.expect(@abs(rgb.r) < 1e-10);
    try testing.expect(@abs(rgb.g) < 1e-10);
    try testing.expect(@abs(rgb.b) < 1e-10);
}

test "BT.2020 -> BT.709: pure red shows dominant red in 709" {
    const rgb = bt2020ToBt709(1.0, 0.0, 0.0);
    try testing.expect(rgb.r > 1.0); // wider gamut red -> >1.0 in 709
    try testing.expect(rgb.g < 0.0);
    try testing.expect(rgb.b < 0.0);
}

test "BT.2020 -> BT.709: pure blue" {
    const rgb = bt2020ToBt709(0.0, 0.0, 1.0);
    try testing.expect(rgb.b > 1.0);
    try testing.expect(rgb.r < 0.0);
    try testing.expect(rgb.g < 0.0);
}

test "BT.2020 -> BT.709: green" {
    const rgb = bt2020ToBt709(0.0, 1.0, 0.0);
    try testing.expect(rgb.g > 0.9);
    try testing.expect(rgb.r < 0.0);
    try testing.expect(rgb.b < 0.0);
}

test "BT.709 OETF: black and white anchors" {
    try testing.expect(@abs(bt709Oetf(0.0)) < 1e-10);
    try testing.expect(@abs(bt709Oetf(1.0) - 1.0) < ref_tol);
}

test "BT.709 OETF: linear segment below threshold" {
    const v = bt709Oetf(0.001);
    try testing.expect(@abs(v - 0.01292) < 1e-5);
}

test "BT.709 OETF: power segment" {
    const v = bt709Oetf(0.5);
    try testing.expect(@abs(v - 0.735) < 0.01);
}

test "BT.709 EOTF: anchors" {
    try testing.expect(@abs(bt709Eotf(0.0)) < 1e-10);
    try testing.expect(@abs(bt709Eotf(1.0) - 1.0) < ref_tol);
}

test "BT.709 EOTF: linear segment below threshold" {
    // V = 0.04045 -> L = 0.0031308
    const l = bt709Eotf(0.04045);
    try testing.expect(@abs(l - 0.0031308) < 1e-6);
    const l2 = bt709Eotf(0.02);
    try testing.expect(@abs(l2 - 0.02 / 12.92) < 1e-6);
}

test "BT.709 EOTF: power segment" {
    // V = 0.5 -> L ~ 0.214041
    const l = bt709Eotf(0.5);
    try testing.expect(l > 0.20);
    try testing.expect(l < 0.23);
}

test "BT.709 EOTF is inverse of OETF" {
    // Round-trip: OETF then EOTF should recover the original value.
    var l: f64 = 0.001;
    while (l <= 1.0) : (l += 0.05) {
        const v = bt709Oetf(l);
        const l_rt = bt709Eotf(v);
        try testing.expect(@abs(l_rt - l) < 0.001);
    }
}

test "hdr_to_sdr: zero input stays zero" {
    var r: f64 = 0.0;
    var g: f64 = 0.0;
    var b: f64 = 0.0;
    hdrToSdr(&r, &g, &b, 2);
    try testing.expect(@abs(r) < 1e-6);
    try testing.expect(@abs(g) < 1e-6);
    try testing.expect(@abs(b) < 1e-6);

    r = 0.0;
    g = 0.0;
    b = 0.0;
    hdrToSdr(&r, &g, &b, 3);
    try testing.expect(@abs(r) < 1e-6);
    try testing.expect(@abs(g) < 1e-6);
    try testing.expect(@abs(b) < 1e-6);
}

test "hdr_to_sdr: output is in [0, 1] for all inputs" {
    var v: f64 = 0.1;
    while (v <= 1.0) : (v += 0.1) {
        var r = v;
        var g = v * 0.8;
        var b = v * 0.6;
        hdrToSdr(&r, &g, &b, 2);
        try testing.expect(r >= 0.0);
        try testing.expect(r <= 1.0);
        try testing.expect(g >= 0.0);
        try testing.expect(g <= 1.0);
        try testing.expect(b >= 0.0);
        try testing.expect(b <= 1.0);
    }
    v = 0.1;
    while (v <= 1.0) : (v += 0.1) {
        var r = v;
        var g = v * 0.8;
        var b = v * 0.6;
        hdrToSdr(&r, &g, &b, 3);
        try testing.expect(r >= 0.0);
        try testing.expect(r <= 1.0);
        try testing.expect(g >= 0.0);
        try testing.expect(g <= 1.0);
        try testing.expect(b >= 0.0);
        try testing.expect(b <= 1.0);
    }
}

test "hdr_to_sdr: dark PQ signal is visible not crushed" {
    var r: f64 = 0.3;
    var g: f64 = 0.3;
    var b: f64 = 0.3;
    hdrToSdr(&r, &g, &b, 2);
    try testing.expect(r > 0.001);
}

test "hdr_to_sdr: PQ reference white maps to visible SDR level" {
    var r: f64 = 0.58;
    var g: f64 = 0.58;
    var b: f64 = 0.58;
    hdrToSdr(&r, &g, &b, 2);
    try testing.expect(r > 0.4);
}

test "hdr_to_sdr: HLG produces watchable output across range" {
    // A typical HLG signal (0.75 bright scene) should produce good visibility.
    var r: f64 = 0.75;
    var g: f64 = 0.75;
    var b: f64 = 0.75;
    hdrToSdr(&r, &g, &b, 3);
    try testing.expect(r > 0.5);
    // Full HLG signal should be bright but not clipped.
    r = 1.0;
    g = 1.0;
    b = 1.0;
    hdrToSdr(&r, &g, &b, 3);
    try testing.expect(r < 1.0);
    try testing.expect(r > 0.7);
}
