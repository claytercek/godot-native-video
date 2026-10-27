# Native video for Godot

MP4/MOV playback (H.264/HEVC) for stock Godot 4.6+ on macOS, Windows, and
Linux. Works with `VideoStreamPlayer` without engine changes. The extension
controls playback timing and decodes through AVFoundation, Media Foundation,
or GStreamer. macOS and Windows/D3D12 support presentation without CPU
copies; Linux uploads CPU-readable planes, with optional hardware decoding.

## Architecture

A Godot-independent core drives each backend in decoder mode:
`AVAssetReader` on macOS, synchronous `IMFSourceReader` on Windows, and
separate video/audio GStreamer readers on Linux. A bounded, shared worker
pool schedules decode and preserves per-stream frame order. Media backends
can also use their own threads.

The core owns the master clock, frame queue, synchronization, and
decode-ahead. Audio drives the clock, with a monotonic fallback for silent
clips. Presentation drops late frames and holds early ones to recover from
decode delays without lasting drift. Scrubbing uses keyframes during fast
drags and selects the exact frame when the drag settles.

On Windows, the backend confines COM to a dedicated MTA (multi-threaded
apartment) executor for the lifetime of the open media. Godot's main thread
runs in an STA, which can't create the required Media Foundation objects.

On macOS, `RenderingDevice.texture_create_from_extension` imports the
hardware-decoded NV12 surface as a `Texture2DRD`. A Metal compute pass
converts NV12 to RGB in an engine-owned texture returned by
`VideoStreamPlayback._get_texture()`. Godot never samples the decoder
surface directly. This path needs no CPU copy, BGRA-to-RGBA swizzle, or GPU
round-trip. Windows/D3D12 uses a similar zero-copy path; see
[Windows present path](#windows-present-path) for selection and fallback.

On Linux, GStreamer supplies retained CPU-readable NV12 (8-bit) or P010
(10-bit) frames. The extension uploads their planes to Godot-owned R/RG
textures and runs the shared color/HDR conversion shader. Hardware decoding
may require a readback before upload. CPU memory bandwidth can limit
multiple high-resolution streams, but this path needs no DMA-BUF or native
Vulkan import. GStreamer doesn't control the playback clock.

## Requirements

- macOS (Apple Silicon or Intel), Windows, or Linux. The extension links
  AVFoundation, CoreMedia, CoreVideo, and Metal on macOS; Media Foundation
  and D3D11/D3D12 on Windows; system GStreamer libraries on Linux.
- Stock Godot 4.6+ with Forward+ on Linux (Vulkan). macOS and Windows also
  support Mobile. Compatibility/OpenGL is unsupported: even CPU uploads
  require a RenderingDevice and compute shaders.
- Zig 0.17.0 for source builds. Other versions are unsupported.
  [gdzig](https://github.com/gdzig/gdzig), the pre-1.0 binding generator, is
  pinned to a specific commit and Zig version.
- A Godot executable for every source-build step, including tests. Set
  `-Dgodot-path=/path/to/Godot` or `GODOT_PATH`, or put `godot` on `PATH`.
  gdzig resolves it during build configuration, even for steps that don't
  launch Godot. Released binaries don't need this setup.
- Python 3 on `PATH` (`python` on Windows, `python3` elsewhere) for
  `zig build smoke` and local validation tools. The released addon doesn't
  need Python.

On Ubuntu/Debian, install the Linux runtime dependencies:

```bash
sudo apt-get update
sudo apt-get install --no-install-recommends \
  libgstreamer1.0-0 libgstreamer-plugins-base1.0-0 \
  gstreamer1.0-tools gstreamer1.0-plugins-base \
  gstreamer1.0-plugins-good gstreamer1.0-plugins-bad \
  gstreamer1.0-plugins-ugly gstreamer1.0-libav
```

The addon doesn't bundle these libraries or plugins. They provide appsinks,
MP4 demuxing, audio/video conversion, and H.264/HEVC/AAC software decoders.
Hardware decoding depends on optional plugins and drivers. Godot also needs
its usual system libraries and a working Vulkan driver. Package names vary
by distribution; no custom Godot build is required.

## Releases

Each GitHub Release includes `native_video-<tag>.zip`. Copy its
`addons/native_video/` folder into your project's `addons/` directory.
Godot loads `native_video.gdextension` automatically.

| Platform | Arch | Files |
| --- | --- | --- |
| macOS | universal (arm64 + x86_64, via `lipo`) | `libnative_video.macos.debug.dylib`, `libnative_video.macos.release.dylib` |
| Windows | x86_64 | `native_video.windows.debug.x86_64.dll`, `native_video.windows.release.x86_64.dll` |
| Windows | x86 (32-bit) | `native_video.windows.debug.x86_32.dll`, `native_video.windows.release.x86_32.dll` |
| Windows | arm64 | `native_video.windows.debug.arm64.dll`, `native_video.windows.release.arm64.dll` |
| Linux | x86_64 | `libnative_video.linux.debug.x86_64.so`, `libnative_video.linux.release.x86_64.so` |

Linux binaries are built natively on Ubuntu 22.04 for a baseline x86_64 CPU
and link system GStreamer. Install the runtime packages above before loading
the addon. Linux ARM64 isn't shipped or tested; the demo manifest allows
native ARM64 source builds.

Each platform/architecture includes debug and release binaries. The
`.gdextension` selects one to match Godot's `template_debug` or
`template_release` export. Debug binaries use `-Doptimize=safe` with safety
checks enabled and stripping disabled; release binaries use stripped
`-Doptimize=fast` builds.

iOS builds produce a valid Mach-O `dylib` but aren't shipped. Godot's iOS
export normally expects a static library or `.xcframework`. Only linking
has been verified, not on-device playback; packaging work has no scheduled
release.

## Windows present path

At startup, the extension selects an import path from the active
`RenderingDevice` driver and Godot version. Both paths are built in;
selection doesn't probe them by trial and error.

| Renderer driver | Import path | Zero-copy | Notes |
| --- | --- | --- | --- |
| `d3d12` | D3D12 shared-handle import | Yes | Shared NT handles and a D3D11/D3D12 fence pass the decoder's D3D11 texture to Godot's D3D12 device. A compute pass splits NV12/P010 into luma/chroma views. Selection requires Godot 4.5+, when D3D12 gained `texture_create_from_extension`; the extension's 4.6+ minimum meets this requirement. |
| `vulkan` (stock) or anything else | CPU-copy fallback | No | Adds a GPU-to-CPU readback per frame. The DXGI shared-handle path through `VK_KHR_external_memory_win32` was disabled upstream before this Zig port and isn't built here: Godot's Vulkan `texture_create_from_extension` mis-binds NV12 plane aspects. |

If D3D12 setup fails, for example because no device is available or shared
handles can't be opened across adapters, playback falls back to CPU copies
for the session. It doesn't retry zero-copy each frame.

Use Godot's D3D12 driver for zero-copy presentation. Stock Vulkan supports
hardware decoding but adds a readback before presentation. See
[Diagnostics](#diagnostics) to check CPU-copy usage.

## Known limitations

- Headless mode (`--headless`) disables presentation because there's no
  RenderingDevice. Decode, audio mixing, the master clock, and playback
  state machines still run to end-of-stream, but produce no texture.
- Linux HEVC Main10/PQ/HLG needs suitable GStreamer decoder plugins. P010
  preserves 10-bit samples through upload and color conversion; this doesn't
  certify OS/compositor HDR signaling or HDR display output.
- Windows HEVC needs a registered decoder MFT, typically the "HEVC Video
  Extensions" package. Some Windows installations lack one.
- Godot 4.6 logs `Attempt to get non-existent interface function` for
  `variant_get_type_by_name`, `classdb_construct_object3`, and
  `classdb_register_extension_class6`. gdzig's bindings use Godot 4.7's API
  description and probe these 4.7-only functions at load. On 4.6, gdzig uses
  older entry points without calling them; playback is unaffected. No API
  hash used by the extension changed between 4.6 and 4.7, and CI tests both.
- Prebuilt libraries require standard single-precision Godot. They won't
  load into a double-precision (`precision=double`) build because core type
  layouts differ. Build from source with `-Dprecision=double`; see
  [Building from source](#building-from-source).

## Diagnostics

Logs from every backend and thread go to stderr and Godot's Output panel.
Errors and warnings use `push_error` / `push_warning`; info/debug lines
print there too. Failed `load()` calls report the resolved OS path and
underlying error, including bad paths, backend failures, and unsupported
content.

Call `get_cpu_copy_count()` on a live `VideoStreamPlayback` to count frames
that used Windows' CPU-copy fallback or Linux's plane upload this session.
It stays zero on macOS. Linux counts uploaded frames, not individual memory
copies.

## Scope

- Codecs: H.264 and HEVC (Main and Main10).
- Containers: MP4 and MOV; the loader registers `.mp4`, `.mov`, and `.m4v`.
- Pixel formats: NV12 (8-bit) and 10-bit biplanar x420 (macOS) or P010
  (Windows/Linux), negotiated to match source bit depth. Conversion
  normalizes 10-bit payloads in 16-bit GPU words.
- Colorimetry: BT.709, BT.601, and BT.2020 YCbCr matrices; BT.709, BT.601,
  BT.2020, and DCI-P3 primaries; BT.709, PQ (ST 2084 / HDR10), and HLG
  transfer functions; video and full range. Unspecified fields default to
  BT.709, video range.
- HDR: PQ/HLG clips tone-map to SDR by default. Set the stream's
  `output_mode` to HDR for scene-linear RGBA16F output, where 1.0 equals
  203-nit Reference White per BT.2408.
- Audio: AAC decoded to interleaved float32 PCM. Mono, stereo, and 5.1
  sources are mixed to the clip's canonical output format.
- Multi-track audio: enumerate with `NativeVideoStream.get_audio_tracks()`
  and select with `VideoStreamPlayer.audio_track` before `play()` or during
  playback.

Only this matrix is tested and supported. Other content may play if the
backend can decode it and its container has a registered extension. VP9/AV1
is out of scope. For mixed-sample-rate clips, the first audio track sets the
sample rate; switching to a track with a different rate is refused.

## Building from source

1. Install Zig 0.17.0 and make Godot available through `-Dgodot-path=`,
   `GODOT_PATH`, or `PATH`, in that resolution order. For example, with gdvm:
   `export GODOT_PATH="$(gdvm show 4.7.2)"`. You can also use your installed
   Godot executable. Every `zig build` step needs it, including tests;
   bindings come from gdzig's vendored API description, not this executable.

   On Linux, install the runtime packages above and the development
   dependencies used by CI:

   ```bash
   sudo apt-get install pkg-config libgstreamer1.0-dev \
     libgstreamer-plugins-base1.0-dev
   pkg-config --modversion gstreamer-1.0 gstreamer-app-1.0 \
     gstreamer-video-1.0 gstreamer-audio-1.0 gstreamer-pbutils-1.0
   ```

   Even backend tests need pkg-config to resolve headers and system
   libraries. Build natively against the target system's GStreamer packages.

2. Build the extension:

   ```bash
   zig build
   ```

   `build.zig` compiles `libnative_video.dylib` (macOS), `native_video.dll`
   (Windows), or `libnative_video.so` (Linux) into `project/lib/`, as expected
   by `project/native_video.gdextension`. Windows links Media Foundation and
   D3D11/D3D12 system libraries.

   The default is a stripped `fast` binary (~380 KB on macOS arm64; Windows
   size hasn't been measured separately). Use `-Doptimize=debug` for debug
   builds or `-Doptimize=small` to trade speed for size.

   Precision defaults to `float`. Add `-Dprecision=double` for
   double-precision Godot. A mismatch causes memory-layout errors, not a
   graceful failure.

3. Run core, platform-backend, and pure presentation-policy tests. They
   don't exercise Godot code, though the build still resolves Godot:

   ```bash
   zig build test
   ```

   Linux also has focused backend and plane-packing tests and a standalone
   decode smoke:

   ```bash
   zig build test-gst
   zig build test-linux-packing
   zig build decode-smoke -- project/synthetic.mp4
   ```

4. Build and launch the interactive demo with `project/synthetic.mp4`, or
   pass another clip after `--`:

   ```bash
   zig build run
   ```

   For unattended verification, run the smoke check. It loads and plays a
   clip, waits for a video texture, checks pixel content, and exits with
   0 (PASS) or 1 (FAIL):

   ```bash
   zig build smoke
   ```

   This builds and installs the extension, then runs `tests/run_smoke.py`
   with the resolved Godot and writes `zig-out/smoke.log`. Unlike
   `zig build run -- --smoke`, it requires completion within 75 seconds, an
   exact PASS line, a Forward+ device banner, and no engine errors except
   the known Godot 4.6 probes.

   Smoke uses dummy audio on every OS, Vulkan on Linux, D3D12 on Windows,
   and the default rendering driver on macOS. It needs a display and a
   working RenderingDevice; don't use `--headless`. Linux CI uses software
   Vulkan under Xvfb. Pass engine setup flags after `--`, for example:
   `zig build smoke -- --display-driver x11`.

### CI and local validation

`.github/workflows/test.yml` requires checks on macOS, Linux, and Windows
with stock Godot 4.7.2 (primary) and 4.6.3 (supported minimum). The shared
`.github/workflows/build.yml`, also used by `.github/workflows/release.yml`,
builds all shipped platforms/architectures in safe/debug and fast/release
modes once per run.

All OS/version combinations run rendered playback smoke with the
fast/release artifacts and `project/synthetic.mp4`. CI calls
`tests/run_smoke.py` directly to test downloaded artifacts without
rebuilding. Unit/backend tests and standalone decode smoke build their own
harnesses and run only on the primary version. Windows generates the
fixtures its native tests need.

### Developer tools

Generate optional fixtures or run local Linux validation with:

```bash
bash tools/gen_stress_media.sh --output-dir tests/fixtures/stress --duration 6
bash tools/gen_linux_validation_media.sh /tmp/native-video-fixtures
bash tools/run_linux_validation.sh --help
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -p 'test_*.py' -v
```

Generators need FFmpeg with libx264; Linux fixture generation also needs
FFprobe and Python 3. The Linux runner's `--help` documents backend and
rendered modes. It requires GNU `timeout` on `PATH`. Python discovery skips
the Xvfb startup suite without `timeout`; on macOS, install Homebrew
`coreutils` and add its commands to `PATH` to run it.

To check an existing build without rebuilding:

```bash
python3 tests/run_smoke.py --godot /path/to/godot --driver vulkan --log zig-out/smoke.log
```

Use `--driver d3d12` on Windows or `--driver default` on macOS. Put display
setup flags after `--`; use `python` on Windows. The shared log checker is
`tests/check_validation_log.py <log> --marker <success-marker>`. Its
`LINUX_VALIDATION_LOG_*` labels remain for existing log consumers.

Linux codec, multitrack, seek, lifecycle, input-rejection, and rendered
transport regressions are local opt-in checks, not CI jobs. Install the
build dependencies above, FFmpeg, and Python 3, then run:

```bash
bash tools/gen_linux_validation_media.sh /tmp/native-video-fixtures
bash tools/run_linux_validation.sh --fixtures /tmp/native-video-fixtures \
  --results /tmp/native-video-backend-results --backend-only
```

For rendered checks with software Vulkan and Xvfb on Ubuntu:

```bash
GNV_LVP_ICD=/usr/share/vulkan/icd.d/lvp_icd.x86_64.json \
  bash tools/run_linux_validation.sh --fixtures /tmp/native-video-fixtures \
  --results /tmp/native-video-rendered-results --rendered-only --renderer software-xvfb
```

Install Xvfb and Mesa Vulkan drivers and adjust the ICD path for your
system. Logs go to the chosen results directory. Software rendering doesn't
certify hardware decoding or HDR display output. Physical AMD RX Vega tests
also covered transport and reentrant preview teardown.

## Project layout

- `src/core/`: engine-independent clock, frame queue, scrubber, presentation
  selector, decode scheduler, backend interface, and color math. Pure Zig
  with no Godot or media-framework imports; tested by `zig build test`.
- `src/avf/`: macOS AVFoundation backend. `avf_shim.m`/`avf_shim.h` expose a
  C ABI to Zig through the core `Backend` interface. `decode_smoke.zig`
  isolates decode bugs without Godot.
- `src/mf/`: Windows Media Foundation backend. Synchronous `IMFSourceReader`,
  the MTA `ComExecutor`, hand-written D3D11/D3D12/DXGI bindings in
  `src/mf/win/`, and a standalone `decode_smoke.zig` harness.
- `src/gst/`: Linux GStreamer backend. A C shim handles discovery and
  independent video/audio readers. Includes retained frame payloads,
  backend tests, `decode_smoke.zig`, the `linux_decode_regression.zig`
  acceptance harness, and the `linux_fixture_pts.zig` fixture PTS oracle.
- `src/godot/`: [gdzig](https://github.com/gdzig/gdzig) class registration
  (`NativeVideoStream` / `NativeVideoStreamPlayback`), NV12-to-RGB
  presentation, and platform importers. macOS uses Metal; Windows uses
  `importer_selector` to choose D3D12 or CPU copies; Linux uses CPU upload
  and pure NV12/P010 plane-packing helpers.
- `project/`: demo and verification harness. `main.gd`/`main.tscn` provide
  the default interactive UI (`zig build run`) and unattended verification
  (`zig build smoke`, `--smoke`).
- `addon/`: release `.gdextension` template; see [Releases](#releases).
  `zig build` uses the separate `project/native_video.gdextension`, which
  points to local output.
- `tests/`: shared smoke/log runners and Python CLI regression tests.
  Generated stress media lives in `tests/fixtures/`.
- `tools/`: media generators and `run_linux_validation.sh`. Keep
  backend-specific Zig tests and harnesses beside their module in `src/`,
  shared validation and tests in `tests/`, and one-off packaging checks in
  release workflows.

See [EVALUATION.md](EVALUATION.md) for implementation benchmarks and rationale.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for release notes and workflow instructions.

## License

MIT; see [LICENSE](LICENSE).
