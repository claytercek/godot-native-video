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


def embed_shader(glsl_path, header_path, var_name="kNv12ToRgbCompute", defines=None):
    glsl_path = os.path.normpath(glsl_path)
    base_dir = os.path.dirname(glsl_path)

    with open(glsl_path, "r") as f:
        lines = f.readlines()

    # Strip the Godot-specific #[compute] directive (line 1 only).
    if lines and lines[0].strip() == "#[compute]":
        lines = lines[1:]

    # Resolve #include directives.
    lines = resolve_includes(lines, base_dir)

    # Insert any requested #define lines immediately after the #version
    # line.  GLSL requires #version to be the first directive in the
    # compiled source, so #define lines must come after it, not before.
    if defines:
        version_pattern = re.compile(r"^\s*#version\b")
        version_index = None
        for i, line in enumerate(lines):
            if version_pattern.match(line):
                version_index = i
                break
        if version_index is None:
            raise RuntimeError("no #version line found -- cannot insert #define")
        define_lines = []
        for name, value in defines:
            if value:
                define_lines.append("#define {} {}\n".format(name, value))
            else:
                define_lines.append("#define {}\n".format(name))
        lines = lines[: version_index + 1] + define_lines + lines[version_index + 1 :]

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


def _usage_error():
    print(
        "Usage: {} <input.glsl> <output.h> [var_name] [-D NAME=VALUE ...]".format(sys.argv[0]),
        file=sys.stderr,
    )
    sys.exit(1)


if __name__ == "__main__":
    args = sys.argv[1:]
    if len(args) < 2:
        _usage_error()

    glsl_path = args[0]
    header_path = args[1]
    rest = args[2:]

    var_name = "kNv12ToRgbCompute"
    if rest and not rest[0].startswith("-"):
        var_name = rest[0]
        rest = rest[1:]

    defines = []
    i = 0
    while i < len(rest):
        if rest[i] != "-D":
            _usage_error()
        if i + 1 >= len(rest):
            _usage_error()
        pair = rest[i + 1]
        if "=" in pair:
            name, value = pair.split("=", 1)
        else:
            name, value = pair, ""
        defines.append((name, value))
        i += 2

    embed_shader(glsl_path, header_path, var_name, defines)
