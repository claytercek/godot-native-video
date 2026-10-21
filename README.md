# Native Video for Godot

MP4/MOV video playback (H.264/HEVC) for stock Godot 4.6+ on macOS,
Windows, and Linux. Drop-in compatible with Godot's `VideoStreamPlayer`;
no engine changes required. The extension owns playback timing and uses
AVFoundation, Media Foundation, or GStreamer for decoding. macOS and
Windows/D3D12 can present without CPU copies; Linux intentionally uploads
CPU-readable NV12/P010 planes, with optional hardware decoding.

## Architecture

The extension is built around a Godot-independent **core** that drives the
media backend in Decoder mode: `AVAssetReader` on macOS, a synchronous
`IMFSourceReader` on Windows, and independent video-only/audio-only
GStreamer readers on Linux. The core schedules decode on a bounded shared
worker pool; GStreamer also manages its own pipeline threads. On Windows,
COM is confined to a single dedicated MTA (multi-threaded apartment)
executor thread the backend owns for the life of the open media, since
Godot's own main thread runs in an STA that Media Foundation object
creation can't use directly.
The core owns the master clock, the frame queue, sync, and decode-ahead, so
nothing implicit in the OS framework owns timing.

On macOS, frames reach the GPU with no CPU copy: the hardware-decoded NV12
surface is imported via `RenderingDevice.texture_create_from_extension` as a
`Texture2DRD` and converted NV12→RGB in a single Metal compute pass into an
engine-owned texture returned from `VideoStreamPlayback._get_texture()`.
Godot never samples the decoder surface directly. On Windows the same
zero-copy shape is available when Godot runs its D3D12 rendering driver —
see [Windows present path](#windows-present-path) below for the one case
where it falls back to a CPU copy instead.

On Linux, GStreamer supplies retained CPU-readable NV12 (8-bit) or P010
(10-bit) frames. The extension uploads both planes into Godot-owned R/RG
textures, then uses the shared color/HDR conversion shader. This is a CPU
upload path, not zero-copy: optional hardware decoding may still require a
readback before upload. The tradeoff is CPU memory bandwidth, especially
with multiple high-resolution streams. No DMA-BUF or native Vulkan import
is required, and GStreamer doesn't own the playback clock.

Highlights:

- **Decoder mode, engine-owned clock** — audio-master sync with a monotonic
  fallback for silent clips; drop-late / hold-early present policy recovers
  from decode hiccups without permanent drift.
- **Zero-copy present pipeline** — no per-frame CPU copies, no BGRA→RGBA
  swizzle, no GPU round-trip, on macOS always and on Windows when the D3D12
  rendering driver is active.
- **Native media backends:** AVFoundation on macOS, Media Foundation on
  Windows, GStreamer on Linux. Linux hardware decoding depends on installed
  plugins and drivers; software decoding is also supported.
- **Adaptive scrubbing** — keyframe-only while dragging fast, exact frame on
  settle.
- **Shared decode-worker pool:** core decode jobs share workers, with
  per-stream frame order preserved. Media frameworks may use their own threads.

## Requirements

- **macOS** (Apple Silicon or Intel; the extension links AVFoundation,
  CoreMedia, CoreVideo, and Metal directly) **or Windows** (the extension
  links Media Foundation and D3D11/D3D12 directly), **or Linux** with system
  GStreamer libraries and codec plugins (see below).
- **Stock Godot 4.6+**, **Forward+ renderer** on Linux (Vulkan). macOS and
  Windows also support Mobile. Compatibility/OpenGL isn't supported on any
  platform. Linux CPU uploads still need a RenderingDevice and compute
  shaders; they aren't a Compatibility renderer fallback.
- **Zig 0.17.0** to build from source. Other Zig versions are not supported:
  the extension is built against
  [gdzig](https://github.com/gdzig/gdzig), a pre-1.0 binding generator
  pinned to a specific commit and Zig version.
- **A Godot executable resolvable at build time** (building from source
  only; irrelevant if you use a released binary) — on `PATH`, or named by
  `-Dgodot-path=/path/to/Godot` or `GODOT_PATH`. gdzig looks one up while
  configuring the build and fails without it, even for steps that never
  launch Godot.

For Linux runtime use on Ubuntu/Debian, install these GStreamer packages:

```bash
sudo apt-get update
sudo apt-get install --no-install-recommends \
  libgstreamer1.0-0 libgstreamer-plugins-base1.0-0 \
  gstreamer1.0-tools gstreamer1.0-plugins-base \
  gstreamer1.0-plugins-good gstreamer1.0-plugins-bad \
  gstreamer1.0-plugins-ugly gstreamer1.0-libav
```

These libraries and plugins **aren't bundled** with the addon. They provide
appsinks, MP4 demuxing, audio/video conversion, and H.264/HEVC/AAC software
decoders. Hardware decoder plugins and drivers are optional and vary by
system. Godot also needs its normal system libraries and a working Vulkan
driver. None of these dependencies require a custom Godot build. Package
names vary on other distributions.

## Releases

Each GitHub Release attaches a `native_video-<tag>.zip` containing an
`addons/native_video/` folder: drop it into a project's `addons/` directory
and Godot picks up `native_video.gdextension` automatically. It bundles:

| Platform | Arch | Files |
| --- | --- | --- |
| macOS | universal (arm64 + x86_64, via `lipo`) | `libnative_video.macos.debug.dylib`, `libnative_video.macos.release.dylib` |
| Windows | x86_64 | `native_video.windows.debug.x86_64.dll`, `native_video.windows.release.x86_64.dll` |
| Windows | x86 (32-bit) | `native_video.windows.debug.x86_32.dll`, `native_video.windows.release.x86_32.dll` |
| Windows | arm64 | `native_video.windows.debug.arm64.dll`, `native_video.windows.release.arm64.dll` |
| Linux | x86_64 | `libnative_video.linux.debug.x86_64.so`, `libnative_video.linux.release.x86_64.so` |

Linux release binaries are built natively on Ubuntu 22.04 with a baseline
x86_64 CPU target and link against system GStreamer. Install the runtime
packages above before loading the addon. Linux ARM64 isn't shipped or
tested; the demo manifest permits native ARM64 source builds, not an ARM
release binary.

Both a debug and a release binary ship for every listed platform/arch, matching
Godot's `template_debug`/`template_release` export split — the `.gdextension`
routes each automatically based on how the exported project was built.
Debug binaries are built with `-Doptimize=safe` (safety checks kept
in, unstripped); release binaries with `-Doptimize=fast` (stripped).

**iOS** builds and links (produces a valid iOS Mach-O `dylib`), but is not
shipped in releases: Godot's iOS export conventionally expects a static
library / `.xcframework` rather than a plain dylib, and only link-time (not
on-device runtime) has been verified. Follow-up work; not currently
tracked for a specific release.

## Windows present path

Windows can run Godot's Vulkan or D3D12 `RenderingDevice` driver, and this
build links two import paths that hand decoded frames to Godot. The choice
is made once, automatically, at startup, from the active RD driver name and
the running Godot version — never a build-time variant, never a
try-and-fail probe:

| Renderer driver | Import path | Zero-copy | Notes |
| --- | --- | --- | --- |
| `d3d12` | D3D12 shared-handle import | Yes | Shared NT handles + a shared D3D11/D3D12 fence hand the decoder's D3D11 texture to Godot's D3D12 device; a plane-split compute pass splits NV12/P010 into luma/chroma views. The selection code requires Godot 4.5+ for this path (`texture_create_from_extension` isn't implemented for the D3D12 driver before that); this extension's Godot 4.6+ floor already clears that bar. |
| `vulkan` (stock) or anything else | CPU-copy fallback | No | A zero-copy Vulkan path (DXGI shared handles into `VK_KHR_external_memory_win32`) is not built here — it was hard-disabled upstream even before this Zig port, because Godot's `texture_create_from_extension` mis-binds NV12 plane aspects on the Vulkan driver. Adds one GPU→CPU readback per frame before the texture reaches Godot. |

If the D3D12 path is selected but fails to come up — no D3D12 device to
bind, or the shared handles can't be opened across adapters — the extension
degrades to the CPU-copy path automatically, once, and stays there for the
rest of that playback session; it never retries the zero-copy path per
frame. Call `get_cpu_copy_count()` on a playback instance to see how many
frames took the CPU-copy path this session (always 0 on macOS, since Metal
import is always zero-copy there).

**Recommendation:** run Godot with the D3D12 rendering driver for zero-copy
present. Stock Vulkan still gets full hardware decode, just with a per-frame
GPU→CPU readback added before present.

## Known limitations

- **Headless mode (`--headless`)**: presentation is disabled because there
  is no RenderingDevice. Decode, audio mixing, the master clock, and
  playback state machines keep running normally, and end-of-stream is
  reached. No texture output is available.
- **Compatibility/OpenGL renderer**: not supported on any platform. CPU
  upload paths still need RenderingDevice textures and compute shaders.
- **Linux HEVC Main10/PQ/HLG**: supported when suitable GStreamer decoder
  plugins are installed. P010 preserves 10-bit samples through upload and
  color conversion, but this doesn't certify OS/compositor HDR signaling
  or actual HDR display output.
- **Vulkan zero-copy on Windows**: not available. A DXGI-shared-handle path
  into Vulkan was hard-disabled upstream (a Godot `texture_create_from_extension`
  bug mis-binds NV12 plane aspects on the Vulkan driver) and isn't built into
  this extension, so Vulkan on Windows always takes the CPU-copy fallback
  described above.
- **HEVC on Windows** depends on a decoder MFT being registered on the
  machine (typically the "HEVC Video Extensions" package) — not present on
  every Windows installation.
- **Three spurious errors on Godot 4.6**: gdzig generates its bindings from
  Godot 4.7's API description, so at load it probes for three 4.7-only
  interface functions (`variant_get_type_by_name`, `classdb_construct_object3`,
  `classdb_register_extension_class6`). A 4.6 engine logs
  `Attempt to get non-existent interface function` for each. gdzig never
  calls them and falls back to the older entry points; playback is
  unaffected. Nothing the extension binds changed hash between 4.6 and 4.7,
  and CI runs the integration smoke against both.
- **Single precision only (prebuilt binaries)**: the released libraries are
  built for the standard single-precision Godot. They will not load into a
  double-precision (`precision=double`) Godot build — the two disagree on the
  in-memory layout of core types. Double-precision users build from source
  with `-Dprecision=double` (see [Building from source](#building-from-source)).

## Diagnostics

Every log line the extension emits — from the main thread or a decode
worker, on any backend — is mirrored to Godot's own reporting surface as
well as stderr: errors and warnings show up in the editor's Output panel
(`push_error` / `push_warning`), not just a console window, and info/debug
lines print there too. A failed `load()` (bad path, backend open failure,
unsupported content) is reported the same way, with the resolved OS path and
the underlying error name, instead of failing silently.

`get_cpu_copy_count()` on a live `VideoStreamPlayback` reports how many
frames in this session have gone through a CPU-copy path: the Windows
fallback or Linux plane upload. It stays zero on macOS. On Linux this
counts uploaded frames, not individual memory copies.

## Scope

- **Codecs:** H.264, HEVC (Main and Main10).
- **Containers:** MP4, MOV — the loader registers `.mp4`, `.mov`, and
  `.m4v`.
- **Pixel formats:** NV12 (8-bit) and 10-bit biplanar: x420 on macOS,
  P010 on Windows/Linux, negotiated to match the source's bit depth. The
  conversion path normalises 10-bit payloads in 16-bit GPU words.
- **Colorimetry:** BT.709, BT.601, and BT.2020 YCbCr matrices; BT.709 /
  BT.601 / BT.2020 / DCI-P3 primaries; BT.709, PQ (ST 2084 / HDR10), and HLG
  transfer functions; video and full range. Unspecified fields default to
  BT.709, video range.
- **HDR:** PQ/HLG clips tone-map to watchable SDR by default, or output
  scene-linear HDR (RGBA16F, 1.0 = 203-nit Reference White per BT.2408) when
  the stream's `output_mode` is set to HDR.
- **Audio:** AAC, decoded to interleaved float32 PCM. Mono, stereo, and 5.1
  sources are channel-mixed to the clip's canonical output format.
- **Multi-track audio:** supported — enumerate tracks with
  `NativeVideoStream.get_audio_tracks()` and select one via
  `VideoStreamPlayer.audio_track`, either before `play()` or mid-playback.

Beyond this scope, the extension will attempt to play anything the media
backend can decode, as long as it arrives in one of the registered
container extensions above. Such content may well work, but only the matrix
above is tested and contractually supported.

**Out of scope:** VP9/AV1. **Known limitation:** mixed-sample-rate clips —
the first audio track's sample rate wins, and a mid-stream switch to a
track with a differing rate is refused.

## Building from source

1. Install Zig 0.17.0, then make a Godot executable resolvable via
   `GODOT_PATH`, `-Dgodot-path=`, or `PATH`.
   For example, with gdvm: `export GODOT_PATH="$(gdvm show 4.7.2)"`.
   Or use the path to your installed Godot executable. Every `zig build`
   invocation needs Godot, including `zig build test`. Resolution order is
   `-Dgodot-path`, then `GODOT_PATH`, then `godot` on `PATH`; bindings come
   from gdzig's vendored API description, not the resolved executable.

   On Linux, install the runtime packages above plus the development
   dependencies used by CI:

   ```bash
   sudo apt-get install pkg-config libgstreamer1.0-dev \
     libgstreamer-plugins-base1.0-dev
   pkg-config --modversion gstreamer-1.0 gstreamer-app-1.0 \
     gstreamer-video-1.0 gstreamer-audio-1.0 gstreamer-pbutils-1.0
   ```

   The build requires pkg-config to resolve these headers and system
   libraries, even for backend tests. Use native Linux builds against the
   target system's GStreamer development packages.

2. Build the extension:

   ```bash
   zig build
   ```

   This compiles `libnative_video.dylib` (macOS), `native_video.dll`
   (Windows), or `libnative_video.so` (Linux) and installs it to
   `project/lib/`, where `project/native_video.gdextension` expects it.
   `build.zig` drives the build. Linux also needs the pkg-config/GStreamer
   packages above; Windows links Media Foundation and D3D11/D3D12 as system
   libraries.

   Builds default to a stripped `fast` binary (~380 KB on macOS
   arm64; Windows binary size hasn't been separately measured). Pass
   `-Doptimize=debug` for a debug build, or `-Doptimize=small` to
   trade some speed for an even smaller library.

   To target a double-precision Godot build, add `-Dprecision=double`
   (default is `float`). The precision must match the Godot the extension
   loads into; a mismatch is a memory-layout error, not a graceful failure.

3. Run the core, platform backend, and pure presentation-policy tests
   (they exercise no Godot code, though the build still resolves a Godot
   executable):

   ```bash
   zig build test
   ```

   On Linux, focused backend and plane-packing tests and a standalone decode
   smoke are also available:

   ```bash
   zig build test-gst
   zig build test-linux-packing
   zig build decode-smoke -- project/synthetic.mp4
   ```

4. Run the demo project (builds the extension, launches Godot, and opens
   the interactive playback UI against `project/synthetic.mp4` or a clip
   passed after `--`):

   ```bash
   zig build run
   ```

   For an unattended pass/fail check instead — loads a clip, plays it, polls
   for a presented video texture, does a pixel-content sanity check, and
   quits with exit 0 (PASS) / 1 (FAIL) — use the dedicated smoke step:

   ```bash
   zig build smoke
   ```

   (equivalent to `zig build run -- --smoke`, with Dummy audio selected
   automatically on Linux). Presentation needs a display and a working
   RenderingDevice, not `--headless`; Linux CI uses software Vulkan under
   Xvfb. Both steps launch the Godot resolved from `-Dgodot-path`,
   `GODOT_PATH`, or `PATH`, in that order.

### CI and local validation

Required checks in `.github/workflows/test.yml` cover macOS, Linux, and
Windows with stock Godot 4.7.2 (primary) and 4.6.3 (supported floor). The
shared `.github/workflows/build.yml`, also called by
`.github/workflows/release.yml`, builds every shipped platform/architecture
in safe/debug and fast/release modes once per run. All six runtime
combinations consume its fast/release artifacts and run a short rendered
playback smoke using the checked-in `project/synthetic.mp4`.
Unit/native-backend tests and standalone decode smoke still build their
own harnesses and run only on the primary version.
Windows also generates the fixtures its native tests require.

Deeper Linux codec, multitrack, seek, lifecycle, input-rejection, and
rendered transport regressions remain local opt-in checks, not CI jobs.
With the build dependencies above plus FFmpeg and Python 3 installed:

```bash
bash tools/gen_linux_validation_media.sh /tmp/native-video-fixtures
bash tools/run_linux_validation.sh --fixtures /tmp/native-video-fixtures \
  --results /tmp/native-video-backend-results --backend-only
```

For rendered checks with software Vulkan and Xvfb (Ubuntu example):

```bash
GNV_LVP_ICD=/usr/share/vulkan/icd.d/lvp_icd.x86_64.json \
  bash tools/run_linux_validation.sh --fixtures /tmp/native-video-fixtures \
  --results /tmp/native-video-rendered-results --rendered-only --renderer software-xvfb
```

Install Xvfb and Mesa Vulkan drivers for that command, and adjust the ICD
path for your system. Logs go to the chosen results directory. Software
rendering doesn't certify hardware decoding or HDR display output.
Physical AMD RX Vega validation also covered transport and reentrant preview
teardown.

## Project layout

- `src/core/` — engine-independent core (clock, frame queue, scrubber,
  present selector, decode scheduler, backend interface, color math). Pure
  Zig, no Godot, AVFoundation, Media Foundation, or GStreamer imports;
  its tests are part of `zig build test`.
- `src/avf/` — the AVFoundation backend (macOS): `avf_shim.m`/`avf_shim.h`
  (a C-ABI Objective-C shim) plus the Zig glue that drives it through the
  core `Backend` interface. `decode_smoke.zig` is a standalone CLI harness
  that pumps the backend without Godot, for isolating decode-side bugs.
- `src/mf/` — the Media Foundation backend (Windows): a synchronous
  `IMFSourceReader` driven through the core `Backend` interface, the
  dedicated MTA `ComExecutor` thread, and the hand-written D3D11/D3D12/DXGI
  bindings under `src/mf/win/`. `decode_smoke.zig` mirrors the AVFoundation
  harness for isolating decode-side bugs without Godot.
- `src/gst/`: the Linux GStreamer backend, with a C shim for discovery and
  independent video/audio readers, retained frame payloads, backend tests,
  and a standalone `decode_smoke.zig` harness.
- `src/godot/` — [gdzig](https://github.com/gdzig/gdzig) glue:
  `NativeVideoStream` / `NativeVideoStreamPlayback` registration, the
  present pipeline that runs the NV12→RGB compute pass, and the surface
  importers it selects between — Metal on macOS; on Windows, the pure
  `importer_selector` function plus the D3D12 zero-copy and CPU-copy
  importers it chooses between; Linux uses the CPU-upload importer and pure
  NV12/P010 plane-packing helpers.
- `project/` — the example/verification Godot project and dev harness.
  `main.gd`/`main.tscn` are a single entry point with two modes selected by
  CLI flag: interactive playback UI (`zig build run`, the default) or
  unattended pass/fail verification (`zig build smoke`, `--smoke`).
- `addon/` — the shipped `.gdextension` template packaged into release
  zips (see [Releases](#releases) above). Not used by `zig build`; the dev
  harness in `project/` has its own `native_video.gdextension` pointing at
  local build output.

For the historical record of how this implementation was chosen —
benchmarks and rationale — see [EVALUATION.md](EVALUATION.md).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for release-note and release-workflow
instructions.

## License

MIT — see [LICENSE](LICENSE).
