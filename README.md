# Native Video for Godot

Hardware-accelerated MP4/MOV video playback (H.264/HEVC) for Godot 4 on
macOS and Windows, using the OS's own media framework as a **hardware
decoder only** — never in player mode — and presenting decoded frames to the
GPU with zero (or, on one Windows fallback path, minimal) CPU copies.
Drop-in compatible with Godot's `VideoStreamPlayer`.

## Architecture

The extension is built around a Godot-independent **core** that drives the
OS media framework in Decoder mode: `AVAssetReader` on macOS, a synchronous
`IMFSourceReader` on Windows. Either way, decode itself runs on a bounded
shared worker pool, not one thread per video; on Windows, COM is confined to
a single dedicated MTA (multi-threaded apartment) executor thread the
backend owns for the life of the open media, since Godot's own main thread
runs in an STA that Media Foundation object creation can't use directly.
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

Highlights:

- **Decoder mode, engine-owned clock** — audio-master sync with a monotonic
  fallback for silent clips; drop-late / hold-early present policy recovers
  from decode hiccups without permanent drift.
- **Zero-copy present pipeline** — no per-frame CPU copies, no BGRA→RGBA
  swizzle, no GPU round-trip, on macOS always and on Windows when the D3D12
  rendering driver is active.
- **Hardware decode via the OS** — AVFoundation on macOS, Media Foundation
  on Windows; low CPU and battery, no bundled FFmpeg.
- **Adaptive scrubbing** — keyframe-only while dragging fast, exact frame on
  settle.
- **Shared decode-worker pool** — many videos in one scene without a thread
  per video; per-stream frame order preserved.

## Requirements

- **macOS** (Apple Silicon or Intel; the extension links AVFoundation,
  CoreMedia, CoreVideo, and Metal directly) **or Windows** (the extension
  links Media Foundation and D3D11/D3D12 directly).
- **Godot 4.6+**, **Forward+ or Mobile renderer** (the RenderingDevice
  renderers). The Compatibility/OpenGL renderer is not supported on either
  platform — there is no CPU present path for it.
- **Zig 0.16.0** to build from source (see [mise.toml](mise.toml)). Other
  Zig versions are not supported: the extension is built against
  [gdzig](https://github.com/gdzig/gdzig), a pre-1.0 binding generator
  pinned to a specific commit and Zig version.

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
- **Compatibility/OpenGL renderer**: not supported on either platform — no
  CPU present path.
- **Vulkan zero-copy on Windows**: not available. A DXGI-shared-handle path
  into Vulkan was hard-disabled upstream (a Godot `texture_create_from_extension`
  bug mis-binds NV12 plane aspects on the Vulkan driver) and isn't built into
  this extension, so Vulkan on Windows always takes the CPU-copy fallback
  described above.
- **HEVC on Windows** depends on a decoder MFT being registered on the
  machine (typically the "HEVC Video Extensions" package) — not present on
  every Windows installation.

## Diagnostics

Every log line the extension emits — from the main thread or a decode
worker, on either backend — is mirrored to Godot's own reporting surface as
well as stderr: errors and warnings show up in the editor's Output panel
(`push_error` / `push_warning`), not just a console window, and info/debug
lines print there too. A failed `load()` (bad path, backend open failure,
unsupported content) is reported the same way, with the resolved OS path and
the underlying error name, instead of failing silently.

`get_cpu_copy_count()` on a live `VideoStreamPlayback` reports how many
frames in this session have gone through the Windows CPU-copy fallback —
see [Windows present path](#windows-present-path) above.

## Scope

- **Codecs:** H.264, HEVC (Main and Main10).
- **Containers:** MP4, MOV — the loader registers `.mp4`, `.mov`, and
  `.m4v`.
- **Pixel formats:** NV12 (8-bit) and 10-bit biplanar — x420 on macOS,
  P010 on Windows — negotiated to match the source's bit depth. The
  conversion shader normalises 10-bit payloads in 16-bit GPU words on both
  platforms.
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

Beyond this scope, the extension will attempt to play anything the OS media
framework can decode, as long as it arrives in one of the registered
container extensions above. Such content may well work, but only the matrix
above is tested and contractually supported.

**Out of scope:** VP9/AV1. **Known limitation:** mixed-sample-rate clips —
the first audio track's sample rate wins, and a mid-stream switch to a
track with a differing rate is refused.

## Building from source

1. Install Zig 0.16.0 (`mise install` picks it up from
   [mise.toml](mise.toml), or install it directly — the system Zig on most
   machines will be a newer, incompatible version).
2. Build the extension:

   ```bash
   zig build
   ```

   This compiles `libnative_video.dylib` (macOS) or `native_video.dll`
   (Windows) and installs it to `project/lib/`, where
   `project/native_video.gdextension` expects it. `build.zig` is the entire
   build — one command, no other tooling required and no external SDK to
   install; Media Foundation and D3D11/D3D12 are linked as system libraries.

   Builds default to a stripped `ReleaseFast` binary (~380 KB on macOS
   arm64; Windows binary size hasn't been separately measured). Pass
   `-Doptimize=Debug` for a debug build, or `-Doptimize=ReleaseSmall` to
   trade some speed for an even smaller library.

3. Run the core unit tests (no Godot needed):

   ```bash
   zig build test
   ```

4. Run the end-to-end smoke test (builds the extension, launches Godot,
   plays `project/synthetic.mp4` through the real `ResourceLoader` /
   `VideoStreamPlayer` path, and self-quits):

   ```bash
   zig build run
   ```

   This looks for Godot at the path hardcoded as `default_godot` in
   `build.zig`; override it with `-Dgodot-path=/path/to/Godot`.

## Project layout

- `src/core/` — engine-independent core (clock, frame queue, scrubber,
  present selector, decode scheduler, backend interface, color math). Pure
  Zig, no Godot, AVFoundation, or Media Foundation imports; this is what
  `zig build test` exercises.
- `src/avf/` — the AVFoundation backend (macOS): `avf_shim.m`/`avf_shim.h`
  (a C-ABI Objective-C shim) plus the Zig glue that drives it through the
  core `Backend` interface. `decode_smoke.zig` is a standalone CLI harness
  that pumps the backend without Godot, for isolating decode-side bugs.
- `src/mf/` — the Media Foundation backend (Windows): a synchronous
  `IMFSourceReader` driven through the core `Backend` interface, the
  dedicated MTA `ComExecutor` thread, and the hand-written D3D11/D3D12/DXGI
  bindings under `src/mf/win/`. `decode_smoke.zig` mirrors the AVFoundation
  harness for isolating decode-side bugs without Godot.
- `src/godot/` — [gdzig](https://github.com/gdzig/gdzig) glue:
  `NativeVideoStream` / `NativeVideoStreamPlayback` registration, the
  present pipeline that runs the NV12→RGB compute pass, and the surface
  importers it selects between — Metal on macOS; on Windows, the pure
  `importer_selector` function plus the D3D12 zero-copy and CPU-copy
  importers it chooses between.
- `project/` — the example/verification Godot project. Its
  `smoke.gd` script is what `zig build run` executes.

For the historical record of how this implementation was chosen —
benchmarks and rationale — see [EVALUATION.md](EVALUATION.md).

## License

MIT — see [LICENSE](LICENSE).
