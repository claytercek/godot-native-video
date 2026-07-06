#pragma once

// -----------------------------------------------------------------------
// avf_backend.h — macOS AVFoundation Backend in Decoder mode.
//
// Implements core::Backend by driving an AVAssetReader as a pure hardware
// decoder. It pulls hardware-decoded NV12 CVPixelBuffers (with
// PTS) for video and PCM float32 (with PTS) for audio. It produces native
// surface handles only; it does NOT import to GPU and references NO Godot /
// RenderingDevice symbols.
//
// The implementation lives in avf_backend.mm (Objective-C++). This header is
// plain C++20 so the rest of the Engine Core can include it without ObjC.
// The AVFoundation reader objects are hidden behind a PImpl to keep ObjC out
// of the header.
// -----------------------------------------------------------------------

#include "backend.h" // core::Backend, VideoFrame, AudioChunk, PixelFormat

#include <memory>
#include <optional>
#include <string>

namespace avf {

class AvfBackend final : public core::Backend {
public:
	AvfBackend();
	~AvfBackend() override;

	// Move-only — owns an AVAssetReader pipeline.
	AvfBackend(const AvfBackend &) = delete;
	AvfBackend &operator=(const AvfBackend &) = delete;
	AvfBackend(AvfBackend &&) noexcept;
	AvfBackend &operator=(AvfBackend &&) noexcept;

	// --- core::Backend ---
	bool open(const std::string &url_or_path) override;
	void close() override;

	double duration_seconds() const override;
	int video_width() const override;
	int video_height() const override;
	int audio_channel_count() const override;
	int audio_sample_rate() const override;

	bool seek(double pts_seconds) override;
	std::optional<core::VideoFrame> next_video_frame() override;
	std::optional<core::AudioChunk> next_audio_chunk() override;

	// True if the most recent decode pump hit an error (as opposed to a clean
	// end-of-stream). Lets the integration test assert "no decode errors".
	bool had_error() const;

private:
	class Impl;
	std::unique_ptr<Impl> impl_;
};

} // namespace avf
