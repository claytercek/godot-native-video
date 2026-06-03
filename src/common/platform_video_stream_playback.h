#pragma once

// -----------------------------------------------------------------------
// platform_video_stream_playback.h — the Binding's VideoStreamPlayback.
//
// Adapts the Godot-independent Engine Core to Godot's VideoStreamPlayback so a
// stock VideoStreamPlayer can play a native clip. It drives a per-platform
// core::Backend (Decoder mode, chosen by make_backend() — AVFoundation on
// macOS, Media Foundation on Windows), buffers decoded NV12 frames in a
// core::FrameQueue, advances a
// core::Clock from the frame delta, and on _update() picks the frame for "now"
// and presents it through the zero-copy PresentPipeline. _get_texture() returns
// the engine-owned RGBA Texture2DRD.
//
// SCOPE (dte — this slice): linear playback + audio-master A/V sync. Audio is
// drained into Godot via mix_audio(); the master clock is derived from the
// audio samples Godot actually consumes (latency-compensated AudioMasterClock),
// with a MonotonicClock delta fallback for silent clips. The present step runs
// the Godot-free drop-late / hold-early present-selector.
//
// SCOPE (g1c — this slice): decode is moved OFF the main thread onto a bounded
// shared core::DecodeScheduler pool. Each playback registers its core::Backend
// with the process-wide scheduler and receives a StreamHandle; a pool worker
// fills that stream's decode-ahead queue while the main/render thread still does
// the present + GPU pass via next_frame() + PresentPipeline. Many
// VideoStreamPlayers share one bounded set of worker threads (no thread-per-
// video). The present/clock/audio logic from dte is unchanged.
//
// BOUNDARIES (out of scope here): adaptive keyframe/exact scrubbing is o3h. The
// scheduler exposes request_seek() as the clean seam the scrubbing slice will
// use to request a keyframe decode without changing the threading model.
// -----------------------------------------------------------------------

#include <godot_cpp/classes/texture2d.hpp>
#include <godot_cpp/classes/video_stream_playback.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>

#include <memory>
#include <optional>

#include "../core/audio_ring.h"
#include "../core/backend.h"
#include "../core/clock.h"
#include "../core/decode_scheduler.h"
#include "../core/present_selector.h"
#include "present_pipeline.h"

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
	// Pull decoded audio chunks from the backend into the audio ring until it is
	// topped up or EOS. Cheap; called every _update before mixing.
	void fill_audio();
	// Drain decoded PCM from the ring into Godot's AudioServer via mix_audio(),
	// and advance the audio-master clock by the frames Godot actually consumed.
	void drive_audio();
	// The current master clock (audio-master when audio present, else monotonic).
	core::Clock *master() const;

	// Handle to this playback's stream registered with the shared decode pool.
	// The pool owns the Backend and decodes video ahead into the stream's queue;
	// this object pulls frames via DecodeScheduler::next_frame() on the main
	// thread. Audio is pumped on the main thread via with_backend() (serialized
	// against the worker pool so the Backend has a single toucher at a time).
	core::StreamHandle stream_;

	// Master-clock implementations. Exactly one is "the master" per clip:
	//  - audio_clock_ when the clip has an audio track (samples-consumed ÷ rate,
	//    latency-compensated). Driven by drive_audio() from real consumption.
	//  - mono_clock_  for silent clips (advanced by _update's render delta).
	std::unique_ptr<core::AudioMasterClock> audio_clock_;
	std::unique_ptr<core::MonotonicClock> mono_clock_;

	// PCM staging between the backend's audio chunks and Godot's mix_audio().
	std::unique_ptr<core::AudioRing> audio_ring_;
	godot::PackedFloat32Array mix_buffer_; // reused mix scratch (no per-frame alloc)

	platform_media::PresentPipeline present_;

	bool loaded_ = false;
	bool playing_ = false;
	bool paused_ = false;
	// Video end-of-stream is tracked by the shared scheduler (at_end()), so this
	// object only tracks audio EOS for the end-of-playback condition.
	bool audio_eos_ = false; // audio end-of-stream
	bool has_audio_ = false; // clip carries an audio track -> audio is master
	double length_ = 0.0;
	double position_ = 0.0; // PTS of the most recently presented frame

	int channels_ = 0;
	int sample_rate_ = 0;

	int width_ = 0;
	int height_ = 0;
};

} // namespace godot
