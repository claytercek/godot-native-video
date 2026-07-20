# Native Video for Godot

Hardware-accelerated MP4/MOV video playback (H.264/HEVC) for Godot 4 on
macOS, using AVFoundation as a **hardware decoder only** — never in player
mode — and presenting decoded frames to the GPU with zero CPU copies.
Drop-in compatible with Godot's `VideoStreamPlayer`.

## Architecture

The extension is built around a Godot-independent **core** that drives
`AVAssetReader` in Decoder mode. The core owns the master clock, the frame
queue, sync, and decode-ahead, so nothing implicit in AVFoundation owns
timing.

Frames reach the GPU with no CPU copy: the hardware-decoded NV12 surface is
imported via `RenderingDevice.texture_create_from_extension` as a
`Texture2DRD` and converted NV12→RGB in a single Metal compute pass into an
engine-owned texture returned from `VideoStreamPlayback._get_texture()`.
Godot never samples the decoder surface directly.

Highlights:

- **Decoder mode, engine-owned clock** — audio-master sync with a monotonic
  fallback for silent clips; drop-late / hold-early present policy recovers
  from decode hiccups without permanent drift.
- **Zero-copy present pipeline** — no per-frame CPU copies, no BGRA→RGBA
  swizzle, no GPU round-trip.
- **Hardware decode via AVFoundation** — low CPU and battery, no bundled
  FFmpeg.
- **Adaptive scrubbing** — keyframe-only while dragging fast, exact frame on
  settle.
- **Shared decode-worker pool** — many videos in one scene without a thread
  per video; per-stream frame order preserved.

## Requirements

- **macOS** (Apple Silicon or Intel; the extension links AVFoundation,
  CoreMedia, CoreVideo, and Metal directly). Windows is not supported.
- **Godot 4.6+**, **Forward+ or Mobile renderer** (the RenderingDevice
  renderers). The Compatibility/OpenGL renderer is not supported — there is
  no CPU present path.
- **Zig 0.16.0** to build from source (see [mise.toml](mise.toml)). Other
  Zig versions are not supported: the extension is built against
  [gdzig](https://github.com/gdzig/gdzig), a pre-1.0 binding generator
  pinned to a specific commit and Zig version.

## Known limitations

- **Headless mode (`--headless`)**: presentation is disabled because there
  is no RenderingDevice. Decode, audio mixing, the master clock, and
  playback state machines keep running normally, and end-of-stream is
  reached. No texture output is available.
- **Compatibility/OpenGL renderer**: not supported — no CPU present path.

## Scope

- **Codecs:** H.264, HEVC (Main and Main10).
- **Containers:** MP4, MOV — the loader registers `.mp4`, `.mov`, and
  `.m4v`.
- **Pixel formats:** NV12 (8-bit) and x420 (10-bit biplanar), negotiated to
  match the source's bit depth. The conversion shader normalises 10-bit
  payloads in 16-bit GPU words.
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

Beyond this scope, the extension will attempt to play anything AVFoundation
can decode, as long as it arrives in one of the registered container
extensions above. Such content may well work, but only the matrix above is
tested and contractually supported.

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

   This compiles `libnative_video.dylib` and installs it to
   `project/lib/`, where `project/native_video.gdextension` expects it.
   `build.zig` is the entire build — one command, no other tooling
   required.

   Builds default to a stripped `ReleaseFast` binary (~380 KB). Pass
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
  Zig, no Godot or AVFoundation imports; this is what `zig build test`
  exercises.
- `src/avf/` — the AVFoundation backend: `avf_shim.m`/`avf_shim.h` (a
  C-ABI Objective-C shim) plus the Zig glue that drives it through the core
  `Backend` interface. `decode_smoke.zig` is a standalone CLI harness that
  pumps the backend without Godot, for isolating decode-side bugs.
- `src/godot/` — [gdzig](https://github.com/gdzig/gdzig) glue:
  `NativeVideoStream` / `NativeVideoStreamPlayback` registration, the
  Metal surface importer, and the present pipeline that runs the NV12→RGB
  compute pass.
- `project/` — the example/verification Godot project. Its
  `smoke.gd` script is what `zig build run` executes.

For the historical record of how this implementation was chosen —
benchmarks and rationale — see [EVALUATION.md](EVALUATION.md).

## License

MIT — see [LICENSE](LICENSE).
