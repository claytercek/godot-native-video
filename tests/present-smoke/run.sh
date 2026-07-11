#!/usr/bin/env bash
# tests/present-smoke/run.sh
# -----------------------------------------------------------------------
# Windowed (non-headless) present-path smoke test.
#
# The headless suite cannot exercise the zero-copy present pipeline: without
# a RenderingDevice there is no surface import, so bugs in the native-texture
# handoff (e.g. the Godot 4.7 Metal driver over-releasing imported
# MTLTextures) never fire there. This test runs the demo project's smoke
# scene in a real window with --autoplay, lets it decode and present for a
# few hundred frames, and fails on a crash, an engine ERROR, or playback
# never reaching the present path.
#
# Requirements:
#   - $GODOT_BIN set to a Godot 4.4+ executable (or `godot` on PATH)
#   - a display session (this cannot run on a headless CI runner)
#   - scons + toolchain (builds the debug extension first)
#
# Usage:
#   ./tests/present-smoke/run.sh
# -----------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEMO_PROJECT="$REPO_ROOT/demo"

# How many rendered frames to run before quitting. The Godot 4.7 Metal
# over-release crashed within ~10 frames; 600 (~10s) gives generous margin.
QUIT_AFTER=600

# --- Locate Godot -----------------------------------------------------------
GODOT="${GODOT_BIN:-}"
if [ -z "$GODOT" ]; then
    GODOT="$(command -v godot 2>/dev/null || true)"
fi
if [ -z "$GODOT" ] || [ ! -x "$GODOT" ]; then
    echo "ERROR: GODOT_BIN must point to a Godot 4.4+ executable" >&2
    exit 1
fi
echo "--- Using Godot: $GODOT ---"

# --- Build extension ---------------------------------------------------------
echo "--- Building extension ---"
(cd "$REPO_ROOT" && scons target=template_debug)

# --- Import pass -------------------------------------------------------------
echo "--- Headless import pass ---"
"$GODOT" --headless --import --path "$DEMO_PROJECT" >/dev/null 2>&1 || true

# --- Windowed run ------------------------------------------------------------
echo "--- Running smoke scene windowed ($QUIT_AFTER frames) ---"
LOG=$(mktemp)
set +e
"$GODOT" --path "$DEMO_PROJECT" scenes/smoke.tscn --quit-after "$QUIT_AFTER" \
    -- --autoplay >"$LOG" 2>&1
RUN_EXIT=$?
set -e

cat "$LOG"

FAIL=0
if [ "$RUN_EXIT" -ne 0 ]; then
    echo "FAIL: Godot exited with code $RUN_EXIT" >&2
    FAIL=1
fi
if grep -q "handle_crash" "$LOG"; then
    echo "FAIL: crash handler fired" >&2
    FAIL=1
fi
if grep -q '^ERROR:' "$LOG"; then
    echo "FAIL: engine ERROR(s) in output" >&2
    FAIL=1
fi
# The smoke scene prints "Playing  pos=...  tex=ok" once per status tick while
# frames are presenting. Require playback to have actually progressed — a run
# that never presents a frame must not pass just because it didn't crash.
if ! grep -q "tex=ok" "$LOG"; then
    echo "FAIL: playback never presented a frame (no 'tex=ok' status line)" >&2
    FAIL=1
fi
rm -f "$LOG"

if [ "$FAIL" -eq 0 ]; then
    echo "PRESENT SMOKE PASSED"
else
    echo "PRESENT SMOKE FAILED" >&2
fi
exit "$FAIL"
