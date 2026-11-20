# Native video for Godot

Play video in stock Godot 4.6+ with `VideoStreamPlayer` and the decoders
installed on macOS, Windows, or Linux. Use H.264 with AAC in MP4 for the widest desktop coverage.
VP9 and AV1 playback depends on the [container and native backend](#scope).
The addon doesn't bundle or install codecs.

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
decoder surface as a `Texture2DRD`. A Metal compute pass
converts its YCbCr planes to RGB in an engine-owned texture returned by
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
  AVFoundation, VideoToolbox, CoreMedia, CoreVideo, and Metal on macOS;
  Media Foundation and D3D11/D3D12 on Windows; system GStreamer libraries
  on Linux.
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
- Prebuilt libraries require standard single-precision Godot. They won't
  load into a double-precision (`precision=double`) build because core type
  layouts differ. Build from source with `-Dprecision=double`; see
  [Building from source](#building-from-source).

## Diagnostics

Godot's resource loader recognizes files by extension. A successful
`load()` creates a stream; it doesn't open the decoder until Godot
instantiates playback. If playback fails, check the backend messages in
Godot's Output panel or stderr. To test a file outside Godot, run
`zig build decode-smoke -- /path/to/clip.mp4` from a source checkout.

Call `get_cpu_copy_count()` on a live `VideoStreamPlayback` to count frames
that used Windows' CPU-copy fallback or Linux's plane upload this session.
It stays zero on macOS. Linux counts uploaded frames, not individual memory
copies.

## Scope

The loader recognizes `.mp4`, `.mov`, and `.m4v` on all desktop platforms.
H.264 and HEVC Main/Main10 in MP4/MOV are the baseline. For VP9 and AV1,
start with MP4 and test on the machines you ship to. A system decoder must
be able to handle the clip's profile and deliver frames the addon can use;
hardware acceleration is optional.

| Backend | VP9 and AV1 |
| --- | --- |
| macOS (AVFoundation) | VP9 and AV1 MP4 passed the 8- and 10-bit decode tests on an M4 Pro. The addon opts in to Apple's VP9 decoder when available. The loader doesn't accept WebM on macOS. |
| Windows (Media Foundation) | VP9 and AV1 MP4 are conditional on a decoder that can deliver a D3D11 surface. The [VP9](https://apps.microsoft.com/detail/9n4d0msmp0pt) or [AV1](https://apps.microsoft.com/detail/9mvzqvxjbq9v) Video Extension may be needed. Run the [MP4 fixture tests](tests/fixtures/README.md) on the target machine. The loader doesn't accept WebM on Windows. |
| Linux (GStreamer) | Use MP4 or `.webm`. The 10-bit VP9 WebM fixture has passed on Ubuntu 22.04. GStreamer needs installed plugins for the container and each track, including Opus for WebM clips with Opus audio. |

To use a WebM clip on macOS or Windows, remux its video into MP4 without
re-encoding it. For a clip with sound, this example converts the audio to AAC:

```sh
ffmpeg -i input.webm -map 0:v:0 -map '0:a:0?' -c:v copy -c:a aac output.mp4
```

Remuxing changes the container. The target machine still needs to decode
that VP9 or AV1 stream. FFmpeg is an asset preparation tool in this
example; players don't need it.

### Output formats

- Pixel formats: NV12 (8-bit) and 10-bit biplanar x420 (macOS) or P010
  (Windows/Linux). Windows prefers the source bit depth when known and
  logs a warning if a 10-bit source must use NV12.
- Colorimetry: BT.709, BT.601, and BT.2020 YCbCr matrices; BT.709, BT.601,
  BT.2020, and DCI-P3 primaries; BT.709, PQ (ST 2084 / HDR10), and HLG
  transfer functions; video and full range. Unspecified fields default to
  BT.709, video range.
- HDR: PQ/HLG clips tone-map to SDR by default. Set the stream's
  `output_mode` to HDR for scene-linear RGBA16F output, where 1.0 equals
  203-nit Reference White per BT.2408.
- Audio: the native backend decodes the selected track to interleaved
  float32 PCM. The addon mixes mono, stereo, and 5.1 sources to the
  clip's canonical output format.
- Multi-track audio: enumerate with `NativeVideoStream.get_audio_tracks()`
  and select with `VideoStreamPlayer.audio_track` before `play()` or during
  playback.

The [fixtures](tests/fixtures/README.md) cover VP9 Profile 0 (8-bit),
VP9 Profile 2 (10-bit), and AV1 Main (8- and 10-bit), all 4:2:0.
These cases do not cover 12-bit, 4:4:4, alpha, or hardware acceleration.
Other codecs in recognized containers may also play.

For mixed-sample-rate clips, the first audio track sets the sample rate;
the addon refuses a switch to a track with a different rate.

## Building from source

1. Install Zig 0.17.0 and make Godot available through `-Dgodot-path=`,
   `GODOT_PATH`, or `PATH`, in that resolution order. With mise, run
   `mise exec zig@0.17.0 godot@4.7.2-stable -- zig build`. Every
   `zig build` step needs Godot, including tests;
   bindings come from gdzig's vendored API description, not this executable.

   For the demo and media tests, install [Git LFS](https://git-lfs.com/) and
   run `git lfs install` before cloning. If you already cloned the repository,
   run `git lfs pull` after setup to download the videos.

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

   This builds and installs the extension and writes Godot's log to
   `zig-out/smoke.log`, with raw process output in `smoke.log.stdout.log`
   and `smoke.log.stderr.log` alongside it. Smoke requires a successful exit
   within 75 seconds, an exact `SMOKE: PASS` line, a Forward+ device banner,
   and no errors in any of the logs.

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

Every OS and Godot version runs rendered smoke against the downloaded
release extension. On the primary Godot version, each OS runs its native
tests and decodes the media fixtures. Linux also runs rendered transport.
Select `linux_extended` in a manual **Test** run for the GStreamer
regressions and more rendered cases. Linux CI uses software Vulkan under
Xvfb; it does not verify hardware decoding or HDR display output.

Run the [checked-in media fixtures](tests/fixtures/README.md) against your
native decoder on macOS, Windows, or Linux:

```bash
zig build test-media --summary all --test-timeout 30s
```

On Linux, `test-media` requires VP9 and AV1 in MP4 and WebM. On macOS
and Windows, add `-Dtest-vp9=true` or `-Dtest-av1=true` to require that
codec's 8- and 10-bit MP4 cases. Enable both on a machine with both
decoders. A decode failure on an enabled case fails the test.

Run `zig build smoke-codecs` on a machine with a display to check Godot
resource loading and rendered pixels. It plays VP9 MP4, seeks while
paused, and reads the frame number from the texture. On Linux it also
checks AV1 WebM. For additional GStreamer checks, run
`zig build test-gst-extended --summary all --test-timeout 30s`.

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
  backend tests, `decode_smoke.zig`, and the `linux_decode_regression.zig`
  seek and input-rejection checks.
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
- `tests/`: native media tests and checked-in synthetic fixtures.
- `tools/`: Zig launcher and log checker for rendered validation.

See [EVALUATION.md](EVALUATION.md) for implementation benchmarks and rationale.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for release notes and workflow instructions.

## License

MIT; see [LICENSE](LICENSE).
