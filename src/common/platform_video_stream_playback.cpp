// -----------------------------------------------------------------------
// platform_video_stream_playback.cpp — see header.
// -----------------------------------------------------------------------

#include "platform_video_stream_playback.h"

#include <godot_cpp/classes/audio_server.hpp>
#include <godot_cpp/classes/project_settings.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>
#include <chrono>
#include <thread>

#include "../core/decode_scheduler.h"
#include "backend_factory.h"

using namespace godot;

PlatformVideoStreamPlayback::PlatformVideoStreamPlayback() = default;

PlatformVideoStreamPlayback::~PlatformVideoStreamPlayback() {
	// Unregister from the shared pool first: this blocks until any in-flight
	// decode slice for our stream completes and releases every buffered surface,
	// so no worker can touch our Backend after this returns (no use-after-free).
	if (stream_) {
		core::DecodeScheduler::instance().unregister_stream(stream_);
		stream_.reset();
	}
	present_.shutdown();
}

void PlatformVideoStreamPlayback::_bind_methods() {
	ClassDB::bind_method(D_METHOD("get_color_info"), &PlatformVideoStreamPlayback::get_color_info);

	ClassDB::bind_method(D_METHOD("set_output_mode", "mode"), &PlatformVideoStreamPlayback::set_output_mode);
	ClassDB::bind_method(D_METHOD("get_output_mode"), &PlatformVideoStreamPlayback::get_output_mode);
	ADD_PROPERTY(PropertyInfo(Variant::INT, "output_mode", PROPERTY_HINT_ENUM, "SDR,HDR"),
			"set_output_mode", "get_output_mode");
}

bool PlatformVideoStreamPlayback::load(const String &path) {
	std::unique_ptr<core::Backend> backend = platform_media::make_backend();

	// Resolve a Godot res:// / user:// path to an absolute OS path the backend's
	// AVURLAsset can open. globalize_path leaves absolute OS paths untouched.
	String os_path = ProjectSettings::get_singleton()->globalize_path(path);
	const std::string utf8 = os_path.utf8().get_data();

	if (!backend->open(utf8)) {
		return false;
	}

	// Cache colorimetry from the backend. These are populated at open time
	// from the track's format descriptions; per-frame CV attachments may
	// provide more accurate metadata at decode time.
	color_ = backend->colorimetry();

	length_ = backend->duration_seconds();
	width_ = backend->video_width();
	height_ = backend->video_height();
	audio_track_count_ = backend->audio_track_count();

	// --- Canonical Mix Format ---
	// Compute the maximum channel count across all audio tracks at the clip's
	// shared sample rate. Godot queries channels/mix-rate exactly once at play
	// start, so these must be stable for the playback's entire lifetime. The
	// channel mixer converts each backend chunk's native channel layout to the
	// canonical format before writing to the audio ring.
	canonical_channels_ = 0;
	canonical_sample_rate_ = 0;
	has_audio_ = false;
	for (int i = 0; i < audio_track_count_; ++i) {
		const core::AudioTrackInfo info = backend->audio_track_info(i);
		if (info.channels > canonical_channels_) {
			canonical_channels_ = info.channels;
		}
		if (info.sample_rate > canonical_sample_rate_) {
			canonical_sample_rate_ = info.sample_rate;
		}
		if (info.channels > 0 && info.sample_rate > 0) {
			has_audio_ = true;
		}
	}
	// Clamp to the max we know how to mix; larger channel counts are passed
	// through unmixed (the ring still fills and plays).
	if (canonical_channels_ > core::kMaxMixSourceChannels) {
		canonical_channels_ = core::kMaxMixSourceChannels;
	}

	// Hand the Backend to the process-wide shared decode pool. From here a pool
	// worker decodes video ahead into stream_'s queue; this object never touches
	// the Backend directly except via the scheduler (next_frame / with_backend).
	stream_ = core::DecodeScheduler::instance().register_stream(std::move(backend));

	if (has_audio_) {
		// Audio-master: derive media time from the samples Godot's AudioServer
		// actually consumes (latency-compensated). The latency offset shifts
		// reported time back so media_time() reflects what the speaker is
		// emitting now, not what was just pushed into the audio buffer.
		double latency = 0.0;
		if (AudioServer *as = AudioServer::get_singleton()) {
			latency = as->get_output_latency();
		}
		audio_clock_ = std::make_unique<core::AudioMasterClock>(canonical_sample_rate_, latency);
		// ~0.5 s of head-room so brief decode jitter never underruns the mixer.
		const size_t ring_frames = static_cast<size_t>(canonical_sample_rate_) / 2;
		audio_ring_ = std::make_unique<core::AudioRing>(canonical_channels_, ring_frames);
	} else {
		// No audio track: fall back to a monotonic clock advanced by the render
		// delta so silent clips still play at the correct rate.
		mono_clock_ = std::make_unique<core::MonotonicClock>(0.0);
	}

	loaded_ = true;
	position_ = 0.0;
	audio_eos_ = false;
	return true;
}

core::Clock *PlatformVideoStreamPlayback::master() const {
	if (has_audio_) {
		return audio_clock_.get();
	}
	return mono_clock_.get();
}

bool PlatformVideoStreamPlayback::audio_exhausted() const {
	// True when no real audio samples will ever advance the clock again:
	// silent clips, and a shorter audio track once it has fully drained.
	return !has_audio_ || (audio_eos_ && audio_ring_ && audio_ring_->empty());
}

void PlatformVideoStreamPlayback::fill_audio() {
	if (!stream_ || !audio_ring_ || audio_eos_) {
		return;
	}
	// Pump audio from the Backend under the scheduler's per-stream exclusion so we
	// never race the worker that is decoding video ahead on the same Backend. The
	// callback runs on THIS (main) thread with sole access to the Backend.
	core::DecodeScheduler::instance().with_backend(stream_, [this](core::Backend &backend) {
		// Top the ring up to roughly half full so there is always a cushion against
		// decode jitter without buffering an unbounded amount of audio ahead.
		while (audio_ring_->free_frames() > audio_ring_->available_frames()) {
			std::optional<core::AudioChunk> chunk = backend.next_audio_chunk();
			if (!chunk.has_value()) {
				audio_eos_ = true;
				break;
			}
			if (chunk->samples == nullptr || chunk->frame_count <= 0) {
				continue;
			}
			// Mix from the backend's native channel layout to the canonical format.
			// The channel mixer is a no-op (memcpy) when channel counts already match.
			const int nf = chunk->frame_count;
			const int sc = chunk->channel_count;
			const int dc = canonical_channels_;
			const size_t needed = static_cast<size_t>(nf) * static_cast<size_t>(dc);
			if (mix_scratch_.size() < needed) {
				mix_scratch_.resize(needed);
			}
			core::mix_channels(chunk->samples, sc, mix_scratch_.data(), dc, nf);
			audio_ring_->write(mix_scratch_.data(), static_cast<size_t>(nf));
		}
	});
}

bool PlatformVideoStreamPlayback::drive_audio() {
	if (!audio_ring_ || !audio_clock_ || canonical_channels_ <= 0) {
		return false;
	}

	// Offer up to a render-tick worth of audio per call. We request exactly the
	// frames currently buffered (capped) so the normal path supplies real PCM
	// with no silence padding; only a genuine underrun pads with zeros.
	constexpr int kMaxMixFramesPerTick = 4096; // ~85 ms @ 48k — generous head-room

	const int ch = canonical_channels_;
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
	//
	// NOTE: read_frames() already drained `real_frames` from the ring. If
	// mix_audio accepts fewer than that (a near-full AudioServer buffer), the
	// surplus real frames are dropped — the clock stays honest (we count only
	// `accepted`), but a tiny amount of audio is lost. In practice mix_audio
	// accepts the full request, and `request` is capped to what is buffered, so
	// this only bites under sustained AudioServer back-pressure. Tolerable for
	// linear playback; the shared decode-pool slice can re-offer instead.
	const int accepted = mix_audio(request, mix_buffer_, 0);
	const int advance = std::min<int>(accepted, static_cast<int>(real_frames));
	if (advance > 0) {
		audio_clock_->on_audio_mixed(advance);
	}
	return advance > 0;
}

void PlatformVideoStreamPlayback::_play() {
	if (!loaded_) {
		return;
	}
	const bool was_playing = playing_;
	playing_ = true;
	paused_ = false;
	if (core::Clock *c = master()) {
		c->set_paused(false);
	}
	// Resuming playback after a scrub: force an exact resolve at the last scrub
	// target so play starts from the precise frame, not an approximate keyframe one.
	// Only when transitioning from stopped/paused into play (not a redundant call).
	if (!was_playing && stream_) {
		apply_scrub_resolve(scrubber_.on_resume(now_ms()));
	}
}

void PlatformVideoStreamPlayback::_stop() {
	playing_ = false;
	paused_ = false;
	audio_eos_ = false;
	position_ = 0.0;
	if (core::Clock *c = master()) {
		c->set_time(0.0);
	}
	if (audio_ring_) {
		audio_ring_->clear();
	}
	// Flush the decode-ahead queue and reseek to the start via the scheduler
	// (serialized against the worker; releases buffered surfaces).
	if (stream_) {
		core::DecodeScheduler::instance().request_seek(stream_, 0.0);
	}
	// Reset scrub state so the next seek starts fresh (no stale velocity/settle).
	scrubber_ = core::Scrubber(scrubber_.config());
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

double PlatformVideoStreamPlayback::now_ms() {
	// Monotonic wall clock for scrub velocity/debounce. steady_clock never jumps.
	using clock = std::chrono::steady_clock;
	const auto t = clock::now().time_since_epoch();
	return std::chrono::duration<double, std::milli>(t).count();
}

void PlatformVideoStreamPlayback::apply_scrub_resolve(const core::ScrubResolve &resolve) {
	core::Clock *c = master();
	if (!stream_ || !c) {
		return;
	}
	double target = resolve.target_seconds < 0.0 ? 0.0 : resolve.target_seconds;

	if (audio_ring_) {
		audio_ring_->clear(); // stale audio must not play after a (re)seek
	}
	core::DecodeScheduler &sched = core::DecodeScheduler::instance();

	// Both modes start by flushing the decode-ahead queue and reseeking the Backend
	// to the preceding keyframe through the scheduler (serialized against the
	// worker; no race / no UAF).
	sched.request_seek(stream_, target);

	if (resolve.mode == core::ResolveMode::Exact) {
		// Precise resolve: decode FORWARD past the keyframe to the exact target,
		// dropping (releasing) every earlier frame so the precise frame is what the
		// present step shows. Bounded by the clip — stops at EOS. We drop frames
		// strictly before the target; the present step then shows the target frame.
		//
		// This runs on the main thread only on a settle/resume (not the hot
		// per-frame path), so a brief wait for the worker to top the queue up is
		// acceptable. We bound the spin so a stall can never hang the main thread:
		// if the worker has not advanced after `kMaxSpins`, we give up and let the
		// normal present step finish converging on the next ticks.
		const double eps = 1.0 / 120.0; // ~half a frame at 60fps tolerance
		constexpr int kMaxSpins = 100000;
		int empty_spins = 0;
		for (;;) {
			std::optional<double> head = sched.peek_head_pts(stream_);
			if (!head.has_value()) {
				if (sched.at_end(stream_) || ++empty_spins > kMaxSpins) {
					break; // EOS before the target, or worker stalled — clamp.
				}
				std::this_thread::yield(); // queue momentarily empty; worker tops up
				continue;
			}
			empty_spins = 0;
			if (*head + eps >= target) {
				break; // head is at/after the target — leave it for the present step
			}
			// Head is before the target: drop it and keep decoding forward.
			std::optional<core::VideoFrame> stale = sched.next_frame(stream_);
			if (stale.has_value() && stale->release) {
				stale->release();
			}
		}
	}

	c->set_time(target); // re-anchor the master clock to the resolved target
	position_ = target;
	audio_eos_ = false;
}

void PlatformVideoStreamPlayback::_seek(double time) {
	if (!stream_ || !master()) {
		return;
	}
	if (time < 0.0) {
		time = 0.0;
	}
	// Feed the seek to the adaptive scrubber: a fast drag burst resolves to the
	// nearest keyframe for instant feedback; a slow/lone seek resolves exactly. A
	// debounced settle (or playback resume) later upgrades a keyframe scrub to an
	// exact resolve via poll()/on_resume() in _update()/_play().
	const core::ScrubResolve resolve = scrubber_.on_seek(time, now_ms());
	apply_scrub_resolve(resolve);
}

void PlatformVideoStreamPlayback::_set_audio_track(int idx) {
	// Validate out-of-range: the stock VideoStreamPlayer calls this before
	// play() to pre-select a track, and while playing for mid-stream switch.
	if (audio_track_count_ > 0 && (idx < 0 || idx >= audio_track_count_)) {
		print_error(
				String("Audio track index ") + String::num_int64(idx) +
				" is out of range. Clip has " + String::num_int64(audio_track_count_) +
				" track(s). Falling back to default (0).");
		idx = 0;
	}
	audio_track_selection_ = idx;

	// Apply the selection to the backend if it's already registered with the
	// scheduler. Before play() the backend exists but no audio is flowing, so
	// the selection takes effect on the next seek (which rebuilds the reader
	// in AVF, or reconfigures stream selection in MF).
	if (stream_) {
		core::DecodeScheduler::instance().with_backend(
				stream_, [idx](core::Backend &backend) {
					backend.select_audio_track(idx);
				});
	}
}

Ref<Texture2D> PlatformVideoStreamPlayback::_get_texture() const {
	// The engine-owned RGBA Texture2DRD. Godot samples ONLY this — never the
	// decoder surface.
	return present_.get_texture();
}

void PlatformVideoStreamPlayback::_update(double delta) {
	core::Clock *clock = master();
	if (!loaded_ || !clock || !stream_) {
		return;
	}

	// Settle check runs regardless of play/pause: scrubbing commonly happens while
	// paused (dragging a timeline). Once a fast drag has gone quiet for the debounce
	// window, upgrade the approximate keyframe frame to the exact target frame.
	if (std::optional<core::ScrubResolve> settle = scrubber_.poll(now_ms())) {
		apply_scrub_resolve(*settle);
	}

	if (!playing_ || paused_) {
		return;
	}
	core::DecodeScheduler &sched = core::DecodeScheduler::instance();

	// One clock rule: advance from real audio samples when any exist; once no
	// more can ever come (silent clip, or a shorter audio track fully drained —
	// legitimate in real-world files), advance by the render delta instead. The
	// gate on !advanced_from_audio keeps the last partial ring drain from
	// double-advancing (real leftover frames + delta on the same tick).
	bool advanced_from_audio = false;
	if (has_audio_) {
		fill_audio();
		advanced_from_audio = drive_audio();
	}
	if (!advanced_from_audio && audio_exhausted()) {
		clock->set_time(clock->media_time() + delta);
	}
	const double now = clock->media_time();

	// Video decode-ahead is now driven by the shared pool's worker(s); the queue
	// is topped up off the main thread. The main thread only consumes here.

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
		std::optional<double> head_pts = sched.peek_head_pts(stream_);
		if (!head_pts.has_value()) {
			break; // queue empty -> hold the current frame
		}
		std::optional<double> next_pts = sched.peek_next_pts(stream_);

		core::PresentAction action =
				core::select_present_action(head_pts, next_pts, now, frame_interval);

		if (action == core::PresentAction::Drop) {
			// Head is stale: pop and retire it, then re-evaluate the new head.
			std::optional<core::VideoFrame> stale = sched.next_frame(stream_);
			if (stale.has_value() && stale->release) {
				stale->release();
			}
			continue;
		}

		if (action == core::PresentAction::Show) {
			// Newest due frame: pop and present it. (Drop already collapsed any
			// backlog, so this is the only due frame.)
			chosen = sched.next_frame(stream_);
		}

		// Show or Hold both end the present scan for this tick.
		break;
	}

	if (chosen.has_value()) {
		position_ = chosen->pts_seconds;
		// present() consumes the frame (moves its release into the retire-ring).
		present_.present(std::move(*chosen));
	}

	// End-of-playback: video stream drained (Backend EOS + empty queue) and audio
	// fully consumed. at_end() reflects the worker-reported EOS for our stream.
	if (sched.at_end(stream_) && audio_exhausted()) {
		playing_ = false;
	}
}

int PlatformVideoStreamPlayback::_get_channels() const {
	// Canonical Mix Format channel count (maximum across all audio tracks,
	// computed at load). Godot sizes its mix buffer from this and queries it
	// exactly once at play start, so it is stable for the playback's lifetime.
	// The channel mixer converts each backend chunk's native layout to this
	// count before writing to the audio ring.
	return canonical_channels_;
}

int PlatformVideoStreamPlayback::_get_mix_rate() const {
	// Canonical Mix Format sample rate (the clip's shared sample rate across
	// all audio tracks). The AudioServer resamples from this to the device
	// rate; the master clock uses it for samples->seconds.
	return canonical_sample_rate_;
}

Dictionary PlatformVideoStreamPlayback::get_color_info() const {
	Dictionary info;
	info["matrix"] = static_cast<int>(color_.matrix);
	info["primaries"] = static_cast<int>(color_.primaries);
	info["transfer"] = static_cast<int>(color_.transfer);
	info["range"] = static_cast<int>(color_.range);
	info["bit_depth"] = color_.bit_depth;
	// Report the effective output mode so callers can distinguish between
	// an SDR clip in HDR viewport vs a native HDR clip.
	info["output_mode"] = static_cast<int>(present_.output_mode());
	return info;
}

void PlatformVideoStreamPlayback::set_output_mode(int mode) {
	if (mode < 0 || mode > 1) {
		return;
	}
	auto om = (mode == 1) ? platform_media::OutputMode::HDR
						  : platform_media::OutputMode::SDR;
	present_.set_output_mode(om);
}

int PlatformVideoStreamPlayback::get_output_mode() const {
	return static_cast<int>(present_.output_mode());
}
