#[compute]
#version 450

// -----------------------------------------------------------------------
// nv12_to_rgb_hdr.glsl — HDR-present variant of the NV12->RGB compute pass.
//
// Identical input bindings as the SDR sibling (nv12_to_rgb.glsl), but the
// output image is RGBA16F and the write path emits scene-linear values scaled
// so 1.0 represents 203-nit Reference White (BT.2408):
//
//   * PQ  → pq_eotf(N) / 203     (nits / reference white)
//   * HLG → hlg_display_eotf(N) / 203
//   * SDR → bt709_eotf(clamp(N, 0, 1))   (linearized, on the same scale)
//
// No tone-mapping, no gamut conversion, no headroom clamping — values > 1.0
// survive naturally in fp16 for Godot's use_hdr_2d compositor, which owns the
// display-referred transfer function.
// -----------------------------------------------------------------------

#include "hdr_color_math.glsl"

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D luma_plane;
layout(set = 0, binding = 1) uniform sampler2D chroma_plane;
layout(set = 0, binding = 2, rgba16f) uniform restrict writeonly image2D rgba_out;

layout(push_constant, std430) uniform Params {
	uint out_width;
	uint out_height;
	uint matrix_select;  // 0=Unspecified, 1=BT.709, 2=BT.601, 3=BT.2020
	uint range_select;   // 0=Unspecified, 1=Video, 2=Full
	uint bit_depth;      // 8 or 10
	uint transfer_select; // 0=Unspecified, 1=BT.709, 2=PQ, 3=HLG
	uint primaries_select; // (unused in HDR mode — no gamut conversion)
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
		float y10 = y * 65535.0;
		float cb10 = cbcr.r * 65535.0;
		float cr10 = cbcr.g * 65535.0;
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
		// SDR reference white (digital 1.0 = ~100 nits) maps to ~0.493 on
		// the 1.0=203-nit scale; SDR content composites correctly in the
		// HDR viewport alongside HDR clips.
		rgb.r = bt709_eotf(clamp(rgb.r, 0.0, 1.0));
		rgb.g = bt709_eotf(clamp(rgb.g, 0.0, 1.0));
		rgb.b = bt709_eotf(clamp(rgb.b, 0.0, 1.0));
	}

	imageStore(rgba_out, ivec2(gid), vec4(rgb, 1.0));
}
