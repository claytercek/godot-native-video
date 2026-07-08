#pragma once

// -----------------------------------------------------------------------
// native_video_stream_playback.h — the Binding's VideoStreamPlayback.
//
// Adapts the Godot-independent Engine Core to Godot's VideoStreamPlayback so a
// stock VideoStreamPlayer can play a native clip. Holds no playback logic of
// its own — every state machine (Canonical Mix Format, Track Switch
// reconciliation, audio drive / mix back-pressure accounting, scrub
// resolution, present selection) lives in the Godot-free core::PlaybackController
// (see playback_controller.h). This class's job is exactly the translation
// layer: Godot type conversion, a MixSink implementation wrapping mix_audio(),
// and present-pipeline plumbing (the zero-copy GPU present + _get_texture()).
//
// _update() calls controller_.tick(), which returns the frame to present (if
// any) BY VALUE; this class performs the actual GPU present via PresentPipeline
// and owns the frame's release() from there via the retire ring.
// -----------------------------------------------------------------------

#include <godot_cpp/classes/texture2d.hpp>
#include <godot_cpp/classes/video_stream_playback.hpp>

#include <memory>

#include "../core/playback_controller.h"
#include "present_pipeline.h"

namespace godot {

class NativeVideoStreamPlayback : public VideoStreamPlayback {
	GDCLASS(NativeVideoStreamPlayback, VideoStreamPlayback)

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

	NativeVideoStreamPlayback();
	~NativeVideoStreamPlayback() override;

	// Open the media file. Returns true on success. Called by NativeVideoStream.
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
	// Monotonic wall-clock milliseconds for the Scrubber's velocity/debounce timing
	// (independent of media time, which jumps around during a scrub).
	static double now_ms();

	// Prints any warnings the controller has queued since the last drain
	// (out-of-range track index, a mixed-sample-rate clip, a failed
	// mid-stream reselect) via print_error(). The controller has no logging
	// dependency of its own; this is the Godot-side half of that seam.
	void flush_warnings();

	// The Godot-free per-stream orchestrator. Owns exactly the state
	// machines the Binding used to hold inline: Canonical Mix Format, Track
	// Switch reconciliation, audio drive, scrub resolution, present
	// selection.
	core::PlaybackController controller_;

	// The one Godot-touching seam the controller calls through to mix
	// audio. Wraps VideoStreamPlayback::mix_audio(); owns its own scratch
	// buffer so repeated ticks don't reallocate.
	std::unique_ptr<core::MixSink> mix_sink_;

	native_video::PresentPipeline present_;
};

} // namespace godot
