#include "vendor/doctest.h"

#include "../../src/core/channel_mixer.h"

#include <vector>

using core::mix_channels;

// Helper: compare two float vectors with tolerance.
static bool approx_eq(const std::vector<float> &a, const std::vector<float> &b, float eps = 1e-6f) {
	if (a.size() != b.size())
		return false;
	for (size_t i = 0; i < a.size(); ++i) {
		if (std::abs(a[i] - b[i]) > eps)
			return false;
	}
	return true;
}

// -----------------------------------------------------------------------
// Identity / passthrough
// -----------------------------------------------------------------------

TEST_CASE("mix_channels passthrough same channel count (1->1)") {
	std::vector<float> in = { 0.5f, -0.25f, 1.0f };
	std::vector<float> out(3, -999.0f);
	mix_channels(in.data(), 1, out.data(), 1, 3);
	CHECK(out[0] == doctest::Approx(0.5f));
	CHECK(out[1] == doctest::Approx(-0.25f));
	CHECK(out[2] == doctest::Approx(1.0f));
}

TEST_CASE("mix_channels passthrough same channel count (2->2)") {
	std::vector<float> in = { 1.0f, 2.0f, 3.0f, 4.0f };
	std::vector<float> out(4, -999.0f);
	mix_channels(in.data(), 2, out.data(), 2, 2);
	CHECK(approx_eq(in, out));
}

TEST_CASE("mix_channels passthrough same channel count (6->6)") {
	std::vector<float> in = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 };
	std::vector<float> out(12, -999.0f);
	mix_channels(in.data(), 6, out.data(), 6, 2);
	CHECK(approx_eq(in, out));
}

TEST_CASE("mix_channels empty frame_count writes nothing") {
	std::vector<float> in = { 1.0f, 2.0f };
	std::vector<float> out = { 999.0f, 999.0f };
	mix_channels(in.data(), 2, out.data(), 1, 0);
	CHECK(out[0] == doctest::Approx(999.0f));
	CHECK(out[1] == doctest::Approx(999.0f));
}

TEST_CASE("mix_channels degenerate src_channels writes nothing") {
	std::vector<float> in = { 1.0f, 2.0f };
	std::vector<float> out = { 999.0f, 999.0f };
	mix_channels(in.data(), 0, out.data(), 2, 1);
	CHECK(out[0] == doctest::Approx(999.0f));
	CHECK(out[1] == doctest::Approx(999.0f));
}

// -----------------------------------------------------------------------
// Mono -> Stereo
// -----------------------------------------------------------------------

TEST_CASE("mix_channels mono to stereo") {
	// 3 mono frames: C = 0.5, -0.25, 1.0
	std::vector<float> in = { 0.5f, -0.25f, 1.0f };
	std::vector<float> out(6, -999.0f);
	mix_channels(in.data(), 1, out.data(), 2, 3);
	// Each mono frame should duplicate to both L and R.
	CHECK(out[0] == doctest::Approx(0.5f));
	CHECK(out[1] == doctest::Approx(0.5f));
	CHECK(out[2] == doctest::Approx(-0.25f));
	CHECK(out[3] == doctest::Approx(-0.25f));
	CHECK(out[4] == doctest::Approx(1.0f));
	CHECK(out[5] == doctest::Approx(1.0f));
}

// -----------------------------------------------------------------------
// Mono -> 5.1
// -----------------------------------------------------------------------

TEST_CASE("mix_channels mono to 5.1") {
	// 2 mono frames: C = 0.8, -0.4
	std::vector<float> in = { 0.8f, -0.4f };
	std::vector<float> out(12, 0.0f);
	mix_channels(in.data(), 1, out.data(), 6, 2);
	// Only C (index 2) should be set; L, R, LFE, Ls, Rs remain 0.
	CHECK(out[0] == doctest::Approx(0.0f)); // L
	CHECK(out[1] == doctest::Approx(0.0f)); // R
	CHECK(out[2] == doctest::Approx(0.8f)); // C
	CHECK(out[3] == doctest::Approx(0.0f)); // LFE
	CHECK(out[4] == doctest::Approx(0.0f)); // Ls
	CHECK(out[5] == doctest::Approx(0.0f)); // Rs

	CHECK(out[6] == doctest::Approx(0.0f));  // L
	CHECK(out[7] == doctest::Approx(0.0f));  // R
	CHECK(out[8] == doctest::Approx(-0.4f)); // C
	CHECK(out[9] == doctest::Approx(0.0f));  // LFE
	CHECK(out[10] == doctest::Approx(0.0f)); // Ls
	CHECK(out[11] == doctest::Approx(0.0f)); // Rs
}

// -----------------------------------------------------------------------
// Stereo -> Mono
// -----------------------------------------------------------------------

TEST_CASE("mix_channels stereo to mono") {
	// 3 stereo frames: (L,R) = (1,0), (0,1), (0.5,0.5)
	std::vector<float> in = { 1.0f, 0.0f, 0.0f, 1.0f, 0.5f, 0.5f };
	std::vector<float> out(3, -999.0f);
	mix_channels(in.data(), 2, out.data(), 1, 3);
	// Mono = 0.5*(L+R)
	CHECK(out[0] == doctest::Approx(0.5f)); // 0.5*(1 + 0)
	CHECK(out[1] == doctest::Approx(0.5f)); // 0.5*(0 + 1)
	CHECK(out[2] == doctest::Approx(0.5f)); // 0.5*(0.5 + 0.5)
}

// -----------------------------------------------------------------------
// Stereo -> 5.1
// -----------------------------------------------------------------------

TEST_CASE("mix_channels stereo to 5.1") {
	// 2 stereo frames: (0.6, 0.4), (-0.2, 0.9)
	std::vector<float> in = { 0.6f, 0.4f, -0.2f, 0.9f };
	std::vector<float> out(12, -999.0f);
	mix_channels(in.data(), 2, out.data(), 6, 2);
	// L -> L, R -> R; C, LFE, Ls, Rs remain 0.
	CHECK(out[0] == doctest::Approx(0.6f));  // L
	CHECK(out[1] == doctest::Approx(0.4f));  // R
	CHECK(out[2] == doctest::Approx(0.0f));  // C
	CHECK(out[3] == doctest::Approx(0.0f));  // LFE
	CHECK(out[4] == doctest::Approx(0.0f));  // Ls
	CHECK(out[5] == doctest::Approx(0.0f));  // Rs

	CHECK(out[6] == doctest::Approx(-0.2f)); // L
	CHECK(out[7] == doctest::Approx(0.9f));  // R
	CHECK(out[8] == doctest::Approx(0.0f));  // C
}

// -----------------------------------------------------------------------
// 5.1 -> Stereo (ITU-R BS.775 downmix)
// -----------------------------------------------------------------------

TEST_CASE("mix_channels 5.1 to stereo downmix") {
	// One 5.1 frame: L=1, R=0, C=0, LFE=0, Ls=0, Rs=0
	// Lt = 1 + 0.707*0 + 0.707*0 = 1
	// Rt = 0 + 0.707*0 + 0.707*0 = 0
	std::vector<float> in = { 1.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f };
	std::vector<float> out(2, -999.0f);
	mix_channels(in.data(), 6, out.data(), 2, 1);
	CHECK(out[0] == doctest::Approx(1.0f));
	CHECK(out[1] == doctest::Approx(0.0f));
}

TEST_CASE("mix_channels 5.1 to stereo centre bleeds into both channels") {
	// L=0, R=0, C=1 -> Lt = 0.707*1, Rt = 0.707*1
	std::vector<float> in = { 0.0f, 0.0f, 1.0f, 0.0f, 0.0f, 0.0f };
	std::vector<float> out(2, -999.0f);
	mix_channels(in.data(), 6, out.data(), 2, 1);
	CHECK(out[0] == doctest::Approx(0.707f));
	CHECK(out[1] == doctest::Approx(0.707f));
}

TEST_CASE("mix_channels 5.1 to stereo surrounds bleed into opposite") {
	// Ls=1 -> Lt = 0.707*1, Rt = 0
	std::vector<float> in = { 0.0f, 0.0f, 0.0f, 0.0f, 1.0f, 0.0f };
	std::vector<float> out(2, -999.0f);
	mix_channels(in.data(), 6, out.data(), 2, 1);
	CHECK(out[0] == doctest::Approx(0.707f));
	CHECK(out[1] == doctest::Approx(0.0f));
}

TEST_CASE("mix_channels 5.1 to stereo LFE excluded") {
	// Only LFE=1 at full scale -> nothing in stereo output.
	std::vector<float> in = { 0.0f, 0.0f, 0.0f, 1.0f, 0.0f, 0.0f };
	std::vector<float> out(2, -999.0f);
	mix_channels(in.data(), 6, out.data(), 2, 1);
	CHECK(out[0] == doctest::Approx(0.0f));
	CHECK(out[1] == doctest::Approx(0.0f));
}

TEST_CASE("mix_channels 5.1 to stereo complex signal") {
	// L=0.5, R=0.3, C=0.2, LFE=0.1, Ls=0.4, Rs=0.6
	// Lt = 0.5 + 0.707*0.2 + 0.707*0.4 = 0.5 + 0.1414 + 0.2828 = 0.9242
	// Rt = 0.3 + 0.707*0.2 + 0.707*0.6 = 0.3 + 0.1414 + 0.4242 = 0.8656
	std::vector<float> in = { 0.5f, 0.3f, 0.2f, 0.1f, 0.4f, 0.6f };
	std::vector<float> out(2, -999.0f);
	mix_channels(in.data(), 6, out.data(), 2, 1);
	CHECK(out[0] == doctest::Approx(0.9242f));
	CHECK(out[1] == doctest::Approx(0.8656f));
}

// -----------------------------------------------------------------------
// 5.1 -> Mono
// -----------------------------------------------------------------------

TEST_CASE("mix_channels 5.1 to mono centre-only") {
	// C=1 only -> M = 1/3.414 ≈ 0.2929
	std::vector<float> in = { 0.0f, 0.0f, 1.0f, 0.0f, 0.0f, 0.0f };
	std::vector<float> out(1, -999.0f);
	mix_channels(in.data(), 6, out.data(), 1, 1);
	CHECK(out[0] == doctest::Approx(1.0f / 3.414f));
}

TEST_CASE("mix_channels 5.1 to mono all channels active") {
	// L=1, R=0.5, C=0.8, LFE=10 (ignored), Ls=0.3, Rs=0.2
	// M = (1 + 0.5 + 0.8 + 0.707*(0.3 + 0.2)) / 3.414
	//   = (2.3 + 0.3535) / 3.414 = 2.6535 / 3.414 ≈ 0.7772
	std::vector<float> in = { 1.0f, 0.5f, 0.8f, 10.0f, 0.3f, 0.2f };
	std::vector<float> out(1, -999.0f);
	mix_channels(in.data(), 6, out.data(), 1, 1);
	float expected = (1.0f + 0.5f + 0.8f + 0.707f * (0.3f + 0.2f)) / 3.414f;
	CHECK(out[0] == doctest::Approx(expected));
}

TEST_CASE("mix_channels 5.1 to mono LFE excluded from 5.1") {
	// Full-scale LFE alone -> mono is silence.
	std::vector<float> in = { 0.0f, 0.0f, 0.0f, 1.0f, 0.0f, 0.0f };
	std::vector<float> out(1, -999.0f);
	mix_channels(in.data(), 6, out.data(), 1, 1);
	CHECK(out[0] == doctest::Approx(0.0f));
}

// -----------------------------------------------------------------------
// Determinism: same input always produces same output
// -----------------------------------------------------------------------

TEST_CASE("mix_channels is deterministic") {
	std::vector<float> in = { 0.3f, 0.7f, 0.2f, 1.0f, 0.1f, 0.5f };

	std::vector<float> a(2, 0.0f);
	std::vector<float> b(2, 0.0f);

	mix_channels(in.data(), 6, a.data(), 2, 1);
	mix_channels(in.data(), 6, b.data(), 2, 1);

	CHECK(a[0] == doctest::Approx(b[0]));
	CHECK(a[1] == doctest::Approx(b[1]));
}

// -----------------------------------------------------------------------
// Multiple frames
// -----------------------------------------------------------------------

TEST_CASE("mix_channels converts multiple frames correctly") {
	// 2 stereo frames -> mono.
	std::vector<float> in = { 1.0f, 0.0f, 0.0f, 1.0f };
	std::vector<float> out(2, -999.0f);
	mix_channels(in.data(), 2, out.data(), 1, 2);
	CHECK(out[0] == doctest::Approx(0.5f));
	CHECK(out[1] == doctest::Approx(0.5f));
}

// -----------------------------------------------------------------------
// Unrecognised layouts: generic copy-min-channels fallback.
//
// These are the total-contract regression cases: the mixer must never write
// past frame_count * dst_channels floats, and must never leave destination
// channels beyond src_channels uninitialized garbage — it zeros them.
// -----------------------------------------------------------------------

TEST_CASE("mix_channels 8ch source to 6ch dst never overflows the dst buffer") {
	// This is the heap-overflow regression: an 8-channel source (e.g. 7.1)
	// mixed into a 6-channel canonical dst must write exactly
	// frame_count * 6 floats, never frame_count * 8.
	const int frame_count = 4;
	const int src_channels = 8;
	const int dst_channels = 6;

	std::vector<float> in(static_cast<size_t>(frame_count) * src_channels);
	for (size_t i = 0; i < in.size(); ++i) {
		in[i] = static_cast<float>(i + 1);
	}

	// dst sized exactly for the contract, plus canary floats past the end.
	const size_t dst_size = static_cast<size_t>(frame_count) * dst_channels;
	const int canary_count = 4;
	std::vector<float> out(dst_size + canary_count, 999.0f);

	mix_channels(in.data(), src_channels, out.data(), dst_channels, frame_count);

	// First dst_channels samples of each frame equal the source's first
	// dst_channels samples.
	for (int f = 0; f < frame_count; ++f) {
		for (int c = 0; c < dst_channels; ++c) {
			CHECK(out[static_cast<size_t>(f) * dst_channels + c] ==
					doctest::Approx(in[static_cast<size_t>(f) * src_channels + c]));
		}
	}

	// Canary region past the dst buffer must be untouched.
	for (size_t i = dst_size; i < dst_size + canary_count; ++i) {
		CHECK(out[i] == doctest::Approx(999.0f));
	}
}

TEST_CASE("mix_channels 5ch to 2ch copies first two channels only") {
	std::vector<float> in = { 1.0f, 2.0f, 3.0f, 4.0f, 5.0f };
	std::vector<float> out(2, -999.0f);
	mix_channels(in.data(), 5, out.data(), 2, 1);
	CHECK(out[0] == doctest::Approx(1.0f));
	CHECK(out[1] == doctest::Approx(2.0f));
}

TEST_CASE("mix_channels 2ch to 5ch copies two channels and zeros the rest") {
	std::vector<float> in = { 0.6f, 0.4f };
	std::vector<float> out(5, -999.0f);
	mix_channels(in.data(), 2, out.data(), 5, 1);
	CHECK(out[0] == doctest::Approx(0.6f));
	CHECK(out[1] == doctest::Approx(0.4f));
	CHECK(out[2] == doctest::Approx(0.0f));
	CHECK(out[3] == doctest::Approx(0.0f));
	CHECK(out[4] == doctest::Approx(0.0f));
}

TEST_CASE("mix_channels 3ch to 3ch uses the memcpy fast path") {
	std::vector<float> in = { 0.1f, 0.2f, 0.3f, 0.4f, 0.5f, 0.6f };
	std::vector<float> out(6, -999.0f);
	mix_channels(in.data(), 3, out.data(), 3, 2);
	CHECK(approx_eq(in, out));
}

TEST_CASE("mix_channels degenerate frame_count and src_channels write nothing (canary check)") {
	std::vector<float> in = { 1.0f, 2.0f, 3.0f };
	std::vector<float> out(3, 999.0f);

	mix_channels(in.data(), 3, out.data(), 3, 0);
	CHECK(out[0] == doctest::Approx(999.0f));
	CHECK(out[1] == doctest::Approx(999.0f));
	CHECK(out[2] == doctest::Approx(999.0f));

	mix_channels(in.data(), 0, out.data(), 3, 1);
	CHECK(out[0] == doctest::Approx(999.0f));
	CHECK(out[1] == doctest::Approx(999.0f));
	CHECK(out[2] == doctest::Approx(999.0f));
}