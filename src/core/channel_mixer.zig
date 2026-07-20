//! channel_mixer.zig — deterministic channel-format converter (Engine Core).
//!
//! The canonical mix format for a clip is the maximum channel count across
//! all audio tracks. Backends emit each track's native channel layout (1/2/6
//! ch). This mixer converts any supported source layout to any supported
//! target layout using fixed float constants so the result is identical on
//! every platform — no OS-level mixer, no platform rounding, no undefined
//! behaviour.
//!
//! The contract is total: mixChannels() always writes exactly
//! frame_count * dst_channels floats and never reads or writes outside the
//! buffers the caller sized for those channel counts, regardless of what
//! src_channels and dst_channels are.
//!
//! Supported layouts (by channel count), with semantic downmix/upmix rules:
//!   1  — Mono                (C)
//!   2  — Stereo              (L, R)
//!   6  — 5.1 surround        (L, R, C, LFE, Ls, Rs)  — SMPTE/ITU-R BS.775
//!
//! Mixing conventions for the layouts above:
//!   * LFE (subwoofer) content is EXCLUDED from all downmixes (consumer-side
//!     bass management reproduces it from the mains).
//!   * Surround channels (Ls, Rs) are attenuated 3 dB relative to mains in
//!     downmixes (coefficient 0.707 ~= 1/sqrt(2), typed as a float literal).
//!   * Upmixes place source content into the semantically closest channels:
//!     mono centre -> centre-only in 5.1, both L/R in stereo; stereo -> mains
//!     only in 5.1 (no phantom centre).
//!   * All coefficients are float literals — no sqrt, no pow, no
//!     platform-varying math functions.
//!
//! Everything else — any (src_channels, dst_channels) pair not listed above,
//! including source or destination layouts we don't understand (3, 4, 5, 7,
//! 8+ channels) — falls back to a documented, layout-agnostic behaviour:
//! copy the first min(src_channels, dst_channels) samples of each frame and
//! zero any remaining destination channels. This is a known limitation, not
//! an error: we have no semantic mapping for those layouts, so we preserve
//! as many channels as fit and stay silent (never garbage) on the rest.

const std = @import("std");

/// Channel counts this mixer understands semantically (1/2/6, per the
/// layouts documented above). Anything outside these layouts gets a
/// correct, if generic, mix via the copy-min-channels fallback.
pub const max_mix_source_channels: i32 = 6;

/// Mix interleaved PCM float32 samples from `src_channels` to `dst_channels`.
///
///   src           : input samples (frame_count * src_channels interleaved floats).
///   src_channels  : number of input channels.
///   dst           : output buffer (frame_count * dst_channels floats).
///   dst_channels  : number of output channels.
///   frame_count   : number of PCM frames to convert.
///
/// src and dst must not overlap. dst must be sized for frame_count *
/// dst_channels floats; this function always writes exactly that many floats
/// and never more, so callers can size dst from dst_channels alone.
///
/// If frame_count, src_channels, or dst_channels is <= 0, nothing is written.
pub fn mixChannels(
    src: []const f32,
    src_channels: i32,
    dst: []f32,
    dst_channels: i32,
    frame_count: i32,
) void {
    if (frame_count <= 0 or src_channels <= 0 or dst_channels <= 0) {
        @branchHint(.unlikely);
        return;
    }

    if (src_channels == dst_channels) {
        // Identical layout — single memcpy fast path.
        const n: usize = @as(usize, @intCast(frame_count)) * @as(usize, @intCast(src_channels));
        @memcpy(dst[0..n], src[0..n]);
        return;
    }

    const known_layouts = (src_channels == 1 or src_channels == 2 or src_channels == 6) and
        (dst_channels == 1 or dst_channels == 2 or dst_channels == 6);

    const sc: usize = @intCast(src_channels);
    const dc: usize = @intCast(dst_channels);

    if (!known_layouts) {
        // Generic fallback: no layout interpretation. Copy the first
        // min(src_channels, dst_channels) samples of each frame and zero
        // anything left over in the destination.
        const copy_channels: usize = @intCast(@min(src_channels, dst_channels));
        for (0..@intCast(frame_count)) |f| {
            const in = src[f * sc ..];
            const out = dst[f * dc ..];
            @memcpy(out[0..copy_channels], in[0..copy_channels]);
            @memset(out[copy_channels..dc], 0.0);
        }
        return;
    }

    // -------------------------------------------------------------------
    // Supported conversions. All coefficients are float literals. Each
    // per-source-layout helper mixes ONE already-zeroed frame; this loop
    // owns iteration and the zero-fill shared by every layout.
    // -------------------------------------------------------------------

    for (0..@intCast(frame_count)) |f| {
        const in = src[f * sc ..];
        const out = dst[f * dc ..];

        // Zero the output frame first so unset channels are silence.
        @memset(out[0..dc], 0.0);

        switch (src_channels) {
            1 => mixFrameFromMono(in, out, dst_channels),
            2 => mixFrameFromStereo(in, out, dst_channels),
            6 => mixFrameFrom51(in, out, dst_channels),
            else => unreachable, // known_layouts guarantees src_channels in {1,2,6}
        }
    }
}

/// Mix one Mono (1ch) source frame into `out` (already zeroed).
fn mixFrameFromMono(in: []const f32, out: []f32, dst_channels: i32) void {
    const C = in[0];
    if (dst_channels == 2) {
        // Mono -> Stereo: centre to both L and R.
        out[0] = C;
        out[1] = C;
    } else if (dst_channels == 6) {
        // Mono -> 5.1: centre to C only.
        out[2] = C; // C
        // L, R, LFE, Ls, Rs remain 0.0
    }
}

/// Mix one Stereo (2ch) source frame into `out` (already zeroed).
fn mixFrameFromStereo(in: []const f32, out: []f32, dst_channels: i32) void {
    const L = in[0];
    const R = in[1];
    if (dst_channels == 1) {
        // Stereo -> Mono: equal-weighted sum.
        out[0] = 0.5 * L + 0.5 * R;
    } else if (dst_channels == 6) {
        // Stereo -> 5.1: L -> L, R -> R. C, LFE, Ls, Rs remain 0.
        out[0] = L;
        out[1] = R;
    }
}

/// Mix one 5.1 (6ch) source frame into `out` (already zeroed).
fn mixFrameFrom51(in: []const f32, out: []f32, dst_channels: i32) void {
    const L = in[0];
    const R = in[1];
    const C = in[2];
    // in[3] = LFE — excluded from all downmixes
    const Ls = in[4];
    const Rs = in[5];

    if (dst_channels == 1) {
        // 5.1 -> Mono: L + R + C + 0.707*(Ls + Rs), scaled by 1/3.414
        // so a full-scale sine in any single channel produces ~0.29
        // peak (safe from clipping when multiple channels are
        // active).
        out[0] = (L + R + C + 0.707 * (Ls + Rs)) / 3.414;
    } else if (dst_channels == 2) {
        // 5.1 -> Stereo (ITU-R BS.775 downmix).
        // Lt = L + 0.707*C + 0.707*Ls
        // Rt = R + 0.707*C + 0.707*Rs
        // LFE excluded.
        out[0] = L + 0.707 * C + 0.707 * Ls;
        out[1] = R + 0.707 * C + 0.707 * Rs;
    }
}

// Helper: compare two float slices with tolerance.
fn approxEq(a: []const f32, b: []const f32, eps: f32) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (@abs(x - y) > eps) return false;
    }
    return true;
}

// -----------------------------------------------------------------------
// Identity / passthrough
// -----------------------------------------------------------------------

test "mix_channels passthrough same channel count (1->1)" {
    const in = [_]f32{ 0.5, -0.25, 1.0 };
    var out = [_]f32{-999.0} ** 3;
    mixChannels(&in, 1, &out, 1, 3);
    try std.testing.expectApproxEqAbs(0.5, out[0], 1e-6);
    try std.testing.expectApproxEqAbs(-0.25, out[1], 1e-6);
    try std.testing.expectApproxEqAbs(1.0, out[2], 1e-6);
}

test "mix_channels passthrough same channel count (2->2)" {
    const in = [_]f32{ 1.0, 2.0, 3.0, 4.0 };
    var out = [_]f32{-999.0} ** 4;
    mixChannels(&in, 2, &out, 2, 2);
    try std.testing.expect(approxEq(&in, &out, 1e-6));
}

test "mix_channels passthrough same channel count (6->6)" {
    const in = [_]f32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 };
    var out = [_]f32{-999.0} ** 12;
    mixChannels(&in, 6, &out, 6, 2);
    try std.testing.expect(approxEq(&in, &out, 1e-6));
}

test "mix_channels empty frame_count writes nothing" {
    const in = [_]f32{ 1.0, 2.0 };
    var out = [_]f32{ 999.0, 999.0 };
    mixChannels(&in, 2, &out, 1, 0);
    try std.testing.expectApproxEqAbs(999.0, out[0], 1e-6);
    try std.testing.expectApproxEqAbs(999.0, out[1], 1e-6);
}

test "mix_channels degenerate src_channels writes nothing" {
    const in = [_]f32{ 1.0, 2.0 };
    var out = [_]f32{ 999.0, 999.0 };
    mixChannels(&in, 0, &out, 2, 1);
    try std.testing.expectApproxEqAbs(999.0, out[0], 1e-6);
    try std.testing.expectApproxEqAbs(999.0, out[1], 1e-6);
}

// -----------------------------------------------------------------------
// Mono -> Stereo
// -----------------------------------------------------------------------

test "mix_channels mono to stereo" {
    // 3 mono frames: C = 0.5, -0.25, 1.0
    const in = [_]f32{ 0.5, -0.25, 1.0 };
    var out = [_]f32{-999.0} ** 6;
    mixChannels(&in, 1, &out, 2, 3);
    // Each mono frame should duplicate to both L and R.
    try std.testing.expectApproxEqAbs(0.5, out[0], 1e-6);
    try std.testing.expectApproxEqAbs(0.5, out[1], 1e-6);
    try std.testing.expectApproxEqAbs(-0.25, out[2], 1e-6);
    try std.testing.expectApproxEqAbs(-0.25, out[3], 1e-6);
    try std.testing.expectApproxEqAbs(1.0, out[4], 1e-6);
    try std.testing.expectApproxEqAbs(1.0, out[5], 1e-6);
}

// -----------------------------------------------------------------------
// Mono -> 5.1
// -----------------------------------------------------------------------

test "mix_channels mono to 5.1" {
    // 2 mono frames: C = 0.8, -0.4
    const in = [_]f32{ 0.8, -0.4 };
    var out = [_]f32{0.0} ** 12;
    mixChannels(&in, 1, &out, 6, 2);
    // Only C (index 2) should be set; L, R, LFE, Ls, Rs remain 0.
    try std.testing.expectApproxEqAbs(0.0, out[0], 1e-6); // L
    try std.testing.expectApproxEqAbs(0.0, out[1], 1e-6); // R
    try std.testing.expectApproxEqAbs(0.8, out[2], 1e-6); // C
    try std.testing.expectApproxEqAbs(0.0, out[3], 1e-6); // LFE
    try std.testing.expectApproxEqAbs(0.0, out[4], 1e-6); // Ls
    try std.testing.expectApproxEqAbs(0.0, out[5], 1e-6); // Rs

    try std.testing.expectApproxEqAbs(0.0, out[6], 1e-6); // L
    try std.testing.expectApproxEqAbs(0.0, out[7], 1e-6); // R
    try std.testing.expectApproxEqAbs(-0.4, out[8], 1e-6); // C
    try std.testing.expectApproxEqAbs(0.0, out[9], 1e-6); // LFE
    try std.testing.expectApproxEqAbs(0.0, out[10], 1e-6); // Ls
    try std.testing.expectApproxEqAbs(0.0, out[11], 1e-6); // Rs
}

// -----------------------------------------------------------------------
// Stereo -> Mono
// -----------------------------------------------------------------------

test "mix_channels stereo to mono" {
    // 3 stereo frames: (L,R) = (1,0), (0,1), (0.5,0.5)
    const in = [_]f32{ 1.0, 0.0, 0.0, 1.0, 0.5, 0.5 };
    var out = [_]f32{-999.0} ** 3;
    mixChannels(&in, 2, &out, 1, 3);
    // Mono = 0.5*(L+R)
    try std.testing.expectApproxEqAbs(0.5, out[0], 1e-6); // 0.5*(1 + 0)
    try std.testing.expectApproxEqAbs(0.5, out[1], 1e-6); // 0.5*(0 + 1)
    try std.testing.expectApproxEqAbs(0.5, out[2], 1e-6); // 0.5*(0.5 + 0.5)
}

// -----------------------------------------------------------------------
// Stereo -> 5.1
// -----------------------------------------------------------------------

test "mix_channels stereo to 5.1" {
    // 2 stereo frames: (0.6, 0.4), (-0.2, 0.9)
    const in = [_]f32{ 0.6, 0.4, -0.2, 0.9 };
    var out = [_]f32{-999.0} ** 12;
    mixChannels(&in, 2, &out, 6, 2);
    // L -> L, R -> R; C, LFE, Ls, Rs remain 0.
    try std.testing.expectApproxEqAbs(0.6, out[0], 1e-6); // L
    try std.testing.expectApproxEqAbs(0.4, out[1], 1e-6); // R
    try std.testing.expectApproxEqAbs(0.0, out[2], 1e-6); // C
    try std.testing.expectApproxEqAbs(0.0, out[3], 1e-6); // LFE
    try std.testing.expectApproxEqAbs(0.0, out[4], 1e-6); // Ls
    try std.testing.expectApproxEqAbs(0.0, out[5], 1e-6); // Rs

    try std.testing.expectApproxEqAbs(-0.2, out[6], 1e-6); // L
    try std.testing.expectApproxEqAbs(0.9, out[7], 1e-6); // R
    try std.testing.expectApproxEqAbs(0.0, out[8], 1e-6); // C
}

// -----------------------------------------------------------------------
// 5.1 -> Stereo (ITU-R BS.775 downmix)
// -----------------------------------------------------------------------

test "mix_channels 5.1 to stereo downmix" {
    // One 5.1 frame: L=1, R=0, C=0, LFE=0, Ls=0, Rs=0
    // Lt = 1 + 0.707*0 + 0.707*0 = 1
    // Rt = 0 + 0.707*0 + 0.707*0 = 0
    const in = [_]f32{ 1.0, 0.0, 0.0, 0.0, 0.0, 0.0 };
    var out = [_]f32{-999.0} ** 2;
    mixChannels(&in, 6, &out, 2, 1);
    try std.testing.expectApproxEqAbs(1.0, out[0], 1e-6);
    try std.testing.expectApproxEqAbs(0.0, out[1], 1e-6);
}

test "mix_channels 5.1 to stereo centre bleeds into both channels" {
    // L=0, R=0, C=1 -> Lt = 0.707*1, Rt = 0.707*1
    const in = [_]f32{ 0.0, 0.0, 1.0, 0.0, 0.0, 0.0 };
    var out = [_]f32{-999.0} ** 2;
    mixChannels(&in, 6, &out, 2, 1);
    try std.testing.expectApproxEqAbs(0.707, out[0], 1e-6);
    try std.testing.expectApproxEqAbs(0.707, out[1], 1e-6);
}

test "mix_channels 5.1 to stereo surrounds bleed into opposite" {
    // Ls=1 -> Lt = 0.707*1, Rt = 0
    const in = [_]f32{ 0.0, 0.0, 0.0, 0.0, 1.0, 0.0 };
    var out = [_]f32{-999.0} ** 2;
    mixChannels(&in, 6, &out, 2, 1);
    try std.testing.expectApproxEqAbs(0.707, out[0], 1e-6);
    try std.testing.expectApproxEqAbs(0.0, out[1], 1e-6);
}

test "mix_channels 5.1 to stereo LFE excluded" {
    // Only LFE=1 at full scale -> nothing in stereo output.
    const in = [_]f32{ 0.0, 0.0, 0.0, 1.0, 0.0, 0.0 };
    var out = [_]f32{-999.0} ** 2;
    mixChannels(&in, 6, &out, 2, 1);
    try std.testing.expectApproxEqAbs(0.0, out[0], 1e-6);
    try std.testing.expectApproxEqAbs(0.0, out[1], 1e-6);
}

test "mix_channels 5.1 to stereo complex signal" {
    // L=0.5, R=0.3, C=0.2, LFE=0.1, Ls=0.4, Rs=0.6
    // Lt = 0.5 + 0.707*0.2 + 0.707*0.4 = 0.5 + 0.1414 + 0.2828 = 0.9242
    // Rt = 0.3 + 0.707*0.2 + 0.707*0.6 = 0.3 + 0.1414 + 0.4242 = 0.8656
    const in = [_]f32{ 0.5, 0.3, 0.2, 0.1, 0.4, 0.6 };
    var out = [_]f32{-999.0} ** 2;
    mixChannels(&in, 6, &out, 2, 1);
    try std.testing.expectApproxEqAbs(0.9242, out[0], 1e-4);
    try std.testing.expectApproxEqAbs(0.8656, out[1], 1e-4);
}

// -----------------------------------------------------------------------
// 5.1 -> Mono
// -----------------------------------------------------------------------

test "mix_channels 5.1 to mono centre-only" {
    // C=1 only -> M = 1/3.414 ~= 0.2929
    const in = [_]f32{ 0.0, 0.0, 1.0, 0.0, 0.0, 0.0 };
    var out = [_]f32{-999.0} ** 1;
    mixChannels(&in, 6, &out, 1, 1);
    try std.testing.expectApproxEqAbs(1.0 / 3.414, out[0], 1e-6);
}

test "mix_channels 5.1 to mono all channels active" {
    // L=1, R=0.5, C=0.8, LFE=10 (ignored), Ls=0.3, Rs=0.2
    // M = (1 + 0.5 + 0.8 + 0.707*(0.3 + 0.2)) / 3.414
    //   = (2.3 + 0.3535) / 3.414 = 2.6535 / 3.414 ~= 0.7772
    const in = [_]f32{ 1.0, 0.5, 0.8, 10.0, 0.3, 0.2 };
    var out = [_]f32{-999.0} ** 1;
    mixChannels(&in, 6, &out, 1, 1);
    const expected: f32 = (1.0 + 0.5 + 0.8 + 0.707 * (0.3 + 0.2)) / 3.414;
    try std.testing.expectApproxEqAbs(expected, out[0], 1e-6);
}

test "mix_channels 5.1 to mono LFE excluded from 5.1" {
    // Full-scale LFE alone -> mono is silence.
    const in = [_]f32{ 0.0, 0.0, 0.0, 1.0, 0.0, 0.0 };
    var out = [_]f32{-999.0} ** 1;
    mixChannels(&in, 6, &out, 1, 1);
    try std.testing.expectApproxEqAbs(0.0, out[0], 1e-6);
}

// -----------------------------------------------------------------------
// Determinism: same input always produces same output
// -----------------------------------------------------------------------

test "mix_channels is deterministic" {
    const in = [_]f32{ 0.3, 0.7, 0.2, 1.0, 0.1, 0.5 };

    var a = [_]f32{0.0} ** 2;
    var b = [_]f32{0.0} ** 2;

    mixChannels(&in, 6, &a, 2, 1);
    mixChannels(&in, 6, &b, 2, 1);

    try std.testing.expectApproxEqAbs(a[0], b[0], 1e-6);
    try std.testing.expectApproxEqAbs(a[1], b[1], 1e-6);
}

// -----------------------------------------------------------------------
// Multiple frames
// -----------------------------------------------------------------------

test "mix_channels converts multiple frames correctly" {
    // 2 stereo frames -> mono.
    const in = [_]f32{ 1.0, 0.0, 0.0, 1.0 };
    var out = [_]f32{-999.0} ** 2;
    mixChannels(&in, 2, &out, 1, 2);
    try std.testing.expectApproxEqAbs(0.5, out[0], 1e-6);
    try std.testing.expectApproxEqAbs(0.5, out[1], 1e-6);
}

// -----------------------------------------------------------------------
// Unrecognised layouts: generic copy-min-channels fallback.
//
// These are the total-contract regression cases: the mixer must never write
// past frame_count * dst_channels floats, and must never leave destination
// channels beyond src_channels uninitialized garbage — it zeros them.
// -----------------------------------------------------------------------

test "mix_channels 8ch source to 6ch dst never overflows the dst buffer" {
    // This is the heap-overflow regression: an 8-channel source (e.g. 7.1)
    // mixed into a 6-channel canonical dst must write exactly
    // frame_count * 6 floats, never frame_count * 8.
    const frame_count: i32 = 4;
    const src_channels: i32 = 8;
    const dst_channels: i32 = 6;

    var in: [@as(usize, @intCast(frame_count)) * @as(usize, @intCast(src_channels))]f32 = undefined;
    for (&in, 0..) |*v, i| {
        v.* = @floatFromInt(i + 1);
    }

    // dst sized exactly for the contract, plus canary floats past the end.
    const dst_size: usize = @as(usize, @intCast(frame_count)) * @as(usize, @intCast(dst_channels));
    const canary_count: usize = 4;
    var out: [dst_size + canary_count]f32 = [_]f32{999.0} ** (dst_size + canary_count);

    mixChannels(&in, src_channels, out[0..dst_size], dst_channels, frame_count);

    // First dst_channels samples of each frame equal the source's first
    // dst_channels samples.
    for (0..@intCast(frame_count)) |f| {
        for (0..@intCast(dst_channels)) |c| {
            try std.testing.expectApproxEqAbs(
                in[f * @as(usize, @intCast(src_channels)) + c],
                out[f * @as(usize, @intCast(dst_channels)) + c],
                1e-6,
            );
        }
    }

    // Canary region past the dst buffer must be untouched.
    for (out[dst_size..]) |v| {
        try std.testing.expectApproxEqAbs(999.0, v, 1e-6);
    }
}

test "mix_channels 5ch to 2ch copies first two channels only" {
    const in = [_]f32{ 1.0, 2.0, 3.0, 4.0, 5.0 };
    var out = [_]f32{-999.0} ** 2;
    mixChannels(&in, 5, &out, 2, 1);
    try std.testing.expectApproxEqAbs(1.0, out[0], 1e-6);
    try std.testing.expectApproxEqAbs(2.0, out[1], 1e-6);
}

test "mix_channels 2ch to 5ch copies two channels and zeros the rest" {
    const in = [_]f32{ 0.6, 0.4 };
    var out = [_]f32{-999.0} ** 5;
    mixChannels(&in, 2, &out, 5, 1);
    try std.testing.expectApproxEqAbs(0.6, out[0], 1e-6);
    try std.testing.expectApproxEqAbs(0.4, out[1], 1e-6);
    try std.testing.expectApproxEqAbs(0.0, out[2], 1e-6);
    try std.testing.expectApproxEqAbs(0.0, out[3], 1e-6);
    try std.testing.expectApproxEqAbs(0.0, out[4], 1e-6);
}

test "mix_channels 3ch to 3ch uses the memcpy fast path" {
    const in = [_]f32{ 0.1, 0.2, 0.3, 0.4, 0.5, 0.6 };
    var out = [_]f32{-999.0} ** 6;
    mixChannels(&in, 3, &out, 3, 2);
    try std.testing.expect(approxEq(&in, &out, 1e-6));
}

// -----------------------------------------------------------------------
// Fuzz: the total contract under arbitrary channel counts, frame counts,
// and sample bits (including NaN/inf). mixChannels must write exactly
// frame_count * dst_channels floats — never past them — and write nothing
// at all for degenerate arguments. Run with `zig build test --fuzz` for
// real fuzzing; a normal test run does one smoke pass.
// -----------------------------------------------------------------------

test "fuzz: mix_channels writes exactly the contract region" {
    try std.testing.fuzz({}, fuzzMixChannels, .{});
}

fn fuzzMixChannels(_: void, smith: *std.testing.Smith) anyerror!void {
    const max_channels = 9; // beyond every known layout, exercises the fallback
    const max_frames = 32;

    const src_channels = smith.valueRangeAtMost(i32, 0, max_channels);
    const dst_channels = smith.valueRangeAtMost(i32, 0, max_channels);
    const frame_count = smith.valueRangeAtMost(i32, 0, max_frames);

    // Arbitrary bit patterns: NaN and inf must not break the write contract.
    var src: [max_frames * max_channels]f32 = undefined;
    for (&src) |*v| v.* = @bitCast(smith.value(u32));

    const canary: f32 = 12345.5;
    var dst: [max_frames * max_channels + 8]f32 = @splat(canary);

    const src_len: usize = @intCast(@max(src_channels, 0) * @max(frame_count, 0));
    const dst_len: usize = @intCast(@max(dst_channels, 0) * @max(frame_count, 0));
    mixChannels(src[0..src_len], src_channels, dst[0..dst_len], dst_channels, frame_count);

    // Nothing past the contract region is ever touched.
    for (dst[dst_len..]) |v| try std.testing.expectEqual(canary, v);
    // Degenerate arguments write nothing at all.
    if (frame_count <= 0 or src_channels <= 0 or dst_channels <= 0) {
        for (dst) |v| try std.testing.expectEqual(canary, v);
    }
}

test "mix_channels degenerate frame_count and src_channels write nothing (canary check)" {
    const in = [_]f32{ 1.0, 2.0, 3.0 };
    var out = [_]f32{ 999.0, 999.0, 999.0 };

    mixChannels(&in, 3, &out, 3, 0);
    try std.testing.expectApproxEqAbs(999.0, out[0], 1e-6);
    try std.testing.expectApproxEqAbs(999.0, out[1], 1e-6);
    try std.testing.expectApproxEqAbs(999.0, out[2], 1e-6);

    mixChannels(&in, 0, &out, 3, 1);
    try std.testing.expectApproxEqAbs(999.0, out[0], 1e-6);
    try std.testing.expectApproxEqAbs(999.0, out[1], 1e-6);
    try std.testing.expectApproxEqAbs(999.0, out[2], 1e-6);
}
