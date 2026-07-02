#!/usr/bin/env python3
"""Generate a C++ header from a GLSL shader file.

Reads a .glsl file and emits a C++ header containing the shader source
as a raw string literal.  The Godot-specific ``#[compute]`` directive
(if present on line 1) is stripped because ``set_stage_source`` already
specifies ``SHADER_STAGE_COMPUTE``.

Output is deterministic so rebuilds from identical input produce an
identical header (no embedded timestamps, no build-path dependence).
"""

import os
import sys


def embed_shader(glsl_path: str, header_path: str) -> None:
    with open(glsl_path, "r") as f:
        lines = f.readlines()

    # Strip the Godot-specific #[compute] directive (line 1 only).
    if lines and lines[0].strip() == "#[compute]":
        lines = lines[1:]

    source = "".join(lines)

    # Delimiter for the raw string literal.  ``"GLSL"`` is conventional.
    # Verify the content doesn't contain ``)GLSL"``; if it does, append
    # underscores until the delimiter is unique.
    delimiter = "GLSL"
    close_token = f"){delimiter}\""
    while close_token in source:
        delimiter += "_"
        close_token = f"){delimiter}\""

    os.makedirs(os.path.dirname(header_path), exist_ok=True)

    with open(header_path, "w") as f:
        f.write("// Auto-generated from ")
        f.write(glsl_path)
        f.write(" -- do not edit by hand.\n")
        f.write("#pragma once\n")
        f.write("\n")
        f.write('static const char *kNv12ToRgbCompute = R"')
        f.write(delimiter)
        f.write("(")
        f.write(source)
        f.write(")")
        f.write(delimiter)
        f.write('";\n')

    # Log to stdout so SCons can capture it if needed.
    print(f"  embed  {glsl_path} -> {header_path}")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <input.glsl> <output.h>", file=sys.stderr)
        sys.exit(1)
    embed_shader(sys.argv[1], sys.argv[2])