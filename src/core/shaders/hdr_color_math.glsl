// -----------------------------------------------------------------------
// hdr_color_math.glsl — GLSL implementations of HDR color math functions.
//
// Mirrors src/common/hdr_color_math.h. Both files implement the same ITU
// formulas with identical constants; the C++ unit tests verify against
// published reference values so the shader matches.
//
// These functions are #included by the NV12→RGB compute shader and are
// only called when the transfer function is PQ (2) or HLG (3).
// -----------------------------------------------------------------------

// -----------------------------------------------------------------------
// PQ EOTF — SMPTE ST 2084 / BT.2100-2 §5.1.1 (Table 5).
//
// Maps non-linear signal N ∈ [0, 1] → linear luminance L ∈ [0, 10000] cd/m².
// -----------------------------------------------------------------------
const float kPQM1  = 2610.0 / 16384.0;        // 0.159301757812500
const float kPQM2  = 2523.0 / 4096.0 * 128.0; // 78.843750000000000
const float kPQC1  = 3424.0 / 4096.0;          // 0.835937500000000
const float kPQC2  = 2413.0 / 4096.0 * 32.0;   // 18.851562500000000
const float kPQC3  = 2392.0 / 4096.0 * 32.0;   // 18.687500000000000
const float kPQPeak = 10000.0;

float pq_eotf(float N) {
	if (N <= 0.0) return 0.0;
	float V = pow(N, 1.0 / kPQM2);
	float num = max(V - kPQC1, 0.0);
	if (num <= 0.0) return 0.0;
	float den = kPQC2 - kPQC3 * V;
	if (den < 1e-12) return kPQPeak;
	return kPQPeak * pow(num / den, 1.0 / kPQM1);
}

// -----------------------------------------------------------------------
// HLG Inverse OETF (scene-light EOTF) — BT.2100-2 §5.1.2 (Table 5).
//
// Maps non-linear signal N ∈ [0, 1] → relative scene luminance L_s.
// -----------------------------------------------------------------------
const float kHLGA = 0.17883277;
const float kHLGB = 0.28466892;    // 1 - 4*a
const float kHLGC = 0.55991073;    // 0.5 - a*ln(4*a)

float hlg_inv_oetf(float N) {
	if (N <= 0.0) return 0.0;
	if (N <= 0.5) {
		return (N * N) / 3.0;
	}
	return (exp((N - kHLGC) / kHLGA) + kHLGB) / 12.0;
}

// -----------------------------------------------------------------------
// HLG Reference Display EOTF — BT.2100-2 §5.3.
//
// Maps scene light L_s → display luminance L_d ∈ [0, 1000] cd/m².
// -----------------------------------------------------------------------
float hlg_display_eotf(float N) {
	float L_s = hlg_inv_oetf(N);
	return 1000.0 * pow(L_s, 1.2);
}

// -----------------------------------------------------------------------
// Tone mapper — maps absolute luminance to SDR display-normalized [0, 1].
// Uses a Reinhard-style mapping normalized to reference white (203 cd/m²).
//
// L_display = L_abs / (L_abs + L_tw)
// -----------------------------------------------------------------------
const float kReferenceWhite = 203.0;

float tone_map(float L_abs) {
	if (L_abs <= 0.0) return 0.0;
	float L_n = L_abs / kReferenceWhite;
	return L_n / (1.0 + L_n);
}

// -----------------------------------------------------------------------
// BT.2020 → BT.709 primary matrix — ITU-R BT.2087-0 §2.
// -----------------------------------------------------------------------
vec3 bt2020_to_bt709(vec3 bt2020) {
	return vec3(
		1.6605 * bt2020.r - 0.5876 * bt2020.g - 0.0728 * bt2020.b,
		-0.1249 * bt2020.r + 1.1330 * bt2020.g - 0.0081 * bt2020.b,
		-0.0182 * bt2020.r - 0.0996 * bt2020.g + 1.1178 * bt2020.b
	);
}

// -----------------------------------------------------------------------
// BT.709 OETF — BT.709-6 §2.1.
// -----------------------------------------------------------------------
float bt709_oetf(float L) {
	if (L < 0.0031308) {
		return 12.92 * L;
	}
	return 1.055 * pow(L, 1.0 / 2.4) - 0.055;
}

// -----------------------------------------------------------------------
// BT.709 EOTF (inverse OETF) — BT.709-6 §2.1 / sRGB.
//
// Maps non-linear signal V ∈ [0, 1] → linear luminance L ∈ [0, 1].
// -----------------------------------------------------------------------
float bt709_eotf(float V) {
	if (V < 0.04045) {
		return V / 12.92;
	}
	return pow((V + 0.055) / 1.055, 2.4);
}

// -----------------------------------------------------------------------
// Per-channel HDR → SDR conversion for one rgb triple.
//
// Input:  rgb — non-linear PQ or HLG encoded in BT.2020 primaries.
//         transfer — 2=PQ, 3=HLG (core::TransferFunction enum values).
// Output: rgb — non-linear BT.709, clamped to [0, 1].
// -----------------------------------------------------------------------
vec3 hdr_to_sdr(vec3 rgb, uint transfer) {
	// Step 1: EOTF (non-linear → linear absolute luminance)
	vec3 lin;
	if (transfer == 2u) {
		lin.r = pq_eotf(rgb.r);
		lin.g = pq_eotf(rgb.g);
		lin.b = pq_eotf(rgb.b);
	} else {
		lin.r = hlg_display_eotf(rgb.r);
		lin.g = hlg_display_eotf(rgb.g);
		lin.b = hlg_display_eotf(rgb.b);
	}

	// Step 2: Tone-map individual channels.
	lin.r = tone_map(lin.r);
	lin.g = tone_map(lin.g);
	lin.b = tone_map(lin.b);

	// Step 3: BT.2020 → BT.709 primaries.
	vec3 s709 = bt2020_to_bt709(lin);

	// Step 4: Apply BT.709 OETF for SDR display.
	s709.r = bt709_oetf(clamp(s709.r, 0.0, 1.0));
	s709.g = bt709_oetf(clamp(s709.g, 0.0, 1.0));
	s709.b = bt709_oetf(clamp(s709.b, 0.0, 1.0));

	return clamp(s709, 0.0, 1.0);
}
