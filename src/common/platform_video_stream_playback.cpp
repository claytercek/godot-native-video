// -----------------------------------------------------------------------
// platform_video_stream_playback.cpp — see header.
// -----------------------------------------------------------------------

#include "platform_video_stream_playback.h"

#include <godot_cpp/classes/audio_server.hpp>
#include <godot_cpp/classes/project_settings.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>

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
	channels_ = backend_->audio_channel_count();
	sample_rate_ = backend_->audio_sample_rate();
	has_audio_ = channels_ > 0 && sample_rate_ > 0;

	queue_ = std::make_unique<core::FrameQueue<core::VideoFrame, kQueueCapacity>>();

	if (has_audio_) {
		// Audio-master: derive media time from the samples Godot's AudioServer
		// actually consumes (latency-compensated). The latency offset shifts
		// reported time back so media_time() reflects what the speaker is
		// emitting now, not what was just pushed into the audio buffer.
		double latency = 0.0;
		if (AudioServer *as = AudioServer::get_singleton()) {
			latency = as->get_output_latency();
		}
		audio_clock_ = std::make_unique<core::AudioMasterClock>(sample_rate_, latency);
		// ~0.5 s of head-room so brief decode jitter never underruns the mixer.
		const size_t ring_frames = static_cast<size_t>(sample_rate_) / 2;
		audio_ring_ = std::make_unique<core::AudioRing>(channels_, ring_frames);
	} else {
		// No audio track: fall back to a monotonic clock advanced by the render
		// delta so silent clips still play at the correct rate.
		mono_clock_ = std::make_unique<core::MonotonicClock>(0.0);
	}

	loaded_ = true;
	position_ = 0.0;
	eos_ = false;
	audio_eos_ = false;
	return true;
}

core::Clock *PlatformVideoStreamPlayback::master() const {
	if (has_audio_) {
		return audio_clock_.get();
	}
	return mono_clock_.get();
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

void PlatformVideoStreamPlayback::fill_audio() {
	if (!backend_ || !audio_ring_ || audio_eos_) {
		return;
	}
	// Top the ring up to roughly half full so there is always a cushion against
	// decode jitter without buffering an unbounded amount of audio ahead.
	while (audio_ring_->free_frames() > audio_ring_->available_frames()) {
		std::optional<core::AudioChunk> chunk = backend_->next_audio_chunk();
		if (!chunk.has_value()) {
			audio_eos_ = true;
			break;
		}
		if (chunk->samples == nullptr || chunk->frame_count <= 0) {
			continue;
		}
		// AudioRing's channel count is fixed at the clip's; backend chunks match.
		audio_ring_->write(chunk->samples, static_cast<size_t>(chunk->frame_count));
	}
}

void PlatformVideoStreamPlayback::drive_audio() {
	if (!audio_ring_ || !audio_clock_ || channels_ <= 0) {
		return;
	}

	// Offer up to a render-tick worth of audio per call. We request exactly the
	// frames currently buffered (capped) so the normal path supplies real PCM
	// with no silence padding; only a genuine underrun pads with zeros.
	constexpr int kMaxMixFramesPerTick = 4096; // ~85 ms @ 48k — generous head-room

	const int ch = channels_;
	const size_t available = audio_ring_->available_frames();
	// On underrun (available == 0) still offer a small block of silence so the
	// AudioServer keeps its buffer fed and playback doesn't glitch; the clock is
	// NOT advanced for silence (read_frames reports 0 real frames).
	int request = static_cast<int>(std::min<size_t>(
			available > 0 ? available : 256, kMaxMixFramesPerTick));

	if (mix_buffer_.size() < static_cast<int64_t>(request) * ch) {
		mix_buffer_.resize(static_cast<int64_t>(request) * ch);
	}

	// Drain decoded PCM (or silence on underrun) into the staging buffer.
	const size_t real_frames =
			audio_ring_->read_frames(mix_buffer_.ptrw(), static_cast<size_t>(request));

	// Hand the PCM to Godot's AudioServer. mix_audio returns the frames it
	// accepted. We advance the master clock ONLY by frames that were both real
	// (non-silence) AND consumed by Godot — so neither underrun silence nor a
	// full AudioServer buffer inflates media time. The clock therefore tracks
	// genuine audio consumption, latency-compensated in AudioMasterClock.
	const int accepted = mix_audio(request, mix_buffer_, 0);
	const int advance = std::min<int>(accepted, static_cast<int>(real_frames));
	if (advance > 0) {
		audio_clock_->on_audio_mixed(advance);
	}
}

void PlatformVideoStreamPlayback::_play() {
	if (!loaded_) {
		return;
	}
	playing_ = true;
	paused_ = false;
	if (core::Clock *c = master()) {
		c->set_paused(false);
	}
}

void PlatformVideoStreamPlayback::_stop() {
	playing_ = false;
	paused_ = false;
	eos_ = false;
	audio_eos_ = false;
	position_ = 0.0;
	if (core::Clock *c = master()) {
		c->set_time(0.0);
	}
	if (audio_ring_) {
		audio_ring_->clear();
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
	if (core::Clock *c = master()) {
		c->set_paused(paused);
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
	core::Clock *c = master();
	if (!backend_ || !c) {
		return;
	}
	if (time < 0.0) {
		time = 0.0;
	}
	drain_queue();
	if (audio_ring_) {
		audio_ring_->clear(); // stale audio must not play after a seek
	}
	backend_->seek(time);
	c->set_time(time); // re-anchor the master clock to the seek target
	position_ = time;
	eos_ = false;
	audio_eos_ = false;
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
	core::Clock *clock = master();
	if (!playing_ || paused_ || !loaded_ || !clock || !queue_) {
		return;
	}

	if (has_audio_) {
		// Audio-master path: keep the audio ring fed, then drain it into Godot's
		// AudioServer. drive_audio() advances the master clock from the samples
		// actually consumed (the audio clock IS the master here — ADR-0001).
		fill_audio();
		drive_audio();
	} else {
		// Silent clip: advance the monotonic clock by the render delta so the
		// video still plays at the correct rate.
		clock->advance(delta);
	}
	const double now = clock->media_time();

	// Keep the video decode-ahead queue topped up.
	fill_queue();

	// --- Present step: drop-late / hold-early, via the Godot-free selector ---
	//
	// We peek the head/next PTS (consumer-side, non-destructive) so frame order
	// is never disturbed, then act on the selector's decision:
	//   * Drop  — head is stale (a newer due frame exists): pop+release it, loop.
	//   * Show  — head is the correct frame for `now`: pop and present it.
	//   * Hold  — head is in the future: present nothing new, keep current frame.
	const double frame_interval = 1.0 / 30.0; // nominal; refined when fps is known
	std::optional<core::VideoFrame> chosen;

	for (;;) {
		const core::VideoFrame *head = queue_->peek();
		if (head == nullptr) {
			break; // queue empty -> hold the current frame
		}
		const core::VideoFrame *next = queue_->peek_next();

		std::optional<double> head_pts = head->pts_seconds;
		std::optional<double> next_pts =
				next ? std::optional<double>(next->pts_seconds) : std::nullopt;

		core::PresentAction action =
				core::select_present_action(head_pts, next_pts, now, frame_interval);

		if (action == core::PresentAction::Drop) {
			// Head is stale: pop and retire it, then re-evaluate the new head.
			std::optional<core::VideoFrame> stale = queue_->pop();
			if (stale.has_value() && stale->release) {
				stale->release();
			}
			continue;
		}

		if (action == core::PresentAction::Show) {
			// Newest due frame: pop and present it. (Drop already collapsed any
			// backlog, so this is the only due frame.)
			chosen = queue_->pop();
		}

		// Show or Hold both end the present scan for this tick.
		break;
	}

	if (chosen.has_value()) {
		position_ = chosen->pts_seconds;
		// present() consumes the frame (moves its release into the retire-ring).
		present_.present(std::move(*chosen));
	}

	// End-of-playback: both streams drained and nothing left to show.
	const bool audio_done = !has_audio_ || (audio_eos_ && audio_ring_ && audio_ring_->empty());
	if (eos_ && queue_->empty() && audio_done) {
		playing_ = false;
	}
}

int PlatformVideoStreamPlayback::_get_channels() const {
	// Real backend channel count (cached at load). Godot sizes its mix buffer
	// from this, so it must match the PCM we feed mix_audio().
	return channels_;
}

int PlatformVideoStreamPlayback::_get_mix_rate() const {
	// Real backend sample rate (cached at load). The AudioServer resamples from
	// this to the device rate; the master clock uses it for samples->seconds.
	return sample_rate_;
}
