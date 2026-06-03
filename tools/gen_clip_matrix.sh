#!/usr/bin/env bash
# tools/gen_clip_matrix.sh
# -----------------------------------------------------------------------
# Real-clip format-matrix generator — test tooling only; never a runtime dep.
#
# Produces the small matrix of REAL hardware-decodable clips that the
# backend coverage tests consume. Unlike tools/gen_test_media.sh (which burns
# in a per-frame marker for frame-index assertions), the matrix clips exercise
# real encoder/container quirks across the 8-bit SDR core matrix:
#
#   - codecs:      H.264 (libx264) and HEVC (libx265)
#   - frame rates: 24, 30, 60 fps
#   - containers:  .mp4 and .mov
#   - audio:       AAC stereo, 48 kHz
#
# Each clip still carries the same machine-readable white index block + burned
# frame number as the synthetic marker clip, so a coverage test can additionally
# verify decode success per frame. The clip set is described by
# tests/fixtures/matrix/matrix.json, which the coverage tests read so the test
# code and the generator never drift out of sync.
#
# These outputs are tracked via Git LFS (see .gitattributes). An operator runs
# this script ONCE and commits the resulting *.mp4 / *.mov via LFS, OR CI
# regenerates them on the fly (ffmpeg is a test-only tool, never shipped).
#
# Usage:
#   tools/gen_clip_matrix.sh [--output-dir DIR]
#
# Defaults:
#   --output-dir  tests/fixtures/matrix
#
# Requirements:
#   ffmpeg >= 4.0 with libx264 + libx265 in PATH (test-only; never shipped).
# -----------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

OUTPUT_DIR="${REPO_ROOT}/tests/fixtures/matrix"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

command -v ffmpeg >/dev/null 2>&1 || {
    echo "ERROR: ffmpeg not found in PATH. Install ffmpeg to generate the clip matrix." >&2
    exit 1
}

mkdir -p "${OUTPUT_DIR}"

SAMPLE_RATE=48000
WIDTH=320
HEIGHT=240

# -----------------------------------------------------------------------
# The matrix. Each row: NAME CODEC FPS CONTAINER FRAMES
# Kept deliberately small (real-world quirk coverage, not an exhaustive sweep).
#
#   h264_30_mp4 : baseline H.264 / 30 fps / mp4
#   h264_24_mov : H.264 / 24 fps / mov container
#   h264_60_mp4 : H.264 / high 60 fps / mp4
#   hevc_30_mp4 : HEVC / 30 fps / mp4
#   hevc_24_mov : HEVC / 24 fps / mov container
#
# This list MUST stay in sync with tests/fixtures/matrix/matrix.json.
# -----------------------------------------------------------------------
MATRIX=(
    "h264_30_mp4 h264 30 mp4 30"
    "h264_24_mov h264 24 mov 24"
    "h264_60_mp4 h264 60 mp4 60"
    "hevc_30_mp4 hevc 30 mp4 30"
    "hevc_24_mov hevc 24 mov 24"
)

gen_clip() {
    local name="$1" codec="$2" fps="$3" container="$4" frames="$5"
    local out="${OUTPUT_DIR}/${name}.${container}"

    local duration frame_dur
    duration=$(awk "BEGIN{printf \"%.6f\", ${frames} / ${fps}}")
    frame_dur=$(awk "BEGIN{printf \"%.10f\", 1 / ${fps}}")

    # Per-frame sine tone (200*(idx+1) Hz), upmixed mono -> STEREO, AAC 48 kHz.
    local audio_filter="" concat=""
    local i freq
    for ((i = 0; i < frames; i++)); do
        freq=$((200 * (i + 1)))
        audio_filter+="sine=frequency=${freq}:sample_rate=${SAMPLE_RATE}:duration=${frame_dur}[a${i}];"
        concat+="[a${i}]"
    done
    audio_filter+="${concat}concat=n=${frames}:v=0:a=1[amono];[amono]pan=stereo|c0=c0|c1=c0[audio_out]"

    local video_filter="color=black:size=${WIDTH}x${HEIGHT}:rate=${fps}:duration=${duration}[base];"
    video_filter+="[base]drawbox=x=0:y=0:w=80:h=80:color=white:t=fill,"
    video_filter+="drawtext=text='%{eif\:n\:d}':x=5:y=5:fontsize=40:fontcolor=black:font=monospace[video_out]"

    local vcodec
    case "${codec}" in
        h264) vcodec=(-c:v libx264 -preset fast -crf 20 -pix_fmt yuv420p) ;;
        hevc) vcodec=(-c:v libx265 -preset fast -crf 22 -pix_fmt yuv420p -tag:v hvc1) ;;
        *) echo "ERROR: unknown codec ${codec}" >&2; return 1 ;;
    esac

    echo "Generating ${name}: ${codec} ${fps}fps ${container} (${frames} frames) -> ${out}"
    ffmpeg -y \
        -filter_complex "${video_filter};${audio_filter}" \
        -map "[video_out]" -map "[audio_out]" \
        "${vcodec[@]}" \
        -c:a aac -b:a 128k -ac 2 -ar "${SAMPLE_RATE}" \
        -t "${duration}" \
        -movflags +faststart \
        "${out}" </dev/null
}

# libx265 may be absent in a minimal ffmpeg; skip HEVC rows with a clear warning
# rather than failing the whole matrix.
have_x265=1
ffmpeg -hide_banner -encoders 2>/dev/null | grep -q libx265 || have_x265=0

generated=0
for row in "${MATRIX[@]}"; do
    # shellcheck disable=SC2086
    set -- ${row}
    name="$1" codec="$2"
    if [[ "${codec}" == "hevc" && "${have_x265}" -eq 0 ]]; then
        echo "WARN: libx265 not available; skipping ${name}" >&2
        continue
    fi
    gen_clip "$@"
    generated=$((generated + 1))
done

echo "Done: generated ${generated} matrix clip(s) into ${OUTPUT_DIR}"
