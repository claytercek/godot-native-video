#pragma once

#include <cmath>
#include <optional>

namespace core {

// -----------------------------------------------------------------------
// scrubber.h — Godot-free adaptive-scrubbing state machine (Engine Core).
//
// Godot drives seeking with nothing but repeated VideoStreamPlayback::_seek(time)
// calls. There is no "drag started / drag ended" signal: a rapid BURST of seeks
// is a user dragging the playhead, and a GAP (or a playback resume) means they
// settled. The Scrubber turns that bare stream of (target, wall-clock-now) seek
// events into a decision about HOW to resolve each seek (Plan D11, CONTEXT.md
// "Scrub vs Seek"):
//
//   * KEYFRAME (fast feedback) — during a fast drag burst we only want to decode
//     + present the nearest keyframe at/just-before each target. Skipping the
//     inter-frame decode-forward gives near-instant visual feedback while the
//     user is still moving, even though the shown frame is approximate.
//
//   * EXACT (precise) — when the user is moving slowly, or has SETTLED (a
//     debounced ~80-120ms gap with no new seek), or playback resumes, we resolve
//     to the exact target PTS (seek the preceding keyframe, decode forward to the
//     target). Correctness over latency once motion stops.
//
// THRESHOLDS (all tunable via ScrubConfig, covered by the unit test):
//   * velocity_threshold — media-seconds of target movement per wall-second
//     between two consecutive seeks. At/above this, and within the burst window,
//     the seek is treated as part of a fast drag (Keyframe). Below it, Exact.
//   * burst_window_ms — two seeks farther apart than this in wall time do not
//     form a burst; the later one starts fresh and resolves Exact.
//   * settle_debounce_ms — wall time with no new seek after which the scrub is
//     considered settled; poll() then emits a single Exact resolve at the last
//     target so the final on-screen frame is precise.
//
// TIME IS INJECTED (now_ms wall-clock milliseconds) so the state machine is
// deterministic and unit-testable with no real clock — same pattern as
// present_selector.h. The binding feeds it a monotonic millisecond timestamp.
//
// NO Godot / RenderingDevice / Backend types here — pure policy. The binding
// maps a Keyframe resolve to a tolerant keyframe seek (the existing
// DecodeScheduler::request_seek path) and an Exact resolve to a precise
// seek-and-decode-forward to the target PTS.
// -----------------------------------------------------------------------

// How a seek target should be resolved.
enum class ResolveMode {
	Keyframe, // Fast: present the nearest keyframe at/before the target.
	Exact, // Precise: decode forward to the exact target PTS.
};

// The decision the Scrubber returns for a seek (or a settle/resume event).
struct ScrubResolve {
	ResolveMode mode = ResolveMode::Exact;
	double target_seconds = 0.0;
};

// Tunable thresholds. Defaults sit in the middle of the issue's guidance band and
// can be overridden by the binding / a project setting.
struct ScrubConfig {
	// Wall ms of quiet after the last seek before the scrub is considered settled.
	double settle_debounce_ms = 100.0;
	// Two seeks more than this far apart (wall ms) do not form a drag burst.
	double burst_window_ms = 120.0;
	// Target movement (media seconds) per wall second at/above which a seek inside
	// the burst window counts as a fast drag (Keyframe). Below this -> Exact.
	double velocity_threshold = 2.0;
};

class Scrubber {
public:
	Scrubber() = default;
	explicit Scrubber(const ScrubConfig &config) :
			config_(config) {}

	const ScrubConfig &config() const { return config_; }

	// Feed one _seek(target) event observed at wall time `now_ms`. Returns how this
	// seek should be resolved RIGHT NOW (Keyframe for a fast drag, Exact otherwise).
	// Records the target/time so a later poll() can detect a settle.
	ScrubResolve on_seek(double target_seconds, double now_ms) {
		ScrubResolve out;
		out.target_seconds = target_seconds;

		if (have_prev_) {
			const double dt_ms = now_ms - prev_now_ms_;
			// A burst requires the previous seek to be recent. A non-positive or
			// zero gap can't yield a meaningful velocity, so treat it conservatively
			// as a continuation of the current burst at "infinite" speed.
			const bool within_burst = dt_ms <= config_.burst_window_ms;
			bool fast = false;
			if (within_burst) {
				if (dt_ms <= 0.0) {
					// Same-instant seeks during a drag: treat as fast.
					fast = true;
				} else {
					const double velocity =
							std::fabs(target_seconds - prev_target_) / (dt_ms / 1000.0);
					fast = velocity >= config_.velocity_threshold;
				}
			}
			out.mode = fast ? ResolveMode::Keyframe : ResolveMode::Exact;
		} else {
			// No prior seek to measure velocity against: a lone seek (timeline click)
			// resolves exactly.
			out.mode = ResolveMode::Exact;
		}

		prev_target_ = target_seconds;
		prev_now_ms_ = now_ms;
		have_prev_ = true;
		last_resolve_mode_ = out.mode;
		// A keyframe scrub leaves an approximate frame on screen, so it still owes a
		// precise resolve once motion settles. An exact resolve is already precise.
		settle_pending_ = (out.mode == ResolveMode::Keyframe);
		return out;
	}

	// Called each tick (or on a timer) with the current wall time. If the scrub has
	// settled — at least `settle_debounce_ms` since the last seek AND the last seek
	// was an approximate keyframe scrub — returns a one-shot Exact resolve at the
	// last target so the final frame is precise. Returns nullopt otherwise. Fires at
	// most once per settle; re-armed by the next keyframe scrub.
	std::optional<ScrubResolve> poll(double now_ms) {
		if (!settle_pending_ || !have_prev_) {
			return std::nullopt;
		}
		if (now_ms - prev_now_ms_ < config_.settle_debounce_ms) {
			return std::nullopt; // still within the debounce window
		}
		settle_pending_ = false;
		ScrubResolve out;
		out.mode = ResolveMode::Exact;
		out.target_seconds = prev_target_;
		return out;
	}

	// Playback is resuming. Force an immediate Exact resolve at the last scrub
	// target so play starts from the precise frame, and consume any pending settle.
	ScrubResolve on_resume(double now_ms) {
		(void)now_ms;
		settle_pending_ = false;
		ScrubResolve out;
		out.mode = ResolveMode::Exact;
		out.target_seconds = have_prev_ ? prev_target_ : 0.0;
		last_resolve_mode_ = ResolveMode::Exact;
		return out;
	}

	// Introspection for tests / instrumentation.
	bool settle_pending() const { return settle_pending_; }
	ResolveMode last_resolve_mode() const { return last_resolve_mode_; }

private:
	ScrubConfig config_{};

	bool have_prev_ = false;
	double prev_target_ = 0.0;
	double prev_now_ms_ = 0.0;

	bool settle_pending_ = false;
	ResolveMode last_resolve_mode_ = ResolveMode::Exact;
};

} // namespace core
