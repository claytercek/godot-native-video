#pragma once

#include <cstdint>
#include <functional>
#include <optional>
#include <string>

namespace core {

// -----------------------------------------------------------------------
// Colorimetry enums — platform-neutral tags for YCbCr matrix, color
// primaries, transfer function, and video/full range. These are populated
// per-frame from the decoder surface's color attachments (e.g. CVImageBuffer
// attachments on Apple, MF_MT_VIDEO_* attributes on Windows). Unspecified
// defaults to BT.709 video range (the v1 assumption, matching today's
// hard-coded shader constants).
// -----------------------------------------------------------------------
enum class ColorMatrix : uint8_t {
	Unspecified = 0,
	BT709 = 1,  // ITU-R BT.709 (HD)
	BT601 = 2,  // ITU-R BT.601 (SD)
	BT2020 = 3, // ITU-R BT.2020 (UHD)
};

enum class ColorPrimaries : uint8_t {
	Unspecified = 0,
	BT709 = 1,
	BT601_625 = 2, // EBU 3213-E (PAL)
	BT601_525 = 3, // SMPTE C (NTSC)
	BT2020 = 4,
	DCI_P3 = 5,
};

enum class TransferFunction : uint8_t {
	Unspecified = 0,
	BT709 = 1, // Also used for sRGB-ish SDR
	PQ = 2,    // SMPTE ST 2084 (HDR10)
	HLG = 3,   // ITU-R BT.2100 HLG
};

enum class ColorRange : uint8_t {
	Unspecified = 0,
	Video = 1, // Limited range: Y [16,235], CbCr [16,240]
	Full = 2,  // Full range: Y/CbCr [0,255]
};

// -----------------------------------------------------------------------
// Pixel format tag — surface types produced by a hardware decoder.
// Only 8-bit SDR formats are in scope for v1.
// -----------------------------------------------------------------------
enum class PixelFormat : uint8_t {
	Unknown = 0,
	NV12, // YUV 4:2:0 semi-planar (luma plane + interleaved UV plane)
	BGRA8, // Packed BGRA, 8 bpc — fallback software path
};

// -----------------------------------------------------------------------
// VideoFrame — one decoded video surface returned from the Backend.
//
// In Decoder mode the Backend hands us a native surface handle whose
// lifetime is managed by the hardware decode pool. The Engine Core
// imports it via RenderingDevice::texture_create_from_extension; it
// never copies the pixel data to CPU RAM.
// -----------------------------------------------------------------------
struct VideoFrame {
	// Presentation timestamp in seconds.
	double pts_seconds = 0.0;

	// Native surface handle (e.g. CVPixelBufferRef on Apple, ID3D11Texture2D*
	// on Windows). The Backend retains ownership; the caller must call
	// release() when done.
	void *native_handle = nullptr;

	// The decoder texture-array slice holding THIS frame. DXVA decoders pack
	// decoded frames as slices of one shared texture array; 0 on platforms
	// whose handles are per-frame (e.g. macOS CVPixelBuffer).
	uint32_t plane_slice = 0;

	int width = 0;
	int height = 0;
	PixelFormat pixel_format = PixelFormat::Unknown;

	// --- Colorimetry metadata ---
	// Populated from the decoder surface's color attachments by the Backend.
	// Unspecified fields are treated as BT.709, video range (the v1 default
	// that matches today's hard-coded shader constants).
	ColorMatrix ycbcr_matrix = ColorMatrix::Unspecified;
	ColorPrimaries primaries = ColorPrimaries::Unspecified;
	TransferFunction transfer = TransferFunction::Unspecified;
	ColorRange range = ColorRange::Unspecified;
	int bit_depth = 8;

	// Call when the consumer is done with this frame so the decode pool can
	// recycle the surface.
	std::function<void()> release;
};

// -----------------------------------------------------------------------
// AudioChunk — one decoded audio packet returned from the Backend.
// -----------------------------------------------------------------------
struct AudioChunk {
	// Presentation timestamp of the first sample in seconds.
	double pts_seconds = 0.0;

	// Interleaved PCM float32 samples, channel-major ordering.
	const float *samples = nullptr;
	int frame_count = 0; // per-channel sample count
	int channel_count = 0;
	int sample_rate = 0;
};

// -----------------------------------------------------------------------
// Backend — pure-virtual decoder-mode interface.
//
// A Backend wraps one OS media framework (AVFoundation, MF, GStreamer) as
// a pure hardware decoder. It is opened on a source, configured to a
// track, and then polled for the next decoded frame / audio chunk.
//
// Design rules:
//  - No Godot / RenderingDevice types — Godot-independent.
//  - No player-mode callbacks (AVPlayer, IMFMediaEngine) — we own the
//    clock; the Backend is a dumb decode pump.
//  - Thread safety: implementations decide; callers are responsible for
//    serialising per-stream access.
// -----------------------------------------------------------------------
class Backend {
public:
	virtual ~Backend() = default;

	// --- Lifecycle ---

	// Open the media at `url_or_path`. Returns true on success.
	// A concrete Backend may accept a file:// URL or a bare path.
	virtual bool open(const std::string &url_or_path) = 0;

	// Release all resources. Safe to call multiple times.
	virtual void close() = 0;

	// --- Media info (valid after a successful open) ---

	virtual double duration_seconds() const = 0;
	virtual int video_width() const = 0;
	virtual int video_height() const = 0;
	virtual int audio_channel_count() const = 0;
	virtual int audio_sample_rate() const = 0;

	// --- Colorimetry (populated after open) ---
	// These return the negotiated colorimetry for the stream as a whole.
	// The per-frame VideoFrame fields carry the per-sample metadata.
	virtual ColorMatrix ycbcr_matrix() const { return ColorMatrix::BT709; }
	virtual ColorPrimaries color_primaries() const { return ColorPrimaries::BT709; }
	virtual TransferFunction transfer_function() const { return TransferFunction::BT709; }
	virtual ColorRange color_range() const { return ColorRange::Video; }
	virtual int bit_depth() const { return 8; }

	// --- Decode pump ---

	// Seek to the nearest keyframe at or before `pts_seconds`.
	// After seek, call next_video_frame() / next_audio_chunk() to pump.
	virtual bool seek(double pts_seconds) = 0;

	// Decode and return the next video frame.
	// Returns std::nullopt at end-of-stream or on decode error.
	virtual std::optional<VideoFrame> next_video_frame() = 0;

	// Decode and return the next audio chunk.
	// Returns std::nullopt at end-of-stream or on decode error.
	virtual std::optional<AudioChunk> next_audio_chunk() = 0;
};

} // namespace core
