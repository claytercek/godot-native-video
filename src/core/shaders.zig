//! Embedded SDR and HDR_OUTPUT=1 variants of shaders/nv12_to_rgb.glsl.
//! Inline hdr_color_math.glsl and strip Godot's #[compute] marker because
//! RenderingDevice.shaderCompileSpirvFromSource does not resolve #includes.
//!
//! Core tests parse these sources without Godot; the present pipeline imports
//! the preprocessed variants through the core module for runtime compilation.

const std = @import("std");

/// Raw shader sources exactly as authored (with `#[compute]` and `#include`).
pub const nv12_to_rgb_glsl = @embedFile("shaders/nv12_to_rgb.glsl");
pub const hdr_color_math_glsl = @embedFile("shaders/hdr_color_math.glsl");

/// SDR variant: `#include` inlined, `#[compute]` stripped. Godot-compilable.
pub const nv12_to_rgb_compute = preprocess(false);

/// HDR variant: same, plus an injected `#define HDR_OUTPUT 1` after
/// `#version`.
pub const nv12_to_rgb_hdr_compute = preprocess(true);

// -----------------------------------------------------------------------
// Comptime preprocessing.
// -----------------------------------------------------------------------

const compute_marker = "#[compute]\n";
const include_directive = "#include \"hdr_color_math.glsl\"";
const version_line = "#version 450\n";
const hdr_define = "#define HDR_OUTPUT 1\n";

/// Produce a Godot-compilable shader string for the requested output mode.
fn preprocess(comptime hdr: bool) []const u8 {
    comptime {
        // 1. Strip the leading `#[compute]` directive (line 1 only).
        var src: []const u8 = nv12_to_rgb_glsl;
        if (std.mem.startsWith(u8, src, compute_marker)) {
            src = src[compute_marker.len..];
        }

        // 2. Inline the single `#include "hdr_color_math.glsl"` directive.
        const inc_idx = std.mem.indexOf(u8, src, include_directive) orelse
            @compileError("nv12_to_rgb.glsl: expected #include \"hdr_color_math.glsl\"");
        src = src[0..inc_idx] ++ hdr_color_math_glsl ++ src[inc_idx + include_directive.len ..];

        // 3. For the HDR variant, inject `#define HDR_OUTPUT 1` right after the
        //    #version line (GLSL requires #version to stay first).
        if (hdr) {
            const ver_idx = std.mem.indexOf(u8, src, version_line) orelse
                @compileError("nv12_to_rgb.glsl: no #version line for #define insertion");
            const after = ver_idx + version_line.len;
            src = src[0..after] ++ hdr_define ++ src[after..];
        }

        return src;
    }
}
