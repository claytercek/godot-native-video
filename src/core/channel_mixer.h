#pragma once

// -----------------------------------------------------------------------
// channel_mixer.h — deterministic channel-format converter (Engine Core).
//
// The canonical mix format for a clip is the maximum channel count across all
// audio tracks. Backends emit each track's native channel layout (1/2/6 ch).
// This mixer converts any supported source layout to any supported target
// layout using fixed float constants so the result is identical on every
// platform — no OS-level mixer, no platform rounding, no undefined behaviour.
//
// The contract is total: mix_channels() always writes exactly
// frame_count * dst_channels floats and never reads or writes outside the
// buffers the caller sized for those channel counts, regardless of what
// src_channels and dst_channels are.
//
// Supported layouts (by channel count), with semantic downmix/upmix rules:
//   1  — Mono                (C)
//   2  — Stereo              (L, R)
//   6  — 5.1 surround        (L, R, C, LFE, Ls, Rs)  — SMPTE/ITU-R BS.775
//
// Mixing conventions for the layouts above:
//   * LFE (subwoofer) content is EXCLUDED from all downmixes (consumer-side
//     bass management reproduces it from the mains).
//   * Surround channels (Ls, Rs) are attenuated 3 dB relative to mains in
//     downmixes (coefficient 0.707 ≈ 1/√2, typed as a float literal).
//   * Upmixes place source content into the semantically closest channels:
//     mono centre -> centre-only in 5.1, both L/R in stereo; stereo -> mains
//     only in 5.1 (no phantom centre).
//   * All coefficients are float literals — no std::sqrt, no pow, no
//     platform-varying math functions.
//
// Everything else — any (src_channels, dst_channels) pair not listed above,
// including source or destination layouts we don't understand (3, 4, 5, 7,
// 8+ channels) — falls back to a documented, layout-agnostic behaviour:
// copy the first min(src_channels, dst_channels) samples of each frame and
// zero any remaining destination channels. This is a known limitation, not
// an error: we have no semantic mapping for those layouts, so we preserve
// as many channels as fit and stay silent (never garbage) on the rest.
// -----------------------------------------------------------------------

#include <algorithm>
#include <cstddef>
#include <cstring>

namespace core {

// Channel counts this mixer understands semantically (1/2/6, per the layouts
// documented above). It no longer gates a memcpy passthrough threshold —
// anything outside these layouts still gets a correct, if generic, mix via
// the copy-min-channels fallback.
inline constexpr int kMaxMixSourceChannels = 6;

// Mix interleaved PCM float32 samples from `src_channels` to `dst_channels`.
//
//   src           : input samples (frame_count * src_channels interleaved floats).
//   src_channels  : number of input channels.
//   dst           : output buffer (frame_count * dst_channels floats).
//   dst_channels  : number of output channels.
//   frame_count   : number of PCM frames to convert.
//
// src and dst must not overlap. dst must be sized for frame_count *
// dst_channels floats; this function always writes exactly that many floats
// and never more, so callers can size dst from dst_channels alone.
//
// If frame_count, src_channels, or dst_channels is <= 0, nothing is written.
inline void mix_channels(const float *src, int src_channels,
		float *dst, int dst_channels,
		int frame_count) {
	if (frame_count <= 0 || src_channels <= 0 || dst_channels <= 0) {
		return;
	}

	if (src_channels == dst_channels) {
		// Identical layout — single memcpy fast path.
		const size_t n = static_cast<size_t>(frame_count) * static_cast<size_t>(src_channels);
		std::memcpy(dst, src, n * sizeof(float));
		return;
	}

	const bool known_layouts = (src_channels == 1 || src_channels == 2 || src_channels == 6) &&
			(dst_channels == 1 || dst_channels == 2 || dst_channels == 6);

	if (!known_layouts) {
		// Generic fallback: no layout interpretation. Copy the first
		// min(src_channels, dst_channels) samples of each frame and zero
		// anything left over in the destination.
		const int copy_channels = std::min(src_channels, dst_channels);
		for (int f = 0; f < frame_count; ++f) {
			const float *in = src + static_cast<size_t>(f) * static_cast<size_t>(src_channels);
			float *out = dst + static_cast<size_t>(f) * static_cast<size_t>(dst_channels);
			for (int c = 0; c < copy_channels; ++c) {
				out[c] = in[c];
			}
			for (int c = copy_channels; c < dst_channels; ++c) {
				out[c] = 0.0f;
			}
		}
		return;
	}

	// -------------------------------------------------------------------
	// Supported conversions. All coefficients are float literals.
	// -------------------------------------------------------------------

	for (int f = 0; f < frame_count; ++f) {
		const float *in = src + static_cast<size_t>(f) * static_cast<size_t>(src_channels);
		float *out = dst + static_cast<size_t>(f) * static_cast<size_t>(dst_channels);

		// Zero the output frame first so unset channels are silence.
		for (int c = 0; c < dst_channels; ++c) {
			out[c] = 0.0f;
		}

		// --- 1 ch (Mono) -> anything ---
		if (src_channels == 1) {
			const float C = in[0];
			if (dst_channels == 2) {
				// Mono -> Stereo: centre to both L and R.
				out[0] = C;
				out[1] = C;
			} else if (dst_channels == 6) {
				// Mono -> 5.1: centre to C only.
				out[2] = C; // C
				// L, R, LFE, Ls, Rs remain 0.0f
			}
			continue;
		}

		// --- 2 ch (Stereo) -> anything ---
		if (src_channels == 2) {
			const float L = in[0];
			const float R = in[1];
			if (dst_channels == 1) {
				// Stereo -> Mono: equal-weighted sum.
				out[0] = 0.5f * L + 0.5f * R;
			} else if (dst_channels == 6) {
				// Stereo -> 5.1: L -> L, R -> R. C, LFE, Ls, Rs remain 0.
				out[0] = L;
				out[1] = R;
			}
			continue;
		}

		// --- 6 ch (5.1) -> anything ---
		if (src_channels == 6) {
			const float L = in[0];
			const float R = in[1];
			const float C = in[2];
			// in[3] = LFE — excluded from all downmixes
			const float Ls = in[4];
			const float Rs = in[5];

			if (dst_channels == 1) {
				// 5.1 -> Mono: L + R + C + 0.707*(Ls + Rs), scaled by 1/3.414
				// so a full-scale sine in any single channel produces ~0.29 peak
				// (safe from clipping when multiple channels are active).
				out[0] = (L + R + C + 0.707f * (Ls + Rs)) / 3.414f;
			} else if (dst_channels == 2) {
				// 5.1 -> Stereo (ITU-R BS.775 downmix).
				// Lt = L + 0.707*C + 0.707*Ls
				// Rt = R + 0.707*C + 0.707*Rs
				// LFE excluded.
				out[0] = L + 0.707f * C + 0.707f * Ls;
				out[1] = R + 0.707f * C + 0.707f * Rs;
			}
			continue;
		}
	}
}

} // namespace core
