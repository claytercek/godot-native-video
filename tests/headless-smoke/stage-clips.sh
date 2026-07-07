#!/usr/bin/env bash
# tests/headless-smoke/stage-clips.sh
# -----------------------------------------------------------------------
# Stage the multi-track synthetic clip into the smoke test project:
# copy SRC_MP4 to synthetic.mp4 (skipped when SRC already is the
# destination), then remux to .mov and .m4v for ResourceLoader extension
# coverage. Single owner of the remux step, shared by run.sh and CI.
#
# Usage: stage-clips.sh SRC_MP4
# -----------------------------------------------------------------------
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="${1:?usage: stage-clips.sh SRC_MP4}"
DST="$PROJECT_DIR/synthetic.mp4"

if [ ! -f "$SRC" ]; then
    echo "ERROR: source clip not found: $SRC" >&2
    exit 1
fi

SRC_ABS="$(cd "$(dirname "$SRC")" && pwd)/$(basename "$SRC")"
if [ "$SRC_ABS" != "$DST" ]; then
    cp "$SRC_ABS" "$DST"
fi

ffmpeg -y -i "$DST" -c copy "$PROJECT_DIR/synthetic.mov" 2>/dev/null
ffmpeg -y -i "$DST" -c copy "$PROJECT_DIR/synthetic.m4v" 2>/dev/null
ls -lh "$PROJECT_DIR"/synthetic.mp4 "$PROJECT_DIR"/synthetic.mov "$PROJECT_DIR"/synthetic.m4v
