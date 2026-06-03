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
