# Native Video — demo

A minimal Godot project that plays a video clip through this extension's
zero-copy present pipeline. Use it to confirm the extension works end-to-end on
your machine: that frames appear, advance, and look correct.

## What it exercises

A stock Godot `VideoStreamPlayer` plays a clip through this extension:

1. `NativeVideoResourceFormatLoader` loads `.mp4/.mov/.m4v` into a
   `NativeVideoStream`.
2. `NativeVideoStreamPlayback` drives the platform decoder backend
   (AVFoundation on macOS, Media Foundation on Windows), queues decoded NV12
   frames, and on each `_update()` picks the frame for the clock and presents it.
3. The present pipeline imports the NV12 planes **zero-copy** via
   `RenderingDevice::texture_create_from_extension`, runs **one** NV12→RGB
   compute pass (BT.709, 8-bit) into an engine-owned N-buffered RGBA
   `Texture2DRD`, and returns that texture from `_get_texture()`. Godot never
   samples the decoder surface directly.
4. A retire-ring holds each decoder surface for N rendered frames so the GPU is
   finished before the surface is recycled.

## Requirements

- Godot **4.4+** with a **Forward+** or **Mobile** renderer (i.e. backed by
  RenderingDevice). The Compatibility/OpenGL renderer is unsupported — the
  zero-copy present path has no CPU fallback.
- A platform with a supported backend: **macOS** (AVFoundation) or **Windows**
  (Media Foundation).
- The built library installed into `demo/bin/<platform>/` by SCons.

## Run it

1. Build the extension for your platform:

   ```sh
   scons target=template_debug platform=macos    # or platform=windows
   ```

   This installs the library into `demo/bin/<platform>/`.

2. Provide a clip. Either point `clip_path` (exported on the demo scene root) at
   any `.mp4/.mov/.m4v` the OS can decode, or generate the synthetic marker
   fixture (ffmpeg required) and copy it next to the project so
   `res://synthetic.mp4` resolves:

   ```sh
   ./tools/gen_test_media.sh --output demo/synthetic.mp4
   ```

3. Open `demo/` in Godot 4.4+ and run the main scene (`scenes/smoke.tscn`), or:

   ```sh
   godot --path demo
   ```

## What to confirm

- The video appears in the `VideoStreamPlayer` and **advances** (the synthetic
  fixture shows a per-frame index counter and a moving block).
- Colours look correct (no green/purple swizzle, no washed-out levels) — this
  validates the BT.709 video-range NV12→RGB math.
- Playback is smooth with no obvious tearing or stutter.

The on-screen `Status` label reports playback position and whether
`get_video_texture()` is non-null each frame.
