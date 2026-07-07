#!/usr/bin/env bash
# tools/multitrack_lib.sh
# -----------------------------------------------------------------------
# Shared multi-track synthetic-audio filtergraph builder — test tooling
# only; never a runtime dep. Sourced by tools/gen_test_media.sh and
# tools/gen_clip_matrix.sh so the multi-track ffmpeg algorithm lives in
# exactly one place.
#
# Each track carries a disjoint per-frame Sync Ladder tone: track k's
# frame i plays at (k * TRACK_STRIDE + 200) + 200*i Hz, so tone frequency
# encodes both track identity and media position. Language tags cycle
# through the caller-supplied list (or a built-in default list when none
# is given).
#
# Usage:
#   gen_multi_track_audio_args <num_tracks> <frames> <frame_dur> \
#       <sample_rate> <stereo:0|1> [lang1 lang2 ...]
#
# bash has no struct/tuple return, so results are communicated via
# globals (by convention prefixed MT_) rather than echoed and re-parsed:
#   MT_AUDIO_FILTER      filtergraph fragment for all tracks (no leading
#                         or trailing ';')
#   MT_AUDIO_MAPS        array:  -map "[audio_out_N]" ...
#   MT_AUDIO_CODEC_ARGS  array:  -c:a:N aac -b:a:N 128k ...
#   MT_METADATA_ARGS     array:  -metadata:s:a:N language=... title=... ...
#   MT_TRACK_BASES       array:  base frequency (Hz) used by track N,
#                         index-aligned with track number — for callers
#                         that log a per-track summary
#   MT_TRACK_LANGS       array:  language tag used by track N, index-
#                         aligned with track number
# -----------------------------------------------------------------------

MULTITRACK_TRACK_STRIDE=3000
MULTITRACK_DEFAULT_LANGS=(eng fra deu spa ita jpn kor chi)

gen_multi_track_audio_args() {
    local num_tracks="$1" frames="$2" frame_dur="$3" sample_rate="$4" stereo="$5"
    shift 5
    local lang_tags=("$@")
    if [[ ${#lang_tags[@]} -eq 0 ]]; then
        lang_tags=("${MULTITRACK_DEFAULT_LANGS[@]}")
    fi

    MT_AUDIO_FILTER=""
    MT_AUDIO_MAPS=()
    MT_AUDIO_CODEC_ARGS=()
    MT_METADATA_ARGS=()
    MT_TRACK_BASES=()
    MT_TRACK_LANGS=()

    local track track_base label lang i freq
    for ((track = 0; track < num_tracks; track++)); do
        track_base=$(( track * MULTITRACK_TRACK_STRIDE + 200 ))
        label="audio_out_${track}"
        MT_AUDIO_MAPS+=(-map "[${label}]")
        MT_AUDIO_CODEC_ARGS+=(-c:a:${track} aac -b:a:${track} 128k)

        lang="${lang_tags[$(( track % ${#lang_tags[@]} ))]}"
        MT_METADATA_ARGS+=(-metadata:s:a:${track} "language=${lang}")
        MT_METADATA_ARGS+=(-metadata:s:a:${track} "title=Track ${track} (${lang})")

        MT_TRACK_BASES+=("${track_base}")
        MT_TRACK_LANGS+=("${lang}")

        # Per-track Sync Ladder: N sine segments (one per frame) concatenated.
        # Frequency = track_base + 200 * frame_index — disjoint per track.
        for ((i = 0; i < frames; i++)); do
            freq=$(( track_base + 200 * i ))
            MT_AUDIO_FILTER+="sine=frequency=${freq}:sample_rate=${sample_rate}:duration=${frame_dur}[t${track}f${i}];"
        done
        for ((i = 0; i < frames; i++)); do
            MT_AUDIO_FILTER+="[t${track}f${i}]"
        done
        MT_AUDIO_FILTER+="concat=n=${frames}:v=0:a=1"

        if [[ "${stereo}" -eq 1 ]]; then
            # Upmix mono -> stereo to match a manifest's audio_channels=2.
            MT_AUDIO_FILTER+="[${label}_mono];"
            MT_AUDIO_FILTER+="[${label}_mono]pan=stereo|c0=c0|c1=c0[${label}]"
        else
            MT_AUDIO_FILTER+="[${label}]"
        fi

        # Separate per-track audio filter chains with ; so ffmpeg treats
        # them as independent chains. The last one gets no trailing separator.
        if [[ $track -lt $(( num_tracks - 1 )) ]]; then
            MT_AUDIO_FILTER+=";"
        fi
    done
}
