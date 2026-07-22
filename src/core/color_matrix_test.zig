//! Reference-value tests for the YCbCr→RGB matrix derivations used by the
//! NV12→RGB present shader. Platform-independent: no GPU, no Godot. Verifies
//! the BT.601 / BT.709 / BT.2020 coefficients against ITU-R reference values
//! AND parses the actual embedded shader SOURCE TEXT (core/shaders.zig) to
//! catch the shader's code diverging from its own derivation — something a
//! hand-maintained reference mirror can never see.
//!
//! Run standalone:
//!   zig test zig/src/core/color_matrix_test.zig

const std = @import("std");
const testing = std.testing;
const shaders = @import("shaders.zig");

// -----------------------------------------------------------------------
// YCbCr→RGB conversion (reference implementation matching the shader).
// -----------------------------------------------------------------------

/// Normalise a video-range luma sample [16,235] to [0,1].
fn yVideoToLinear(y: u8) f64 {
    return (@as(f64, @floatFromInt(y)) - 16.0) / 219.0;
}

/// Normalise a video-range chroma sample [16,240] to [-0.5, 0.5].
fn cVideoToLinear(c: u8) f64 {
    return (@as(f64, @floatFromInt(c)) - 128.0) / 224.0;
}

/// Normalise a full-range luma sample [0,255] to [0,1].
fn yFullToLinear(y: u8) f64 {
    return @as(f64, @floatFromInt(y)) / 255.0;
}

fn cFullToLinear(c: u8) f64 {
    return (@as(f64, @floatFromInt(c)) - 128.0) / 255.0;
}

// BT.601 coefficients (SD, ITU-R BT.601-7)
const Bt601Coeffs = struct {
    const Kr: f64 = 0.299;
    const Kb: f64 = 0.114;
    const Kg: f64 = 1.0 - Kr - Kb; // 0.587

    const r_cr: f64 = 2.0 * (1.0 - Kr); // 1.402
    const b_cb: f64 = 2.0 * (1.0 - Kb); // 1.772
    const g_cb: f64 = -2.0 * Kb * (1.0 - Kb) / Kg; // -0.344
    const g_cr: f64 = -2.0 * Kr * (1.0 - Kr) / Kg; // -0.714
};

// BT.709 coefficients (HD, ITU-R BT.709-6)
const Bt709Coeffs = struct {
    const Kr: f64 = 0.2126;
    const Kb: f64 = 0.0722;
    const Kg: f64 = 1.0 - Kr - Kb; // 0.7152

    const r_cr: f64 = 2.0 * (1.0 - Kr); // 1.5748
    const b_cb: f64 = 2.0 * (1.0 - Kb); // 1.8556
    const g_cb: f64 = -2.0 * Kb * (1.0 - Kb) / Kg; // -0.1873
    const g_cr: f64 = -2.0 * Kr * (1.0 - Kr) / Kg; // -0.4681
};

// BT.2020 coefficients (UHD, ITU-R BT.2020-2)
const Bt2020Coeffs = struct {
    const Kr: f64 = 0.2627;
    const Kb: f64 = 0.0593;
    const Kg: f64 = 1.0 - Kr - Kb; // 0.6780

    const r_cr: f64 = 2.0 * (1.0 - Kr); // 1.4746
    const b_cb: f64 = 2.0 * (1.0 - Kb); // 1.8814
    const g_cb: f64 = -2.0 * Kb * (1.0 - Kb) / Kg; // -0.1645
    const g_cr: f64 = -2.0 * Kr * (1.0 - Kr) / Kg; // -0.5714
};

const Rgb = struct { r: f64, g: f64, b: f64 };

/// Convert Y'CbCr to R'G'B' using the given coefficients.
fn ycbcrToRgb(y: f64, cb: f64, cr: f64, r_cr: f64, g_cb: f64, g_cr: f64, b_cb: f64) Rgb {
    return .{
        .r = y + r_cr * cr,
        .g = y + g_cb * cb + g_cr * cr,
        .b = y + b_cb * cb,
    };
}

/// Tolerance for floating-point comparison in these tests.
const tol: f64 = 0.001;

// -----------------------------------------------------------------------
// Shader-source coefficient parsing (for the regression guard test below).
//
// Parses the actual embedded GLSL SOURCE TEXT (core/shaders.zig's
// nv12_to_rgb_compute, the SDR embedding) to catch a shader whose code
// diverges from its own derivation.
// -----------------------------------------------------------------------

const ParsedCoeffs = struct {
    r_cr: f64 = 0.0,
    g_cb: f64 = 0.0,
    g_cr: f64 = 0.0,
    b_cb: f64 = 0.0,
};

/// Drop any line whose first non-whitespace characters are "//" so the parser
/// can't match the illustrative comment table above the matrix code (e.g.
/// "// BT.709 (HD): R=Y+1.57480*Cr ...") instead of the real `rgb.r = ...`
/// assignment statements. Returns a heap buffer the caller frees.
fn stripCommentLines(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const first = std.mem.indexOfNone(u8, line, " \t");
        if (first) |f| {
            if (line.len - f >= 2 and std.mem.eql(u8, line[f .. f + 2], "//")) {
                continue;
            }
        }
        try out.appendSlice(allocator, line);
        try out.append(allocator, '\n');
    }
    return out.toOwnedSlice(allocator);
}

/// Parse the first floating-point literal that appears after `after` within
/// `s`, starting the search at `from`. Returns the value and the index just
/// past the parsed number.
fn parseFloatAfter(s: []const u8, from: usize, needle: []const u8) ?struct { value: f64, end: usize } {
    const pos = std.mem.indexOfPos(u8, s, from, needle) orelse return null;
    var i = pos + needle.len;
    // Skip whitespace.
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) : (i += 1) {}
    const start = i;
    while (i < s.len and (std.ascii.isDigit(s[i]) or s[i] == '.')) : (i += 1) {}
    if (i == start) return null;
    const value = std.fmt.parseFloat(f64, s[start..i]) catch return null;
    return .{ .value = value, .end = i };
}

/// Parse the three coefficient assignment lines out of one matrix branch's
/// code block. The shader writes the g-channel line as two subtractions with
/// positive literals (`rgb.g = yf - A * cb - B * cr;`), so the signed
/// coefficients (negative, matching Bt*Coeffs.g_cb/g_cr) are the negation of
/// the parsed magnitudes.
fn parseMatrixBlock(allocator: std.mem.Allocator, block_raw: []const u8) !ParsedCoeffs {
    const block = try stripCommentLines(allocator, block_raw);
    defer allocator.free(block);

    var result: ParsedCoeffs = .{};

    // rgb.r = yf + <r_cr> * cr;
    const r_line = std.mem.indexOf(u8, block, "rgb.r").?;
    result.r_cr = (parseFloatAfter(block, r_line, "yf +").?).value;

    // rgb.g = yf - <g_cb> * cb - <g_cr> * cr;
    const g_line = std.mem.indexOf(u8, block, "rgb.g").?;
    const g_cb_parsed = parseFloatAfter(block, g_line, "yf -").?;
    result.g_cb = -g_cb_parsed.value;
    // Second subtraction: the "- <g_cr> * cr" after the cb term.
    result.g_cr = -(parseFloatAfter(block, g_cb_parsed.end, "-").?).value;

    // rgb.b = yf + <b_cb> * cb;
    const b_line = std.mem.indexOf(u8, block, "rgb.b").?;
    result.b_cb = (parseFloatAfter(block, b_line, "yf +").?).value;

    return result;
}

// =========================================================================
// Tests
// =========================================================================

test "BT.601 matrix coefficients match ITU-R BT.601-7" {
    try testing.expect(@abs(Bt601Coeffs.r_cr - 1.402) < tol);
    try testing.expect(@abs(Bt601Coeffs.b_cb - 1.772) < tol);
    try testing.expect(@abs(Bt601Coeffs.g_cb - (-0.34414)) < tol);
    try testing.expect(@abs(Bt601Coeffs.g_cr - (-0.71414)) < tol);
}

test "BT.709 matrix coefficients match ITU-R BT.709-6" {
    try testing.expect(@abs(Bt709Coeffs.r_cr - 1.5748) < tol);
    try testing.expect(@abs(Bt709Coeffs.b_cb - 1.8556) < tol);
    try testing.expect(@abs(Bt709Coeffs.g_cb - (-0.18732)) < tol);
    try testing.expect(@abs(Bt709Coeffs.g_cr - (-0.46812)) < tol);
}

test "BT.2020 matrix coefficients match ITU-R BT.2020-2" {
    try testing.expect(@abs(Bt2020Coeffs.r_cr - 1.4746) < tol);
    try testing.expect(@abs(Bt2020Coeffs.b_cb - 1.8814) < tol);
    try testing.expect(@abs(Bt2020Coeffs.g_cb - (-0.16455)) < tol);
    try testing.expect(@abs(Bt2020Coeffs.g_cr - (-0.57135)) < tol);
}

test "Shader source matrix coefficients match ITU-R derivations (regression guard)" {
    // Parse the embedded shader SOURCE TEXT itself (not a hand-reimplemented
    // mirror) and check its rgb.r/rgb.g/rgb.b coefficients against the
    // ITU-derived constants above. The SDR embedding is checked; the HDR
    // embedding comes from the same source and differs only by an injected
    // #define, so the matrix-selection code is identical in both.
    const allocator = testing.allocator;
    const source = shaders.nv12_to_rgb_compute;

    // matrix_select: 2u=BT.601, 3u=BT.2020, else (default)=BT.709.
    const bt601_pos = std.mem.indexOf(u8, source, "if (params.matrix_select == 2u) {").?;
    const bt2020_pos = std.mem.indexOfPos(u8, source, bt601_pos, "} else if (params.matrix_select == 3u) {").?;
    const bt709_pos = std.mem.indexOfPos(u8, source, bt2020_pos, "} else {").?;
    const bt709_end = std.mem.indexOfPos(u8, source, bt709_pos, "\n\t}\n").?;

    const bt601 = try parseMatrixBlock(allocator, source[bt601_pos..bt2020_pos]);
    const bt2020 = try parseMatrixBlock(allocator, source[bt2020_pos..bt709_pos]);
    const bt709 = try parseMatrixBlock(allocator, source[bt709_pos..bt709_end]);

    try testing.expect(@abs(bt601.r_cr - Bt601Coeffs.r_cr) < tol);
    try testing.expect(@abs(bt601.g_cb - Bt601Coeffs.g_cb) < tol);
    try testing.expect(@abs(bt601.g_cr - Bt601Coeffs.g_cr) < tol);
    try testing.expect(@abs(bt601.b_cb - Bt601Coeffs.b_cb) < tol);

    try testing.expect(@abs(bt2020.r_cr - Bt2020Coeffs.r_cr) < tol);
    try testing.expect(@abs(bt2020.g_cb - Bt2020Coeffs.g_cb) < tol);
    try testing.expect(@abs(bt2020.g_cr - Bt2020Coeffs.g_cr) < tol);
    try testing.expect(@abs(bt2020.b_cb - Bt2020Coeffs.b_cb) < tol);

    try testing.expect(@abs(bt709.r_cr - Bt709Coeffs.r_cr) < tol);
    try testing.expect(@abs(bt709.g_cb - Bt709Coeffs.g_cb) < tol);
    try testing.expect(@abs(bt709.g_cr - Bt709Coeffs.g_cr) < tol);
    try testing.expect(@abs(bt709.b_cb - Bt709Coeffs.b_cb) < tol);
}

test "White reference: BT.601 video-range YCbCr maps to RGB=1,1,1" {
    const y = yVideoToLinear(235); // 1.0
    const cb = cVideoToLinear(128); // 0.0
    const cr = cVideoToLinear(128); // 0.0
    const c = ycbcrToRgb(y, cb, cr, Bt601Coeffs.r_cr, Bt601Coeffs.g_cb, Bt601Coeffs.g_cr, Bt601Coeffs.b_cb);
    try testing.expect(@abs(c.r - 1.0) < tol);
    try testing.expect(@abs(c.g - 1.0) < tol);
    try testing.expect(@abs(c.b - 1.0) < tol);
}

test "Black reference: BT.709 video-range YCbCr maps to RGB=0,0,0" {
    const y = yVideoToLinear(16);
    const cb = cVideoToLinear(128);
    const cr = cVideoToLinear(128);
    const c = ycbcrToRgb(y, cb, cr, Bt709Coeffs.r_cr, Bt709Coeffs.g_cb, Bt709Coeffs.g_cr, Bt709Coeffs.b_cb);
    try testing.expect(@abs(c.r - 0.0) < tol);
    try testing.expect(@abs(c.g - 0.0) < tol);
    try testing.expect(@abs(c.b - 0.0) < tol);
}

test "BT.2020 black reference: video-range YCbCr maps to RGB=0,0,0" {
    const y = yVideoToLinear(16);
    const cb = cVideoToLinear(128);
    const cr = cVideoToLinear(128);
    const c = ycbcrToRgb(y, cb, cr, Bt2020Coeffs.r_cr, Bt2020Coeffs.g_cb, Bt2020Coeffs.g_cr, Bt2020Coeffs.b_cb);
    try testing.expect(@abs(c.r - 0.0) < tol);
    try testing.expect(@abs(c.g - 0.0) < tol);
    try testing.expect(@abs(c.b - 0.0) < tol);
}

test "BT.2020 white reference: video-range YCbCr maps to RGB=1,1,1" {
    const y = yVideoToLinear(235);
    const cb = cVideoToLinear(128);
    const cr = cVideoToLinear(128);
    const c = ycbcrToRgb(y, cb, cr, Bt2020Coeffs.r_cr, Bt2020Coeffs.g_cb, Bt2020Coeffs.g_cr, Bt2020Coeffs.b_cb);
    try testing.expect(@abs(c.r - 1.0) < tol);
    try testing.expect(@abs(c.g - 1.0) < tol);
    try testing.expect(@abs(c.b - 1.0) < tol);
}

test "BT.2020 and BT.709 produce different RGB for the same YCbCr (UHD vs HD)" {
    const y = yVideoToLinear(30);
    const cb = cVideoToLinear(240);
    const cr = cVideoToLinear(110);
    const a = ycbcrToRgb(y, cb, cr, Bt2020Coeffs.r_cr, Bt2020Coeffs.g_cb, Bt2020Coeffs.g_cr, Bt2020Coeffs.b_cb);
    const b = ycbcrToRgb(y, cb, cr, Bt709Coeffs.r_cr, Bt709Coeffs.g_cb, Bt709Coeffs.g_cr, Bt709Coeffs.b_cb);
    const diff = @abs(a.b - b.b) + @abs(a.g - b.g);
    try testing.expect(diff > 0.01);
}

test "Red-dominant YCbCr decodes to R-heavy RGB: BT.601" {
    const y = yVideoToLinear(82);
    const cb = cVideoToLinear(90);
    const cr = cVideoToLinear(240);
    const c = ycbcrToRgb(y, cb, cr, Bt601Coeffs.r_cr, Bt601Coeffs.g_cb, Bt601Coeffs.g_cr, Bt601Coeffs.b_cb);
    try testing.expect(c.r > 0.9);
    try testing.expect(c.r > c.g * 3.0);
    try testing.expect(c.r > c.b * 3.0);
}

test "BT.601 and BT.709 produce different RGB for the same YCbCr (chroma difference)" {
    const y = yVideoToLinear(30);
    const cb = cVideoToLinear(240);
    const cr = cVideoToLinear(110);
    const a = ycbcrToRgb(y, cb, cr, Bt601Coeffs.r_cr, Bt601Coeffs.g_cb, Bt601Coeffs.g_cr, Bt601Coeffs.b_cb);
    const b = ycbcrToRgb(y, cb, cr, Bt709Coeffs.r_cr, Bt709Coeffs.g_cb, Bt709Coeffs.g_cr, Bt709Coeffs.b_cb);
    const diff = @abs(a.b - b.b) + @abs(a.g - b.g);
    try testing.expect(diff > 0.01);
}

test "Full-range vs video-range: white at Y=255 vs Y=235 both give RGB=1,1,1" {
    const y_f = yFullToLinear(255);
    const cb_f = cFullToLinear(128);
    const cr_f = cFullToLinear(128);
    const cf = ycbcrToRgb(y_f, cb_f, cr_f, Bt709Coeffs.r_cr, Bt709Coeffs.g_cb, Bt709Coeffs.g_cr, Bt709Coeffs.b_cb);
    try testing.expect(@abs(cf.r - 1.0) < tol);
    try testing.expect(@abs(cf.g - 1.0) < tol);
    try testing.expect(@abs(cf.b - 1.0) < tol);

    const y_v = yVideoToLinear(235);
    const cv = ycbcrToRgb(y_v, cb_f, cr_f, Bt709Coeffs.r_cr, Bt709Coeffs.g_cb, Bt709Coeffs.g_cr, Bt709Coeffs.b_cb);
    try testing.expect(@abs(cv.r - 1.0) < tol);
    try testing.expect(@abs(cv.g - 1.0) < tol);
    try testing.expect(@abs(cv.b - 1.0) < tol);
}

test "Full-range vs video-range: Y=0 in full maps to RGB near black" {
    const y = yFullToLinear(0);
    const cb = cFullToLinear(128);
    const cr = cFullToLinear(128);
    const c = ycbcrToRgb(y, cb, cr, Bt709Coeffs.r_cr, Bt709Coeffs.g_cb, Bt709Coeffs.g_cr, Bt709Coeffs.b_cb);
    try testing.expect(@abs(c.r - 0.0) < tol);
    try testing.expect(@abs(c.g - 0.0) < tol);
    try testing.expect(@abs(c.b - 0.0) < tol);
}

test "10-bit code recovery: right-justified and left-justified conventions" {
    var code: i32 = 0;
    while (code < 1024) : (code += 1) {
        const cf: f32 = @floatFromInt(code);
        // Right-justified 10-in-16 (sample_scale = 1.0).
        const right_texel: f32 = cf / 65535.0;
        const right_recovered: f32 = right_texel * 65535.0 * 1.0;
        try testing.expect(@abs(right_recovered - cf) < 0.01);

        // Left-justified P010 word (sample_scale = 1/64).
        const left_texel: f32 = @as(f32, @floatFromInt(code << 6)) / 65535.0;
        const left_recovered: f32 = left_texel * 65535.0 * (1.0 / 64.0);
        try testing.expect(@abs(left_recovered - cf) < 0.01);
    }
}
