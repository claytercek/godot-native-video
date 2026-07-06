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
// SCOPE (linear-playback slice): linear playback + audio-master A/V sync. Audio is
// drained into Godot via mix_audio(); the master clock is derived from the
// audio samples Godot actually consumes (latency-compensated AudioMasterClock),
// with a MonotonicClock delta fallback for silent clips. The present step runs
// the Godot-free drop-late / hold-early present-selector.
//
// SCOPE (decode-pool slice): decode is moved OFF the main thread onto a bounded
// shared core::DecodeScheduler pool. Each playback registers its core::Backend
// with the process-wide scheduler and receives a StreamHandle; a pool worker
// fills that stream's decode-ahead queue while the main/render thread still does
// the present + GPU pass via next_frame() + PresentPipeline. Many
// VideoStreamPlayers share one bounded set of worker threads (no thread-per-
// video). The present/clock/audio logic from the linear-playback slice is
// unchanged.
//
// SCOPE (scrubbing slice): adaptive scrubbing. Godot only signals seeking via
// repeated _seek(time): a fast burst is a drag, a debounced gap (or playback
// resume) is a settle. The Godot-free core::Scrubber turns that bare seek stream
// into a per-seek decision — a fast drag presents the nearest KEYFRAME for
// instant feedback (cheap request_seek + present the first decoded frame), while
// a slow/settled/resumed seek resolves the EXACT target (request_seek to the
// preceding keyframe, then decode FORWARD to the target PTS). The scheduler's
// request_seek() is the seam; the threading model is unchanged.
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
#include "../core/scrubber.h"
#include "present_pipeline.h"

namespace godot {

class PlatformVideoStreamPlayback : public VideoStreamPlayback {
	GDCLASS(PlatformVideoStreamPlayback, VideoStreamPlayback)

public:
	// -------------------------------------------------------------------
	// Output mode — selects between SDR (RGBA8, stock) and HDR (RGBA16F,
	// scene-linear 1.0 = 203-nit Reference White). Default SDR.
	// Toggling at runtime forces a pipeline rebuild.
	// -------------------------------------------------------------------
	enum OutputMode {
		OUTPUT_MODE_SDR = 0,
		OUTPUT_MODE_HDR = 1,
	};

	PlatformVideoStreamPlayback();
	~PlatformVideoStreamPlayback() override;

	// Open the media file. Returns true on success. Called by PlatformVideoStream.
	bool load(const String &path);

	// --- Output mode ---
	void set_output_mode(int mode);
	int get_output_mode() const;

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

	// --- Colorimetry ---
	// Returns a Dictionary with the parsed/negotiated colorimetry.
	// Callable after load() succeeds (i.e. after open but before play).
	// Untagged clips return BT.709 video-range defaults.
	// The returned dictionary always includes an "output_mode" key (0 or 1)
	// reporting the pipeline's effective output mode.
	godot::Dictionary get_color_info() const;

protected:
	static void _bind_methods();

private:
	// Pull decoded audio chunks from the backend into the audio ring until it is
	// topped up or EOS. Cheap; called every _update before mixing.
	void fill_audio();
	// Drain decoded PCM from the ring into Godot's AudioServer via mix_audio(),
	// and advance the audio-master clock by the frames Godot actually consumed.
	// Returns true iff the clock was advanced this call — _update() uses this to
	// avoid double-advancing on the tick real audio runs out.
	bool drive_audio();
	// True once no real audio samples will ever advance the clock again: silent
	// clips, and a shorter audio track once it has fully drained. From then on
	// _update() advances the master clock by the render delta instead.
	bool audio_exhausted() const;
	// The current master clock (audio-master when audio present, else monotonic).
	core::Clock *master() const;

	// Apply a scrubber decision to the stream. Keyframe -> a tolerant keyframe
	// reseek (the scheduler flushes + reseeks; the next decoded frame is presented
	// for instant feedback). Exact -> reseek to the preceding keyframe then decode
	// FORWARD to the target PTS so the precise frame lands on screen. Re-anchors the
	// master clock + position to the target either way.
	void apply_scrub_resolve(const core::ScrubResolve &resolve);

	// Monotonic wall-clock milliseconds for the Scrubber's velocity/debounce timing
	// (independent of media time, which jumps around during a scrub).
	static double now_ms();

	// Handle to this playback's stream registered with the shared decode pool.
	// The pool owns the Backend and decodes video ahead into the stream's queue;
	// this object pulls frames via DecodeScheduler::next_frame() on the main
	// thread. Audio is pumped on the main thread via with_backend() (serialized
	// against the worker pool so the Backend has a single toucher at a time).
	core::StreamHandle stream_;

	// Adaptive-scrubbing state machine. Fed every _seek() with the target and a
	// wall-clock timestamp; decides keyframe-on-drag vs exact-on-settle. poll()'d
	// each _update() to fire the deferred exact resolve once a drag settles.
	core::Scrubber scrubber_;

	// Master-clock implementations. Exactly one is "the master" per clip:
	//  - audio_clock_ when the clip has an audio track (samples-consumed ÷ rate,
	//    latency-compensated), driven by drive_audio() from real consumption.
	//  - mono_clock_  for silent clips.
	// Either way, once audio_exhausted() the master advances by render delta.
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

	// Cached colorimetry from the backend. Default-constructed (all Unspecified,
	// 8-bit) until load() overwrites it with the backend's negotiated values.
	core::Colorimetry color_;
};

} // namespace godot
