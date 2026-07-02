#include "vendor/doctest.h"

#include "../../src/core/clock.h"

#include <cmath>

using core::AudioMasterClock;
using core::MonotonicClock;

// -----------------------------------------------------------------------
// MonotonicClock
// -----------------------------------------------------------------------

TEST_CASE("MonotonicClock starts at given initial time") {
	MonotonicClock c(0.0);
	CHECK(c.media_time() == doctest::Approx(0.0));

	MonotonicClock c2(1.5);
	CHECK(c2.media_time() == doctest::Approx(1.5));
}

TEST_CASE("MonotonicClock advance accumulates time") {
	MonotonicClock c;
	c.advance(0.016); // ~60 fps frame
	CHECK(c.media_time() == doctest::Approx(0.016).epsilon(1e-9));
	c.advance(0.016);
	CHECK(c.media_time() == doctest::Approx(0.032).epsilon(1e-9));
}

TEST_CASE("MonotonicClock ignores negative or zero delta") {
	MonotonicClock c(1.0);
	c.advance(-0.5);
	CHECK(c.media_time() == doctest::Approx(1.0));
	c.advance(0.0);
	CHECK(c.media_time() == doctest::Approx(1.0));
}

TEST_CASE("MonotonicClock set_time repositions the clock") {
	MonotonicClock c;
	c.advance(2.5);
	c.set_time(10.0);
	CHECK(c.media_time() == doctest::Approx(10.0));
}

TEST_CASE("MonotonicClock paused does not advance") {
	MonotonicClock c(5.0);
	c.set_paused(true);
	CHECK(c.is_paused());
	c.advance(1.0);
	CHECK(c.media_time() == doctest::Approx(5.0));
}

TEST_CASE("MonotonicClock resumes after unpause") {
	MonotonicClock c(0.0);
	c.set_paused(true);
	c.advance(1.0);
	c.set_paused(false);
	CHECK_FALSE(c.is_paused());
	c.advance(0.5);
	CHECK(c.media_time() == doctest::Approx(0.5));
}

TEST_CASE("MonotonicClock many small advances accumulate without drift") {
	MonotonicClock c(0.0);
	const int N = 10'000;
	const double delta = 1.0 / 60.0;
	for (int i = 0; i < N; ++i) {
		c.advance(delta);
	}
	// Allow a generous floating-point epsilon
	CHECK(c.media_time() == doctest::Approx(N * delta).epsilon(1e-6));
}

// -----------------------------------------------------------------------
// AudioMasterClock
// -----------------------------------------------------------------------

TEST_CASE("AudioMasterClock starts at zero") {
	AudioMasterClock c(48000, 0.0);
	CHECK(c.media_time() == doctest::Approx(0.0));
}

TEST_CASE("AudioMasterClock advances by sample count") {
	AudioMasterClock c(48000, 0.0);
	// 48000 frames / 48000 Hz = 1 second
	c.on_audio_mixed(48000);
	CHECK(c.media_time() == doctest::Approx(1.0).epsilon(1e-9));
}

TEST_CASE("AudioMasterClock accumulates multiple mix calls") {
	AudioMasterClock c(44100, 0.0);
	// 3 calls of 512 frames each
	c.on_audio_mixed(512);
	c.on_audio_mixed(512);
	c.on_audio_mixed(512);
	double expected = 3.0 * 512.0 / 44100.0;
	CHECK(c.media_time() == doctest::Approx(expected).epsilon(1e-9));
}

TEST_CASE("AudioMasterClock latency compensation shifts time back") {
	const double latency = 0.02; // 20 ms
	AudioMasterClock c(48000, latency);
	// Mix exactly the latency worth of audio; should still read 0 (clamped).
	c.on_audio_mixed(static_cast<int>(latency * 48000));
	CHECK(c.media_time() == doctest::Approx(0.0).epsilon(1e-9));

	// Mix another second; reported time should be 1 second behind the
	// accumulated time.
	c.on_audio_mixed(48000);
	CHECK(c.media_time() == doctest::Approx(1.0).epsilon(1e-4));
}

TEST_CASE("AudioMasterClock clamps to zero when latency exceeds accumulated") {
	AudioMasterClock c(48000, 0.1);
	c.on_audio_mixed(100); // tiny amount
	// 100/48000 ~ 2 ms < 100 ms latency => media_time should be 0
	CHECK(c.media_time() == doctest::Approx(0.0));
}

TEST_CASE("AudioMasterClock set_time repositions (e.g. after seek)") {
	AudioMasterClock c(48000, 0.0);
	c.on_audio_mixed(48000); // 1 s
	c.set_time(30.0);
	CHECK(c.media_time() == doctest::Approx(30.0));
}

TEST_CASE("AudioMasterClock paused does not advance on mix") {
	AudioMasterClock c(48000, 0.0);
	c.set_paused(true);
	c.on_audio_mixed(48000);
	CHECK(c.media_time() == doctest::Approx(0.0));
}

TEST_CASE("AudioMasterClock advance() is a no-op") {
	AudioMasterClock c(48000, 0.0);
	c.advance(999.0); // should be ignored
	CHECK(c.media_time() == doctest::Approx(0.0));
}

TEST_CASE("AudioMasterClock sample_rate and latency accessors") {
	AudioMasterClock c(44100, 0.05);
	CHECK(c.sample_rate() == 44100);
	CHECK(c.latency_seconds() == doctest::Approx(0.05));
}

// -----------------------------------------------------------------------
// ClockBridge
// -----------------------------------------------------------------------

using core::ClockBridge;

// Utility: create a bridge starting in audio-master mode.
static auto make_audio_bridge(double latency = 0.0) {
	return std::make_unique<ClockBridge>(
			std::make_unique<AudioMasterClock>(48000, latency),
			std::make_unique<MonotonicClock>(0.0),
			/*audio_master=*/true);
}

// Utility: create a bridge starting in monotonic-master mode.
static auto make_mono_bridge(double initial = 0.0) {
	return std::make_unique<ClockBridge>(
			std::make_unique<AudioMasterClock>(48000, 0.0),
			std::make_unique<MonotonicClock>(initial),
			/*audio_master=*/false);
}

TEST_CASE("ClockBridge starts as audio-master") {
	auto b = make_audio_bridge();
	CHECK(b->is_audio_master());
	CHECK(b->media_time() == doctest::Approx(0.0));
}

TEST_CASE("ClockBridge starts as monotonic-master") {
	auto b = make_mono_bridge(5.0);
	CHECK_FALSE(b->is_audio_master());
	CHECK(b->media_time() == doctest::Approx(5.0));
}

TEST_CASE("ClockBridge audio-master: advance is no-op, on_audio_mixed advances") {
	auto b = make_audio_bridge();
	b->advance(1.0);
	CHECK(b->media_time() == doctest::Approx(0.0));
	b->on_audio_mixed(48000); // 1 s
	CHECK(b->media_time() == doctest::Approx(1.0));
}

TEST_CASE("ClockBridge audio-master: on_audio_mixed accumulates") {
	auto b = make_audio_bridge();
	b->on_audio_mixed(48000);
	b->on_audio_mixed(24000);
	CHECK(b->media_time() == doctest::Approx(1.5));
}

TEST_CASE("ClockBridge handoff seeds monotonic at audio position") {
	auto b = make_audio_bridge();
	b->on_audio_mixed(48000); // 1 s
	b->handoff_to_monotonic();
	CHECK_FALSE(b->is_audio_master());
	// After handoff, the monotonic clock starts at the audio clock's position.
	CHECK(b->media_time() == doctest::Approx(1.0));
}

TEST_CASE("ClockBridge handoff is idempotent") {
	auto b = make_audio_bridge();
	b->on_audio_mixed(24000); // 0.5 s
	b->handoff_to_monotonic();
	CHECK_FALSE(b->is_audio_master());
	CHECK(b->media_time() == doctest::Approx(0.5));
	// Second handoff should be a no-op.
	b->handoff_to_monotonic();
	CHECK_FALSE(b->is_audio_master());
	CHECK(b->media_time() == doctest::Approx(0.5));
}

TEST_CASE("ClockBridge handoff then advance advances monotonic") {
	auto b = make_audio_bridge();
	b->on_audio_mixed(48000); // 1 s
	b->handoff_to_monotonic();
	b->advance(0.5);
	CHECK(b->media_time() == doctest::Approx(1.5));
}

TEST_CASE("ClockBridge re-anchor keeps position continuous") {
	auto b = make_audio_bridge();
	b->on_audio_mixed(48000); // 1 s
	b->handoff_to_monotonic();
	b->advance(2.0); // 3 s total
	b->reanchor_to_audio();
	CHECK(b->is_audio_master());
	// Position should be 3.0 — no backward jump.
	CHECK(b->media_time() == doctest::Approx(3.0).epsilon(1e-9));
}

TEST_CASE("ClockBridge re-anchor is idempotent") {
	auto b = make_audio_bridge();
	b->on_audio_mixed(24000); // 0.5 s
	b->handoff_to_monotonic();
	b->reanchor_to_audio();
	CHECK(b->is_audio_master());
	CHECK(b->media_time() == doctest::Approx(0.5));
	// Second re-anchor should be a no-op.
	b->reanchor_to_audio();
	CHECK(b->is_audio_master());
	CHECK(b->media_time() == doctest::Approx(0.5));
}

TEST_CASE("ClockBridge on_audio_mixed is no-op in monotonic mode") {
	auto b = make_audio_bridge();
	b->on_audio_mixed(24000); // 0.5 s
	b->handoff_to_monotonic();
	// on_audio_mixed while in monotonic mode should be ignored.
	b->on_audio_mixed(48000);
	CHECK(b->media_time() == doctest::Approx(0.5));
}

TEST_CASE("ClockBridge re-anchor then on_audio_mixed advances audio") {
	auto b = make_audio_bridge();
	b->on_audio_mixed(48000); // 1 s
	b->handoff_to_monotonic();
	b->advance(2.0); // 3 s
	b->reanchor_to_audio();
	b->on_audio_mixed(48000); // +1 s
	CHECK(b->media_time() == doctest::Approx(4.0).epsilon(1e-9));
}

TEST_CASE("ClockBridge long gap via monotonic") {
	// Simulates an arbitrarily long silent gap: handoff, advance by a large
	// delta, re-anchor. Position must be continuous.
	auto b = make_audio_bridge();
	b->on_audio_mixed(48000); // 1 s
	b->handoff_to_monotonic();
	b->advance(300.0); // 5 minute gap
	b->reanchor_to_audio();
	CHECK(b->media_time() == doctest::Approx(301.0).epsilon(1e-9));
	// Audio clock should now be master and can continue from 301 s.
	b->on_audio_mixed(48000); // +1 s
	CHECK(b->media_time() == doctest::Approx(302.0).epsilon(1e-9));
}

TEST_CASE("ClockBridge set_time synchronizes both clocks") {
	auto b = make_audio_bridge();
	b->on_audio_mixed(48000); // 1 s
	b->set_time(10.0);
	CHECK(b->media_time() == doctest::Approx(10.0));
	// Handoff after set_time: monotonic should be at 10.0 too.
	b->handoff_to_monotonic();
	CHECK(b->media_time() == doctest::Approx(10.0));
}

TEST_CASE("ClockBridge set_paused pauses both clocks") {
	auto b = make_audio_bridge();
	b->set_paused(true);
	CHECK(b->is_paused());
	// Neither audio nor monotonic should advance.
	b->on_audio_mixed(48000);
	CHECK(b->media_time() == doctest::Approx(0.0));
	// Handoff while paused, then advance — should stay put.
	b->handoff_to_monotonic();
	b->advance(1.0);
	CHECK(b->media_time() == doctest::Approx(0.0));
	// Unpause: monotonic should start advancing.
	b->set_paused(false);
	b->advance(0.5);
	CHECK(b->media_time() == doctest::Approx(0.5));
}

TEST_CASE("ClockBridge latency compensation works through bridge") {
	const double latency = 0.02; // 20 ms
	auto b = make_audio_bridge(latency);
	CHECK(b->latency_seconds() == doctest::Approx(latency));
	// Mix exactly the latency worth of audio; should still read 0.
	b->on_audio_mixed(static_cast<int>(latency * 48000));
	CHECK(b->media_time() == doctest::Approx(0.0));
	// Mix another second; reported time is 1 s behind accumulated.
	b->on_audio_mixed(48000);
	CHECK(b->media_time() == doctest::Approx(1.0).epsilon(1e-4));
	// Handoff seeds mono at the latency-compensated position.
	b->handoff_to_monotonic();
	CHECK(b->media_time() == doctest::Approx(1.0).epsilon(1e-4));
}

TEST_CASE("ClockBridge round-trip: audio → mono → audio → mono") {
	auto b = make_audio_bridge();
	// Phase 1: audio advances 1s.
	b->on_audio_mixed(48000);
	CHECK(b->media_time() == doctest::Approx(1.0));
	// Phase 2: handoff to mono, advance 2s.
	b->handoff_to_monotonic();
	b->advance(2.0);
	CHECK(b->media_time() == doctest::Approx(3.0));
	// Phase 3: re-anchor to audio, advance 1s via audio.
	b->reanchor_to_audio();
	b->on_audio_mixed(48000);
	CHECK(b->media_time() == doctest::Approx(4.0));
	// Phase 4: handoff back to mono, advance 0.5s.
	b->handoff_to_monotonic();
	b->advance(0.5);
	CHECK(b->media_time() == doctest::Approx(4.5));
}

TEST_CASE("ClockBridge sample_rate delegation") {
	auto b = make_audio_bridge();
	CHECK(b->sample_rate() == 48000);
}

// -----------------------------------------------------------------------
// ClockBridge — null audio clock (silent clips)
// -----------------------------------------------------------------------

// Utility: create a bridge with no audio clock at all.
static auto make_null_audio_bridge(double initial = 0.0, bool request_audio_master = true) {
	return std::make_unique<ClockBridge>(
			nullptr,
			std::make_unique<MonotonicClock>(initial),
			/*audio_master=*/request_audio_master);
}

TEST_CASE("ClockBridge with null audio forces monotonic-master") {
	auto b = make_null_audio_bridge(0.0, /*request_audio_master=*/true);
	CHECK_FALSE(b->is_audio_master());
}

TEST_CASE("ClockBridge with null audio: media_time advances via advance()") {
	auto b = make_null_audio_bridge();
	CHECK(b->media_time() == doctest::Approx(0.0));
	b->advance(1.0);
	CHECK(b->media_time() == doctest::Approx(1.0));
	b->advance(0.5);
	CHECK(b->media_time() == doctest::Approx(1.5));
}

TEST_CASE("ClockBridge with null audio: set_time and set_paused work") {
	auto b = make_null_audio_bridge();
	b->set_time(10.0);
	CHECK(b->media_time() == doctest::Approx(10.0));

	b->set_paused(true);
	CHECK(b->is_paused());
	b->advance(5.0);
	CHECK(b->media_time() == doctest::Approx(10.0));

	b->set_paused(false);
	b->advance(1.0);
	CHECK(b->media_time() == doctest::Approx(11.0));
}

TEST_CASE("ClockBridge with null audio: reanchor_to_audio is a safe no-op") {
	auto b = make_null_audio_bridge();
	b->advance(2.0);
	b->reanchor_to_audio();
	CHECK_FALSE(b->is_audio_master());
	CHECK(b->media_time() == doctest::Approx(2.0));
}

TEST_CASE("ClockBridge with null audio: on_audio_mixed is a safe no-op") {
	auto b = make_null_audio_bridge();
	b->advance(1.0);
	b->on_audio_mixed(48000);
	CHECK(b->media_time() == doctest::Approx(1.0));
}

TEST_CASE("ClockBridge with null audio: sample_rate and latency_seconds are zero") {
	auto b = make_null_audio_bridge();
	CHECK(b->sample_rate() == 0);
	CHECK(b->latency_seconds() == doctest::Approx(0.0));
}
