#!/usr/bin/env bash
# tests/headless-smoke/run-suite.sh
# -----------------------------------------------------------------------
# Import and run the headless smoke suite, and decide pass/fail.
#
# This is the single owner of the smoke-failure policy, shared by run.sh
# (local) and the godot-smoke CI job: the suite fails on a nonzero exit
# from the smoke script OR any engine ERROR line on stderr.
#
# Requirements:
#   - $GODOT_BIN set to a Godot 4.4+ executable
#   - the extension library and synthetic clips already staged into this
#     project (run.sh and CI each handle that their own way)
# -----------------------------------------------------------------------
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ -z "${GODOT_BIN:-}" ] || [ ! -x "$GODOT_BIN" ]; then
    echo "ERROR: GODOT_BIN must point to a Godot 4.4+ executable" >&2
    exit 1
fi

# --- Headless import pass ----------------------------------------------
# Materializes project metadata (.godot/, *.uid) before the real run.
echo "--- Headless import pass ---"
"$GODOT_BIN" --headless --import --path "$PROJECT_DIR" 2>&1

# --- Run smoke suite -----------------------------------------------------
echo ""
echo "========================================================================"
echo "  Running headless smoke suite"
echo "========================================================================"
echo ""

# Capture stderr so we can scan for ERROR lines. stdout from the GDScript
# print() calls goes to real stdout.
STDERR_LOG=$(mktemp)
set +e
"$GODOT_BIN" --headless --path "$PROJECT_DIR" 2>"$STDERR_LOG"
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
