//! shaders.zig — Godot-side embedded GLSL present-pipeline shaders.
//!
//! Zig 0.15 forbids cross-directory @import/@embedFile, and core/shaders.zig is
//! deliberately not wired into core.zig (it has no place in the pure-math test
//! surface), so the Godot glue cannot reach the core-owned copy. This file is a
//! byte-for-byte functional twin of core/shaders.zig, embedding the glue's own
//! copy under src/godot/shaders/. The source of truth is src/common/*.glsl;
//! keep all three copies in sync when editing the shaders.
//!
//! Mirrors tools/embed_shader.py: embeds nv12_to_rgb.glsl twice (SDR +
//! HDR_OUTPUT=1), inlining the `#include "hdr_color_math.glsl"` directive and
//! stripping the `#[compute]` marker, because Godot's runtime GLSL compiler
//! (RenderingDevice.shaderCompileSpirvFromSource) does not resolve #includes.

const std = @import("std");

const nv12_to_rgb_glsl = @embedFile("shaders/nv12_to_rgb.glsl");
const hdr_color_math_glsl = @embedFile("shaders/hdr_color_math.glsl");

/// SDR variant: `#include` inlined, `#[compute]` stripped. Godot-compilable.
pub const nv12_to_rgb_compute = preprocess(false);

/// HDR variant: same, plus an injected `#define HDR_OUTPUT 1` after `#version`.
pub const nv12_to_rgb_hdr_compute = preprocess(true);

const compute_marker = "#[compute]\n";
const include_directive = "#include \"hdr_color_math.glsl\"";
const version_line = "#version 450\n";
const hdr_define = "#define HDR_OUTPUT 1\n";

/// Produce a Godot-compilable shader string for the requested output mode.
fn preprocess(comptime hdr: bool) []const u8 {
    comptime {
        var src: []const u8 = nv12_to_rgb_glsl;
        if (std.mem.startsWith(u8, src, compute_marker)) {
            src = src[compute_marker.len..];
        }
        const inc_idx = std.mem.indexOf(u8, src, include_directive) orelse
            @compileError("nv12_to_rgb.glsl: expected #include \"hdr_color_math.glsl\"");
        src = src[0..inc_idx] ++ hdr_color_math_glsl ++ src[inc_idx + include_directive.len ..];
        if (hdr) {
            const ver_idx = std.mem.indexOf(u8, src, version_line) orelse
                @compileError("nv12_to_rgb.glsl: no #version line for #define insertion");
            const after = ver_idx + version_line.len;
            src = src[0..after] ++ hdr_define ++ src[after..];
        }
        return src;
    }
}
