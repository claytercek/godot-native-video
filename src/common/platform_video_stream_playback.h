#pragma once

// -----------------------------------------------------------------------
// platform_video_stream_playback.h — the Binding's VideoStreamPlayback.
//
// Adapts the Godot-independent Engine Core to Godot's VideoStreamPlayback so a
// stock VideoStreamPlayer can play a native clip. It drives an avf::AvfBackend
// (Decoder mode), buffers decoded NV12 frames in a core::FrameQueue, advances a
// core::Clock from the frame delta, and on _update() picks the frame for "now"
// and presents it through the zero-copy PresentPipeline. _get_texture() returns
// the engine-owned RGBA Texture2DRD.
//
// SCOPE (this slice, zr2): simple monotonic-clock linear playback. Audio output
// and audio-master A/V sync, plus sophisticated drop-late / hold-early policy,
// are the next slice (dte); the present-path boundary is kept clean so dte can
// slot in without touching the GPU pipeline.
// -----------------------------------------------------------------------

#include <godot_cpp/classes/video_stream_playback.hpp>
#include <godot_cpp/classes/texture2d.hpp>

#include <memory>
#include <optional>

#include "../core/backend.h"
#include "../core/clock.h"
#include "../core/frame_queue.h"
#include "present_pipeline.h"

namespace avf {
class AvfBackend;
}

namespace godot {

class PlatformVideoStreamPlayback : public VideoStreamPlayback {
	GDCLASS(PlatformVideoStreamPlayback, VideoStreamPlayback)

public:
	PlatformVideoStreamPlayback();
	~PlatformVideoStreamPlayback() override;

	// Open the media file. Returns true on success. Called by PlatformVideoStream.
	bool load(const String &path);

	// --- VideoStreamPlayback overrides ---
	void _play() override;
	void _stop() override;
	bool _is_playing() const override;
	void _set_paused(bool paused) override;
	bool _is_paused() const override;
	double _get_length() const override;
	double _get_playback_position() const override;
	void _seek(double time) override;
	void _set_audio_track(int idx) override;
	Ref<Texture2D> _get_texture() const override;
	void _update(double delta) override;
	int _get_channels() const override;
	int _get_mix_rate() const override;

protected:
	static void _bind_methods();

private:
	// Decode-ahead capacity. Power of two for FrameQueue. A handful of frames is
	// enough for linear playback; dte tunes pool depth alongside A/V sync.
	static constexpr size_t kQueueCapacity = 8;

	// Pull frames from the backend into the queue until full or EOS.
	void fill_queue();
	// Release any frames still owned by the queue (e.g. on seek/stop).
	void drain_queue();

	std::unique_ptr<avf::AvfBackend> backend_;
	std::unique_ptr<core::FrameQueue<core::VideoFrame, kQueueCapacity>> queue_;
	std::unique_ptr<core::MonotonicClock> clock_;
	platform_media::PresentPipeline present_;

	bool loaded_ = false;
	bool playing_ = false;
	bool paused_ = false;
	bool eos_ = false;
	double length_ = 0.0;
	double position_ = 0.0; // PTS of the most recently presented frame

	int width_ = 0;
	int height_ = 0;
};

} // namespace godot
