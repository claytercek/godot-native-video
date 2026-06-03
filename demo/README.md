# Native Media Streams — smoke test (HITL visual gate)

This demo is the human-in-the-loop (HITL) artifact for the zero-copy present
pipeline (issue `zr2`, ADR-0003). Programmatic checks assert zero CPU copies,
no use-after-free, and a clean build, but **on-device visual correctness needs
human eyes** — that is what this scene is for.

## What it exercises

A stock Godot `VideoStreamPlayer` plays a native clip through this extension:

1. `PlatformMediaResourceFormatLoader` loads `.mp4/.mov/.m4v` into a
   `PlatformVideoStream`.
2. `PlatformVideoStreamPlayback` drives the AVFoundation Backend (Decoder mode),
   queues NV12 `CVPixelBuffer`s, and on each `_update()` picks the frame for the
   clock and presents it.
3. The present pipeline imports the NV12 planes **zero-copy** via
   `RenderingDevice::texture_create_from_extension` (Metal `MTLTexture`s aliasing
   the decoder's `IOSurface`), runs **one** NV12→RGB compute pass (BT.709, 8-bit)
   into an engine-owned N-buffered RGBA `Texture2DRD`, and returns that texture
   from `_get_texture()`. Godot never samples the decoder surface directly.
4. A retire-ring holds each decoder surface for N rendered frames so the GPU is
   finished before the surface is recycled.

## Requirements

- macOS, Godot **4.4+**, **Forward+** or **Mobile** renderer (Metal /
  RenderingDevice). The Compatibility/OpenGL renderer is unsupported (ADR-0002):
  there is no CPU present path.
- The built `.dylib` is installed into `demo/bin/macos/` by SCons.

## Run it

1. Build the extension:

   ```sh
   scons target=template_debug platform=macos
   ```

   This installs `libplatform-media-streams.macos.template_debug.dylib` into
   `demo/bin/macos/`.

2. Provide a clip. Generate the synthetic marker fixture (ffmpeg required) and
   copy it next to the project so `res://synthetic.mp4` resolves:

   ```sh
   ./tools/gen_test_media.sh --output demo/synthetic.mp4
   ```

   Or point `clip_path` (exported on the smoke scene root) at any `.mp4/.mov`
   the OS can decode.

3. Open `demo/` in Godot 4.4+ and run the main scene (`scenes/smoke.tscn`), or:

   ```sh
   godot --path demo
   ```

## What to confirm (the HITL gate)

- The video appears in the `VideoStreamPlayer` and **advances** (the synthetic
  fixture shows a per-frame index counter and a moving block).
- Colours look correct (no green/purple swizzle, no washed-out levels) — this
  validates the BT.709 video-range NV12→RGB math.
- Playback is smooth with no obvious tearing or stutter.

The on-screen `Status` label reports playback position and whether
`get_video_texture()` is non-null each frame.

> AFK note: this scene was authored and the pipeline was verified to build and
> pass all headless tests, but the visual confirmation above could not be
> performed automatically (no display / reliable headless GPU here). It remains
> the one outstanding acceptance criterion for `zr2`.
