#!/usr/bin/env python3
"""Generate a C++ header from a GLSL shader file.

Reads a .glsl file and emits a C++ header containing the shader source
as a raw string literal.  Supports ``#include "filename"`` directives
that resolve relative to the input file's directory.

The Godot-specific ``#[compute]`` directive (if present on line 1) is
stripped because ``set_stage_source`` already specifies
``SHADER_STAGE_COMPUTE``.

Output is deterministic so rebuilds from identical input produce an
identical header (no embedded timestamps, no build-path dependence).
"""

import os
import re
import sys


def resolve_includes(lines, base_dir, depth=0):
    """Replace all ``#include "..."`` lines with the referenced file's
    contents (recursively).  Max depth 10 to catch circular includes."""
    if depth > 10:
        raise RuntimeError("include depth > 10 -- circular include?")

    out = []
    pattern = re.compile(r'^\s*#include\s+"([^"]+)"\s*$')
    for line in lines:
        m = pattern.match(line)
        if not m:
            out.append(line)
            continue
        inc_path = os.path.join(base_dir, m.group(1))
        inc_path = os.path.normpath(inc_path)
        if not os.path.isfile(inc_path):
            raise FileNotFoundError(
                "include not found: {} (resolved: {})".format(m.group(1), inc_path)
            )
        with open(inc_path, "r") as f:
            inc_lines = f.readlines()
        out.extend(resolve_includes(inc_lines, base_dir, depth + 1))
    return out


def embed_shader(glsl_path, header_path, var_name="kNv12ToRgbCompute"):
    glsl_path = os.path.normpath(glsl_path)
    base_dir = os.path.dirname(glsl_path)

    with open(glsl_path, "r") as f:
        lines = f.readlines()

    # Strip the Godot-specific #[compute] directive (line 1 only).
    if lines and lines[0].strip() == "#[compute]":
        lines = lines[1:]

    # Resolve #include directives.
    lines = resolve_includes(lines, base_dir)

    source = "".join(lines)

    # Delimiter for the raw string literal.  ``"GLSL"`` is conventional.
    # Verify the content doesn't contain ``)GLSL"``; if it does, append
    # underscores until the delimiter is unique.
    delimiter = "GLSL"
    close_token = ")" + delimiter + '"'
    while close_token in source:
        delimiter += "_"
        close_token = ")" + delimiter + '"'

    os.makedirs(os.path.dirname(header_path), exist_ok=True)

    with open(header_path, "w") as f:
        f.write("// Auto-generated from ")
        f.write(glsl_path)
        f.write(" -- do not edit by hand.\n")
        f.write("#pragma once\n")
        f.write("\n")
        f.write('static const char *{} = R"'.format(var_name))
        f.write(delimiter)
        f.write("(")
        f.write(source)
        f.write(")")
        f.write(delimiter)
        f.write('";\n')

    # Log to stdout so SCons can capture it if needed.
    print("  embed  {} -> {}".format(glsl_path, header_path))


if __name__ == "__main__":
    argc = len(sys.argv)
    if argc not in (3, 4):
        print("Usage: {} <input.glsl> <output.h> [var_name]".format(sys.argv[0]), file=sys.stderr)
        sys.exit(1)
    var_name = sys.argv[3] if argc >= 4 else "kNv12ToRgbCompute"
    embed_shader(sys.argv[1], sys.argv[2], var_name)