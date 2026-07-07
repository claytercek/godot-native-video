#!/usr/bin/env bash
# tests/headless-smoke/run.sh
# -----------------------------------------------------------------------
# One-command headless smoke test for the Platform Media Streams extension.
#
# Generates a multi-track marker clip (2 Audio Tracks) into the test project
# if missing, builds the extension for the host platform, locates Godot via
# $GODOT_BIN (falling back to PATH), runs Godot's headless import pass to
# materialize project metadata, then runs the smoke script and exits nonzero
# on any assertion failure.
#
# Requirements:
#   - godot >= 4.4 (set $GODOT_BIN or put it on PATH)
#   - ffmpeg >= 4.0 (on PATH, for test clip generation)
#   - scons, C++ toolchain matching the Godot build
#
# Usage:
#   ./tests/headless-smoke/run.sh
# -----------------------------------------------------------------------
set -euo pipefail

# --- Paths -----------------------------------------------------------------
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEST_PROJECT="$REPO_ROOT/tests/headless-smoke"
DEMO_PROJECT="$REPO_ROOT/demo"
TOOLS="$REPO_ROOT/tools"
CLIP="$TEST_PROJECT/synthetic.mp4"
CLIP_MOV="$TEST_PROJECT/synthetic.mov"
CLIP_M4V="$TEST_PROJECT/synthetic.m4v"

# --- Platform detection ----------------------------------------------------
case "$(uname -s)" in
    Darwin*)  PLATFORM="macos" ;;
    MINGW*|MSYS*|CYGWIN*) PLATFORM="windows" ;;
    *)
        echo "ERROR: unsupported platform ($(uname -s))" >&2
        exit 1
        ;;
esac

LIB_NAME="libplatform-media-streams"
SUFFIX="template_debug"
if [ "$PLATFORM" = "macos" ]; then
    LIB_FILE="${LIB_NAME}.${PLATFORM}.${SUFFIX}.dylib"
else
    LIB_FILE="${LIB_NAME}.${PLATFORM}.${SUFFIX}.x86_64.dll"
fi
LIB_SRC="$REPO_ROOT/bin/$PLATFORM/$LIB_FILE"
LIB_DST="$TEST_PROJECT/bin/$PLATFORM/$LIB_FILE"

# --- 1. Generate multi-track clip -----------------------------------------
if [ ! -f "$CLIP" ]; then
    echo "--- Generating multi-track clip (2 audio tracks) ---"
    mkdir -p "$TEST_PROJECT"

    # Generate the .mp4 clip with 2 audio tracks
    "$TOOLS/gen_test_media.sh" \
        --multi-track 2 \
        --output "$CLIP"

    # Remux to .mov and .m4v for ResourceLoader extension coverage
    echo "--- Remuxing to .mov and .m4v ---"
    ffmpeg -y -i "$CLIP" -c copy "$CLIP_MOV" 2>/dev/null
    ffmpeg -y -i "$CLIP" -c copy "$CLIP_M4V" 2>/dev/null

    echo "--- Clip generated ---"
else
    echo "--- Clip already exists ---"
fi

# --- 2. Build extension ----------------------------------------------------
echo "--- Building extension for $PLATFORM ---"
cd "$REPO_ROOT"
scons platform="$PLATFORM" target="$SUFFIX"

# Verify the library was produced.
if [ ! -f "$LIB_SRC" ]; then
    echo "ERROR: build produced no library at $LIB_SRC" >&2
    exit 1
fi

# The SConstruct should have installed the library into both projects.
# Double-check the test project has it; if not, copy manually.
if [ ! -f "$LIB_DST" ]; then
    echo "--- Installing library to test project ---"
    mkdir -p "$(dirname "$LIB_DST")"
    cp "$LIB_SRC" "$LIB_DST"
fi

# --- 3. Locate Godot -------------------------------------------------------
GODOT="${GODOT_BIN:-}"
if [ -z "$GODOT" ]; then
    GODOT="$(command -v godot 2>/dev/null || true)"
fi
if [ -z "$GODOT" ]; then
    cat >&2 <<'ERRMSG'
ERROR: Godot binary not found.
Set the GODOT_BIN environment variable to the path of a Godot 4.4+ executable,
or ensure `godot` is on your PATH.

Example:
    export GODOT_BIN=/Applications/Godot.app/Contents/MacOS/Godot
    ./tests/headless-smoke/run.sh

This script does NOT download Godot for you.
ERRMSG
    exit 1
fi
echo "--- Using Godot: $GODOT ---"

# --- 4. Headless import pass -----------------------------------------------
echo "--- Headless import pass ---"
"$GODOT" --headless --import --path "$TEST_PROJECT" 2>&1

# --- 5. Run smoke test -----------------------------------------------------
echo ""
echo "========================================================================"
echo "  Running headless smoke suite"
echo "========================================================================"
echo ""

# Capture stderr so we can scan for ERROR lines. stdout from the GDScript
# print() calls goes to real stdout.
STDERR_LOG=$(mktemp)
set +e
"$GODOT" --headless --path "$TEST_PROJECT" 2>"$STDERR_LOG"
SMOKE_EXIT=$?
STDERR_CONTENT=$(cat "$STDERR_LOG")
rm -f "$STDERR_LOG"
set -e

# Print captured stderr lines that are not info-level
if [ -n "$STDERR_CONTENT" ]; then
    echo "[GODOT STDERR]" >&2
    echo "$STDERR_CONTENT" >&2
fi

# Scan stderr for engine ERROR lines (not NOTICE or INFO).
if echo "$STDERR_CONTENT" | grep -q '^ERROR:' 2>/dev/null; then
    echo ""
    echo "FAIL: Engine ERROR(s) detected in stderr" >&2
    SMOKE_EXIT=1
fi

if [ "$SMOKE_EXIT" -eq 0 ]; then
    echo ""
    echo "========================================================================"
    echo "  SUITE PASSED"
    echo "========================================================================"
else
    echo ""
    echo "========================================================================"
    echo "  SUITE FAILED (exit code $SMOKE_EXIT)"
    echo "========================================================================"
fi

exit "$SMOKE_EXIT"