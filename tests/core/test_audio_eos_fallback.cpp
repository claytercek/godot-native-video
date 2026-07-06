#include "vendor/doctest.h"

#include "../../src/core/clock.h"
#include "../../src/core/present_selector.h"

#include <algorithm>
#include <cmath>
#include <deque>
#include <optional>

// -----------------------------------------------------------------------
// Audio-EOS wall-clock fallback (a201p68c) — no Godot, no GPU.
//
// A clip's audio track can legitimately end before its video track (mismatched
// track durations are common in real-world files). The audio-master clock only
// advances from real samples consumed (on_audio_mixed()); once the backend
// stops producing real audio frames for good, nothing will ever call
// on_audio_mixed() again, so the clock would freeze permanently unless
// something else advances it.
//
// This models exactly what PlatformVideoStreamPlayback::_update() does: each
// tick, drive_audio() advances the clock by whatever real frames are left
// (down to a partial final block, matching the real ring-drains-mid-block
// case); only once a tick had NO real frames left does the fallback advance
// the clock by wall-clock delta instead (AudioMasterClock::set_time()) — the
// two are mutually exclusive per tick, exactly like the production code's
// `if (!advanced_from_audio && audio_eos_ && ...)` gate.
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
// it on, this reproduces PlatformVideoStreamPlayback::_update()'s mutually
// exclusive real-advance-or-fallback gate; with it off, it reproduces the
// pre-fix behavior (audio_eos_ latches and nothing ever advances the clock).
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
		const bool audio_eos = real_frames_consumed >= total_real_frames;
		if (apply_fallback && !advanced_from_audio && audio_eos) {
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
	// Demonstrates the PRE-FIX behavior (audio_eos_ latches and nothing ever
	// advances the clock again) — guards against silently reintroducing it.
	const SimResult result = simulate(/*apply_fallback=*/false);

	// The clip never reaches its last frame: playback is stuck at the frame
	// nearest the audio cutoff.
	CHECK(result.shown_pts < (kTotalFrames - 1) * kFrameInterval);
	CHECK(result.shown_pts <= kAudioEndSeconds);
}
