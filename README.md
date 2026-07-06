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

v1 targets the **8-bit SDR core matrix**, tested identically on macOS and
Windows:

- **Codecs:** H.264, HEVC (with the per-platform caveat below).
- **Containers:** MP4, MOV — the loader registers `.mp4`, `.mov`, and `.m4v`.
- **Pixel format:** NV12, BT.709.
- **Audio:** AAC, stereo.

Decoding is delegated to the OS, so what actually plays depends on the
platform — and on Windows, on the machine:

| Codec | macOS (AVFoundation) | Windows (Media Foundation)                     |
| ----- | -------------------- | ---------------------------------------------- |
| H.264 | Built in             | Built in                                       |
| HEVC  | Built in             | Requires an HEVC decoder MFT — typically the "HEVC Video Extensions" Microsoft Store package. Not present on server SKUs and some desktops. |

Beyond the matrix, the extension will attempt to play anything the OS can
decode, as long as it arrives in one of the registered container extensions
above. Such content may well work, but only the matrix is tested and
contractually supported. **Out of scope for v1:** 10-bit / HDR (P010,
PQ/HLG), VP9/AV1, and multi-track audio — these are tracked as follow-ups.

## Platform Support

| Platform | Framework                | Status                                       |
| -------- | ------------------------ | -------------------------------------------- |
| macOS    | AVFoundation             | Supported                                    |
| Windows  | Windows Media Foundation | Supported ([details](#windows))              |
| Linux    | GStreamer vs VA-API      | Deferred (decision pending)                  |

### Windows

Hardware decode is identical on every Windows setup and **verified on real
hardware**: the full `mf_tests` suite passes (synthetic clip + real-clip
matrix, H.264 & HEVC hardware decode, NV12 D3D11 textures, monotonic PTS,
float32 PCM), and playback runs end-to-end in the demo.

What varies is the **present path** — how decoded frames reach Godot's
renderer. It is chosen once at runtime from
`RenderingServer::get_current_rendering_driver_name()` +
`Engine::get_version_info()` — never as separate build variants, and never a
try-and-fail probe:

| Your setup                          | Present path     | Zero-copy | Notes                                            |
| ----------------------------------- | ---------------- | --------- | ------------------------------------------------ |
| Godot 4.5+, `d3d12` driver          | D3D12 import     | Yes       | **Recommended.** Verified on-device, pixel-correct. |
| Any Godot, stock `vulkan` driver    | CPU-copy fallback | No        | Verified on-device. Adds one GPU→CPU readback per frame. |
| Godot patched with PR #114940, `vulkan` | DXGI zero-copy import | Yes  | Built and verified, but hard-disabled on stock Godot (see below). |

**Recommendation:** run Godot 4.5+ with the D3D12 rendering driver. On stock
Vulkan you still get full hardware decode, but with a per-frame GPU→CPU
readback before present — the sole, explicit exception to the zero-copy
contract, and the only drawback of that path.

The Vulkan zero-copy path stays hard-disabled on stock Godot because the
engine does not enable `VK_KHR_external_memory_win32` on its Vulkan device,
and even with PR #114940, `texture_create_from_extension`'s hardcoded `COLOR`
aspect mis-binds the NV12 plane views until godot-proposals#13969 lands
upstream.

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

   No SDK installs are required: the Vulkan headers the Windows build needs
   come from the `thirdparty/vulkan-headers` submodule, and the Vulkan loader
   is resolved from `vulkan-1.dll` at runtime rather than linked.

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
  24/30/60 fps, MP4/MOV/M4V, AAC stereo) consumed by the backend coverage
  tests.
  Nothing is committed: this script is the single source of truth, regenerating
  the clips **and** the manifests (`matrix.list`, parsed by the tests, plus a
  `matrix.json` mirror) into `tests/fixtures/matrix/`. Local runs invoke it
  before the backend tests; CI generates the media once in a dedicated job
  (cached across runs) and shares it with the backend jobs as an artifact.

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
- `thirdparty/vulkan-headers/` — Khronos Vulkan headers (submodule; used by the
  Windows build only).
