#pragma once

// -----------------------------------------------------------------------
// playback_controller.h — the per-stream Engine Core orchestrator.
//
// Godot-free: no godot_cpp includes, no RenderingDevice, no AudioServer. This
// is the "Playback Controller" of the glossary — the Binding
// (NativeVideoStreamPlayback) owns exactly one per playback and translates
// its inputs/outputs to Godot types. Composes the pieces that already lived
// in the Engine Core (ClockBridge, AudioRing, Scrubber, DecodeScheduler,
// select_present_action, mix_channels) into the state machines that used to
// live inline in the Binding's _update():
//
//   * Canonical Mix Format derivation at load() time.
//   * Track Switch reconciliation: rollback of the desired track when the
//     backend refuses a reselect, and the Clock Bridge handoff.
//   * Audio drive: ring top-up, end-of-stream detection, and clock advance
//     by accepted-and-real frames only (mix back-pressure accounting) via
//     the MixSink seam.
//   * Scrub resolution: keyframe-vs-exact, bounded forward-decode.
//   * The present-selection loop: Drop/Show/Hold plumbing around the
//     already-tested select_present_action(), returning the chosen frame BY
//     VALUE from tick() — the caller performs all GPU calls.
//
// SEAMS:
//   * MixSink — the one virtual call the controller makes into "the mixer".
//     Its return value carries the accepted-frame count, which is exactly
//     the back-pressure signal the clock-advance accounting needs. The
//     Binding's implementation wraps VideoStreamPlayback::mix_audio().
//   * Decode — injected through the existing DecodeScheduler registration
//     seam (register_stream / with_backend / next_frame / peek_*_pts /
//     request_seek / at_end); the controller depends on the same process-
//     wide scheduler the Binding used directly before this extraction.
//   * Audio output latency is a plain double parameter to load() rather than
//     a live AudioServer query — the Binding resolves it once and hands it
//     in.
//   * Warnings (out-of-range track index, a mixed-sample-rate clip, a failed
//     mid-stream reselect) are queued via take_warnings() rather than
//     printed directly — this class has no logging dependency of its own;
//     the Binding drains the queue and calls print_error().
// -----------------------------------------------------------------------

#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "audio_ring.h"
#include "backend.h"
#include "canonical_mix_format.h"
#include "clock.h"
#include "decode_scheduler.h"
#include "scrubber.h"
#include "wall_clock.h"

namespace core {

// -----------------------------------------------------------------------
// MixSink — the one Godot-touching seam the controller calls through.
//
// `interleaved` carries `frame_count * channel_count` interleaved float32
// samples in the Canonical Mix Format. The sink returns the number of
// frames it actually ACCEPTED (<= frame_count) — e.g. the return value of
// Godot's VideoStreamPlayback::mix_audio(). The controller advances its
// master clock by min(accepted, real_frames_read_from_the_ring) only, so
// neither underrun silence nor a full downstream buffer inflates media time.
// -----------------------------------------------------------------------
class MixSink {
public:
	virtual ~MixSink() = default;
	virtual int mix(const float *interleaved, int frame_count, int channel_count) = 0;
};

// -----------------------------------------------------------------------
// PlaybackController — Godot-free per-stream playback state machine.
// -----------------------------------------------------------------------
class PlaybackController {
public:
	PlaybackController() = default;
	~PlaybackController();

	PlaybackController(const PlaybackController &) = delete;
	PlaybackController &operator=(const PlaybackController &) = delete;

	// --- Load ---
	//
	// Takes ownership of `backend` (already open()'d by the caller — path
	// resolution is a Godot concern the Binding handles). Derives the
	// Canonical Mix Format from the backend's audio tracks, builds the
	// master clock (audio-master using `audio_output_latency_seconds` for
	// latency compensation when the clip has audio; monotonic otherwise),
	// and registers the backend with the shared DecodeScheduler. A pending
	// pre-load audio-track selection made via request_audio_track() before
	// load() is validated and cheaply applied here.
	void load(std::unique_ptr<Backend> backend, double audio_output_latency_seconds);

	// Unregisters the stream from the shared DecodeScheduler, blocking until
	// any in-flight decode slice completes. Safe to call multiple times.
	// Called automatically by the destructor; the Binding calls it early
	// (before tearing down its own GPU-facing resources) to match the
	// original teardown order.
	void shutdown();

	bool is_loaded() const { return loaded_; }
	double length() const { return length_; }
	int width() const { return width_; }
	int height() const { return height_; }
	Colorimetry colorimetry() const { return color_; }

	// Canonical Mix Format, stable for the playback's lifetime once load()
	// returns. Godot queries these exactly once at play start.
	int canonical_channels() const { return canonical_channels_; }
	int canonical_sample_rate() const { return canonical_sample_rate_; }

	// --- Transport ---

	void play(WallClockMs now);
	void stop();
	void set_paused(bool paused);
	bool is_playing() const { return playing_; }
	bool is_paused() const { return paused_; }
	double position() const { return position_; }

	// The master clock's current media time (audio-master when audio is
	// present, monotonic otherwise). Distinct from position(), which is the
	// PTS of the most recently PRESENTED video frame; media_time() is the
	// clock the present-selector compares frames against.
	double media_time() const {
		const Clock *c = master();
		return c ? c->media_time() : 0.0;
	}

	// --- Seek / scrub ---
	//
	// Feeds the scrubber and applies the resulting resolve (keyframe or exact).
	void seek(double time_seconds, WallClockMs now);

	// --- Audio track selection ---
	//
	// Validates range and (while playing) refuses a mid-stream switch to a
	// track whose sample rate differs from the canonical rate, then applies
	// immediately (stopped/pre-load) or defers to the next tick() (playing
	// or paused).
	void request_audio_track(int idx);
	int desired_audio_track() const { return desired_track_; }
	int live_audio_track() const { return live_track_; }

	// --- Per-frame drive ---
	//
	// Advances the clock, resolves any pending scrub settle, reconciles any
	// pending track switch, drives audio through `sink`, and runs the
	// present-selection loop. Returns the frame to present this tick, if
	// any — the caller performs the actual GPU present and owns the frame's
	// release() from here on. A no-op (returns nullopt) when not loaded, not
	// playing, or paused.
	std::optional<VideoFrame> tick(double delta_seconds, WallClockMs now, MixSink &sink);

	// --- Diagnostics ---
	//
	// Drains and returns any warnings queued since the last call (out-of-
	// range track index, a mixed-sample-rate clip, a failed mid-stream
	// reselect). The controller has no logging dependency of its own; the
	// caller surfaces these however it likes (e.g. print_error()).
	std::vector<std::string> take_warnings();

private:
	void reconcile_audio_track();
	void apply_scrub_resolve(const ScrubResolve &resolve);
	void fill_audio();
	bool drive_audio(MixSink &sink);

	// advance_master_clock — the one-clock rule: advance the master clock by
	// exactly one source per tick, never two. When audio is present and drove
	// the clock (`advanced_from_audio`), that is the one advance. When audio
	// is master but exhausted (no more real samples will ever come — a
	// shorter audio track fully drained, a legitimate real-world case), fall
	// back to the render delta. The gates prevent double-advance: the
	// `!advanced_from_audio` gate keeps the last partial ring drain from
	// stacking real frames + delta; the `is_audio_master()` gate keeps this
	// from stacking on top of the bridge advance() while in monotonic-master
	// mode. Reordering these conditions would silently break A/V sync — the
	// three "one-clock rule" tests pin the behavior.
	void advance_master_clock(double delta_seconds, bool advanced_from_audio);
	bool audio_exhausted() const;
	Clock *master() const { return clock_.get(); }
	void warn(std::string message);

	StreamHandle stream_;
	Scrubber scrubber_;
	std::unique_ptr<ClockBridge> clock_;
	std::unique_ptr<AudioRing> audio_ring_;

	// Scratch buffers kept as members to avoid per-call allocations on the
	// decode/mix path (resized only when a larger buffer is needed).
	std::vector<float> mix_scratch_; // fill_audio()'s channel-mix scratch
	std::vector<float> drive_scratch_; // drive_audio()'s ring-read scratch handed to MixSink

	bool loaded_ = false;
	bool playing_ = false;
	bool paused_ = false;
	// Video end-of-stream is tracked by the shared scheduler (at_end()), so
	// this only tracks audio EOS for the end-of-playback condition.
	bool audio_eos_ = false;
	bool has_audio_ = false; // clip carries an audio track -> audio is master
	int audio_track_count_ = 0; // cached from the backend at load time
	double length_ = 0.0;
	double position_ = 0.0; // PTS of the most recently presented frame

	int width_ = 0;
	int height_ = 0;
	Colorimetry color_;

	// Canonical Mix Format: canonical_channels_ is the maximum channel count
	// across all audio tracks (clamped to kMaxMixSourceChannels).
	// canonical_sample_rate_ is the FIRST audio-bearing track's rate, NOT a
	// shared rate across tracks — mixed-sample-rate clips are a documented
	// limitation (load() warns once if a later track differs; a mid-stream
	// switch to a differing rate is refused).
	int canonical_channels_ = 0;
	int canonical_sample_rate_ = 0;

	// --- Audio track reconcile state ---
	//
	// desired_track_ and live_track_ converge by construction via
	// reconcile_audio_track(): desired_track_ is what the caller asked for
	// (via request_audio_track()), live_track_ is what the backend is
	// actually decoding. They can disagree only between a request and the
	// next reconcile; a failed reselect rolls desired_track_ back to
	// live_track_ instead of leaving the two permanently out of sync.
	int desired_track_ = 0;
	int live_track_ = 0;

	// True between a mid-stream reselect and the first audio chunk from the
	// new track. During this window the ClockBridge is in monotonic-master
	// mode so video keeps advancing while audio is silent.
	bool switch_in_progress_ = false;

	// Per-track audio metadata cached at load time for sample-rate
	// validation during mid-stream track switches (the backend is behind
	// the scheduler's per-stream exclusion, so the info needed for the fast
	// path is cached here instead).
	std::vector<AudioTrackInfo> track_infos_;

	std::vector<std::string> warnings_;
};

} // namespace core
