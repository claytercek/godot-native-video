// playback_controller.cpp — see header.

#include "playback_controller.h"

#include "canonical_mix_format.h"
#include "channel_mixer.h"
#include "present_selector.h"

#include <algorithm>
#include <chrono>
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
	// Cached at open time from the track's format descriptions; per-frame CV
	// attachments may carry more accurate metadata at decode time.
	color_ = backend->colorimetry();
	length_ = backend->duration_seconds();
	width_ = backend->video_width();
	height_ = backend->video_height();
	audio_track_count_ = backend->audio_track_count();

	// --- Canonical Mix Format ---
	// Derived pure from the backend's audio tracks (no scheduler, no clock);
	// see canonical_mix_format.h for the mixed-sample-rate limitation. Done
	// before the backend moves into the scheduler, which takes ownership.
	CanonicalMixFormat fmt = derive_canonical_mix_format(*backend);
	canonical_channels_ = fmt.channels;
	canonical_sample_rate_ = fmt.sample_rate;
	has_audio_ = fmt.has_audio;
	track_infos_ = std::move(fmt.track_infos);
	for (std::string &w : fmt.warnings) {
		warn(std::move(w));
	}

	// Hand the Backend to the process-wide shared decode pool. From here a
	// pool worker decodes video ahead into stream_'s queue; this object
	// never touches the Backend directly except via the scheduler
	// (next_frame / with_backend).
	stream_ = DecodeScheduler::instance().register_stream(std::move(backend));

	if (has_audio_) {
		// Audio-master: latency-compensated so media_time() reflects what the
		// speaker is emitting, not what was just queued.
		auto audio = std::make_unique<AudioMasterClock>(canonical_sample_rate_, audio_output_latency_seconds);
		auto mono = std::make_unique<MonotonicClock>(0.0);
		clock_ = std::make_unique<ClockBridge>(std::move(audio), std::move(mono), /*audio_master=*/true);
		const size_t ring_frames = static_cast<size_t>(canonical_sample_rate_) / 2; // ~0.5 s head-room
		audio_ring_ = std::make_unique<AudioRing>(canonical_channels_, ring_frames);
	} else {
		// Silent clip: a null audio clock makes the bridge permanently
		// monotonic-master, so every audio-facing ClockBridge method is a
		// safe no-op.
		auto mono = std::make_unique<MonotonicClock>(0.0);
		clock_ = std::make_unique<ClockBridge>(nullptr, std::move(mono), /*audio_master=*/false);
	}

	loaded_ = true;
	position_ = 0.0;
	audio_eos_ = false;
	switch_in_progress_ = false;

	// A pre-load request_audio_track() selection must survive, not be
	// clobbered; validate it now that audio_track_count_ is known.
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

void PlaybackController::advance_master_clock(double delta_seconds, bool advanced_from_audio) {
	// See the header: this is the one-clock rule as a single named decision.
	if (!clock_ || !clock_->is_audio_master() || advanced_from_audio) {
		return;
	}
	if (!audio_exhausted()) {
		return;
	}
	clock_->set_time(clock_->media_time() + delta_seconds);
}

void PlaybackController::fill_audio() {
	if (!stream_ || !audio_ring_ || audio_eos_) {
		return;
	}
	// Pump under the scheduler's per-stream exclusion so we never race the
	// worker decoding video ahead on the same Backend.
	DecodeScheduler::instance().with_backend(stream_, [this](Backend &backend) {
		// Half-fill: cushion against decode jitter without buffering unbounded audio.
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
			// Mix native layout -> canonical (no-op memcpy when counts match).
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

	constexpr int kMaxMixFramesPerTick = 4096; // ~85 ms @ 48k

	const int ch = canonical_channels_;
	const size_t available = audio_ring_->available_frames();
	// On underrun, offer a small block of silence so the sink keeps its
	// buffer fed; the clock is NOT advanced for silence (read_frames reports
	// 0 real frames).
	int request = static_cast<int>(std::min<size_t>(
			available > 0 ? available : 256, kMaxMixFramesPerTick));

	const size_t needed = static_cast<size_t>(request) * static_cast<size_t>(ch);
	if (drive_scratch_.size() < needed) {
		drive_scratch_.resize(needed);
	}

	// Drain decoded PCM (or silence on underrun) into the staging buffer.
	const size_t real_frames =
			audio_ring_->read_frames(drive_scratch_.data(), static_cast<size_t>(request));

	// Advance the clock ONLY by frames both real (non-silence) AND consumed —
	// neither underrun silence nor a full downstream buffer inflates media
	// time. If the sink accepts fewer than `real_frames` (near-full
	// downstream buffer), the surplus is dropped: the clock stays honest at
	// the cost of a little lost audio. Tolerable for linear playback.
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
	// Resuming after a scrub: force an exact resolve at the last scrub target
	// so play starts from the precise frame, not an approximate keyframe one.
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
	// Flush + reseek to start (serialized against the worker).
	if (stream_) {
		DecodeScheduler::instance().request_seek(stream_, 0.0);
	}
	scrubber_ = Scrubber(scrubber_.config()); // no stale velocity/settle
	switch_in_progress_ = false;
	// Track selection persists across stop (desired_/live_track_ are NOT reset
	// here). If the caller stopped mid-switch, re-anchor so the bridge does
	// not stay monotonic-master forever with no fill_audio() to re-anchor it.
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
		// Decode forward past the keyframe to the exact target, dropping
		// earlier frames; bounded by the clip (stops at EOS). Runs on the
		// caller's thread only on settle/resume (not the hot per-frame path),
		// so a brief wait for the worker is acceptable. The wait uses bounded
		// backoff (kScrubMaxYieldSpins / kScrubMaxSleepSpins in the header): a
		// pure yield loop could hot-loop on a loaded machine.
		const double eps = 1.0 / 120.0; // ~half a frame at 60fps tolerance
		int yield_spins = 0;
		int sleep_spins = 0;
		const auto sleep_dur = std::chrono::microseconds(
				static_cast<int64_t>(kScrubSpinSleepMs * 1000.0));
		for (;;) {
			std::optional<double> head = sched.peek_head_pts(stream_);
			if (!head.has_value()) {
				if (sched.at_end(stream_)) {
					break; // EOS before the target — clamp.
				}
				if (yield_spins < kScrubMaxYieldSpins) {
					std::this_thread::yield();
					++yield_spins;
				} else if (sleep_spins < kScrubMaxSleepSpins) {
					std::this_thread::sleep_for(sleep_dur);
					++sleep_spins;
				} else {
					break; // worker stalled — give up, let present step converge.
				}
				continue;
			}
			yield_spins = 0;
			sleep_spins = 0;
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
		// Stopped / pre-play: cheap apply. Deferred in the backend until its
		// next seek — which play()'s scrub-resume resolve always issues first.
		const int target = desired_track_;
		DecodeScheduler::instance().with_backend(
				stream_, [target](Backend &backend) {
					backend.select_audio_track(target);
				});
		live_track_ = desired_track_;
		return;
	}

	// Playing (or paused — reselecting now primes the new reader at
	// position_ so resume is instant).
	if (!clock_ || !audio_ring_) {
		return;
	}

	clock_->handoff_to_monotonic(); // no-op if already monotonic
	switch_in_progress_ = true;

	const int target = desired_track_;
	const double prime_seconds = position_;

	// Reselect under the scheduler's per-stream exclusion. Tears down and
	// rebuilds ONLY the audio decode path (plus the video reader in AVF's
	// case, but the FrameQueue still has buffered frames so presenting is
	// uninterrupted).
	bool ok = false;
	DecodeScheduler::instance().with_backend(
			stream_, [&](Backend &backend) {
				ok = backend.reselect_audio_track(target, prime_seconds);
			});

	if (!ok) {
		// The Backend contract leaves the audio decode path undefined on
		// failure (on AVF this can even leave no readers at all), so the old
		// track is not safely playable. Roll desired back to what is still
		// live and force a seek to recover.
		desired_track_ = live_track_;
		switch_in_progress_ = false;
		clock_->reanchor_to_audio();
		std::ostringstream oss;
		oss << "Audio track switch to " << target << " failed; recovering via seek.";
		warn(oss.str());
		DecodeScheduler::instance().request_seek(stream_, position_);
		return;
	}

	// Clear stale samples; fill_audio() re-anchors when the new track flows.
	live_track_ = desired_track_;
	audio_ring_->clear();
	audio_eos_ = false;
}

void PlaybackController::request_audio_track(int idx) {
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

	// The canonical mix format and AudioMasterClock are fixed to the clip's
	// canonical rate and cannot change mid-stream, so a mid-stream switch to
	// a differing-rate track is refused outright (stopped/pre-play has no
	// live audio path yet, so it is allowed).
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

	// Stopped/pre-play applies immediately; playing/paused defers to the
	// next tick() (which runs while paused).
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

	// No-op when audio-master; keeps video advancing through monotonic-master
	// silence (silent clip, or the handoff window during a track switch).
	clock->advance(delta_seconds);

	// One clock rule: advance from real audio samples when any exist; once
	// no more can ever come (a shorter audio track fully drained — legitimate
	// in real-world files), advance by the render delta instead. Extracted
	// into advance_master_clock() so the rule is a single named concept a
	// future edit can't silently break by reordering the ifs.
	bool advanced_from_audio = false;
	if (has_audio_) {
		fill_audio();
		advanced_from_audio = drive_audio(sink);
	}
	advance_master_clock(delta_seconds, advanced_from_audio);
	const double media_now = clock->media_time();

	// --- Present step: drop-late / hold-early, via the Godot-free selector. ---
	// Peek head/next PTS non-destructively (frame order is never disturbed):
	//   * Drop  — head stale: pop+release, loop.
	//   * Show  — head is the due frame for `media_now`: pop and present it.
	//   * Hold  — head in the future: present nothing new.
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
			std::optional<VideoFrame> stale = sched.next_frame(stream_);
			if (stale.has_value() && stale->release) {
				stale->release();
			}
			continue;
		}

		if (action == PresentAction::Show) {
			chosen = sched.next_frame(stream_);
		}

		// Show or Hold both end the present scan for this tick.
		break;
	}

	if (chosen.has_value()) {
		position_ = chosen->pts_seconds;
	}

	// End-of-playback: video EOS (at_end() is worker-reported) and audio drained.
	if (sched.at_end(stream_) && audio_exhausted()) {
		playing_ = false;
	}

	return chosen;
}

} // namespace core
