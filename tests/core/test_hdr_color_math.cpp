// -----------------------------------------------------------------------
// test_hdr_color_math.cpp — reference-value tests for HDR colour math.
//
// Pins the PQ EOTF, HLG EOTF (inverse OETF + display EOTF), tone mapper,
// and BT.2020→BT.709 primary matrix against published ITU / SMPTE
// reference values. These are the same mathematical functions the compiled
// shader implements (via src/common/hdr_color_math.glsl), so the ITU
// constants cannot drift from what ships.
//
// Reference documents:
//   SMPTE ST 2084    — PQ EOTF
//   ITU-R BT.2100-2  — HLG OETF/EOTF
//   ITU-R BT.2390-4  — Tone mapping (§5.2)
//   ITU-R BT.2087-0  — Colour conversion (BT.2020 ↔ BT.709)
//   ITU-R BT.709-6   — SDR OETF
//   ITU-R BT.2408-2  — Reference white (203 cd/m²)
// -----------------------------------------------------------------------

#include "vendor/doctest.h"

#include <cmath>

#include "hdr_color_math.h"

using namespace hdr_color_math;

constexpr double kRefTol = 0.001;

// =====================================================================
// PQ EOTF — reference values
//
// Reference: SMPTE ST 2084 Table 2 (selected normalized signal →
// luminance values). Values computed from the standard formula.
//
//   N (normalised signal)    L (cd/m²)
//   0.0                     0.000
//   0.1                     0.325
//   0.25                    5.15
//   0.5                     92.25
//   0.75                    983
//   0.9                     3906
//   0.95                    6228
//   1.0                     10000.0
// =====================================================================
TEST_CASE("PQ EOTF: dark signal") {
	CHECK(std::fabs(pq_eotf(0.0) - 0.0) < 1e-10);
	CHECK(pq_eotf(0.1) > 0.3);
	CHECK(pq_eotf(0.1) < 0.35);
	CHECK(pq_eotf(0.25) > 4.0);
	CHECK(pq_eotf(0.25) < 6.0);
}

TEST_CASE("PQ EOTF: mid range") {
	double L = pq_eotf(0.5);
	CHECK(L > 80.0);
	CHECK(L < 100.0);
	L = pq_eotf(0.75);
	CHECK(L > 900.0);
	CHECK(L < 1050.0);
	L = pq_eotf(0.9);
	CHECK(L > 3800.0);
	CHECK(L < 4000.0);
}

TEST_CASE("PQ EOTF: bright range") {
	double L = pq_eotf(0.95);
	CHECK(L > 6100.0);
	CHECK(L < 6400.0);
	CHECK(std::fabs(pq_eotf(1.0) - kPQPeak) < 0.1);
}

TEST_CASE("PQ EOTF: reference white level") {
	// PQ signal N≈0.58 produces ~203 cd/m² (reference white).
	double L_203 = pq_eotf(0.58);
	CHECK(L_203 > 190.0);
	CHECK(L_203 < 210.0);
}

TEST_CASE("PQ constants match ITU-R BT.2100-2 Table 5") {
	CHECK(std::fabs(kPQM1 - 0.159301757812500) < 1e-12);
	CHECK(std::fabs(kPQM2 - 78.84375) < 1e-10);
	CHECK(std::fabs(kPQC1 - 0.83593750) < 1e-8);
	CHECK(std::fabs(kPQC2 - 18.85156250) < 1e-8);
	CHECK(std::fabs(kPQC3 - 18.68750000) < 1e-8);
}

// =====================================================================
// HLG Inverse OETF — BT.2100-2 Table 5
//
//   N (HLG signal)   L_s (scene light)
//   0.0              0.0
//   0.25             0.02083
//   0.5              0.08333
//   0.75             0.26496
//   1.0              1.0
// =====================================================================
TEST_CASE("HLG constants match ITU-R BT.2100-2 Table 5") {
	CHECK(std::fabs(kHLGA - 0.17883277) < 1e-8);
	CHECK(std::fabs(kHLGB - 0.28466892) < 1e-8);
	CHECK(std::fabs(kHLGC - 0.55991073) < 1e-8);
}

TEST_CASE("HLG inverse OETF: zero signal") {
	CHECK(std::fabs(hlg_inv_oetf(0.0) - 0.0) < 1e-10);
}

TEST_CASE("HLG inverse OETF: linear segment") {
	// N = 0.25 → L_s = 0.25²/3 = 0.02083
	double L = hlg_inv_oetf(0.25);
	CHECK(std::fabs(L - 0.0208333) < 0.001);
	// N = 0.5 → L_s = 0.25/3 = 0.08333
	L = hlg_inv_oetf(0.5);
	CHECK(std::fabs(L - 0.0833333) < 0.001);
}

TEST_CASE("HLG inverse OETF: log segment") {
	// N = 0.75 → L_s ≈ 0.26496
	double L = hlg_inv_oetf(0.75);
	CHECK(L > 0.20);
	CHECK(L < 0.30);
	// N = 1.0 → L_s ≈ 1.0
	L = hlg_inv_oetf(1.0);
	CHECK(std::fabs(L - 1.0) < 0.001);
}

TEST_CASE("HLG display EOTF scales to 1000 cd/m²") {
	double L = hlg_display_eotf(1.0);
	CHECK(std::fabs(L - 1000.0) < 20.0);
}

TEST_CASE("HLG display EOTF: reference white level") {
	// HLG signal ~0.75 ≈ 203 cd/m² on reference display.
	double L_203 = hlg_display_eotf(0.75);
	CHECK(L_203 > 195.0);
	CHECK(L_203 < 210.0);
}

// =====================================================================
// Tone mapper (BT.2390-4 inspired) — invariants
//
// The Reinhard-style tone mapper L_n / (1 + L_n) where L_n = L_abs / L_tw.
//
// Reference white (203 cd/m²) → L_n = 1.0 → output = 0.5 (linear).
// Highlights are smoothly compressed; nothing clips.
// =====================================================================
TEST_CASE("tone_map: zero maps to zero") {
	CHECK(std::fabs(tone_map(0.0, kReferenceWhite)) < 1e-10);
	CHECK(std::fabs(tone_map_pq(0.0)) < 1e-10);
	CHECK(std::fabs(tone_map_hlg(0.0)) < 1e-10);
}

TEST_CASE("tone_map: reference white maps to 0.5 linear") {
	// L_abs = L_tw → L_n = 1.0 → 1.0/(1+1) = 0.5
	double t = tone_map(kReferenceWhite, kReferenceWhite);
	CHECK(std::fabs(t - 0.5) < kRefTol);
}

TEST_CASE("tone_map: output in [0, 1) for all finite inputs") {
	for (double L = 0.0; L <= 100000.0; L += 1000.0) {
		double t = tone_map_pq(L);
		CHECK(t >= 0.0);
		CHECK(t < 1.0);
	}
}

TEST_CASE("tone_map: monotonic") {
	for (double L = 1.0; L < 9000.0; L += 100.0) {
		double t_lo = tone_map_pq(L);
		double t_hi = tone_map_pq(L + 5.0);
		CHECK(t_hi > t_lo);
	}
}

TEST_CASE("tone_map: characteristic values") {
	// PQ: reference white (203) → 0.5, peak (10000) → ~0.98
	double tw = tone_map_pq(kReferenceWhite);
	CHECK(std::fabs(tw - 0.5) < 0.01);
	double peak = tone_map_pq(kPQPeak);
	CHECK(peak > 0.95);
	CHECK(peak < 1.0);

	// HLG: reference white → 0.5, peak (1000) → ~0.83
	double hlg_tw = tone_map_hlg(kReferenceWhite);
	CHECK(std::fabs(hlg_tw - 0.5) < 0.01);
	double hlg_peak = tone_map_hlg(1000.0);
	CHECK(hlg_peak > 0.80);
	CHECK(hlg_peak < 0.85);
}

// =====================================================================
// BT.2020 → BT.709 primary matrix
//
// Reference: ITU-R BT.2087-0 Table 1.
// =====================================================================
TEST_CASE("BT.2020 → BT.709: white remains white") {
	double r, g, b;
	bt2020_to_bt709(1.0, 1.0, 1.0, r, g, b);
	CHECK(std::fabs(r - 1.0) < kRefTol);
	CHECK(std::fabs(g - 1.0) < kRefTol);
	CHECK(std::fabs(b - 1.0) < kRefTol);
}

TEST_CASE("BT.2020 → BT.709: black remains black") {
	double r, g, b;
	bt2020_to_bt709(0.0, 0.0, 0.0, r, g, b);
	CHECK(std::fabs(r) < 1e-10);
	CHECK(std::fabs(g) < 1e-10);
	CHECK(std::fabs(b) < 1e-10);
}

TEST_CASE("BT.2020 → BT.709: pure red shows dominant red in 709") {
	double r, g, b;
	bt2020_to_bt709(1.0, 0.0, 0.0, r, g, b);
	CHECK(r > 1.0); // wider gamut red → >1.0 in 709
	CHECK(g < 0.0);
	CHECK(b < 0.0);
}

TEST_CASE("BT.2020 → BT.709: pure blue") {
	double r, g, b;
	bt2020_to_bt709(0.0, 0.0, 1.0, r, g, b);
	CHECK(b > 1.0);
	CHECK(r < 0.0);
	CHECK(g < 0.0);
}

TEST_CASE("BT.2020 → BT.709: green") {
	double r, g, b;
	bt2020_to_bt709(0.0, 1.0, 0.0, r, g, b);
	CHECK(g > 0.9);
	CHECK(r < 0.0);
	CHECK(b < 0.0);
}

// =====================================================================
// BT.709 OETF — sRGB-compliant reference check
// =====================================================================
TEST_CASE("BT.709 OETF: black and white anchors") {
	CHECK(std::fabs(bt709_oetf(0.0)) < 1e-10);
	CHECK(std::fabs(bt709_oetf(1.0) - 1.0) < kRefTol);
}

TEST_CASE("BT.709 OETF: linear segment below threshold") {
	double V = bt709_oetf(0.001);
	CHECK(std::fabs(V - 0.01292) < 1e-5);
}

TEST_CASE("BT.709 OETF: power segment") {
	double V = bt709_oetf(0.5);
	CHECK(std::fabs(V - 0.735) < 0.01);
}

// =====================================================================
// End-to-end: HDR → SDR conversion invariants
// =====================================================================
TEST_CASE("hdr_to_sdr: zero input stays zero") {
	double r = 0.0, g = 0.0, b = 0.0;
	hdr_to_sdr(r, g, b, 2);
	CHECK(std::fabs(r) < 1e-6);
	CHECK(std::fabs(g) < 1e-6);
	CHECK(std::fabs(b) < 1e-6);

	r = g = b = 0.0;
	hdr_to_sdr(r, g, b, 3);
	CHECK(std::fabs(r) < 1e-6);
	CHECK(std::fabs(g) < 1e-6);
	CHECK(std::fabs(b) < 1e-6);
}

TEST_CASE("hdr_to_sdr: output is in [0, 1] for all inputs") {
	for (double V = 0.1; V <= 1.0; V += 0.1) {
		double r = V, g = V * 0.8, b = V * 0.6;
		hdr_to_sdr(r, g, b, 2);
		CHECK(r >= 0.0);
		CHECK(r <= 1.0);
		CHECK(g >= 0.0);
		CHECK(g <= 1.0);
		CHECK(b >= 0.0);
		CHECK(b <= 1.0);
	}
	for (double V = 0.1; V <= 1.0; V += 0.1) {
		double r = V, g = V * 0.8, b = V * 0.6;
		hdr_to_sdr(r, g, b, 3);
		CHECK(r >= 0.0);
		CHECK(r <= 1.0);
		CHECK(g >= 0.0);
		CHECK(g <= 1.0);
		CHECK(b >= 0.0);
		CHECK(b <= 1.0);
	}
}

TEST_CASE("hdr_to_sdr: dark PQ signal is visible not crushed") {
	double r = 0.3, g = 0.3, b = 0.3;
	hdr_to_sdr(r, g, b, 2);
	CHECK(r > 0.001);
}

TEST_CASE("hdr_to_sdr: PQ reference white maps to visible SDR level") {
	double r = 0.58, g = 0.58, b = 0.58;
	hdr_to_sdr(r, g, b, 2);
	CHECK(r > 0.4);
}

TEST_CASE("hdr_to_sdr: HLG produces watchable output across range") {
	// A typical HLG signal (0.75 bright scene) should produce good visibility.
	double r = 0.75, g = 0.75, b = 0.75;
	hdr_to_sdr(r, g, b, 3);
	CHECK(r > 0.5);
	// Full HLG signal should be bright but not clipped.
	r = 1.0;
	g = 1.0;
	b = 1.0;
	hdr_to_sdr(r, g, b, 3);
	CHECK(r < 1.0);
	CHECK(r > 0.7);
}