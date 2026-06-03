#!/usr/bin/env bash
# tools/gen_test_media.sh
# -----------------------------------------------------------------------
# Synthetic test-media generator — test tooling only; never a runtime dep.
#
# Produces an MP4 clip whose:
#   - Video contains a high-contrast frame-index marker (bright white block
#     in the top-left corner, with the decimal frame index burned in as
#     large text) so automated tests can verify which frame was decoded.
#   - Audio is a 200 Hz * (frame_index + 1) sine tone that changes every
#     frame, letting tests verify A/V sync by checking the tone frequency
#     at each PTS.  (A sync tone whose frequency maps to frame index, as
#     required by the issue.)
#     200 Hz base keeps the highest tone (200*N Hz) well below the 24 kHz
#     Nyquist limit for up to 119 frames at 48 kHz sample rate.
#
# Usage:
#   tools/gen_test_media.sh [--frames N] [--fps FPS] [--width W] [--height H]
#                           [--output PATH]
#
# Defaults:
#   --frames  60    (approx. 2 seconds at 30 fps)
#   --fps     30
#   --width   320
#   --height  240
#   --output  tests/fixtures/synthetic.mp4
#
# Requirements:
#   ffmpeg >= 4.0 in PATH  (test-only; never shipped with the extension)
# -----------------------------------------------------------------------
set -euo pipefail

FRAMES=60
FPS=30
WIDTH=320
HEIGHT=240
OUTPUT="tests/fixtures/synthetic.mp4"

# Parse args
while [[ $# -gt 0 ]]; do
    case "$1" in
        --frames)  FRAMES="$2"; shift 2 ;;
        --fps)     FPS="$2";    shift 2 ;;
        --width)   WIDTH="$2";  shift 2 ;;
        --height)  HEIGHT="$2"; shift 2 ;;
        --output)  OUTPUT="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

command -v ffmpeg >/dev/null 2>&1 || {
    echo "ERROR: ffmpeg not found in PATH. Install ffmpeg to generate test media." >&2
    exit 1
}

mkdir -p "$(dirname "$OUTPUT")"

SAMPLE_RATE=48000

# Use awk for portable floating-point arithmetic — bc can omit the
# leading zero (e.g. ".333333") which ffmpeg's duration parser rejects.
DURATION=$(awk "BEGIN{printf \"%.6f\", $FRAMES / $FPS}")
FRAME_DUR=$(awk "BEGIN{printf \"%.10f\", 1 / $FPS}")

# Build the audio filter_complex string
AUDIO_FILTER=""
for ((i=0; i<FRAMES; i++)); do
    FREQ=$(( 200 * (i + 1) ))
    # Each segment: sine at FREQ Hz for one frame duration
    AUDIO_FILTER+="sine=frequency=${FREQ}:sample_rate=${SAMPLE_RATE}:duration=${FRAME_DUR}[a${i}];"
done

# Concatenate all segments
CONCAT_INPUTS=""
for ((i=0; i<FRAMES; i++)); do
    CONCAT_INPUTS+="[a${i}]"
done
AUDIO_FILTER+="${CONCAT_INPUTS}concat=n=${FRAMES}:v=0:a=1[audio_out]"

# -----------------------------------------------------------------------
# Video: black background + white index block + burned-in frame number.
#
# drawbox   — white rectangle in top-left as a coarse machine-readable marker
# drawtext  — large frame index number for human / OCR verification
#
# n is the zero-based frame number in ffmpeg's lavfi/drawtext.
# -----------------------------------------------------------------------
VIDEO_FILTER="color=black:size=${WIDTH}x${HEIGHT}:rate=${FPS}:duration=${DURATION}[base];"
VIDEO_FILTER+="[base]drawbox=x=0:y=0:w=80:h=80:color=white:t=fill,"
VIDEO_FILTER+="drawtext=text='%{eif\:n\:d}':x=5:y=5:fontsize=40:fontcolor=black:font=monospace[video_out]"

# -----------------------------------------------------------------------
# Encode to H.264 + AAC MP4
# -----------------------------------------------------------------------
echo "Generating ${FRAMES}-frame synthetic clip -> ${OUTPUT}"
echo "  video: ${WIDTH}x${HEIGHT} @ ${FPS} fps, black+index block"
echo "  audio: sine per-frame (200*(idx+1) Hz), ${SAMPLE_RATE} Hz"

ffmpeg -y \
    -filter_complex "${VIDEO_FILTER};${AUDIO_FILTER}" \
    -map "[video_out]" \
    -map "[audio_out]" \
    -c:v libx264 -preset fast -crf 18 -pix_fmt yuv420p \
    -c:a aac -b:a 128k \
    -t "${DURATION}" \
    -movflags +faststart \
    "${OUTPUT}"

echo "Done: ${OUTPUT}"
