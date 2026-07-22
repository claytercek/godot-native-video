#[compute]
#version 450

#ifndef HDR_OUTPUT
#define HDR_OUTPUT 0
#endif

// -----------------------------------------------------------------------
// nv12_to_rgb.glsl — the single GPU pass of the zero-copy present pipeline.
//
// Inputs are the two planes of a hardware-decoded biplanar Y'CbCr surface,
// imported zero-copy from the decoder's CVPixelBuffer/IOSurface via
// RenderingDevice::texture_create_from_extension (no CPU upload):
//   - binding 0: luma plane  Y   — R8 or R16   (full resolution, value in .r)
//   - binding 1: chroma plane CbCr — RG8 or RG16 (half res, Cb in .r, Cr in .g)
//
// Output is an engine-owned storage image that Godot samples through a
// Texture2DRD. Godot never samples the decoder planes directly. This file
// is compiled twice (see shaders.zig, which embeds and preprocesses the
// source at comptime): once with no defines for the SDR variant, and once
// with HDR_OUTPUT=1 for the HDR variant.
//
// Colour math: the YCbCr matrix and video/full-range normalisation are
// selected by the push constants from per-frame metadata (matrix_select,
// range_select, bit_depth), so BT.601 SD clips, BT.2020 UHD clips, and 10-bit
// sources all decode correctly. Untagged clips default to BT.709 video range
// 8-bit.
//
// Output modes (HDR_OUTPUT):
//   * SDR (0, default): writes rgba8. When transfer_select is PQ (2) or HLG
//     (3), the shader linearises via the correct EOTF, tone-maps to SDR range
//     using a Reinhard-style operator (peak normalised to the 203-nit
//     Reference White target per BT.2408-2), and maps BT.2020 primaries to
//     BT.709 by matrix-then-clip — HDR content degrades gracefully to a
//     clamped SDR output that's readable on any display with no
//     configuration. The colour math functions live in hdr_color_math.glsl,
//     which is #included here and whose source text is parsed and checked
//     against the Zig constants by color_matrix_test.zig.
//   * HDR (1): writes rgba16f and emits scene-linear values scaled so 1.0
//     represents 203-nit Reference White (BT.2408): PQ and HLG are decoded
//     via their EOTFs and normalised by the reference white, while SDR
//     content is linearised via the BT.709 EOTF onto the same scale. There is
//     no tone-mapping, no gamut conversion, and no headroom clamping — values
//     > 1.0 survive naturally in fp16 for Godot's use_hdr_2d compositor,
//     which owns the display-referred transfer function.
// -----------------------------------------------------------------------

#include "hdr_color_math.glsl"

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D luma_plane;
layout(set = 0, binding = 1) uniform sampler2D chroma_plane;
#if HDR_OUTPUT
layout(set = 0, binding = 2, rgba16f) uniform restrict writeonly image2D rgba_out;
#else
layout(set = 0, binding = 2, rgba8) uniform restrict writeonly image2D rgba_out;
#endif

layout(push_constant, std430) uniform Params {
	uint out_width;
	uint out_height;
	uint matrix_select;  // 0=Unspecified, 1=BT.709, 2=BT.601, 3=BT.2020 (core.ColorMatrix)
	uint range_select;   // 0=Unspecified, 1=Video, 2=Full (core.ColorRange)
	uint bit_depth;      // 8 or 10
	uint transfer_select; // 0=Unspecified, 1=BT.709, 2=PQ, 3=HLG (core.TransferFunction)
	uint primaries_select; // 0=Unspecified, 1=BT.709, 2=BT.601_625, 3=BT.601_525,
	                       // 4=BT.2020, 5=DCI_P3 (core.ColorPrimaries)
	float sample_scale; // 10-bit code recovery: code = texel * 65535 * sample_scale.
	                    // 1.0 for every path that stores right-justified codes;
	                    // 1/64 for the Vulkan Zero-Copy Path's P010 import, whose
	                    // plane views alias left-justified P010 memory
	                    // (surface_importer.zig).
	                    // Occupying the former pad slot keeps the block a 16-byte
	                    // multiple: pre-4.7 Godot rounds the required
	                    // push-constant size up to 32, 4.7+ validates the exact
	                    // declared size — 32 bytes satisfies both.
} params;

void main() {
	uvec2 gid = gl_GlobalInvocationID.xy;
	if (gid.x >= params.out_width || gid.y >= params.out_height) {
		return;
	}

	vec2 uv = (vec2(gid) + vec2(0.5)) / vec2(params.out_width, params.out_height);

	float y = texture(luma_plane, uv).r;
	vec2 cbcr = texture(chroma_plane, uv).rg;

	// ---- Range normalisation ----
	float yf, cb, cr;
	if (params.bit_depth == 10u) {
		float y10 = y * 65535.0 * params.sample_scale;
		float cb10 = cbcr.r * 65535.0 * params.sample_scale;
		float cr10 = cbcr.g * 65535.0 * params.sample_scale;
		if (params.range_select <= 1u) {
			yf = (y10 - 64.0) / 876.0;
			cb = (cb10 - 512.0) / 896.0;
			cr = (cr10 - 512.0) / 896.0;
		} else {
			yf = y10 / 1023.0;
			cb = (cb10 - 512.0) / 1023.0;
			cr = (cr10 - 512.0) / 1023.0;
		}
	} else {
		float y8 = y * 255.0;
		float cb8 = cbcr.r * 255.0;
		float cr8 = cbcr.g * 255.0;
		if (params.range_select <= 1u) {
			yf = (y8 - 16.0) / 219.0;
			cb = (cb8 - 128.0) / 224.0;
			cr = (cr8 - 128.0) / 224.0;
		} else {
			yf = y8 / 255.0;
			cb = (cb8 - 128.0) / 255.0;
			cr = (cr8 - 128.0) / 255.0;
		}
	}

	// ---- YCbCr -> RGB matrix ----
	// BT.601 (SD):    R=Y+1.40200*Cr   G=Y-0.34414*Cb-0.71414*Cr   B=Y+1.77200*Cb
	// BT.709 (HD):    R=Y+1.57480*Cr   G=Y-0.18732*Cb-0.46812*Cr   B=Y+1.85560*Cb
	// BT.2020 (UHD):  R=Y+1.47460*Cr   G=Y-0.16455*Cb-0.57135*Cr   B=Y+1.88140*Cb
	vec3 rgb;
	if (params.matrix_select == 2u) {
		rgb.r = yf + 1.40200 * cr;
		rgb.g = yf - 0.34414 * cb - 0.71414 * cr;
		rgb.b = yf + 1.77200 * cb;
	} else if (params.matrix_select == 3u) {
		rgb.r = yf + 1.47460 * cr;
		rgb.g = yf - 0.16455 * cb - 0.57135 * cr;
		rgb.b = yf + 1.88140 * cb;
	} else {
		rgb.r = yf + 1.57480 * cr;
		rgb.g = yf - 0.18732 * cb - 0.46812 * cr;
		rgb.b = yf + 1.85560 * cb;
	}

#if HDR_OUTPUT
	// ---- Scene-linear HDR output (no clamping, no tone-mapping) ----
	// Values are scaled so 1.0 = 203-nit Reference White (BT.2408).
	if (params.transfer_select == 2u) {
		// PQ: decode to nits, then normalise by reference white.
		rgb.r = pq_eotf(rgb.r) / kReferenceWhite;
		rgb.g = pq_eotf(rgb.g) / kReferenceWhite;
		rgb.b = pq_eotf(rgb.b) / kReferenceWhite;
	} else if (params.transfer_select == 3u) {
		// HLG: scene-light OETF inverse then display OOTF, normalise.
		rgb.r = hlg_display_eotf(rgb.r) / kReferenceWhite;
		rgb.g = hlg_display_eotf(rgb.g) / kReferenceWhite;
		rgb.b = hlg_display_eotf(rgb.b) / kReferenceWhite;
	} else {
		// SDR: BT.709 EOTF — linearise onto the same scene-linear scale.
		// Per BT.2408-2, SDR graphics white (digital 1.0) maps to the 203-nit
		// Reference White, i.e. exactly 1.0 on this 1.0=203-nit scale — so SDR
		// content composites correctly in the HDR viewport alongside HDR clips.
		rgb.r = bt709_eotf(clamp(rgb.r, 0.0, 1.0));
		rgb.g = bt709_eotf(clamp(rgb.g, 0.0, 1.0));
		rgb.b = bt709_eotf(clamp(rgb.b, 0.0, 1.0));
	}
#else
	// ---- HDR graceful degradation ----
	// When the transfer function is PQ (2) or HLG (3), linearise via the
	// correct EOTF, tone-map to SDR range, and convert primaries to BT.709.
	// The clamped SDR output is readable on any display with no configuration.
	if (params.transfer_select == 2u || params.transfer_select == 3u) {
		rgb = hdr_to_sdr(rgb, params.transfer_select);
	} else {
		rgb = clamp(rgb, 0.0, 1.0);
	}
#endif

	imageStore(rgba_out, ivec2(gid), vec4(rgb, 1.0));
}
