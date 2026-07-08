#pragma once

// -----------------------------------------------------------------------
// playback_controller.h — Godot-free per-stream playback state machine.
//
// The Binding (NativeVideoStreamPlayback) owns exactly one of these per
// playback and translates its inputs/outputs to Godot types. No godot_cpp
// includes, no RenderingDevice, no AudioServer — the controller talks to
// the mixer via the MixSink seam, to the decoder via the shared
// DecodeScheduler, and surfaces warnings via take_warnings(). tick()
// returns the frame to present BY VALUE; the caller owns the GPU present
// and the frame's release().
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

// Bounded backoff for the Exact-resolve forward-decode spin in
// apply_scrub_resolve(). The spin waits for the decode pool worker to top
// the queue up to the exact scrub target. A pure yield loop (the old
// kMaxSpins=100000) can hot-loop on a loaded machine; instead we yield a
// bounded number of times (cheap, sub-ms latency), then sleep in small
// increments (bounded CPU), then give up and let the present step converge
// on the next ticks. Total wall-clock ceiling is roughly
// kScrubMaxYieldSpins yields + kScrubMaxSleepSpins * kScrubSpinSleep.
inline constexpr int kScrubMaxYieldSpins = 100;
inline constexpr int kScrubMaxSleepSpins = 1000;
// 0.1 ms per sleep iteration — responsive without burning a core.
inline constexpr double kScrubSpinSleepMs = 100.0;

// MixSink — the one Godot-touching seam the controller calls through.
// Returns the frames it actually ACCEPTED; that count is the back-pressure
// signal the controller's clock-advance accounting keys on (it advances by
// min(accepted, real_frames) so neither underrun silence nor a full
// downstream buffer inflates media time). The Binding wraps mix_audio().
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

	// Takes ownership of an already-open()'d backend (path resolution is a
	// Godot concern the Binding handles) and derives the Canonical Mix Format,
	// builds the master clock, and registers with the shared DecodeScheduler.
	// A pre-load request_audio_track() selection is validated and applied here.
	void load(std::unique_ptr<Backend> backend, double audio_output_latency_seconds);

	// Unregisters from the scheduler, blocking until any in-flight decode
	// slice completes (no use-after-free). Safe to call multiple times; the
	// Binding calls it before tearing down its own GPU resources.
	void shutdown();

	bool is_loaded() const { return loaded_; }
	double length() const { return length_; }
	int width() const { return width_; }
	int height() const { return height_; }
	Colorimetry colorimetry() const { return color_; }

	// Canonical Mix Format, stable for the playback's lifetime once load()
	// returns. See canonical_mix_format.h for the mixed-sample-rate limitation.
	int canonical_channels() const { return canonical_channels_; }
	int canonical_sample_rate() const { return canonical_sample_rate_; }

	// --- Transport ---

	void play(WallClockMs now);
	void stop();
	void set_paused(bool paused);
	bool is_playing() const { return playing_; }
	bool is_paused() const { return paused_; }
	double position() const { return position_; }

	// Master-clock media time — the clock the present-selector compares
	// frames against. Distinct from position() (the PTS of the most recently
	// PRESENTED video frame).
	double media_time() const {
		const Clock *c = master();
		return c ? c->media_time() : 0.0;
	}

	// Feeds the scrubber and applies the resulting resolve (keyframe or exact).
	void seek(double time_seconds, WallClockMs now);

	// Refuses a mid-stream switch to a track whose sample rate differs from
	// the canonical rate (the mix format is fixed for the lifetime); applies
	// immediately when stopped/pre-load, otherwise defers to the next tick().
	void request_audio_track(int idx);
	int desired_audio_track() const { return desired_track_; }
	int live_audio_track() const { return live_track_; }

	// Returns the frame to present this tick (BY VALUE), or nullopt when not
	// loaded / not playing / paused. The caller owns the GPU present and the
	// frame's release().
	std::optional<VideoFrame> tick(double delta_seconds, WallClockMs now, MixSink &sink);

	// Drains warnings queued since the last call. The controller has no
	// logging dependency; the caller surfaces these (e.g. print_error()).
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

	// See canonical_mix_format.h. canonical_sample_rate_ is the FIRST
	// audio-bearing track's rate, NOT shared across tracks.
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
