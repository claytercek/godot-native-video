// -----------------------------------------------------------------------
// platform_video_stream_playback.cpp — see header.
// -----------------------------------------------------------------------

#include "platform_video_stream_playback.h"

#include <godot_cpp/classes/project_settings.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include "../../backends/avf/avf_backend.h"

using namespace godot;

PlatformVideoStreamPlayback::PlatformVideoStreamPlayback() = default;

PlatformVideoStreamPlayback::~PlatformVideoStreamPlayback() {
	drain_queue();
	present_.shutdown();
	if (backend_) {
		backend_->close();
	}
}

void PlatformVideoStreamPlayback::_bind_methods() {
	// No script-facing API beyond the VideoStreamPlayback contract.
}

bool PlatformVideoStreamPlayback::load(const String &path) {
	backend_ = std::make_unique<avf::AvfBackend>();

	// Resolve a Godot res:// / user:// path to an absolute OS path the backend's
	// AVURLAsset can open. globalize_path leaves absolute OS paths untouched.
	String os_path = ProjectSettings::get_singleton()->globalize_path(path);
	const std::string utf8 = os_path.utf8().get_data();

	if (!backend_->open(utf8)) {
		backend_.reset();
		return false;
	}

	length_ = backend_->duration_seconds();
	width_ = backend_->video_width();
	height_ = backend_->video_height();

	queue_ = std::make_unique<core::FrameQueue<core::VideoFrame, kQueueCapacity>>();
	clock_ = std::make_unique<core::MonotonicClock>(0.0);
	loaded_ = true;
	position_ = 0.0;
	eos_ = false;
	return true;
}

void PlatformVideoStreamPlayback::fill_queue() {
	if (!backend_ || !queue_ || eos_) {
		return;
	}
	while (!queue_->full()) {
		std::optional<core::VideoFrame> f = backend_->next_video_frame();
		if (!f.has_value()) {
			eos_ = true;
			break;
		}
		if (!queue_->push(std::move(*f))) {
			// Race against capacity: push the frame back by releasing it. With a
			// single consumer this shouldn't happen, but stay leak-safe.
			if (f->release) {
				f->release();
			}
			break;
		}
	}
}

void PlatformVideoStreamPlayback::drain_queue() {
	if (!queue_) {
		return;
	}
	while (auto f = queue_->pop()) {
		if (f->release) {
			f->release();
		}
	}
}

void PlatformVideoStreamPlayback::_play() {
	if (!loaded_) {
		return;
	}
	playing_ = true;
	paused_ = false;
	if (clock_) {
		clock_->set_paused(false);
	}
}

void PlatformVideoStreamPlayback::_stop() {
	playing_ = false;
	paused_ = false;
	eos_ = false;
	position_ = 0.0;
	if (clock_) {
		clock_->set_time(0.0);
	}
	drain_queue();
	if (backend_) {
		backend_->seek(0.0);
	}
}

bool PlatformVideoStreamPlayback::_is_playing() const {
	return playing_;
}

void PlatformVideoStreamPlayback::_set_paused(bool paused) {
	paused_ = paused;
	if (clock_) {
		clock_->set_paused(paused);
	}
}

bool PlatformVideoStreamPlayback::_is_paused() const {
	return paused_;
}

double PlatformVideoStreamPlayback::_get_length() const {
	return length_;
}

double PlatformVideoStreamPlayback::_get_playback_position() const {
	return position_;
}

void PlatformVideoStreamPlayback::_seek(double time) {
	if (!backend_ || !clock_) {
		return;
	}
	if (time < 0.0) {
		time = 0.0;
	}
	drain_queue();
	backend_->seek(time);
	clock_->set_time(time);
	position_ = time;
	eos_ = false;
	// NOTE (boundary -> o3h): this is a tolerant keyframe seek. Adaptive
	// keyframe-on-drag / exact-on-settle scrubbing is the scrubbing slice.
}

void PlatformVideoStreamPlayback::_set_audio_track(int /*idx*/) {
	// Single-track audio only in v1; audio output lands in the A/V-sync slice (dte).
}

Ref<Texture2D> PlatformVideoStreamPlayback::_get_texture() const {
	// The engine-owned RGBA Texture2DRD. Godot samples ONLY this — never the
	// decoder surface (ADR-0003).
	return present_.get_texture();
}

void PlatformVideoStreamPlayback::_update(double delta) {
	if (!playing_ || paused_ || !loaded_ || !clock_ || !queue_) {
		return;
	}

	// Advance the master clock by the render delta (monotonic fallback path; the
	// audio-master clock is wired in dte).
	clock_->advance(delta);
	const double now = clock_->media_time();

	// Keep the decode-ahead queue topped up.
	fill_queue();

	// Pick the frame for "now": present the newest queued frame whose PTS is at
	// or before the clock, dropping any older frames we skipped past. This is a
	// deliberately simple present policy; sophisticated drop-late / hold-early
	// lives in dte.
	std::optional<core::VideoFrame> chosen;
	while (!queue_->empty()) {
		// Peek by popping; FrameQueue is SPSC pop-only, so we pop and decide.
		std::optional<core::VideoFrame> f = queue_->pop();
		if (!f.has_value()) {
			break;
		}
		if (f->pts_seconds <= now + 1e-6) {
			// This frame is due. If we already had a due frame, retire the older
			// one (we skipped it) before taking the newer.
			if (chosen.has_value() && chosen->release) {
				chosen->release();
			}
			chosen = std::move(f);
			// Keep scanning in case an even-newer frame is also due (catch-up).
			continue;
		}
		// f is in the future: we can't present it yet. We've already removed it
		// from the queue, so present `chosen` (if any) and re-queue f by holding
		// it for next frame. With our small queue, simplest correct option is to
		// release future frames we over-pulled only if we have a chosen frame;
		// otherwise present f as the best available (hold-early).
		if (!chosen.has_value()) {
			chosen = std::move(f); // hold-early: show the nearest upcoming frame
		} else {
			// We over-pulled a future frame; retire it (it will be re-decoded by
			// the next fill via the backend's linear pump only if we seek — for
			// linear playback we simply drop it, accepting we lose one frame of
			// lookahead. Acceptable for this slice; dte adds proper peeking).
			if (f->release) {
				f->release();
			}
		}
		break;
	}

	if (chosen.has_value()) {
		position_ = chosen->pts_seconds;
		// present() consumes the frame (moves its release into the retire-ring).
		present_.present(std::move(*chosen));
	}

	if (eos_ && queue_->empty()) {
		playing_ = false;
	}
}

int PlatformVideoStreamPlayback::_get_channels() const {
	return backend_ ? backend_->audio_channel_count() : 0;
}

int PlatformVideoStreamPlayback::_get_mix_rate() const {
	return backend_ ? backend_->audio_sample_rate() : 0;
}
