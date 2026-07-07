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

#include "push_constants.h"

using platform_media::pack_push_constants;

// -----------------------------------------------------------------------
// Helper: pack a known set of parameters and check every byte.
// -----------------------------------------------------------------------
static void check_packed_bytes(
		uint32_t width,
		uint32_t height,
		uint32_t matrix,
		uint32_t range,
		uint32_t depth,
		uint32_t transfer,
		uint32_t primaries,
		float sample_scale,
		const uint8_t *expected) {
	uint8_t buf[32];
	pack_push_constants(buf, width, height, matrix, range, depth,
	                    transfer, primaries, sample_scale);
	if (std::memcmp(buf, expected, 32) != 0) {
		// Hex dump on failure so a layout typo is immediately visible.
		FAIL("byte mismatch — got: " << std::hex
			<< std::setfill('0')
			<< std::setw(2) << +buf[0]
			<< std::setw(2) << +buf[1]
			<< std::setw(2) << +buf[2]
			<< std::setw(2) << +buf[3] << " | "
			<< std::setw(2) << +buf[4]
			<< std::setw(2) << +buf[5]
			<< std::setw(2) << +buf[6]
			<< std::setw(2) << +buf[7] << " | "
			<< std::setw(2) << +buf[8]
			<< std::setw(2) << +buf[9]
			<< std::setw(2) << +buf[10]
			<< std::setw(2) << +buf[11] << " | "
			<< std::setw(2) << +buf[12]
			<< std::setw(2) << +buf[13]
			<< std::setw(2) << +buf[14]
			<< std::setw(2) << +buf[15] << " | "
			<< std::setw(2) << +buf[16]
			<< std::setw(2) << +buf[17]
			<< std::setw(2) << +buf[18]
			<< std::setw(2) << +buf[19] << " | "
			<< std::setw(2) << +buf[20]
			<< std::setw(2) << +buf[21]
			<< std::setw(2) << +buf[22]
			<< std::setw(2) << +buf[23] << " | "
			<< std::setw(2) << +buf[24]
			<< std::setw(2) << +buf[25]
			<< std::setw(2) << +buf[26]
			<< std::setw(2) << +buf[27] << " | "
			<< std::setw(2) << +buf[28]
			<< std::setw(2) << +buf[29]
			<< std::setw(2) << +buf[30]
			<< std::setw(2) << +buf[31]);
	}
}

// -----------------------------------------------------------------------
// All-default / zero values.
// -----------------------------------------------------------------------
TEST_CASE("Push constant: all-zero inputs produce zero-filled buffer (float(0) is also zero)") {
	// width=height=0, all enums=0, bit_depth=0, sample_scale=0.0f
	// float 0.0 is bytes 00 00 00 00, so the whole 32 bytes are zeros.
	uint8_t expected[32];
	std::memset(expected, 0, 32);
	check_packed_bytes(0, 0, 0, 0, 0, 0, 0, 0.0f, expected);
}

// -----------------------------------------------------------------------
// HD 1080p, BT.709, Video range, 8-bit — the most common configuration.
// -----------------------------------------------------------------------
TEST_CASE("Push constant: 1920x1080, BT.709, Video, 8-bit, sample_scale=1.0") {
	uint8_t expected[32] = {
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
	check_packed_bytes(1920, 1080, 1, 1, 8, 1, 1, 1.0f, expected);
}

// -----------------------------------------------------------------------
// 4K, BT.2020, PQ, Full range, 10-bit — HDR source.
// -----------------------------------------------------------------------
TEST_CASE("Push constant: 3840x2160, BT.2020, PQ, Full, 10-bit, sample_scale=1.0") {
	uint8_t expected[32] = {
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
	check_packed_bytes(3840, 2160, 3, 2, 10, 2, 4, 1.0f, expected);
}

// -----------------------------------------------------------------------
// SD, BT.601, PAL colour primaries — a historical-but-valid combination.
// -----------------------------------------------------------------------
TEST_CASE("Push constant: 720x576, BT.601, BT.601_625, HLG, Video, 8-bit") {
	uint8_t expected[32] = {
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
	check_packed_bytes(720, 576, 2, 1, 8, 3, 2, 1.0f, expected);
}

// -----------------------------------------------------------------------
// DCI-P3 primaries, 10-bit, left-justified P010 sample_scale (1/64).
// -----------------------------------------------------------------------
TEST_CASE("Push constant: sample_scale=1/64 from DXGI left-justified P010") {
	uint8_t expected[32] = {
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
	check_packed_bytes(1920, 1080, 3, 2, 10, 2, 5, 1.0f / 64.0f, expected);
}

// -----------------------------------------------------------------------
// The convenience overload that takes core::Colorimetry.
// -----------------------------------------------------------------------
TEST_CASE("Push constant: Colorimetry convenience overload matches manual fields") {
	core::Colorimetry color;
	color.matrix = core::ColorMatrix::BT2020;
	color.range = core::ColorRange::Full;
	color.bit_depth = 10;
	color.transfer = core::TransferFunction::PQ;
	color.primaries = core::ColorPrimaries::BT2020;

	uint8_t manual[32];
	pack_push_constants(manual, 1920, 1080,
	                    3, 2, 10, 2, 4, 1.0f);

	uint8_t from_colorimetry[32];
	pack_push_constants(from_colorimetry, 1920, 1080, color, 1.0f);

	CHECK(std::memcmp(manual, from_colorimetry, 32) == 0);
}

// -----------------------------------------------------------------------
// buf beyond offset 31 is never written (32-byte buffer is respected).
// -----------------------------------------------------------------------
TEST_CASE("Push constant: does not write past byte 31") {
	uint8_t buf[36]; // 32-byte writable region + 4 guard bytes
	std::memset(buf, 0xAB, sizeof(buf));
	// Write into buf[2..33], leaving buf[0..1] and buf[34..35] as guards.
	pack_push_constants(buf + 2, 0, 0, 0, 0, 0, 0, 0, 0.0f);
	// Guard bytes before the 32-byte region must stay untouched.
	CHECK(buf[0] == 0xAB);
	CHECK(buf[1] == 0xAB);
	// Guard bytes after the 32-byte region must stay untouched.
	CHECK(buf[34] == 0xAB);
	CHECK(buf[35] == 0xAB);
	// The written region (buf[2..33]) is zeroed by memset inside
	// pack_push_constants. Spot-check the first and last written bytes.
	CHECK(buf[2] == 0);
	CHECK(buf[33] == 0);
}
