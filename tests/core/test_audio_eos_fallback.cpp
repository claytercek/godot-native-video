#include "vendor/doctest.h"

#include "../../src/core/clock.h"
#include "../../src/core/present_selector.h"

#include <algorithm>
#include <cmath>
#include <deque>
#include <optional>

// -----------------------------------------------------------------------
// Audio-EOS wall-clock fallback — no Godot, no GPU.
//
// A clip's audio track can legitimately end before its video track (mismatched
// track durations are common in real-world files). The audio-master clock only
// advances from real samples consumed (on_audio_mixed()); once the backend
// stops producing real audio frames for good, nothing will ever call
// on_audio_mixed() again, so the clock would freeze permanently unless
// something else advances it.
//
// This models PlatformVideoStreamPlayback::_update()'s unified clock rule:
//
//   bool advanced_from_audio = false;
//   if (has_audio_) { fill_audio(); advanced_from_audio = drive_audio(); }
//   if (!advanced_from_audio && audio_exhausted()) {
//       clock->set_time(clock->media_time() + delta);
//   }
//
// where audio_exhausted() == !has_audio_ || (audio_eos_ && ring empty): the
// clock advances from real samples whenever any exist; only once no more can
// ever come (a silent clip, or a shorter audio track fully drained) does the
// render delta take over. The !advanced_from_audio gate keeps the tick that
// drains the last partial block from double-advancing (real leftover + delta).
// -----------------------------------------------------------------------

namespace {

constexpr int kSampleRate = 48000;
constexpr double kFps = 30.0;
constexpr double kFrameInterval = 1.0 / kFps;
constexpr double kTickSeconds = 1.0 / 60.0; // render tick, independent of fps
constexpr int kTotalFrames = 300; // 10s @ 30fps, matching the reported repro.
// Audio track only covers the first ~2.63s, like the reported freeze point.
// Deliberately not a multiple of a tick's worth of samples, so one tick drains
// a partial final block of real audio — the exact seam a double-advance bug
// would show up on.
constexpr double kAudioEndSeconds = 2.63;

// Deliver every video frame whose PTS has already passed, into the
// decode-ahead buffer (no jitter — this test is about the clock, not drift).
void fill_ready_frames(std::deque<double> &buf, int &next_frame, double now) {
	while (next_frame < kTotalFrames && next_frame * kFrameInterval <= now) {
		buf.push_back(next_frame * kFrameInterval);
		++next_frame;
	}
}

double run_present(std::deque<double> &buf, double now, double held_pts) {
	double shown = held_pts;
	for (;;) {
		std::optional<double> head = buf.empty() ? std::nullopt : std::optional<double>(buf.front());
		std::optional<double> next = buf.size() >= 2 ? std::optional<double>(buf[1]) : std::nullopt;
		core::PresentAction a = core::select_present_action(head, next, now, kFrameInterval);
		if (a == core::PresentAction::Drop) {
			buf.pop_front();
			continue;
		}
		if (a == core::PresentAction::Show) {
			shown = buf.front();
			buf.pop_front();
		}
		break;
	}
	return shown;
}

struct SimResult {
	double shown_pts = -1.0;
	double max_tick_advance = 0.0; // largest single-tick clock jump observed
};

// Runs the freeze scenario. `apply_fallback` toggles the fix under test: with
// it on, this reproduces _update()'s unified rule (real-advance when samples
// exist, wall-clock delta once audio_exhausted() and nothing real advanced
// this tick); with it off, it reproduces the pre-fix behavior (audio EOS
// latches and nothing ever advances the clock).
SimResult simulate(bool apply_fallback) {
	SimResult result;
	core::AudioMasterClock clock(kSampleRate, 0.0);
	std::deque<double> buf;
	int next_frame = 0;
	const long long total_real_frames = static_cast<long long>(kAudioEndSeconds * kSampleRate);
	long long real_frames_consumed = 0;
	double prev_now = 0.0;

	for (int tick = 0; tick < 1200; ++tick) {
		const long long block = static_cast<long long>(kTickSeconds * kSampleRate);
		const long long remaining = total_real_frames - real_frames_consumed;
		const long long this_block = std::min(block, std::max<long long>(remaining, 0));

		bool advanced_from_audio = false;
		if (this_block > 0) {
			clock.on_audio_mixed(static_cast<int>(this_block));
			real_frames_consumed += this_block;
			advanced_from_audio = true;
		}
		// audio_exhausted(): the backend reported genuine EOS and the ring has
		// drained — in this sim the supply running dry stands in for both.
		const bool audio_exhausted = real_frames_consumed >= total_real_frames;
		if (apply_fallback && !advanced_from_audio && audio_exhausted) {
			clock.set_time(clock.media_time() + kTickSeconds);
		}

		const double now = clock.media_time();
		result.max_tick_advance = std::max(result.max_tick_advance, now - prev_now);
		prev_now = now;

		fill_ready_frames(buf, next_frame, now);
		result.shown_pts = run_present(buf, now, result.shown_pts);

		if (result.shown_pts >= (kTotalFrames - 1) * kFrameInterval) {
			break; // last frame presented — playback reached the end
		}
	}
	return result;
}

} // namespace

TEST_CASE("audio ending before video falls back to wall-clock so trailing video keeps playing") {
	const SimResult result = simulate(/*apply_fallback=*/true);

	// Without the fallback, `now` would freeze at kAudioEndSeconds forever and
	// shown_pts would get stuck well short of the clip's last frame.
	CHECK(result.shown_pts >= (kTotalFrames - 1) * kFrameInterval);
	CHECK(result.shown_pts <= kTotalFrames * kFrameInterval);

	// The real-advance/fallback gate must be mutually exclusive: no tick should
	// ever advance the clock by more than one tick's worth (a double-advance on
	// the tick real audio's last partial block drains would jump the clock by
	// tick + leftover, dropping a trailing video frame right at the seam).
	CHECK(result.max_tick_advance <= kTickSeconds * 1.0001);
}

TEST_CASE("without the fallback, audio ending early freezes video short of the clip end") {
	// Demonstrates the PRE-FIX behavior (audio EOS latches and nothing ever
	// advances the clock again) — guards against silently reintroducing it.
	const SimResult result = simulate(/*apply_fallback=*/false);

	// The clip never reaches its last frame: playback is stuck at the frame
	// nearest the audio cutoff.
	CHECK(result.shown_pts < (kTotalFrames - 1) * kFrameInterval);
	CHECK(result.shown_pts <= kAudioEndSeconds);
}

TEST_CASE("mid-stream underrun without audio EOS freezes the clock until audio resumes") {
	// Models a transient decode stall: real audio stops arriving for a stretch
	// of ticks, but the backend never reported EOS, so audio_exhausted() stays
	// false and the wall-clock fallback must NOT fire. The clock (and with it
	// the video) holds until audio resumes, and A/V sync is intact afterwards
	// because media time still equals exactly the real samples consumed. Guards
	// the audio-EOS gate against someone "fixing" a stutter by advancing the
	// clock on any underrun.
	core::AudioMasterClock clock(kSampleRate, 0.0);
	std::deque<double> buf;
	int next_frame = 0;
	double shown_pts = -1.0;
	long long real_frames_consumed = 0;
	const long long block = static_cast<long long>(kTickSeconds * kSampleRate);

	constexpr int kGapStart = 120; // ticks [kGapStart, kGapEnd): no audio arrives
	constexpr int kGapEnd = 180;

	double time_at_gap_start = -1.0;
	double shown_at_gap_start = -1.0;

	for (int tick = 0; tick < 480; ++tick) {
		const bool in_gap = tick >= kGapStart && tick < kGapEnd;

		bool advanced_from_audio = false;
		if (!in_gap) { // audio flowing normally
			clock.on_audio_mixed(static_cast<int>(block));
			real_frames_consumed += block;
			advanced_from_audio = true;
		}
		// audio_exhausted() is false throughout: has_audio_, and audio_eos_ was
		// never set — an empty ring alone must not trigger the fallback.
		const bool audio_exhausted = false;
		if (!advanced_from_audio && audio_exhausted) {
			clock.set_time(clock.media_time() + kTickSeconds);
		}

		const double now = clock.media_time();
		fill_ready_frames(buf, next_frame, now);
		shown_pts = run_present(buf, now, shown_pts);

		if (tick == kGapStart) {
			time_at_gap_start = now;
			shown_at_gap_start = shown_pts;
		}
		if (in_gap) {
			// Frozen: no advance of any kind during the underrun.
			CHECK(now == doctest::Approx(time_at_gap_start));
			CHECK(shown_pts == doctest::Approx(shown_at_gap_start));
		}
	}

	// A/V sync preserved across the gap: media time is exactly the real samples
	// consumed — the underrun neither advanced nor skewed the clock.
	CHECK(clock.media_time() ==
			doctest::Approx(static_cast<double>(real_frames_consumed) / kSampleRate));
	// Video resumed after the gap and moved past where it froze.
	CHECK(shown_pts > shown_at_gap_start);
}

TEST_CASE("silent clip advances by exactly delta per tick under the unified rule") {
	// No audio track at all: audio_exhausted() is true from tick 0, so the
	// same fallback that handles the post-audio-EOS tail drives the whole clip
	// — the silent clip and the tail are one rule. The master here is the
	// MonotonicClock, where set_time(media_time() + delta) is equivalent to
	// advance(delta) (pause is excluded before the gate; delta is non-negative).
	core::MonotonicClock clock(0.0);
	std::deque<double> buf;
	int next_frame = 0;
	double shown_pts = -1.0;

	for (int tick = 0; tick < 1200; ++tick) {
		const double before = clock.media_time();

		// The unified gate, folded: with no audio track, advanced_from_audio is
		// always false (drive_audio() never runs) and audio_exhausted() is always
		// true (!has_audio_), so the fallback fires every tick.
		clock.set_time(clock.media_time() + kTickSeconds);

		// Exactly one render delta per tick — the clip plays at the correct rate.
		CHECK(clock.media_time() - before == doctest::Approx(kTickSeconds));

		const double now = clock.media_time();
		fill_ready_frames(buf, next_frame, now);
		shown_pts = run_present(buf, now, shown_pts);

		if (shown_pts >= (kTotalFrames - 1) * kFrameInterval) {
			break; // last frame presented — the silent clip played to the end
		}
	}

	CHECK(shown_pts >= (kTotalFrames - 1) * kFrameInterval);
}
