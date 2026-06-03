#pragma once

// -----------------------------------------------------------------------
// mf_backend.h — Windows Media Foundation Backend in Decoder mode.
//
// The Windows analog of avf::AvfBackend. Implements core::Backend by driving an
// IMFSourceReader as a pure hardware decoder (ADR-0001), configured with an
// IMFDXGIDeviceManager so video frames decode directly into D3D11 NV12 textures
// (DXGI_FORMAT_NV12) and audio into interleaved float32 PCM. It produces native
// surface handles only (native_handle == ID3D11Texture2D*); it does NOT import
// to the GPU and references NO Godot / RenderingDevice symbols.
//
// The implementation lives in mf_backend.cpp and uses Media Foundation / D3D11
// directly. This header is plain C++20 (no Windows headers) so the rest of the
// Engine Core can include it without dragging in <mfapi.h> etc.; the MF/D3D
// objects hide behind a PImpl exactly as the AVFoundation reader hides behind
// AvfBackend::Impl.
//
// STATUS: implemented but UNVERIFIED — written and self-reviewed on a macOS
// host with no Windows toolchain. Compiles/links/runs only on Windows; see the
// commit body for the exact verification steps.
// -----------------------------------------------------------------------

#include "backend.h" // core::Backend, VideoFrame, AudioChunk, PixelFormat

#include <memory>
#include <optional>
#include <string>

namespace mf {

class MfBackend final : public core::Backend {
public:
	MfBackend();
	~MfBackend() override;

	// Move-only — owns an IMFSourceReader + D3D11 device pipeline.
	MfBackend(const MfBackend &) = delete;
	MfBackend &operator=(const MfBackend &) = delete;
	MfBackend(MfBackend &&) noexcept;
	MfBackend &operator=(MfBackend &&) noexcept;

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

	// True if the most recent decode pump hit an error (vs. a clean
	// end-of-stream). Lets the integration test assert "no decode errors",
	// mirroring AvfBackend::had_error().
	bool had_error() const;

private:
	class Impl;
	std::unique_ptr<Impl> impl_;
};

} // namespace mf
