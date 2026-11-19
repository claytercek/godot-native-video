# Synthetic video fixtures

From a clone with Git LFS installed, run `git lfs pull` to fetch the clips,
then `zig build test-media --summary all --test-timeout 30s` from the repository root.
The tests decode the clips with the platform's native decoder.
You don't need FFmpeg to run them. Rendered smoke uses a separate clip,
[`project/synthetic.mp4`](../../project/synthetic.mp4).

## Decode

The H.264 and HEVC clips in `decode/` use a 320×240 moving test pattern at
30 fps, starting at timestamp zero. Each frame has a row of nine 32×32 cells
starting at pixel (16, 16): black and white references, then the zero-based
frame number in seven bits, least significant bit first. The rendered seek
test reads those pixels to tell which frame actually appeared on screen.

- `h264-aac.mp4` and `h264-silent.mp4`: the same 90 frames of H.264 video with B-frames. The first has a 440 Hz tone in stereo AAC at 48 kHz; the second has no audio track.
- `h264-multitrack.mp4` and `h264-multitrack.mkv`: the same video with two stereo AAC tracks at 48 kHz. Track 0 is a 440 Hz sine (`eng`, `low-tone`); track 1 is an 880 Hz sine (`deu`, `high-tone`) and the container default. Start both sines at phase zero: the GStreamer seek test compares the waveform at specific sample positions. The Matroska metadata check also runs on GStreamer.
- `hevc-main10-pq.mp4`: 30 frames of silent 10-bit HEVC Main 10 with BT.2020 primaries and PQ transfer. Tested on macOS and Linux; the Windows HEVC decoder is optional.
- `vp9-10.webm`: two silent 10-bit VP9 Profile 2 frames at 2 fps, for GStreamer.
- `invalid.mp4`: a plain-text file containing `deliberately invalid MP4`, for input rejection.

## Stress

The `stress/` clips use H.264 video and 48 kHz AAC. Unless noted, each has
72 frames at 24 fps and a 320×240 picture.

- `bframes.mp4`: B-frame reordering with 300 Hz and 500 Hz tones in stereo.
- `surround51.mp4`: 90 frames at 30 fps without B-frames. The 5.1 channel tones are 220, 440, 880, 55, 1760, and 3520 Hz in FL, FR, FC, LFE, BL, BR order.
- `timecode.mov` and `combined_stress.mov`: B-frames with stereo and 5.1 AAC respectively. Mux the tracks in **video, timecode (`tmcd`), audio** order: the test checks that the decoder finds audio at stream index 2.
- `marker_bframes.mp4`: 240 frames at 24 fps with B-frames and stereo audio. Ten full-height, 32-pixel-wide black or white bars encode each frame number, most significant bit first.
- `nonmod16_854x480.mp4`: an 854×480 cyan picture with an eight-pixel magenta stripe at the right edge and a mono audio track. A decoder may pad its texture to 864 pixels wide; only the first 854 should be visible.

## Running individual checks

From the repository root, with the platform build dependencies installed:

- GStreamer AAC seek and input rejection: `zig build test-gst-extended --summary all --test-timeout 30s`
- Decode a single clip: `zig build decode-smoke -- tests/fixtures/stress/bframes.mp4`

## Replacing fixtures

Preserve the decoded frames, audio, and stream metadata described above.
The encoded bytes can differ. For example, to make a candidate for the
display-aperture test, run this in an empty directory with FFmpeg and libx264:

```bash
ffmpeg -f lavfi -i 'color=c=cyan:size=854x480:rate=24:duration=3' \
  -f lavfi -i 'sine=frequency=300:sample_rate=48000:duration=3' \
  -vf 'drawbox=x=iw-8:y=0:w=8:h=ih:color=magenta:t=fill' \
  -c:v libx264 -pix_fmt yuv420p -crf 15 -c:a aac -ac 1 nonmod16_854x480.mp4
```

Check that the stripe reaches the right edge of the decoded picture. Copy
the candidate into `tests/fixtures/stress/` and run `zig build test-media`
from the repository root. For changes to AAC track selection or seeking,
also run `test-gst-extended` on Linux.
