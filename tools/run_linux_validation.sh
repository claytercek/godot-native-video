#!/usr/bin/env bash
# Linux media integration, distinct from pure tests and headless/load checks.
# Requirements: Zig 0.17.0, pkg-config/GStreamer development+codec packages,
# Python3, timeout, and Godot (all zig build steps resolve it); Xvfb for software-xvfb.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
fixtures=/tmp/godot-native-video-linux-fixtures
results=
backend=1
rendered=1
renderer=physical-wayland
godot=${GODOT_PATH:-godot}
skip_build=0
usage() {
  echo "Usage: $0 --fixtures DIR [--results DIR] [--backend-only|--rendered-only]"
  echo '       [--renderer physical-wayland|software-xvfb] [--godot PATH] [--skip-build]'
}
while (($#)); do
  case "$1" in
    --fixtures) fixtures=$2; shift 2;;
    --results) results=$2; shift 2;;
    --backend-only) backend=1; rendered=0; shift;;
    --rendered-only) backend=0; rendered=1; shift;;
    --renderer) renderer=$2; shift 2;;
    --godot) godot=$2; shift 2;;
    --skip-build) skip_build=1; shift;;
    --help|-h) usage; exit 0;;
    *) usage >&2; exit 2;;
  esac
done
# Resolve CLI selection before either phase: even backend-only builds configure
# gdzig. Do not depend on a separate `godot` command remaining on PATH.
command -v "$godot" >/dev/null || { echo "Missing Godot: $godot (required at build configure time)" >&2; exit 2; }
godot=$(realpath "$(command -v "$godot")")
export GODOT_PATH="$godot"
fixtures=$(realpath "$fixtures")
results=${results:-$(mktemp -d /tmp/gnv-linux-validation.XXXXXX)}
mkdir -p "$results"
results=$(realpath "$results")
case "$results/" in "$repo/"*) echo 'Choose results outside checkout' >&2; exit 2;; esac
cd "$repo"
for command in timeout python3 pkg-config gst-inspect-1.0; do
  command -v "$command" >/dev/null || { echo "Missing $command" >&2; exit 2; }
done
for fixture in h264-aac.mp4 h264-silent.mp4 h264-multitrack.mp4 h264-multitrack.mkv invalid.mp4; do
  test -s "$fixtures/$fixture" || { echo "Missing fixture: $fixture; run tools/gen_linux_validation_media.sh" >&2; exit 2; }
done
printf 'LINUX_VALIDATION_ENV results=%s renderer=%s godot=%s\n' "$results" "$renderer" "$godot"
"$godot" --version > "$results/godot-version.log"
pkg-config --modversion gstreamer-1.0 gstreamer-app-1.0 gstreamer-video-1.0 gstreamer-audio-1.0 gstreamer-pbutils-1.0 > "$results/gstreamer-versions.log"

# HEVC is conditional only on fixture+factory availability. Once available,
# decode/presentation failure is a failure, not silently converted into skip.
hevc=0
if test -s "$fixtures/hevc-main10-pq.mp4"; then
  for factory in avdec_h265 libde265dec vah265dec nvh265dec v4l2h265dec v4l2slh265dec vulkanh265dec; do
    if gst-inspect-1.0 "$factory" > "$results/hevc-$factory.log" 2>&1; then hevc=1; break; fi
  done
fi
if (( ! hevc )); then echo 'LINUX_VALIDATION_SKIP HEVC10: fixture or decoder factory absent'; fi
vp9=0
if test -s "$fixtures/vp9-10.webm"; then
  for factory in avdec_vp9 vp9dec vavp9dec nvvp9dec v4l2vp9dec v4l2slvp9dec; do
    if gst-inspect-1.0 "$factory" > "$results/vp9-$factory.log" 2>&1; then vp9=1; break; fi
  done
fi
if (( ! vp9 )); then echo 'LINUX_VALIDATION_SKIP VP9 Profile2: fixture or decoder factory absent'; fi

run_backend() {
  local mode=$1 path=$2 name=$3 deadline=${4:-90}
  if ! timeout --kill-after=2 "$deadline" zig build linux-decode-regression -Doptimize=debug -Dgodot-path="$godot" -- "$mode" "$path" > "$results/$name.log" 2>&1; then
    tail -60 "$results/$name.log" >&2; return 1
  fi
  if ! grep -F "LINUX_DECODE_PASS mode=$mode" "$results/$name.log" >/dev/null; then
    tail -60 "$results/$name.log" >&2; echo "Missing backend success marker: $name" >&2; return 1
  fi
  echo "LINUX_VALIDATION_BACKEND_PASS $name"
}
if (( backend )); then
  test "$(zig version)" = 0.17.0 || { echo 'Zig 0.17.0 required' >&2; exit 2; }
  run_backend av "$fixtures/h264-aac.mp4" decode-av
  run_backend silent "$fixtures/h264-silent.mp4" decode-silent
  run_backend multi "$fixtures/h264-multitrack.mp4" decode-multitrack
  run_backend defaults "$fixtures/h264-multitrack.mkv" decode-default-metadata
  if (( hevc )); then run_backend hevc10 "$fixtures/hevc-main10-pq.mp4" decode-hevc10; fi
  if (( vp9 )); then run_backend vp9ten "$fixtures/vp9-10.webm" decode-vp9ten; fi
  run_backend reject "$fixtures/invalid.mp4" reject-invalid
  missing="$results/does-not-exist.mp4"
  test ! -e "$missing" || { echo 'Missing-media test path unexpectedly exists' >&2; exit 2; }
  run_backend reject "$missing" reject-missing
  # Native readers support local regular files, not indefinite streams. Compile
  # above before timing these actual unsupported-input rejection cases.
  fifo="$results/blocked-media.fifo"
  test -p "$fifo" || mkfifo "$fifo"
  run_backend reject "$fifo" reject-fifo 14
  run_backend reject "$results" reject-directory 14
  # This affects only this child process, not the host's process-global ranks.
  GST_PLUGIN_FEATURE_RANK='avdec_h264:0,openh264dec:0,vah264dec:0,vaapih264dec:0,nvh264dec:0,nvh264sldec:0,v4l2h264dec:0,v4l2slh264dec:0,vulkanh264dec:0' \
    run_backend missing-decoder "$fixtures/h264-aac.mp4" reject-missing-decoder
fi

xvfb_pid=
cleanup() {
  if [[ -n "$xvfb_pid" ]]; then kill "$xvfb_pid" 2>/dev/null || true; wait "$xvfb_pid" 2>/dev/null || true; fi
}
trap cleanup EXIT
if (( rendered )); then
  if (( ! skip_build )); then
    if ! timeout --kill-after=5 180 zig build -Dgodot-path="$godot" --summary all > "$results/build.log" 2>&1; then
      tail -60 "$results/build.log" >&2; exit 1
    fi
  fi
  test -s project/lib/libnative_video.so || { echo 'Build the extension first' >&2; exit 2; }
  sha256sum project/lib/libnative_video.so > "$results/native-library.sha256"
  project="$results/project"
  mkdir -p "$project"
  tar -C "$repo/project" --exclude='./.godot' -cf - . | tar -C "$project" -xf -
  mkdir -p "$project/.godot"
  printf 'res://native_video.gdextension\n' > "$project/.godot/extension_list.cfg"
  display_args=()
  physical_args=()
  case "$renderer" in
    physical-wayland)
      export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
      test -n "${WAYLAND_DISPLAY:-}" || { echo 'Set WAYLAND_DISPLAY for physical-wayland' >&2; exit 2; }
      test -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" || { echo 'Wayland socket unavailable' >&2; exit 2; }
      display_args=(--display-driver wayland)
      physical_args=(--physical)
      ;;
    software-xvfb)
      command -v Xvfb >/dev/null || { echo 'Missing Xvfb' >&2; exit 2; }
      lvp=${GNV_LVP_ICD:-${GNV_MESA:-/run/opengl-driver}/share/vulkan/icd.d/lvp_icd.x86_64.json}
      test -f "$lvp" || { echo 'Set GNV_LVP_ICD to the lavapipe ICD JSON' >&2; exit 2; }
      export VK_DRIVER_FILES="$lvp" VK_ICD_FILENAMES="$lvp" LIBGL_ALWAYS_SOFTWARE=1
      export XDG_RUNTIME_DIR="$results/runtime"
      mkdir -p "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR"
      Xvfb -displayfd 3 -screen 0 640x480x24 -nolisten tcp 3> "$results/xvfb-display" > "$results/xvfb.log" 2>&1 &
      xvfb_pid=$!
      for ((i=0; i<50; i++)); do
        [[ -s "$results/xvfb-display" ]] && break
        kill -0 "$xvfb_pid" 2>/dev/null || { echo 'Xvfb failed' >&2; exit 1; }
        sleep 0.1
      done
      read -r display < "$results/xvfb-display"
      export DISPLAY=:$display
      display_args=(--display-driver x11)
      echo 'LINUX_VALIDATION_RENDERER software lavapipe/Xvfb (not physical-GPU proof)'
      ;;
    *) echo "Unknown renderer: $renderer" >&2; exit 2;;
  esac
  run_godot() {
    local name=$1 marker=$2; shift 2
    if ! timeout --kill-after=5 75 "$godot" --path "$project" \
      "${display_args[@]}" --rendering-method forward_plus --rendering-driver vulkan \
      --audio-driver Dummy --max-fps 60 "$@" > "$results/$name.log" 2>&1; then
      tail -60 "$results/$name.log" >&2; return 1
    fi
    if ! python3 tools/check_linux_validation_log.py "$results/$name.log" --marker "$marker" "${physical_args[@]}"; then
      tail -60 "$results/$name.log" >&2; return 1
    fi
  }
  # Existing synthetic-specific luminance/variance assertions remain authoritative.
  run_godot synthetic-smoke 'SMOKE: PASS' -- --smoke
  run_godot transport-av LINUX_TRANSPORT_PASS --script res://linux_transport_test.gd -- --file="$fixtures/h264-aac.mp4" --expect-audio=1
  run_godot transport-silent LINUX_TRANSPORT_PASS --script res://linux_transport_test.gd -- --file="$fixtures/h264-silent.mp4" --expect-audio=0
  if (( hevc )); then
    run_godot transport-hevc10 LINUX_TRANSPORT_PASS --script res://linux_transport_test.gd -- --file="$fixtures/hevc-main10-pq.mp4" --expect-audio=0
  fi
fi
printf 'LINUX_VALIDATION_PASS backend=%s rendered=%s renderer=%s results=%s\n' "$backend" "$rendered" "$renderer" "$results"
