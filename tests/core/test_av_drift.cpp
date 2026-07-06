#include "vendor/doctest.h"

#include "../../src/core/clock.h"
#include "../../src/core/present_selector.h"

#include <algorithm>
#include <cmath>
#include <deque>
#include <optional>
#include <random>
#include <vector>

// -----------------------------------------------------------------------
// A/V drift simulation — the key correctness gate for this slice.
//
// Model (no Godot, no GPU, fully deterministic with a fixed RNG seed):
//
//   * The MASTER CLOCK is the AudioMasterClock. We "consume" audio in fixed
//     mix blocks (like Godot's AudioServer pulling a buffer), each call
//     advancing the clock by block_frames / sample_rate. This is exactly how
//     the binding drives the clock from real audio consumption.
//
//   * A simulated DECODE THREAD delivers video frames into a decode-ahead
//     buffer (a std::deque of PTS values, FIFO/PTS-ordered like the binding's
//     FrameQueue). Frame N has the ideal PTS N*frame_interval, but it ARRIVES
//     with INDUCED JITTER: a random, sometimes large delay relative to when it
//     "should" have been decoded. A deliberate JITTER SPIKE stalls decode
//     entirely for a span of ticks to test recovery (a decode hiccup).
//
//   * Each render tick we run the REAL present-selector (drop-late/hold-early)
//     against the buffer head/next and the master clock, applying its decisions
//     (Drop pops the head; Show presents the head; Hold keeps the current
//     frame). We record the PTS of whatever frame is on screen.
//
// Assertions:
//   (a) Steady state: once frames are flowing, the presented PTS stays within
//       half a frame interval of the master clock (the standard "in sync"
//       budget — a frame is correct for ~its own display interval).
//   (b) Recovery: after the jitter spike drains, the player catches back up to
//       within the steady-state budget within a bounded number of ticks (it
//       does NOT drift permanently — drop-late collapses the backlog).
// -----------------------------------------------------------------------

namespace {

constexpr int kSampleRate = 48000;
constexpr double kFps = 30.0;
constexpr double kFrameInterval = 1.0 / kFps;

// Audio mix block size (frames per AudioServer pull). 512 @ 48k ~= 10.7 ms.
constexpr int kMixBlock = 512;
constexpr double kBlockSeconds = static_cast<double>(kMixBlock) / kSampleRate;

// Consume ~one frame-interval of audio per render tick so the clock advances at
// real rate (2 blocks @ ~10.7 ms ~= 21.3 ms ~ slightly under one 30fps frame;
// close enough that the decoder must keep up).
constexpr int kBlocksPerTick = 2;

// Apply the selector to the decode buffer for the current clock time and return
// the PTS now on screen (or the held value if nothing new is due).
double run_present(std::deque<double> &buf, double now, double held_pts) {
	double shown = held_pts;
	for (;;) {
		std::optional<double> head =
				buf.empty() ? std::nullopt : std::optional<double>(buf.front());
		std::optional<double> next =
				buf.size() >= 2 ? std::optional<double>(buf[1]) : std::nullopt;

		core::PresentAction a =
				core::select_present_action(head, next, now, kFrameInterval);
		if (a == core::PresentAction::Drop) {
			buf.pop_front(); // discard stale head, re-evaluate
			continue;
		}
		if (a == core::PresentAction::Show) {
			shown = buf.front();
			buf.pop_front();
		}
		// Hold or Show both terminate the tick.
		break;
	}
	return shown;
}

} // namespace

TEST_CASE("A/V drift stays within budget under induced decode jitter") {
	(void)kBlockSeconds;

	// Master clock: audio-master, with a realistic output-latency comp.
	const double latency = 0.020; // 20 ms, like AudioServer::get_output_latency()
	core::AudioMasterClock clock(kSampleRate, latency);
	clock.set_paused(false);

	std::deque<double> buf; // decode-ahead PTS buffer (PTS-ordered)
	std::mt19937 rng(1234567u); // fixed seed -> deterministic
	// Jitter: each frame's arrival is perturbed +/- ~0.75 frame around its
	// nominal ready time. Arrivals stay monotonic (we max against the previous).
	std::uniform_real_distribution<double> jitter(-0.75 * kFrameInterval, 0.75 * kFrameInterval);

	const int kTicks = 1500;
	const int kTotalFrames = 3000;

	// `wall` is real elapsed time; it advances by exactly the audio duration we
	// consume each tick, the same quantity that drives the master clock. The
	// decoder produces frames against `wall` (real time), the clock reads media
	// time off consumed audio — when in sync the two track each other.
	const double kTickSeconds = kBlocksPerTick * kBlockSeconds;
	double wall = 0.0;

	// DECODE SCHEDULE: frame N is "intended" to be ready at N*interval of wall
	// time, but lands at a jittered offset. We give the decoder a real LEAD by
	// shifting the schedule earlier by a few frames so frames arrive before the
	// clock needs them (decode-ahead).
	const double kDecodeLead = 4.0 * kFrameInterval;
	int next_frame = 0;
	double last_ready = -1.0; // monotonic arrival guard
	double shown_pts = -1.0; // nothing on screen yet

	// Hard decode stall (jitter spike): no frames arrive for this span of wall
	// time, then the decoder sprints to catch up afterwards.
	const int kSpikeStart = 500;
	const int kSpikeEnd = 540; // ~40 ticks of total stall
	const double spike_begin_wall = kSpikeStart * kTickSeconds;
	const double spike_end_wall = kSpikeEnd * kTickSeconds;

	std::vector<double> steady_drift;
	double peak_post_spike = 0.0;
	double during_spike_peak = 0.0;
	int ticks_to_recover = -1;

	for (int tick = 0; tick < kTicks; ++tick) {
		// --- advance master clock from consumed audio, and wall time in lockstep ---
		for (int b = 0; b < kBlocksPerTick; ++b) {
			clock.on_audio_mixed(kMixBlock);
		}
		wall += kTickSeconds;
		const double now = clock.media_time();

		// --- decode: deliver every frame whose jittered ready time has passed ---
		while (next_frame < kTotalFrames) {
			// Nominal ready time, shifted earlier by the decode lead, plus jitter.
			double ready = next_frame * kFrameInterval - kDecodeLead + jitter(rng);
			ready = std::max(ready, last_ready); // arrivals are monotonic
			// During the stall window, nothing becomes ready; frames that were
			// scheduled inside it pile up and all land at spike_end_wall.
			if (ready >= spike_begin_wall && ready < spike_end_wall) {
				ready = spike_end_wall;
			}
			if (ready > wall) {
				break; // not ready yet this tick
			}
			buf.push_back(next_frame * kFrameInterval);
			last_ready = ready;
			++next_frame;
		}

		// --- present (drop-late / hold-early) ---
		shown_pts = run_present(buf, now, shown_pts);

		// --- record drift ---
		if (shown_pts >= 0.0) {
			const double drift = std::fabs(now - shown_pts);
			if (tick < kSpikeStart) {
				if (tick > 30) { // skip warm-up
					steady_drift.push_back(drift);
				}
			} else {
				// From the stall onward: the held frame goes stale as the buffer
				// drains, so drift grows during the spike; once frames flow again
				// drop-late collapses the backlog and drift returns to budget.
				// We measure recovery from kSpikeEnd (when frames resume).
				if (tick >= kSpikeEnd) {
					peak_post_spike = std::max(peak_post_spike, drift);
					if (ticks_to_recover < 0 && drift <= 0.5 * kFrameInterval) {
						ticks_to_recover = tick - kSpikeEnd;
					}
				}
				during_spike_peak = std::max(during_spike_peak, drift);
			}
		}
	}

	REQUIRE_FALSE(steady_drift.empty());

	// (a) Steady-state budget: presented PTS within half a frame of the clock.
	double max_steady = 0.0, sum = 0.0;
	for (double d : steady_drift) {
		max_steady = std::max(max_steady, d);
		sum += d;
	}
	const double mean_steady = sum / steady_drift.size();
	MESSAGE("steady-state max drift = " << max_steady << "s ("
										<< (max_steady / kFrameInterval) << " frames), mean = "
										<< mean_steady << "s; budget = " << (0.5 * kFrameInterval) << "s");
	CHECK(max_steady <= 0.5 * kFrameInterval);

	// (b) Recovery after the spike: catch back up, and quickly.
	MESSAGE("during-spike peak drift = " << during_spike_peak << "s ("
										 << (during_spike_peak / kFrameInterval) << " frames); recovered "
										 << ticks_to_recover << " ticks after spike; peak post-spike drift = "
										 << peak_post_spike << "s (" << (peak_post_spike / kFrameInterval) << " frames)");
	// The spike must actually induce out-of-budget drift, else recovery is vacuous.
	CHECK(during_spike_peak > 0.5 * kFrameInterval);
	CHECK(ticks_to_recover >= 0); // did recover
	CHECK(ticks_to_recover <= 60); // bounded recovery (~< 1 s of ticks)
}
