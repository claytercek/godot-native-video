# Platform Media Streams for Godot

A high-performance GDExtension for native, hardware-accelerated video playback in
Godot. Instead of bundling a software decoder, it uses each OS's media framework
purely as a **hardware decoder** and presents decoded frames to the GPU
**zero-copy**. It is drop-in compatible with Godot's stock `VideoStreamPlayer`.

## Architecture

The extension is built around a Godot-independent **Engine Core** that drives the
OS media framework in **Decoder mode** (`AVAssetReader` on macOS,
`IMFSourceReader` on Windows) — never in player mode. The Engine Core owns the
master clock, the frame queue, sync, and decode-ahead, so nothing implicit in the
OS owns timing.

Frames reach the GPU with no CPU copy: the hardware-decoded NV12 surface is
imported via `RenderingDevice.texture_create_from_extension` as a `Texture2DRD`
and converted NV12→RGB in a single GPU compute pass into an engine-owned texture
returned from `VideoStreamPlayback._get_texture()`. Godot never samples the
decoder surface directly.

Highlights:

- **Decoder mode, engine-owned clock** — audio-master sync with a monotonic
  fallback for silent clips; drop-late / hold-early present policy recovers from
  decode hiccups without permanent drift.
- **Zero-copy present pipeline** — no per-frame CPU copies, no BGRA→RGBA swizzle,
  no GPU round-trip.
- **Hardware decode via the OS** — low CPU and battery, no bundled FFmpeg.
- **Adaptive scrubbing** — keyframe-only while dragging fast, exact frame on
  settle.
- **Shared decode-worker pool** — many videos in one scene without a thread per
  video; per-stream frame order preserved.

## Requirements

- **Godot 4.4+**.
- **Forward+ or Mobile renderer** (the RenderingDevice renderers). The
  **Compatibility / OpenGL** renderer is **not supported** — there is no CPU
  present path.

## Scope

v1 targets the **8-bit SDR core matrix**:

- **Codecs:** H.264, HEVC.
- **Containers:** MP4, MOV.
- **Pixel format:** NV12, BT.709.
- **Audio:** AAC, stereo.

At runtime the extension will attempt to play whatever the OS can decode, but only
the matrix above is tested and contractually supported. **Out of scope for v1:**
10-bit / HDR (P010, PQ/HLG), VP9/AV1, and multi-track audio — these are tracked as
follow-ups.

## Platform Support

| Platform | Framework                | Status                                       |
| -------- | ------------------------ | -------------------------------------------- |
| macOS    | AVFoundation             | Supported                                    |
| Windows  | Windows Media Foundation | Supported (§below)                           |
| Linux    | GStreamer vs VA-API      | Deferred (decision pending)                  |

### Windows status (QA'd on-device, 2026-07)

The Media Foundation backend is **verified on real hardware**: the full
`mf_tests` suite passes (synthetic clip + real-clip matrix, H.264 & HEVC
hardware decode, NV12 D3D11 textures, monotonic PTS, float32 PCM), and
playback (loader → backend → clock → frame queue → present) runs end-to-end
in the demo.

Windows ships three present-side **Import Paths**, chosen once at
runtime by `RenderingServer::get_current_rendering_driver_name()` +
`Engine::get_version_info()` — never as separate build variants, and never a
try-and-fail probe:

1. **D3D12 Path** (zero-copy) — the `d3d12` RenderingDevice driver on Godot
   4.5+. Verified end-to-end on-device, pixel-correct.
2. **Vulkan Zero-Copy Path** — the original `DxgiSurfaceImporter`. Fully built
   and verified end-to-end against a patched Godot (PR #114940), but **hard-
   disabled** on stock Godot: the engine does not enable
   `VK_KHR_external_memory_win32` on its Vulkan device, and even with that PR,
   `texture_create_from_extension`'s hardcoded `COLOR` aspect mis-binds the
   NV12 plane views until godot-proposals#13969 lands upstream.
3. **CPU-Copy Path** — the fallback for the common case: stock Vulkan driver,
   any Godot version. Same hardware decode, plus a GPU→CPU readback before
   present (this path's sole, explicit exception to the zero-copy contract).
   Verified end-to-end on-device on a stock Godot install.

## Installation

TODO

## Development & Contributing

### Building from Source

1. **Initialize submodules**:

   ```bash
   git submodule update --init --recursive
   ```

2. **Build for your platform**:

   ```bash
   scons target=[template_debug|template_release] platform=[macos|windows]
   ```

   On Windows the DXGI→Vulkan importer needs the Vulkan headers and loader
   import library. Install the [LunarG Vulkan SDK](https://vulkan.lunarg.com/)
   (its installer sets `VULKAN_SDK`, which SConstruct picks up), or point
   `VULKAN_SDK` at any directory containing `Include/vulkan/*.h` and
   `Lib/vulkan-1.lib`.

3. **Run the demo**:

   ```bash
   godot --path demo/
   ```

### Tests

The Engine Core and the platform backends are tested headlessly — no Godot, no
GPU required.

- **Engine Core unit tests** (Godot-independent): `scons target=core_tests && ./bin/core_tests`
- **macOS backend integration + real-clip matrix**: `scons target=avf_tests && ./bin/avf_tests`
- **Windows backend integration + real-clip matrix**: `scons target=mf_tests platform=windows` then `bin\mf_tests.exe`

Test media is generated by **ffmpeg, which is a test-only tool and is never a
runtime dependency**:

- `tools/gen_test_media.sh` — synthetic clip with a burned-in per-frame index
  marker and a per-frame sync tone, for deterministic frame/sync assertions.
- `tools/gen_clip_matrix.sh` — the small real-clip format matrix (H.264/HEVC,
  24/30/60 fps, MP4/MOV, AAC stereo) consumed by the backend coverage tests.
  Nothing is committed: this script is the single source of truth, regenerating
  the clips **and** the manifests (`matrix.list`, parsed by the tests, plus a
  `matrix.json` mirror) into `tests/fixtures/matrix/`. CI and local runs invoke
  it before the backend tests.

### Repository Structure

- `src/core/` — Engine Core (Clock, FrameQueue, Scrubber, Presenter, Scheduler,
  Backend interface, MediaSource). No Godot / RenderingDevice dependency.
- `src/backends/avf/` — AVFoundation decoder backend (macOS).
- `src/backends/mf/` — Media Foundation decoder backend (Windows).
- `src/common/` — Godot binding / adapter layer (`VideoStreamPlayback`, present
  pipeline, surface importers).
- `tests/` — headless core unit tests + per-platform backend integration/coverage
  tests.
- `demo/` — test Godot project.
- `godot-cpp/` — Godot C++ bindings (submodule).
