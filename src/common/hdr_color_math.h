// -----------------------------------------------------------------------
// hdr_color_math.h — shared constexpr HDR color conversion math functions.
//
// Matches ITU-R BT.2100 (PQ/HLG EOTFs), SMPTE ST 2084, BT.2390-4 EETF,
// and BT.2020→BT.709 primary-matrix conversion. The same mathematical
// constants appear in src/common/hdr_color_math.glsl for the GPU path; the
// unit tests in tests/core/test_hdr_color_math.cpp verify both against
// published ITU reference values so the constants cannot drift independently.
//
// All luminance values are in candelas per square metre (cd/m²).
// All normalized signal values are in [0, 1] unless noted.
// -----------------------------------------------------------------------

#pragma once

#include <algorithm>
#include <cmath>

namespace hdr_color_math {

// =======================================================================
// Reference white (SDR target) — 203 cd/m² per BT.2408-2 §4.1.
// =======================================================================
inline constexpr double kReferenceWhite = 203.0;

// =======================================================================
// PQ EOTF — SMPTE ST 2084 / BT.2100-2 §5.1.1 (Table 5).
//
// Maps non-linear signal N ∈ [0, 1] → linear luminance L ∈ [0, 10000] cd/m².
// =======================================================================
inline constexpr double kPQM1 = 2610.0 / 16384.0; // 0.159301757812500
inline constexpr double kPQM2 = 2523.0 / 4096.0 * 128.0; // 78.843750000000000
inline constexpr double kPQC1 = 3424.0 / 4096.0; // 0.835937500000000
inline constexpr double kPQC2 = 2413.0 / 4096.0 * 32.0; // 18.851562500000000
inline constexpr double kPQC3 = 2392.0 / 4096.0 * 32.0; // 18.687500000000000
inline constexpr double kPQPeak = 10000.0;

inline double pq_eotf(double N) noexcept {
	if (N <= 0.0) {
		return 0.0;
	}
	const double V = std::pow(N, 1.0 / kPQM2);
	const double num = std::max(V - kPQC1, 0.0);
	if (num <= 0.0) {
		return 0.0;
	}
	const double den = kPQC2 - kPQC3 * V;
	if (den < 1e-12) {
		return kPQPeak;
	}
	return kPQPeak * std::pow(num / den, 1.0 / kPQM1);
}

// =======================================================================
// HLG Inverse OETF (scene-light EOTF) — BT.2100-2 §5.1.2 (Table 5).
//
// Maps non-linear signal N ∈ [0, 1] → relative scene luminance L_s,
// normalized so L_s ∈ [0, 1] represents scene light.
// =======================================================================
inline constexpr double kHLGA = 0.17883277;
inline constexpr double kHLGB = 0.28466892; // 1 - 4*a
inline constexpr double kHLGC = 0.55991073; // 0.5 - a*ln(4*a)

inline double hlg_inv_oetf(double N) noexcept {
	if (N <= 0.0) {
		return 0.0;
	}
	if (N <= 0.5) {
		// Linear segment: V' = sqrt(3*E) → E = V'² / 3
		return (N * N) / 3.0;
	}
	// Log segment: V' = a*ln(12*E - b) + c → E = (exp((V' - c)/a) + b) / 12
	return (std::exp((N - kHLGC) / kHLGA) + kHLGB) / 12.0;
}

// =======================================================================
// HLG Reference Display EOTF — BT.2100-2 §5.3.
//
// Drives a hypothetical 1000 cd/m² display with system gamma γ = 1.2.
// Maps scene light L_s → display luminance L_d ∈ [0, 1000] cd/m².
// =======================================================================
inline double hlg_display_eotf(double N) noexcept {
	const double L_s = hlg_inv_oetf(N);
	return 1000.0 * std::pow(L_s, 1.2);
}

// =======================================================================
// Tone mapper — maps absolute luminance to SDR display-normalized [0, 1].
//
// Uses a Reinhard-style mapping normalized to the reference white level:
//   L_display = L_abs / (L_abs + L_tw)
//
// This preserves reference white at a visible mid-range level (~0.5 in
// linear space, ~0.73 after OETF) and compresses highlights smoothly
// so full peak maps to ~0.99 — never clipping.
//
// Reference: BT.2390-4 §5.2 (simplified global tone mapping operator).
// =======================================================================
inline double tone_map(double L_abs, double L_tw) noexcept {
	if (L_abs <= 0.0) {
		return 0.0;
	}
	const double L_n = L_abs / L_tw;
	return L_n / (1.0 + L_n);
}

inline double tone_map_pq(double L_abs) noexcept {
	return tone_map(L_abs, kReferenceWhite);
}

inline double tone_map_hlg(double L_abs) noexcept {
	return tone_map(L_abs, kReferenceWhite);
}

// =======================================================================
// BT.2020 → BT.709 primary matrix conversion.
//
// Converts linear RGB in BT.2020 primaries to linear RGB in BT.709
// primaries. The matrix is derived from the CIE xy chromaticities of
// the two colour spaces (BT.2020 Table 4, BT.709 Table 2) using
// the standard XYZ intermediary transform.
//
// Coefficients from ITU-R BT.2087-0 §2 (colour conversion).
// =======================================================================
inline void bt2020_to_bt709(double r2020, double g2020, double b2020,
		double &r709, double &g709, double &b709) noexcept {
	r709 = 1.6605 * r2020 - 0.5876 * g2020 - 0.0728 * b2020;
	g709 = -0.1249 * r2020 + 1.1330 * g2020 - 0.0081 * b2020;
	b709 = -0.0182 * r2020 - 0.0996 * g2020 + 1.1178 * b2020;
}

// =======================================================================
// BT.709 OETF (opto-electronic transfer function).
//
// Maps linear R'G'B' in [0, 1] to non-linear R'G'B' for SDR display
// per BT.709-6 §2.1 (sRGB-approximate piecewise curve).
// =======================================================================
inline double bt709_oetf(double L) noexcept {
	if (L < 0.0031308) {
		return 12.92 * L;
	}
	return 1.055 * std::pow(L, 1.0 / 2.4) - 0.055;
}

// =======================================================================
// BT.709 EOTF (inverse OETF) — BT.709-6 §2.1 / sRGB.
//
// Maps non-linear signal V ∈ [0, 1] → linear luminance L ∈ [0, 1].
// =======================================================================
inline double bt709_eotf(double V) noexcept {
	if (V < 0.04045) {
		return V / 12.92;
	}
	return std::pow((V + 0.055) / 1.055, 2.4);
}

// =======================================================================
// Convenience: full HDR → SDR pixel conversion for one RGB triple.
//
// Input:  R, G, B in non-linear PQ or HLG encoded domain, BT.2020 primaries.
// Output: R, G, B in non-linear BT.709 domain, clamped to [0, 1].
//
// transfer: 2 = PQ (SMPTE ST 2084), 3 = HLG (BT.2100)
// =======================================================================
inline void hdr_to_sdr(double &r, double &g, double &b, int transfer) noexcept {
	// Step 1: EOTF (non-linear → linear absolute luminance)
	double Lr, Lg, Lb;
	if (transfer == 2) {
		Lr = pq_eotf(r);
		Lg = pq_eotf(g);
		Lb = pq_eotf(b);
	} else {
		Lr = hlg_display_eotf(r);
		Lg = hlg_display_eotf(g);
		Lb = hlg_display_eotf(b);
	}

	// Step 2: Tone-map each channel to SDR-normalized [0, 1].
	Lr = tone_map(Lr, kReferenceWhite);
	Lg = tone_map(Lg, kReferenceWhite);
	Lb = tone_map(Lb, kReferenceWhite);

	// Step 3: BT.2020 → BT.709 primary conversion.
	double r709, g709, b709;
	bt2020_to_bt709(Lr, Lg, Lb, r709, g709, b709);

	// Step 4: Apply BT.709 OETF (linear → non-linear for display).
	r = bt709_oetf(std::clamp(r709, 0.0, 1.0));
	g = bt709_oetf(std::clamp(g709, 0.0, 1.0));
	b = bt709_oetf(std::clamp(b709, 0.0, 1.0));

	// Final clamp (OETF can produce very slightly > 1 or < 0 in extreme cases).
	r = std::clamp(r, 0.0, 1.0);
	g = std::clamp(g, 0.0, 1.0);
	b = std::clamp(b, 0.0, 1.0);
}

} // namespace hdr_color_math