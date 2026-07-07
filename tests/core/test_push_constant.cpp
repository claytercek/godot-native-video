// -----------------------------------------------------------------------
// test_push_constant.cpp — byte-for-byte verification of the NV12→RGB
// compute shader push-constant packing.
//
// The GLSL shader declares a std430 push-constant block (seven uint32 +
// one float, 32 bytes). Every mismatch between the CPU-side packer and the
// shader's declared layout silently corrupts colour — no crash, no warning.
// These tests pin the exact byte sequence for known inputs so a layout typo
// is caught immediately.
// -----------------------------------------------------------------------

#include "vendor/doctest.h"

#include <cstring>
#include <cstdint>
#include <iomanip>
#include <sstream>
#include <string>

#include "push_constants.h"

using native_video::kPushConstantSize;
using native_video::pack_push_constants;

static_assert(kPushConstantSize == 32, "push-constant block must stay 32 bytes");

// -----------------------------------------------------------------------
// Helper: pack a known set of parameters and check every byte.
// -----------------------------------------------------------------------
static void check_packed_bytes(
		uint32_t width,
		uint32_t height,
		const core::Colorimetry &color,
		float sample_scale,
		const uint8_t *expected) {
	uint8_t buf[kPushConstantSize];
	pack_push_constants(buf, width, height, color, sample_scale);
	if (std::memcmp(buf, expected, kPushConstantSize) != 0) {
		// Hex dump on failure so a layout typo is immediately visible.
		std::ostringstream oss;
		oss << "byte mismatch — got: " << std::hex << std::setfill('0');
		for (uint32_t i = 0; i < kPushConstantSize; ++i) {
			if (i != 0 && i % 4 == 0) {
				oss << " | ";
			}
			oss << std::setw(2) << +buf[i];
		}
		FAIL(oss.str());
	}
}

// -----------------------------------------------------------------------
// All-default / zero values.
// -----------------------------------------------------------------------
TEST_CASE("Push constant: all-zero inputs produce zero-filled buffer (float(0) is also zero)") {
	// width=height=0, all enums=Unspecified(0), bit_depth=0, sample_scale=0.0f
	// float 0.0 is bytes 00 00 00 00, so the whole 32 bytes are zeros.
	core::Colorimetry color;
	color.matrix = core::ColorMatrix::Unspecified;
	color.range = core::ColorRange::Unspecified;
	color.bit_depth = 0;
	color.transfer = core::TransferFunction::Unspecified;
	color.primaries = core::ColorPrimaries::Unspecified;

	uint8_t expected[kPushConstantSize];
	std::memset(expected, 0, kPushConstantSize);
	check_packed_bytes(0, 0, color, 0.0f, expected);
}

// -----------------------------------------------------------------------
// HD 1080p, BT.709, Video range, 8-bit — the most common configuration.
// -----------------------------------------------------------------------
TEST_CASE("Push constant: 1920x1080, BT.709, Video, 8-bit, sample_scale=1.0") {
	core::Colorimetry color;
	color.matrix = core::ColorMatrix::BT709;
	color.range = core::ColorRange::Video;
	color.bit_depth = 8;
	color.transfer = core::TransferFunction::BT709;
	color.primaries = core::ColorPrimaries::BT709;

	uint8_t expected[kPushConstantSize] = {
		// out_width = 1920 = 0x780 (little-endian)
		0x80, 0x07, 0x00, 0x00,
		// out_height = 1080 = 0x438 (little-endian)
		0x38, 0x04, 0x00, 0x00,
		// matrix_select = BT709 = 1
		0x01, 0x00, 0x00, 0x00,
		// range_select = Video = 1
		0x01, 0x00, 0x00, 0x00,
		// bit_depth = 8
		0x08, 0x00, 0x00, 0x00,
		// transfer_select = BT709 = 1
		0x01, 0x00, 0x00, 0x00,
		// primaries_select = BT709 = 1
		0x01, 0x00, 0x00, 0x00,
		// sample_scale = 1.0f
		0x00, 0x00, 0x80, 0x3f,
	};
	check_packed_bytes(1920, 1080, color, 1.0f, expected);
}

// -----------------------------------------------------------------------
// 4K, BT.2020, PQ, Full range, 10-bit — HDR source.
// -----------------------------------------------------------------------
TEST_CASE("Push constant: 3840x2160, BT.2020, PQ, Full, 10-bit, sample_scale=1.0") {
	core::Colorimetry color;
	color.matrix = core::ColorMatrix::BT2020;
	color.range = core::ColorRange::Full;
	color.bit_depth = 10;
	color.transfer = core::TransferFunction::PQ;
	color.primaries = core::ColorPrimaries::BT2020;

	uint8_t expected[kPushConstantSize] = {
		// out_width = 3840 = 0xF00
		0x00, 0x0F, 0x00, 0x00,
		// out_height = 2160 = 0x870
		0x70, 0x08, 0x00, 0x00,
		// matrix_select = BT2020 = 3
		0x03, 0x00, 0x00, 0x00,
		// range_select = Full = 2
		0x02, 0x00, 0x00, 0x00,
		// bit_depth = 10
		0x0A, 0x00, 0x00, 0x00,
		// transfer_select = PQ = 2
		0x02, 0x00, 0x00, 0x00,
		// primaries_select = BT2020 = 4
		0x04, 0x00, 0x00, 0x00,
		// sample_scale = 1.0f
		0x00, 0x00, 0x80, 0x3f,
	};
	check_packed_bytes(3840, 2160, color, 1.0f, expected);
}

// -----------------------------------------------------------------------
// SD, BT.601, PAL colour primaries — a historical-but-valid combination.
// -----------------------------------------------------------------------
TEST_CASE("Push constant: 720x576, BT.601, BT.601_625, HLG, Video, 8-bit") {
	core::Colorimetry color;
	color.matrix = core::ColorMatrix::BT601;
	color.range = core::ColorRange::Video;
	color.bit_depth = 8;
	color.transfer = core::TransferFunction::HLG;
	color.primaries = core::ColorPrimaries::BT601_625;

	uint8_t expected[kPushConstantSize] = {
		// out_width = 720 = 0x2D0
		0xD0, 0x02, 0x00, 0x00,
		// out_height = 576 = 0x240
		0x40, 0x02, 0x00, 0x00,
		// matrix_select = BT601 = 2
		0x02, 0x00, 0x00, 0x00,
		// range_select = Video = 1
		0x01, 0x00, 0x00, 0x00,
		// bit_depth = 8
		0x08, 0x00, 0x00, 0x00,
		// transfer_select = HLG = 3
		0x03, 0x00, 0x00, 0x00,
		// primaries_select = BT601_625 = 2
		0x02, 0x00, 0x00, 0x00,
		// sample_scale = 1.0f
		0x00, 0x00, 0x80, 0x3f,
	};
	check_packed_bytes(720, 576, color, 1.0f, expected);
}

// -----------------------------------------------------------------------
// DCI-P3 primaries, 10-bit, left-justified P010 sample_scale (1/64).
// -----------------------------------------------------------------------
TEST_CASE("Push constant: sample_scale=1/64 from DXGI left-justified P010") {
	core::Colorimetry color;
	color.matrix = core::ColorMatrix::BT2020;
	color.range = core::ColorRange::Full;
	color.bit_depth = 10;
	color.transfer = core::TransferFunction::PQ;
	color.primaries = core::ColorPrimaries::DCI_P3;

	uint8_t expected[kPushConstantSize] = {
		// out_width = 1920
		0x80, 0x07, 0x00, 0x00,
		// out_height = 1080
		0x38, 0x04, 0x00, 0x00,
		// matrix_select = BT2020 = 3
		0x03, 0x00, 0x00, 0x00,
		// range_select = Full = 2
		0x02, 0x00, 0x00, 0x00,
		// bit_depth = 10
		0x0A, 0x00, 0x00, 0x00,
		// transfer_select = PQ = 2
		0x02, 0x00, 0x00, 0x00,
		// primaries_select = DCI_P3 = 5
		0x05, 0x00, 0x00, 0x00,
		// sample_scale = 1/64 ≈ 0.015625
		0x00, 0x00, 0x80, 0x3C,
	};
	check_packed_bytes(1920, 1080, color, 1.0f / 64.0f, expected);
}

// -----------------------------------------------------------------------
// buf beyond offset 31 is never written (32-byte buffer is respected).
// -----------------------------------------------------------------------
TEST_CASE("Push constant: does not write past byte 31") {
	uint8_t buf[kPushConstantSize + 4]; // writable region + 4 guard bytes
	std::memset(buf, 0xAB, sizeof(buf));
	// Write into buf[2..33], leaving buf[0..1] and buf[34..35] as guards.
	core::Colorimetry color; // default/zero Colorimetry
	pack_push_constants(buf + 2, 0, 0, color, 0.0f);
	// Guard bytes before the written region must stay untouched.
	CHECK(buf[0] == 0xAB);
	CHECK(buf[1] == 0xAB);
	// Guard bytes after the written region must stay untouched.
	CHECK(buf[kPushConstantSize + 2] == 0xAB);
	CHECK(buf[kPushConstantSize + 3] == 0xAB);
	// The written region (buf[2..33]) is zeroed by memset inside
	// pack_push_constants. Spot-check the first and last written bytes.
	CHECK(buf[2] == 0);
	CHECK(buf[2 + kPushConstantSize - 1] == 0);
}
