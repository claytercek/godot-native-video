#include "vendor/doctest.h"

#include "../../src/core/audio_ring.h"

#include <vector>

using core::AudioRing;

TEST_CASE("AudioRing starts empty") {
	AudioRing r(2, 1024);
	CHECK(r.channel_count() == 2);
	CHECK(r.empty());
	CHECK(r.available_frames() == 0);
}

TEST_CASE("AudioRing round-trips interleaved stereo frames") {
	AudioRing r(2, 64);
	// 3 stereo frames: L,R per frame.
	std::vector<float> in = { 1, 2, 3, 4, 5, 6 };
	CHECK(r.write(in.data(), 3) == 3);
	CHECK(r.available_frames() == 3);

	std::vector<float> out(6, -1.0f);
	CHECK(r.read_frames(out.data(), 3) == 3);
	CHECK(out == in);
	CHECK(r.empty());
}

TEST_CASE("AudioRing underrun produces silence and reports real frame count") {
	AudioRing r(1, 64);
	std::vector<float> in = { 7, 8 };
	CHECK(r.write(in.data(), 2) == 2);

	std::vector<float> out(5, 99.0f);
	// Ask for 5 mono frames but only 2 are available.
	size_t real = r.read_frames(out.data(), 5);
	CHECK(real == 2);
	CHECK(out[0] == doctest::Approx(7.0f));
	CHECK(out[1] == doctest::Approx(8.0f));
	// Underrun tail is silence.
	CHECK(out[2] == doctest::Approx(0.0f));
	CHECK(out[3] == doctest::Approx(0.0f));
	CHECK(out[4] == doctest::Approx(0.0f));
}

TEST_CASE("AudioRing full read on empty ring is all silence") {
	AudioRing r(2, 16);
	std::vector<float> out(8, 1.0f);
	CHECK(r.read_frames(out.data(), 4) == 0);
	for (float v : out) {
		CHECK(v == doctest::Approx(0.0f));
	}
}

TEST_CASE("AudioRing write drops samples that do not fit (never grows/blocks)") {
	AudioRing r(1, 4); // 4 frames of head-room
	std::vector<float> in = { 1, 2, 3, 4, 5, 6 };
	size_t stored = r.write(in.data(), 6);
	CHECK(stored <= 4);
	CHECK(r.available_frames() == stored);
}

TEST_CASE("AudioRing clear discards buffered audio") {
	AudioRing r(2, 32);
	std::vector<float> in = { 1, 2, 3, 4 };
	r.write(in.data(), 2);
	CHECK(r.available_frames() == 2);
	r.clear();
	CHECK(r.empty());
	CHECK(r.available_frames() == 0);
}

TEST_CASE("AudioRing wraps around correctly") {
	AudioRing r(1, 8);
	std::vector<float> a = { 1, 2, 3, 4, 5, 6 };
	r.write(a.data(), 6);
	std::vector<float> out(4, 0.0f);
	r.read_frames(out.data(), 4); // consume 4 -> head advances
	// Now write 6 more, forcing wrap-around past the buffer end.
	std::vector<float> b = { 10, 11, 12, 13, 14, 15 };
	size_t stored = r.write(b.data(), 6);
	// remaining: {5,6} + as many of b as fit.
	std::vector<float> drained(16, 0.0f);
	size_t real = r.read_frames(drained.data(), 2 + stored);
	CHECK(real == 2 + stored);
	CHECK(drained[0] == doctest::Approx(5.0f));
	CHECK(drained[1] == doctest::Approx(6.0f));
	CHECK(drained[2] == doctest::Approx(10.0f));
}
