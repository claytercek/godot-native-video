// -----------------------------------------------------------------------
// test_color_matrix.cpp — reference-value tests for YCbCr matrix derivations.
//
// Verifies the BT.601 and BT.709 YCbCr→RGB matrix coefficients produce the
// correct reference values. These tests are platform-independent and cover
// the same maths the NV12→RGB shader uses. They do NOT require a GPU or
// Godot — just standard C++20.
//
// Reference values from ITU-R BT.601-7 and ITU-R BT.709-6.
// -----------------------------------------------------------------------

#include "vendor/doctest.h"

#include <cmath>
#include <cstdint>
#include <regex>
#include <sstream>
#include <string>

#include "nv12_to_rgb_shader.h"

namespace {

// -----------------------------------------------------------------------
// YCbCr→RGB conversion (reference implementation matching the shader).
// -----------------------------------------------------------------------

// Normalise a video-range luma sample [16,235] to [0,1].
static double y_video_to_linear(uint8_t y) {
	return (static_cast<double>(y) - 16.0) / 219.0;
}

// Normalise a video-range chroma sample [16,240] to [-0.5, 0.5].
static double c_video_to_linear(uint8_t c) {
	return (static_cast<double>(c) - 128.0) / 224.0;
}

// Normalise a full-range luma/chroma sample [0,255] to respective range.
static double y_full_to_linear(uint8_t y) {
	return static_cast<double>(y) / 255.0;
}

static double c_full_to_linear(uint8_t c) {
	return (static_cast<double>(c) - 128.0) / 255.0;
}

// BT.601 coefficients (SD, ITU-R BT.601-7)
struct Bt601Coeffs {
	static constexpr double Kr = 0.299;
	static constexpr double Kb = 0.114;
	static constexpr double Kg = 1.0 - Kr - Kb; // 0.587

	// Inverse matrix: R = Y + 2*(1-Kr)*Cr, B = Y + 2*(1-Kb)*Cb, etc.
	static constexpr double r_cr = 2.0 * (1.0 - Kr);   // 2 * 0.701 = 1.402
	static constexpr double b_cb = 2.0 * (1.0 - Kb);   // 2 * 0.886 = 1.772
	static constexpr double g_cb = -2.0 * Kb * (1.0 - Kb) / Kg; // -2*0.114*0.886/0.587 = -0.344
	static constexpr double g_cr = -2.0 * Kr * (1.0 - Kr) / Kg; // -2*0.299*0.701/0.587 = -0.714
};

// BT.709 coefficients (HD, ITU-R BT.709-6)
struct Bt709Coeffs {
	static constexpr double Kr = 0.2126;
	static constexpr double Kb = 0.0722;
	static constexpr double Kg = 1.0 - Kr - Kb; // 0.7152

	static constexpr double r_cr = 2.0 * (1.0 - Kr);   // 2 * 0.7874 = 1.5748
	static constexpr double b_cb = 2.0 * (1.0 - Kb);   // 2 * 0.9278 = 1.8556
	static constexpr double g_cb = -2.0 * Kb * (1.0 - Kb) / Kg; // -2*0.0722*0.9278/0.7152 = -0.1873
	static constexpr double g_cr = -2.0 * Kr * (1.0 - Kr) / Kg; // -2*0.2126*0.7874/0.7152 = -0.4681
};

// BT.2020 coefficients (UHD, ITU-R BT.2020-2)
struct Bt2020Coeffs {
	static constexpr double Kr = 0.2627;
	static constexpr double Kb = 0.0593;
	static constexpr double Kg = 1.0 - Kr - Kb; // 0.6780

	static constexpr double r_cr = 2.0 * (1.0 - Kr);   // 2 * 0.7373 = 1.4746
	static constexpr double b_cb = 2.0 * (1.0 - Kb);   // 2 * 0.9407 = 1.8814
	static constexpr double g_cb = -2.0 * Kb * (1.0 - Kb) / Kg; // -2*0.0593*0.9407/0.6780 = -0.1645
	static constexpr double g_cr = -2.0 * Kr * (1.0 - Kr) / Kg; // -2*0.2627*0.7373/0.6780 = -0.5714
};

// Convert Y'CbCr to R'G'B' using the given coefficients.
// All values in nominal [0,1]/[-0.5,0.5] linear range.
static void ycbcr_to_rgb(double y, double cb, double cr,
		double &r, double &g, double &b,
		double r_cr, double g_cb, double g_cr, double b_cb) {
	r = y + r_cr * cr;
	g = y + g_cb * cb + g_cr * cr;
	b = y + b_cb * cb;
}

// Tolerance for floating-point comparison in these tests.
constexpr double kTol = 0.001;

// -----------------------------------------------------------------------
// Shader-source coefficient parsing (for the regression guard test below).
//
// Unlike the C++ reference structs above, this parses the actual embedded
// GLSL SOURCE TEXT (nv12_to_rgb_shader.h, generated from
// src/common/nv12_to_rgb.glsl by tools/embed_shader.py) to catch the case
// where the shader's code diverges from its own derivation -- something a
// C++-only reference test can never see.
// -----------------------------------------------------------------------

struct ParsedCoeffs {
	double r_cr = 0.0;
	double g_cb = 0.0;
	double g_cr = 0.0;
	double b_cb = 0.0;
};

// Drop any line whose first non-whitespace characters are "//" so the parser
// below can't accidentally match the illustrative comment table above the
// matrix code (e.g. "// BT.709 (HD): R=Y+1.57480*Cr ...") instead of the real
// `rgb.r = ...` / `rgb.g = ...` / `rgb.b = ...` assignment statements.
static std::string strip_comment_lines(const std::string &text) {
	std::string out;
	std::istringstream iss(text);
	std::string line;
	while (std::getline(iss, line)) {
		const size_t first = line.find_first_not_of(" \t");
		if (first != std::string::npos && line.compare(first, 2, "//") == 0) {
			continue;
		}
		out += line;
		out += "\n";
	}
	return out;
}

// Parse the three coefficient assignment lines out of one matrix branch's
// code block (the body of an `if`/`else if`/`else` for params.matrix_select).
// The shader writes the g-channel line as two subtractions with positive
// literals (e.g. `rgb.g = yf - 0.18732 * cb - 0.46812 * cr;`), so the signed
// coefficients (matching Bt*Coeffs::g_cb/g_cr, which are negative) are the
// negation of the parsed magnitudes.
static ParsedCoeffs parse_matrix_block(const std::string &block_raw) {
	const std::string block = strip_comment_lines(block_raw);
	ParsedCoeffs result;

	static const std::regex r_pattern(R"(rgb\.r\s*=\s*yf\s*\+\s*([0-9]*\.?[0-9]+)\s*\*\s*cr;)");
	static const std::regex g_pattern(R"(rgb\.g\s*=\s*yf\s*-\s*([0-9]*\.?[0-9]+)\s*\*\s*cb\s*-\s*([0-9]*\.?[0-9]+)\s*\*\s*cr;)");
	static const std::regex b_pattern(R"(rgb\.b\s*=\s*yf\s*\+\s*([0-9]*\.?[0-9]+)\s*\*\s*cb;)");

	std::smatch m;
	REQUIRE(std::regex_search(block, m, r_pattern));
	result.r_cr = std::stod(m[1].str());

	REQUIRE(std::regex_search(block, m, g_pattern));
	result.g_cb = -std::stod(m[1].str());
	result.g_cr = -std::stod(m[2].str());

	REQUIRE(std::regex_search(block, m, b_pattern));
	result.b_cb = std::stod(m[1].str());

	return result;
}

// -----------------------------------------------------------------------
// Known reference values (computed independently for verification).
//
// For a pure white video-range signal:
//   Y=235, Cb=128, Cr=128  →  R=G=B=1.0  (white)
//
// For a pure black video-range signal:
//   Y=16,  Cb=128, Cr=128  →  R=G=B=0.0  (black)
//
// For a pure red video-range signal (BT.601):
//   Y=82,  Cb=90,  Cr=240  →  R≈1.0, G≈0.0, B≈0.0  (red)
//     (Y = 0.299*235 + 0.587*16 + 0.114*16 = 81.9 ≈ 82)
//     (Cb = -0.169*235 - 0.331*16 + 0.500*16 + 128 = 89.8 ≈ 90)
//     (Cr = 0.500*235 - 0.419*16 - 0.081*16 + 128 = 240.7 ≈ 240)
// -----------------------------------------------------------------------

} // namespace

TEST_CASE("BT.601 matrix coefficients match ITU-R BT.601-7") {
	// Verify derived coefficients are within 0.001 of the standard values.
	CHECK(std::fabs(Bt601Coeffs::r_cr - 1.402) < kTol);  // R = Y + 1.402*Cr
	CHECK(std::fabs(Bt601Coeffs::b_cb - 1.772) < kTol);  // B = Y + 1.772*Cb
	CHECK(std::fabs(Bt601Coeffs::g_cb - (-0.34414)) < kTol); // G = Y - 0.34414*Cb
	CHECK(std::fabs(Bt601Coeffs::g_cr - (-0.71414)) < kTol); // G = Y - 0.71414*Cr
}

TEST_CASE("BT.709 matrix coefficients match ITU-R BT.709-6") {
	CHECK(std::fabs(Bt709Coeffs::r_cr - 1.5748) < kTol);
	CHECK(std::fabs(Bt709Coeffs::b_cb - 1.8556) < kTol);
	CHECK(std::fabs(Bt709Coeffs::g_cb - (-0.18732)) < kTol);
	CHECK(std::fabs(Bt709Coeffs::g_cr - (-0.46812)) < kTol);
}

TEST_CASE("BT.2020 matrix coefficients match ITU-R BT.2020-2") {
	// Verify derived coefficients are within 0.001 of the standard values.
	CHECK(std::fabs(Bt2020Coeffs::r_cr - 1.4746) < kTol);  // R = Y + 1.4746*Cr
	CHECK(std::fabs(Bt2020Coeffs::b_cb - 1.8814) < kTol);  // B = Y + 1.8814*Cb
	CHECK(std::fabs(Bt2020Coeffs::g_cb - (-0.16455)) < kTol); // G = Y - 0.16455*Cb - 0.57135*Cr
	CHECK(std::fabs(Bt2020Coeffs::g_cr - (-0.57135)) < kTol);
}

// Regression guard: parse the embedded shader SOURCE TEXT itself (not a
// hand-reimplemented C++ mirror) and check its rgb.r/rgb.g/rgb.b coefficients
// against the ITU-derived Bt601Coeffs/Bt709Coeffs/Bt2020Coeffs above.
//
// This test exists because the merge of the separate SDR and HDR shader
// files into one src/common/nv12_to_rgb.glsl once shipped a real bug: the
// BT.709 branch's rgb.g line carried BT.2020's -0.57135 Cr coefficient
// (copy-pasted from the adjacent branch) instead of BT.709's own -0.46812.
// None of the TEST_CASEs above could have caught that -- they only check the
// derived C++ constants, never the actual GLSL that ships. This test reads
// the shader text and would have failed on that bug.
//
// kNv12ToRgbCompute is the SDR embedding of nv12_to_rgb.glsl. The HDR
// embedding (kNv12ToRgbHdrCompute, built with -D HDR_OUTPUT=1) comes from the
// exact same source file and differs only by an injected #define -- the
// matrix-selection code checked here is identical in both, so checking the
// SDR string covers both variants.
TEST_CASE("Shader source matrix coefficients match ITU-R derivations (regression guard)") {
	const std::string source(kNv12ToRgbCompute);

	// matrix_select: 2u=BT.601, 3u=BT.2020, else (default)=BT.709.
	const size_t bt601_pos = source.find("if (params.matrix_select == 2u) {");
	REQUIRE(bt601_pos != std::string::npos);

	const size_t bt2020_pos = source.find("} else if (params.matrix_select == 3u) {", bt601_pos);
	REQUIRE(bt2020_pos != std::string::npos);

	const size_t bt709_pos = source.find("} else {", bt2020_pos);
	REQUIRE(bt709_pos != std::string::npos);

	const size_t bt709_end = source.find("\n\t}\n", bt709_pos);
	REQUIRE(bt709_end != std::string::npos);

	const std::string bt601_block = source.substr(bt601_pos, bt2020_pos - bt601_pos);
	const std::string bt2020_block = source.substr(bt2020_pos, bt709_pos - bt2020_pos);
	const std::string bt709_block = source.substr(bt709_pos, bt709_end - bt709_pos);

	const ParsedCoeffs bt601 = parse_matrix_block(bt601_block);
	const ParsedCoeffs bt2020 = parse_matrix_block(bt2020_block);
	const ParsedCoeffs bt709 = parse_matrix_block(bt709_block);

	CHECK(std::fabs(bt601.r_cr - Bt601Coeffs::r_cr) < kTol);
	CHECK(std::fabs(bt601.g_cb - Bt601Coeffs::g_cb) < kTol);
	CHECK(std::fabs(bt601.g_cr - Bt601Coeffs::g_cr) < kTol);
	CHECK(std::fabs(bt601.b_cb - Bt601Coeffs::b_cb) < kTol);

	CHECK(std::fabs(bt2020.r_cr - Bt2020Coeffs::r_cr) < kTol);
	CHECK(std::fabs(bt2020.g_cb - Bt2020Coeffs::g_cb) < kTol);
	CHECK(std::fabs(bt2020.g_cr - Bt2020Coeffs::g_cr) < kTol);
	CHECK(std::fabs(bt2020.b_cb - Bt2020Coeffs::b_cb) < kTol);

	CHECK(std::fabs(bt709.r_cr - Bt709Coeffs::r_cr) < kTol);
	CHECK(std::fabs(bt709.g_cb - Bt709Coeffs::g_cb) < kTol);
	CHECK(std::fabs(bt709.g_cr - Bt709Coeffs::g_cr) < kTol);
	CHECK(std::fabs(bt709.b_cb - Bt709Coeffs::b_cb) < kTol);
}

TEST_CASE("White reference: BT.601 video-range YCbCr maps to RGB=1,1,1") {
	// Video-range white: Y=235, Cb=128, Cr=128
	double y = y_video_to_linear(235); // → 1.0
	double cb = c_video_to_linear(128); // → 0.0
	double cr = c_video_to_linear(128); // → 0.0

	double r, g, b;
	ycbcr_to_rgb(y, cb, cr, r, g, b,
			Bt601Coeffs::r_cr, Bt601Coeffs::g_cb,
			Bt601Coeffs::g_cr, Bt601Coeffs::b_cb);

	CHECK(std::fabs(r - 1.0) < kTol);
	CHECK(std::fabs(g - 1.0) < kTol);
	CHECK(std::fabs(b - 1.0) < kTol);
}

TEST_CASE("Black reference: BT.709 video-range YCbCr maps to RGB=0,0,0") {
	double y = y_video_to_linear(16);  // → 0.0
	double cb = c_video_to_linear(128); // → 0.0
	double cr = c_video_to_linear(128); // → 0.0

	double r, g, b;
	ycbcr_to_rgb(y, cb, cr, r, g, b,
			Bt709Coeffs::r_cr, Bt709Coeffs::g_cb,
			Bt709Coeffs::g_cr, Bt709Coeffs::b_cb);

	CHECK(std::fabs(r - 0.0) < kTol);
	CHECK(std::fabs(g - 0.0) < kTol);
	CHECK(std::fabs(b - 0.0) < kTol);
}

TEST_CASE("BT.2020 black reference: video-range YCbCr maps to RGB=0,0,0") {
	double y = y_video_to_linear(16);
	double cb = c_video_to_linear(128);
	double cr = c_video_to_linear(128);

	double r, g, b;
	ycbcr_to_rgb(y, cb, cr, r, g, b,
			Bt2020Coeffs::r_cr, Bt2020Coeffs::g_cb,
			Bt2020Coeffs::g_cr, Bt2020Coeffs::b_cb);

	CHECK(std::fabs(r - 0.0) < kTol);
	CHECK(std::fabs(g - 0.0) < kTol);
	CHECK(std::fabs(b - 0.0) < kTol);
}

TEST_CASE("BT.2020 white reference: video-range YCbCr maps to RGB=1,1,1") {
	double y = y_video_to_linear(235);
	double cb = c_video_to_linear(128);
	double cr = c_video_to_linear(128);

	double r, g, b;
	ycbcr_to_rgb(y, cb, cr, r, g, b,
			Bt2020Coeffs::r_cr, Bt2020Coeffs::g_cb,
			Bt2020Coeffs::g_cr, Bt2020Coeffs::b_cb);

	CHECK(std::fabs(r - 1.0) < kTol);
	CHECK(std::fabs(g - 1.0) < kTol);
	CHECK(std::fabs(b - 1.0) < kTol);
}

TEST_CASE("BT.2020 and BT.709 produce different RGB for the same YCbCr (UHD vs HD)") {
	constexpr uint8_t y_samp = 30;
	constexpr uint8_t cb_samp = 240;
	constexpr uint8_t cr_samp = 110;

	double y = y_video_to_linear(y_samp);
	double cb = c_video_to_linear(cb_samp);
	double cr = c_video_to_linear(cr_samp);

	double r2020, g2020, b2020;
	double r709, g709, b709;

	ycbcr_to_rgb(y, cb, cr, r2020, g2020, b2020,
			Bt2020Coeffs::r_cr, Bt2020Coeffs::g_cb,
			Bt2020Coeffs::g_cr, Bt2020Coeffs::b_cb);

	ycbcr_to_rgb(y, cb, cr, r709, g709, b709,
			Bt709Coeffs::r_cr, Bt709Coeffs::g_cb,
			Bt709Coeffs::g_cr, Bt709Coeffs::b_cb);

	const double diff = std::fabs(b2020 - b709) + std::fabs(g2020 - g709);
	CHECK(diff > 0.01);
}

TEST_CASE("Red-dominant YCbCr decodes to R-heavy RGB: BT.601") {
	// For a red-dominant video-range signal (Y~82, Cb~90, Cr~240 in BT.601),
	// the decoded RGB should have R significantly higher than G and B.
	// This is a qualitative check: R dominates, G and B are much dimmer.
	double y = y_video_to_linear(82);
	double cb = c_video_to_linear(90);
	double cr = c_video_to_linear(240);

	double r, g, b;
	ycbcr_to_rgb(y, cb, cr, r, g, b,
			Bt601Coeffs::r_cr, Bt601Coeffs::g_cb,
			Bt601Coeffs::g_cr, Bt601Coeffs::b_cb);

	// R is dominant (significantly brighter than G and B)
	CHECK(r > 0.9);
	CHECK(r > g * 3.0);
	CHECK(r > b * 3.0);
}

TEST_CASE("BT.601 and BT.709 produce different RGB for the same YCbCr (chroma difference)") {
	// For a saturated colour (blue: Y=30, Cb=240, Cr=110), the two matrices
	// give measurably different B and G values. This is the key distinction:
	// BT.709 has higher Kr (0.2126 vs 0.299) so Cr contributes less to G.
	constexpr uint8_t y_samp = 30;
	constexpr uint8_t cb_samp = 240;
	constexpr uint8_t cr_samp = 110;

	double y = y_video_to_linear(y_samp);
	double cb = c_video_to_linear(cb_samp);
	double cr = c_video_to_linear(cr_samp);

	double r601, g601, b601;
	double r709, g709, b709;

	ycbcr_to_rgb(y, cb, cr, r601, g601, b601,
			Bt601Coeffs::r_cr, Bt601Coeffs::g_cb,
			Bt601Coeffs::g_cr, Bt601Coeffs::b_cb);

	ycbcr_to_rgb(y, cb, cr, r709, g709, b709,
			Bt709Coeffs::r_cr, Bt709Coeffs::g_cb,
			Bt709Coeffs::g_cr, Bt709Coeffs::b_cb);

	// The matrices differ by > 0.01 for at least one channel.
	const double diff = std::fabs(b601 - b709) + std::fabs(g601 - g709);
	CHECK(diff > 0.01);
}

TEST_CASE("Full-range vs video-range: white at Y=255 vs Y=235 both give RGB=1,1,1") {
	// Full-range white: Y=255, Cb=128, Cr=128 → RGB=1,1,1
	double y_f = y_full_to_linear(255);
	double cb_f = c_full_to_linear(128);
	double cr_f = c_full_to_linear(128);

	double r_f, g_f, b_f;
	ycbcr_to_rgb(y_f, cb_f, cr_f, r_f, g_f, b_f,
			Bt709Coeffs::r_cr, Bt709Coeffs::g_cb,
			Bt709Coeffs::g_cr, Bt709Coeffs::b_cb);

	CHECK(std::fabs(r_f - 1.0) < kTol);
	CHECK(std::fabs(g_f - 1.0) < kTol);
	CHECK(std::fabs(b_f - 1.0) < kTol);

	// Both video-range white (Y=235) and full-range white (Y=255) give RGB=1,1,1.
	double y_v = y_video_to_linear(235);
	double r_v, g_v, b_v;
	ycbcr_to_rgb(y_v, cb_f, cr_f, r_v, g_v, b_v,
			Bt709Coeffs::r_cr, Bt709Coeffs::g_cb,
			Bt709Coeffs::g_cr, Bt709Coeffs::b_cb);

	CHECK(std::fabs(r_v - 1.0) < kTol);
	CHECK(std::fabs(g_v - 1.0) < kTol);
	CHECK(std::fabs(b_v - 1.0) < kTol);
}

TEST_CASE("Full-range vs video-range: Y=0 in full maps to RGB near black") {
	// Full-range black: Y=0, Cb=128, Cr=128
	double y = y_full_to_linear(0);
	double cb = c_full_to_linear(128);
	double cr = c_full_to_linear(128);

	double r, g, b;
	ycbcr_to_rgb(y, cb, cr, r, g, b,
			Bt709Coeffs::r_cr, Bt709Coeffs::g_cb,
			Bt709Coeffs::g_cr, Bt709Coeffs::b_cb);

	// Should be near black (small negative clamped later in shader).
	CHECK(std::fabs(r - 0.0) < kTol);
	CHECK(std::fabs(g - 0.0) < kTol);
	CHECK(std::fabs(b - 0.0) < kTol);
}

// -----------------------------------------------------------------------
// 10-bit code recovery through sample_scale (PlaneTextures / push constant).
//
// The shader recovers a 10-bit code from a sampled UNORM texel as
// `texel * 65535 * sample_scale` (float32, same as the GPU). Two storage
// conventions feed it:
//   - right-justified (CPU-Copy pack, D3D12 plane-split, Metal x420):
//     texel = code / 65535, sample_scale = 1.0
//   - left-justified P010 aliased directly by the DXGI/Vulkan plane views:
//     texel = (code << 6) / 65535, sample_scale = 1/64
// Both must round back to the exact code for every 10-bit value.
// -----------------------------------------------------------------------
TEST_CASE("10-bit code recovery: right-justified and left-justified conventions") {
	for (int code = 0; code < 1024; ++code) {
		// Right-justified 10-in-16 (sample_scale = 1.0).
		const float right_texel = static_cast<float>(code) / 65535.0f;
		const float right_recovered = right_texel * 65535.0f * 1.0f;
		CHECK(std::fabs(right_recovered - code) < 0.01);

		// Left-justified P010 word (sample_scale = 1/64).
		const float left_texel = static_cast<float>(code << 6) / 65535.0f;
		const float left_recovered = left_texel * 65535.0f * (1.0f / 64.0f);
		CHECK(std::fabs(left_recovered - code) < 0.01);
	}
}
