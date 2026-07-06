// -----------------------------------------------------------------------
// test_colorimetry.cpp — regression coverage for core::Colorimetry, the
// single struct that replaced the five parallel scalar colorimetry fields
// on core::VideoFrame and the five separate virtuals on core::Backend.
//
// Pins the two default conventions that must coexist:
//   - Per-frame (VideoFrame::color): Colorimetry{} defaults to all
//     Unspecified, 8-bit — the shader treats Unspecified as BT.709 video
//     range.
//   - Negotiated (Backend::colorimetry() and backend impls):
//     bt709_defaults() returns concrete BT709/BT709/BT709/Video/8 values.
// -----------------------------------------------------------------------

#include "vendor/doctest.h"

#include "../../src/core/backend.h"

using core::Backend;
using core::ColorMatrix;
using core::ColorPrimaries;
using core::ColorRange;
using core::Colorimetry;
using core::TransferFunction;

TEST_CASE("Colorimetry default-constructs to the per-frame Unspecified convention") {
	Colorimetry color;
	CHECK(color.matrix == ColorMatrix::Unspecified);
	CHECK(color.primaries == ColorPrimaries::Unspecified);
	CHECK(color.transfer == TransferFunction::Unspecified);
	CHECK(color.range == ColorRange::Unspecified);
	CHECK(color.bit_depth == 8);
}

TEST_CASE("Colorimetry::bt709_defaults() returns the negotiated-default convention") {
	Colorimetry color = Colorimetry::bt709_defaults();
	CHECK(color.matrix == ColorMatrix::BT709);
	CHECK(color.primaries == ColorPrimaries::BT709);
	CHECK(color.transfer == TransferFunction::BT709);
	CHECK(color.range == ColorRange::Video);
	CHECK(color.bit_depth == 8);
}

namespace {

// Minimal stub implementing only the pure virtuals of core::Backend, so the
// base class's default colorimetry() implementation is exercised untouched.
class StubBackend final : public Backend {
public:
	bool open(const std::string &) override { return true; }
	void close() override {}

	double duration_seconds() const override { return 0.0; }
	int video_width() const override { return 0; }
	int video_height() const override { return 0; }
	int audio_channel_count() const override { return 0; }
	int audio_sample_rate() const override { return 0; }

	bool seek(double) override { return true; }
	std::optional<core::VideoFrame> next_video_frame() override { return std::nullopt; }
	std::optional<core::AudioChunk> next_audio_chunk() override { return std::nullopt; }
};

} // namespace

TEST_CASE("Backend::colorimetry() base implementation returns the negotiated defaults") {
	StubBackend backend;
	Colorimetry color = backend.colorimetry();
	CHECK(color.matrix == ColorMatrix::BT709);
	CHECK(color.primaries == ColorPrimaries::BT709);
	CHECK(color.transfer == TransferFunction::BT709);
	CHECK(color.range == ColorRange::Video);
	CHECK(color.bit_depth == 8);
}
