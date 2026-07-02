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
# With --multi-track N, the clip carries N independent audio tracks, each
# with a disjoint frequency band and a language tag. Track 0 keeps the
# 200*(idx+1) Hz Sync Ladder; track k adds k*3000 Hz to all per-frame
# frequencies so tone frequency encodes both track identity and media
# position. Language tags cycle through a built-in list.
#
# Usage:
#   tools/gen_test_media.sh [--frames N] [--fps FPS] [--width W] [--height H]
#                           [--output PATH] [--multi-track N]
#
# Defaults:
#   --frames       60    (approx. 2 seconds at 30 fps)
#   --fps          30
#   --width        320
#   --height       240
#   --output       tests/fixtures/synthetic.mp4
#   --multi-track  0     (single audio track, backwards-compatible)
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
MULTI_TRACK=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --frames)       FRAMES="$2"; shift 2 ;;
        --fps)          FPS="$2";    shift 2 ;;
        --width)        WIDTH="$2";  shift 2 ;;
        --height)       HEIGHT="$2"; shift 2 ;;
        --output)       OUTPUT="$2"; shift 2 ;;
        --multi-track)  MULTI_TRACK="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

command -v ffmpeg >/dev/null 2>&1 || {
    echo "ERROR: ffmpeg not found in PATH. Install ffmpeg to generate test media." >&2
    exit 1
}

mkdir -p "$(dirname "$OUTPUT")"

# drawtext font selection. On Windows, fontconfig-enabled ffmpeg builds crash
# resolving a font *family* (no fontconfig config file ships with the binary),
# so point freetype at a concrete font file instead. Elsewhere the family
# lookup works and stays font-installation agnostic.
if [[ "${OS:-}" == "Windows_NT" ]]; then
    DRAWTEXT_FONT="fontfile='C\\:/Windows/Fonts/consola.ttf'"
else
    DRAWTEXT_FONT="font=monospace"
fi

SAMPLE_RATE=48000
TRACK_STRIDE=3000

DURATION=$(awk "BEGIN{printf \"%.6f\", $FRAMES / $FPS}")
FRAME_DUR=$(awk "BEGIN{printf \"%.10f\", 1 / $FPS}")

AUDIO_STREAMS=$(( MULTI_TRACK > 0 ? MULTI_TRACK : 1 ))

# -----------------------------------------------------------------------
# Build the filtergraph as a single string.
# ffmpeg's filter_complex uses ; between filter chains.
# Lazily-defined language tag list cycles for N tracks.
# -----------------------------------------------------------------------
FILTERGRAPH="color=black:size=${WIDTH}x${HEIGHT}:rate=${FPS}:duration=${DURATION}[base];"
FILTERGRAPH+="[base]drawbox=x=0:y=0:w=80:h=80:color=white:t=fill,"
FILTERGRAPH+="drawtext=text='%{eif\:n\:d}':x=5:y=5:fontsize=40:fontcolor=black:${DRAWTEXT_FONT}[video_out];"

LANG_TAGS=(eng fra deu spa ita jpn kor chi)
AUDIO_MAPS=()
AUDIO_CODEC_ARGS=()
METADATA_ARGS=()

for ((track=0; track<AUDIO_STREAMS; track++)); do
    TRACK_BASE=$(( track * TRACK_STRIDE + 200 ))
    LABEL="audio_out_${track}"
    AUDIO_MAPS+=(-map "[${LABEL}]")
    AUDIO_CODEC_ARGS+=(-c:a:${track} aac -b:a:${track} 128k)

    LANG="${LANG_TAGS[$(( track % ${#LANG_TAGS[@]} ))]}"
    METADATA_ARGS+=(-metadata:s:a:${track} "language=${LANG}")
    METADATA_ARGS+=(-metadata:s:a:${track} "title=Track ${track} (${LANG})")

    # Per-track Sync Ladder: N sine segments (one per frame) concatenated.
    # Frequency = TRACK_BASE + 200 * frame_index — disjoint per track.
    for ((i=0; i<FRAMES; i++)); do
        FREQ=$(( TRACK_BASE + 200 * i ))
        FILTERGRAPH+="sine=frequency=${FREQ}:sample_rate=${SAMPLE_RATE}:duration=${FRAME_DUR}[t${track}f${i}];"
    done
    # Concatenate all segments for this track.
    for ((i=0; i<FRAMES; i++)); do
        FILTERGRAPH+="[t${track}f${i}]"
    done
    FILTERGRAPH+="concat=n=${FRAMES}:v=0:a=1[${LABEL}]"
    # Separate per-track audio filter chains with ; so ffmpeg treats them
    # as independent chains. The last one does not get a trailing separator.
    if [[ $track -lt $(( AUDIO_STREAMS - 1 )) ]]; then
        FILTERGRAPH+=";"
    fi
done

# -----------------------------------------------------------------------
# Encode to H.264 + AAC MP4
# -----------------------------------------------------------------------
echo "Generating ${FRAMES}-frame synthetic clip -> ${OUTPUT}"
echo "  video: ${WIDTH}x${HEIGHT} @ ${FPS} fps, black+index block"
echo "  audio: ${AUDIO_STREAMS} track(s), per-frame Sync Ladder, ${SAMPLE_RATE} Hz"
for ((track=0; track<AUDIO_STREAMS; track++)); do
    BASE=$(( track * TRACK_STRIDE + 200 ))
    LANG="${LANG_TAGS[$(( track % ${#LANG_TAGS[@]} ))]}"
    echo "    track ${track}: base=${BASE} Hz, lang=${LANG}"
done

ffmpeg -y \
    -filter_complex "${FILTERGRAPH}" \
    -map "[video_out]" \
    "${AUDIO_MAPS[@]}" \
    -c:v libx264 -preset fast -crf 18 -pix_fmt yuv420p \
    "${AUDIO_CODEC_ARGS[@]}" \
    "${METADATA_ARGS[@]}" \
    -t "${DURATION}" \
    -movflags +faststart \
    "${OUTPUT}"

echo "Done: ${OUTPUT}"