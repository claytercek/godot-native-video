#!/usr/bin/env bash
# Reproducible integration fixtures; never writes media into the checkout.
set -euo pipefail
out=${1:-/tmp/godot-native-video-linux-fixtures}
mkdir -p "$out"
out=$(realpath "$out")
repo=$(cd "$(dirname "$0")/.." && pwd)
case "$out/" in "$repo/"*) echo 'Choose a fixture directory outside the checkout' >&2; exit 2;; esac
for tool in ffmpeg ffprobe python3; do command -v "$tool" >/dev/null || { echo "Missing $tool" >&2; exit 2; }; done

ffmpeg -nostdin -hide_banner -loglevel error -y \
  -f lavfi -i 'testsrc2=size=320x240:rate=30:duration=3' \
  -f lavfi -i 'sine=frequency=440:sample_rate=48000:duration=3' \
  -map 0:v -map 1:a -c:v libx264 -preset fast -pix_fmt yuv420p \
  -g 30 -bf 2 -x264-params b-adapt=0 -c:a aac -ac 2 -ar 48000 \
  -movflags +faststart "$out/h264-aac.mp4"
ffmpeg -nostdin -hide_banner -loglevel error -y -i "$out/h264-aac.mp4" \
  -map 0:v -c:v copy -an "$out/h264-silent.mp4"

# Two distinct tones and explicit metadata exercise real track enumeration/reselect.
ffmpeg -nostdin -hide_banner -loglevel error -y -i "$out/h264-aac.mp4" \
  -f lavfi -i 'sine=frequency=440:sample_rate=48000:duration=3' \
  -f lavfi -i 'sine=frequency=880:sample_rate=48000:duration=3' \
  -map 0:v -map 1:a -map 2:a -c:v copy -c:a aac -ac 2 -ar 48000 \
  -metadata:s:a:0 language=eng -metadata:s:a:0 title=low-tone \
  -metadata:s:a:0 handler_name=low-tone -disposition:a:0 0 \
  -metadata:s:a:1 language=deu -metadata:s:a:1 title=high-tone \
  -metadata:s:a:1 handler_name=high-tone -disposition:a:1 default \
  -movflags +faststart "$out/h264-multitrack.mp4"

# Matroska carries explicit track titles/default flags that MP4 demuxers may
# truthfully report as unknown. Keep this as a separate metadata regression.
ffmpeg -nostdin -hide_banner -loglevel error -y -i "$out/h264-multitrack.mp4" \
  -map 0 -c copy -metadata:s:a:0 title=low-tone \
  -metadata:s:a:1 title=high-tone -disposition:a:0 0 -disposition:a:1 default \
  "$out/h264-multitrack.mkv"

# Conditional encoder support is an explicit skip, never an 8-bit substitute.
if ffmpeg -hide_banner -encoders 2>/dev/null | grep 'libx265' >/dev/null; then
  ffmpeg -nostdin -hide_banner -loglevel error -y \
    -f lavfi -i 'testsrc2=size=320x240:rate=30:duration=1' \
    -c:v libx265 -preset fast -pix_fmt yuv420p10le -profile:v main10 \
    -x265-params 'pools=1:frame-threads=1:log-level=error:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc' -tag:v hvc1 \
    -color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc \
    -an "$out/hevc-main10-pq.mp4"
else
  rm -f "$out/hevc-main10-pq.mp4"
  echo 'LINUX_VALIDATION_SKIP HEVC fixture: libx265 encoder absent'
fi
# VP9 Profile 2 catches precision decisions based only on HEVC profile strings.
if ffmpeg -hide_banner -encoders 2>/dev/null | grep 'libvpx-vp9' >/dev/null; then
  ffmpeg -nostdin -hide_banner -loglevel error -y \
    -f lavfi -i 'testsrc2=size=320x240:rate=2:duration=1' \
    -c:v libvpx-vp9 -deadline realtime -cpu-used 8 -pix_fmt yuv420p10le \
    -profile:v 2 -an "$out/vp9-10.webm"
else
  rm -f "$out/vp9-10.webm"
  echo 'LINUX_VALIDATION_SKIP VP9 fixture: libvpx-vp9 encoder absent'
fi
printf 'deliberately invalid MP4\n' > "$out/invalid.mp4"

# Independent fixture checks: exact frame counts, actual B-frames, audio layout.
python3 - "$out" <<'PY'
import json, pathlib, subprocess, sys
root = pathlib.Path(sys.argv[1])
def probe(name):
    return json.loads(subprocess.check_output([
        'ffprobe', '-v', 'error', '-count_frames', '-show_streams', '-of', 'json', str(root/name)]))['streams']
for name in ('h264-aac.mp4', 'h264-silent.mp4'):
    streams = probe(name)
    video = next(s for s in streams if s['codec_type'] == 'video')
    assert (video['codec_name'], video['width'], video['height'], int(video['nb_read_frames'])) == ('h264', 320, 240, 90), video
    assert int(video['has_b_frames']) > 0, video
    audio = [s for s in streams if s['codec_type'] == 'audio']
    if name == 'h264-aac.mp4':
        assert len(audio) == 1 and audio[0]['codec_name'] == 'aac', audio
        assert (int(audio[0]['sample_rate']), audio[0]['channels']) == (48000, 2), audio
    else:
        assert not audio, audio
audio = [s for s in probe('h264-multitrack.mp4') if s['codec_type'] == 'audio']
assert len(audio) == 2, audio
assert [s['tags']['language'] for s in audio] == ['eng', 'deu'], audio
assert [s['tags']['handler_name'] for s in audio] == ['low-tone', 'high-tone'], audio
assert [s['disposition']['default'] for s in audio] == [0, 1], audio
assert all((int(s['sample_rate']), s['channels']) == (48000, 2) for s in audio), audio
audio = [s for s in probe('h264-multitrack.mkv') if s['codec_type'] == 'audio']
assert [s['disposition']['default'] for s in audio] == [0, 1], audio
assert [s['tags']['title'] for s in audio] == ['low-tone', 'high-tone'], audio
if (root/'hevc-main10-pq.mp4').exists():
    video = next(s for s in probe('hevc-main10-pq.mp4') if s['codec_type'] == 'video')
    assert (video['codec_name'], video['profile'], video['pix_fmt'], int(video['nb_read_frames'])) == ('hevc', 'Main 10', 'yuv420p10le', 30), video
    assert video['color_transfer'] == 'smpte2084', video
if (root/'vp9-10.webm').exists():
    video = next(s for s in probe('vp9-10.webm') if s['codec_type'] == 'video')
    assert (video['codec_name'], video['profile'], video['pix_fmt']) == ('vp9', 'Profile 2', 'yuv420p10le'), video
    assert int(video['nb_read_frames']) == 2 and video['avg_frame_rate'] == '2/1', video
print('LINUX_VALIDATION_FIXTURES_PASS', root)
PY
find "$out" -maxdepth 1 -type f \( -name '*.mp4' -o -name '*.webm' -o -name '*.mkv' \) -print0 | sort -z | xargs -0 sha256sum > "$out/SHA256SUMS"
