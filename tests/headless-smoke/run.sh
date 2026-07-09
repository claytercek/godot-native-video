#!/usr/bin/env bash
# tests/headless-smoke/run.sh
# -----------------------------------------------------------------------
# One-command headless smoke test for the Native Video extension.
#
# Generates a multi-track marker clip (2 Audio Tracks) into the test project
# if missing (stage-clips.sh), builds the extension for the host platform,
# locates Godot via $GODOT_BIN (falling back to PATH), then hands off to
# run-suite.sh — the shared import + run + verify step also used by CI.
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

# --- Platform detection ----------------------------------------------------
case "$(uname -s)" in
    Darwin*)  PLATFORM="macos" ;;
    MINGW*|MSYS*|CYGWIN*) PLATFORM="windows" ;;
    *)
        echo "ERROR: unsupported platform ($(uname -s))" >&2
        exit 1
        ;;
esac

LIB_NAME="libnative-video"
SUFFIX="template_debug"
if [ "$PLATFORM" = "macos" ]; then
    LIB_FILE="${LIB_NAME}.${PLATFORM}.${SUFFIX}.dylib"
else
    LIB_FILE="${LIB_NAME}.${PLATFORM}.${SUFFIX}.x86_64.dll"
fi
LIB_SRC="$REPO_ROOT/bin/$PLATFORM/$LIB_FILE"
LIB_DST="$TEST_PROJECT/addons/native-video/$PLATFORM/$LIB_FILE"

# --- 1. Generate multi-track clip -----------------------------------------
if [ ! -f "$CLIP" ]; then
    echo "--- Generating multi-track clip (2 audio tracks) ---"
    "$TOOLS/gen_test_media.sh" \
        --multi-track 2 \
        --output "$CLIP"
    "$TEST_PROJECT/stage-clips.sh" "$CLIP"
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

# --- 4. Import + run + verify (shared with CI) ------------------------------
export GODOT_BIN="$GODOT"
exec "$TEST_PROJECT/run-suite.sh"