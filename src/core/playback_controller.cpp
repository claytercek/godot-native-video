// -----------------------------------------------------------------------
// playback_controller.cpp — see header.
// -----------------------------------------------------------------------

#include "playback_controller.h"

#include "channel_mixer.h"
#include "present_selector.h"

#include <algorithm>
#include <sstream>
#include <thread>

namespace core {

PlaybackController::~PlaybackController() {
	shutdown();
}

void PlaybackController::warn(std::string message) {
	warnings_.push_back(std::move(message));
}

std::vector<std::string> PlaybackController::take_warnings() {
	std::vector<std::string> out;
	out.swap(warnings_);
	return out;
}

void PlaybackController::shutdown() {
	// Blocks until any in-flight decode slice for our stream completes and
	// releases every buffered surface, so no worker can touch the Backend
	// after this returns (no use-after-free).
	if (stream_) {
		DecodeScheduler::instance().unregister_stream(stream_);
		stream_.reset();
	}
}

void PlaybackController::load(std::unique_ptr<Backend> backend, double audio_output_latency_seconds) {
	// Cache colorimetry/dimensions from the backend. These are populated at
	// open time from the track's format descriptions; per-frame CV
	// attachments may provide more accurate metadata at decode time.
	color_ = backend->colorimetry();
	length_ = backend->duration_seconds();
	width_ = backend->video_width();
	height_ = backend->video_height();
	audio_track_count_ = backend->audio_track_count();

	// --- Canonical Mix Format ---
	// canonical_channels_ is the maximum channel count across all audio
	// tracks. canonical_sample_rate_ is the FIRST audio-bearing track's rate
	// — NOT a shared rate across tracks. Mixed-sample-rate clips are a
	// documented limitation: the default track's rate wins, and a later
	// track with a differing rate only gets one warning here (a mid-stream
	// switch to it is refused in request_audio_track()). Godot queries
	// channels/mix-rate exactly once at play start, so these must be stable
	// for the playback's entire lifetime. The channel mixer converts each
	// backend chunk's native channel layout to the canonical format before
	// writing to the audio ring.
	canonical_channels_ = 0;
	canonical_sample_rate_ = 0;
	has_audio_ = false;
	track_infos_.clear();
	bool warned_mixed_sample_rates = false;
	for (int i = 0; i < audio_track_count_; ++i) {
		const AudioTrackInfo info = backend->audio_track_info(i);
		track_infos_.push_back(info);
		if (info.channels > canonical_channels_) {
			canonical_channels_ = info.channels;
		}
		if (info.channels > 0 && info.sample_rate > 0) {
			if (!has_audio_) {
				canonical_sample_rate_ = info.sample_rate;
				has_audio_ = true;
			} else if (!warned_mixed_sample_rates && info.sample_rate != canonical_sample_rate_) {
				std::ostringstream oss;
				oss << "Audio track " << i << " sample rate " << info.sample_rate
					<< " Hz differs from the canonical rate " << canonical_sample_rate_
					<< " Hz. Mixed-sample-rate clips are not supported; this track "
					   "will play at the canonical rate and mid-stream switches to "
					   "it are refused.";
				warn(oss.str());
				warned_mixed_sample_rates = true;
			}
		}
	}
	// Clamp to the max we know how to mix; larger channel counts are passed
	// through unmixed (the ring still fills and plays).
	if (canonical_channels_ > kMaxMixSourceChannels) {
		canonical_channels_ = kMaxMixSourceChannels;
	}

	// Hand the Backend to the process-wide shared decode pool. From here a
	// pool worker decodes video ahead into stream_'s queue; this object
	// never touches the Backend directly except via the scheduler
	// (next_frame / with_backend).
	stream_ = DecodeScheduler::instance().register_stream(std::move(backend));

	if (has_audio_) {
		// Audio-master: derive media time from the samples Godot's
		// AudioServer actually consumes (latency-compensated). The latency
		// offset shifts reported time back so media_time() reflects what
		// the speaker is emitting now, not what was just pushed into the
		// audio buffer.
		auto audio = std::make_unique<AudioMasterClock>(canonical_sample_rate_, audio_output_latency_seconds);
		auto mono = std::make_unique<MonotonicClock>(0.0);
		clock_ = std::make_unique<ClockBridge>(std::move(audio), std::move(mono), /*audio_master=*/true);
		// ~0.5 s of head-room so brief decode jitter never underruns the mixer.
		const size_t ring_frames = static_cast<size_t>(canonical_sample_rate_) / 2;
		audio_ring_ = std::make_unique<AudioRing>(canonical_channels_, ring_frames);
	} else {
		// No audio track: fall back to a monotonic clock advanced by the
		// render delta so silent clips still play at the correct rate. A
		// null audio clock makes the bridge permanently monotonic-master —
		// every audio-facing ClockBridge method becomes a safe no-op.
		auto mono = std::make_unique<MonotonicClock>(0.0);
		clock_ = std::make_unique<ClockBridge>(nullptr, std::move(mono), /*audio_master=*/false);
	}

	loaded_ = true;
	position_ = 0.0;
	audio_eos_ = false;
	switch_in_progress_ = false;

	// desired_track_ may already carry a pre-load selection made via
	// request_audio_track() before load() ran; it must survive, not be
	// clobbered. Validate it now that audio_track_count_ is known.
	if (audio_track_count_ > 0 && (desired_track_ < 0 || desired_track_ >= audio_track_count_)) {
		std::ostringstream oss;
		oss << "Audio track index " << desired_track_ << " is out of range. Clip has "
			<< audio_track_count_ << " track(s). Falling back to default (0).";
		warn(oss.str());
		desired_track_ = 0;
	}
	live_track_ = 0;
	// Cheap-applies any pre-load selection (we are not yet playing_).
	reconcile_audio_track();
}

bool PlaybackController::audio_exhausted() const {
	// True when no real audio samples will ever advance the clock again:
	// silent clips, and a shorter audio track once it has fully drained.
	return !has_audio_ || (audio_eos_ && audio_ring_ && audio_ring_->empty());
}

void PlaybackController::fill_audio() {
	if (!stream_ || !audio_ring_ || audio_eos_) {
		return;
	}
	// Pump audio from the Backend under the scheduler's per-stream exclusion
	// so we never race the worker that is decoding video ahead on the same
	// Backend. The callback runs on the caller's thread with sole access to
	// the Backend.
	DecodeScheduler::instance().with_backend(stream_, [this](Backend &backend) {
		// Top the ring up to roughly half full so there is always a cushion
		// against decode jitter without buffering an unbounded amount of
		// audio ahead.
		while (audio_ring_->free_frames() > audio_ring_->available_frames()) {
			std::optional<AudioChunk> chunk = backend.next_audio_chunk();
			if (!chunk.has_value()) {
				// EOS. If a switch is still in progress, we simply never
				// re-anchor: the bridge stays monotonic-master and tick()'s
				// clock->advance() keeps video moving through what is now a
				// permanent gap.
				audio_eos_ = true;
				break;
			}
			if (chunk->samples == nullptr || chunk->frame_count <= 0) {
				continue;
			}
			// --- Mid-stream track switch: re-anchor clock when new audio flows ---
			// During a switch the clock is in monotonic-master mode so video
			// keeps advancing through the audio silence. reconcile_audio_track()
			// cleared the ring before this call, so the first chunk to reach
			// this point (decoded, not merely attempted) is genuinely from the
			// new track: the audio clock is repositioned to the current
			// monotonic position so media_time() remains continuous.
			if (switch_in_progress_) {
				clock_->reanchor_to_audio();
				switch_in_progress_ = false;
			}
			// Mix from the backend's native channel layout to the canonical
			// format. The channel mixer is a no-op (memcpy) when channel
			// counts already match.
			const int nf = chunk->frame_count;
			const int sc = chunk->channel_count;
			const int dc = canonical_channels_;
			const size_t needed = static_cast<size_t>(nf) * static_cast<size_t>(dc);
			if (mix_scratch_.size() < needed) {
				mix_scratch_.resize(needed);
			}
			mix_channels(chunk->samples, sc, mix_scratch_.data(), dc, nf);
			audio_ring_->write(mix_scratch_.data(), static_cast<size_t>(nf));
		}
	});
}

bool PlaybackController::drive_audio(MixSink &sink) {
	if (!audio_ring_ || !clock_ || canonical_channels_ <= 0) {
		return false;
	}

	// Offer up to a render-tick worth of audio per call. We request exactly
	// the frames currently buffered (capped) so the normal path supplies
	// real PCM with no silence padding; only a genuine underrun pads with
	// zeros.
	constexpr int kMaxMixFramesPerTick = 4096; // ~85 ms @ 48k — generous head-room

	const int ch = canonical_channels_;
	const size_t available = audio_ring_->available_frames();
	// On underrun (available == 0) still offer a small block of silence so
	// the sink keeps its buffer fed and playback doesn't glitch; the clock
	// is NOT advanced for silence (read_frames reports 0 real frames).
	int request = static_cast<int>(std::min<size_t>(
			available > 0 ? available : 256, kMaxMixFramesPerTick));

	const size_t needed = static_cast<size_t>(request) * static_cast<size_t>(ch);
	if (drive_scratch_.size() < needed) {
		drive_scratch_.resize(needed);
	}

	// Drain decoded PCM (or silence on underrun) into the staging buffer.
	const size_t real_frames =
			audio_ring_->read_frames(drive_scratch_.data(), static_cast<size_t>(request));

	// Hand the PCM to the sink. It returns the frames it accepted. We
	// advance the master clock ONLY by frames that were both real
	// (non-silence) AND consumed by the sink — so neither underrun silence
	// nor a full downstream buffer inflates media time. The clock therefore
	// tracks genuine audio consumption, latency-compensated in
	// AudioMasterClock.
	//
	// NOTE: read_frames() already drained `real_frames` from the ring. If
	// the sink accepts fewer than that (a near-full downstream buffer), the
	// surplus real frames are dropped — the clock stays honest (we count
	// only `accepted`), but a tiny amount of audio is lost. In practice the
	// sink accepts the full request, and `request` is capped to what is
	// buffered, so this only bites under sustained downstream back-pressure.
	// Tolerable for linear playback.
	const int accepted = sink.mix(drive_scratch_.data(), request, ch);
	const int advance = std::min<int>(accepted, static_cast<int>(real_frames));
	if (advance > 0) {
		clock_->on_audio_mixed(advance);
	}
	return advance > 0;
}

void PlaybackController::play(WallClockMs now) {
	if (!loaded_) {
		return;
	}
	const bool was_playing = playing_;
	playing_ = true;
	paused_ = false;
	if (Clock *c = master()) {
		c->set_paused(false);
	}
	// Resuming playback after a scrub: force an exact resolve at the last
	// scrub target so play starts from the precise frame, not an
	// approximate keyframe one. Only when transitioning from stopped/paused
	// into play (not a redundant call).
	if (!was_playing && stream_) {
		apply_scrub_resolve(scrubber_.on_resume(now.ms));
	}
}

void PlaybackController::stop() {
	playing_ = false;
	paused_ = false;
	audio_eos_ = false;
	position_ = 0.0;
	if (Clock *c = master()) {
		c->set_time(0.0);
	}
	if (audio_ring_) {
		audio_ring_->clear();
	}
	// Flush the decode-ahead queue and reseek to the start via the
	// scheduler (serialized against the worker; releases buffered surfaces).
	if (stream_) {
		DecodeScheduler::instance().request_seek(stream_, 0.0);
	}
	// Reset scrub state so the next seek starts fresh (no stale velocity/settle).
	scrubber_ = Scrubber(scrubber_.config());
	switch_in_progress_ = false;
	// The backend's track selection persists across stop (desired_/live_track_
	// are NOT reset here), so audio is still live if the clip has any. If the
	// caller stopped mid-switch, the bridge would otherwise stay
	// monotonic-master forever with no more fill_audio() calls to re-anchor it.
	if (has_audio_ && clock_) {
		clock_->reanchor_to_audio();
	}
}

void PlaybackController::set_paused(bool paused) {
	paused_ = paused;
	if (Clock *c = master()) {
		c->set_paused(paused);
	}
}

void PlaybackController::seek(double time_seconds, WallClockMs now) {
	if (!stream_ || !master()) {
		return;
	}
	if (time_seconds < 0.0) {
		time_seconds = 0.0;
	}
	// Feed the seek to the adaptive scrubber: a fast drag burst resolves to
	// the nearest keyframe for instant feedback; a slow/lone seek resolves
	// exactly. A debounced settle (or playback resume) later upgrades a
	// keyframe scrub to an exact resolve via poll()/on_resume() in tick()/play().
	const ScrubResolve resolve = scrubber_.on_seek(time_seconds, now.ms);
	apply_scrub_resolve(resolve);
}

void PlaybackController::apply_scrub_resolve(const ScrubResolve &resolve) {
	Clock *c = master();
	if (!stream_ || !c) {
		return;
	}
	double target = resolve.target_seconds < 0.0 ? 0.0 : resolve.target_seconds;

	if (audio_ring_) {
		audio_ring_->clear(); // stale audio must not play after a (re)seek
	}
	DecodeScheduler &sched = DecodeScheduler::instance();

	// Both modes start by flushing the decode-ahead queue and reseeking the
	// Backend to the preceding keyframe through the scheduler (serialized
	// against the worker; no race / no UAF).
	sched.request_seek(stream_, target);

	if (resolve.mode == ResolveMode::Exact) {
		// Precise resolve: decode FORWARD past the keyframe to the exact
		// target, dropping (releasing) every earlier frame so the precise
		// frame is what the present step shows. Bounded by the clip —
		// stops at EOS. We drop frames strictly before the target; the
		// present step then shows the target frame.
		//
		// This runs on the caller's thread only on a settle/resume (not the
		// hot per-frame path), so a brief wait for the worker to top the
		// queue up is acceptable. We bound the spin so a stall can never
		// hang the caller: if the worker has not advanced after
		// `kMaxSpins`, we give up and let the normal present step finish
		// converging on the next ticks.
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
			std::optional<VideoFrame> stale = sched.next_frame(stream_);
			if (stale.has_value() && stale->release) {
				stale->release();
			}
		}
	}

	c->set_time(target); // re-anchor the master clock to the resolved target
	position_ = target;
	audio_eos_ = false;

	// Reconcile any pending track switch at the resolved position (position_
	// == target here) so a new selection is primed at the correct spot.
	reconcile_audio_track();
}

void PlaybackController::reconcile_audio_track() {
	if (desired_track_ == live_track_ || !stream_) {
		return;
	}

	if (!playing_) {
		// Stopped / pre-play: apply cheaply. Selection is deferred in the
		// backend until its next seek — which play()'s scrub-resume resolve
		// always issues before resuming.
		const int target = desired_track_;
		DecodeScheduler::instance().with_backend(
				stream_, [target](Backend &backend) {
					backend.select_audio_track(target);
				});
		live_track_ = desired_track_;
		return;
	}

	// Playing (including paused — reselecting now primes the new reader at
	// position_ so resume is instant).
	if (!clock_ || !audio_ring_) {
		return;
	}

	clock_->handoff_to_monotonic(); // no-op if already monotonic
	switch_in_progress_ = true;

	const int target = desired_track_;
	const double prime_seconds = position_;

	// Call reselect_audio_track on the backend under the scheduler's
	// per-stream exclusion. This tears down and rebuilds ONLY the audio
	// decode path (plus the video reader in AVF's case, but the FrameQueue
	// still has buffered frames so the caller keeps presenting without
	// interruption).
	bool ok = false;
	DecodeScheduler::instance().with_backend(
			stream_, [&](Backend &backend) {
				ok = backend.reselect_audio_track(target, prime_seconds);
			});

	if (!ok) {
		// Reselect failed: the Backend contract leaves the audio decode path
		// undefined on failure (on AVF this can even leave no readers at
		// all), so we cannot assume the old track is still playable. Roll
		// the desired selection back to what is still live and force a seek
		// to recover, per the Backend contract.
		desired_track_ = live_track_;
		switch_in_progress_ = false;
		clock_->reanchor_to_audio();
		std::ostringstream oss;
		oss << "Audio track switch to " << target << " failed; recovering via seek.";
		warn(oss.str());
		DecodeScheduler::instance().request_seek(stream_, position_);
		return;
	}

	// Clear the audio ring so stale samples from the old track don't play
	// into the new track's first chunks. fill_audio() re-anchors the clock
	// when the first chunk from the new track arrives.
	live_track_ = desired_track_;
	audio_ring_->clear();
	audio_eos_ = false;
}

void PlaybackController::request_audio_track(int idx) {
	// Validate out-of-range: the stock VideoStreamPlayer calls this before
	// play() to pre-select a track, and while playing for mid-stream switch.
	if (audio_track_count_ > 0 && (idx < 0 || idx >= audio_track_count_)) {
		std::ostringstream oss;
		oss << "Audio track index " << idx << " is out of range. Clip has "
			<< audio_track_count_ << " track(s). Falling back to default (0).";
		warn(oss.str());
		idx = 0;
	}

	if (idx == desired_track_) {
		return;
	}

	// Mid-stream sample-rate refusal: the canonical mix format and
	// AudioMasterClock are fixed to the clip's canonical rate and cannot
	// change mid-stream, so a switch to a differing-rate track is refused
	// outright (while stopped/pre-play there is no live audio path yet to
	// disturb, so the switch is allowed and validated again at load-derived
	// canonical-rate time).
	if (playing_ && has_audio_ && static_cast<size_t>(idx) < track_infos_.size() &&
			track_infos_[static_cast<size_t>(idx)].sample_rate != canonical_sample_rate_) {
		std::ostringstream oss;
		oss << "Cannot switch to audio track " << idx << ": sample rate "
			<< track_infos_[static_cast<size_t>(idx)].sample_rate
			<< " Hz differs from the canonical rate " << canonical_sample_rate_
			<< " Hz. Rejecting switch.";
		warn(oss.str());
		return;
	}

	desired_track_ = idx;

	// Stopped / pre-play: apply immediately (cheap — deferred in the
	// backend until its next seek). While playing or paused, tick()
	// reconciles on its next call (it already runs while paused).
	if (!playing_) {
		reconcile_audio_track();
	}
}

std::optional<VideoFrame> PlaybackController::tick(double delta_seconds, WallClockMs now, MixSink &sink) {
	Clock *clock = master();
	if (!loaded_ || !clock || !stream_) {
		return std::nullopt;
	}

	// Settle check runs regardless of play/pause: scrubbing commonly happens
	// while paused (dragging a timeline). Once a fast drag has gone quiet
	// for the debounce window, upgrade the approximate keyframe frame to the
	// exact target frame.
	if (std::optional<ScrubResolve> settle = scrubber_.poll(now.ms)) {
		apply_scrub_resolve(*settle);
	}

	// Reconcile any pending track switch. This runs even while paused so a
	// switch requested mid-pause (or during a scrub) is picked up promptly.
	reconcile_audio_track();

	if (!playing_ || paused_) {
		return std::nullopt;
	}
	DecodeScheduler &sched = DecodeScheduler::instance();

	// Always advance the clock bridge: when audio-master this is a no-op
	// (AudioMasterClock ignores advance()), but in monotonic-master mode —
	// a silent clip, or the handoff window during a track switch — it keeps
	// video advancing through the silence.
	clock->advance(delta_seconds);

	// One clock rule: advance from real audio samples when any exist; once
	// no more can ever come (a shorter audio track fully drained —
	// legitimate in real-world files), advance by the render delta instead.
	// The gate on !advanced_from_audio keeps the last partial ring drain
	// from double-advancing (real leftover frames + delta on the same
	// tick). The is_audio_master() gate keeps this from stacking on top of
	// the bridge advance() above while in monotonic-master mode.
	bool advanced_from_audio = false;
	if (has_audio_) {
		// drive_audio() calls clock_->on_audio_mixed() from the samples
		// actually consumed — the ClockBridge delegates to AudioMasterClock
		// when audio-master and is a no-op during the monotonic handoff.
		fill_audio();
		advanced_from_audio = drive_audio(sink);
	}
	if (clock_->is_audio_master() && !advanced_from_audio && audio_exhausted()) {
		clock->set_time(clock->media_time() + delta_seconds);
	}
	const double media_now = clock->media_time();

	// Video decode-ahead is driven by the shared pool's worker(s); the
	// queue is topped up off the pool's threads. We only consume here.

	// --- Present step: drop-late / hold-early, via the Godot-free selector ---
	//
	// We peek the head/next PTS (consumer-side, non-destructive) so frame
	// order is never disturbed, then act on the selector's decision:
	//   * Drop  — head is stale (a newer due frame exists): pop+release it, loop.
	//   * Show  — head is the correct frame for `media_now`: pop and present it.
	//   * Hold  — head is in the future: present nothing new, keep current frame.
	const double frame_interval = 1.0 / 30.0; // nominal; refined when fps is known
	std::optional<VideoFrame> chosen;

	for (;;) {
		std::optional<double> head_pts = sched.peek_head_pts(stream_);
		if (!head_pts.has_value()) {
			break; // queue empty -> hold the current frame
		}
		std::optional<double> next_pts = sched.peek_next_pts(stream_);

		PresentAction action =
				select_present_action(head_pts, next_pts, media_now, frame_interval);

		if (action == PresentAction::Drop) {
			// Head is stale: pop and retire it, then re-evaluate the new head.
			std::optional<VideoFrame> stale = sched.next_frame(stream_);
			if (stale.has_value() && stale->release) {
				stale->release();
			}
			continue;
		}

		if (action == PresentAction::Show) {
			// Newest due frame: pop and present it. (Drop already collapsed
			// any backlog, so this is the only due frame.)
			chosen = sched.next_frame(stream_);
		}

		// Show or Hold both end the present scan for this tick.
		break;
	}

	if (chosen.has_value()) {
		position_ = chosen->pts_seconds;
	}

	// End-of-playback: video stream drained (Backend EOS + empty queue) and
	// audio fully consumed. at_end() reflects the worker-reported EOS for
	// our stream.
	if (sched.at_end(stream_) && audio_exhausted()) {
		playing_ = false;
	}

	return chosen;
}

} // namespace core
