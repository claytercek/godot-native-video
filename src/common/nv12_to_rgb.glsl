#[compute]
#version 450

// -----------------------------------------------------------------------
// nv12_to_rgb.glsl — the single GPU pass of the zero-copy present pipeline.
//
// Inputs are the two planes of a hardware-decoded NV12 surface, imported
// zero-copy from the decoder's CVPixelBuffer/IOSurface via
// RenderingDevice::texture_create_from_extension (no CPU upload):
//   - binding 0: luma plane  Y   — R8   (full resolution, value in .r)
//   - binding 1: chroma plane CbCr — RG8 (half resolution, Cb in .r, Cr in .g)
//
// Output is an engine-owned RGBA8 storage image that Godot samples through a
// Texture2DRD. Godot never samples the decoder planes directly.
//
// Colour math: the YCbCr matrix and video/full-range normalisation are
// selected by the push constants from per-frame metadata (matrix_select,
// range_select), so BT.601 SD clips and P3-tagged content decode correctly.
// Untagged clips default to BT.709 video range (matching the old hard-coded
// behaviour).
// -----------------------------------------------------------------------

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// Sampled image bindings (combined sampler + texture). We sample with
// normalised coordinates so the half-resolution chroma plane is bilinearly
// upsampled for free by the sampler.
layout(set = 0, binding = 0) uniform sampler2D luma_plane;   // Y
layout(set = 0, binding = 1) uniform sampler2D chroma_plane; // CbCr

// Engine-owned output. rgba8 storage image.
layout(set = 0, binding = 2, rgba8) uniform restrict writeonly image2D rgba_out;

layout(push_constant, std430) uniform Params {
	uint out_width;
	uint out_height;
	uint matrix_select; // 0=Unspecified, 1=BT.709, 2=BT.601, 3=BT.2020 (core::ColorMatrix)
	uint range_select;  // 0=Unspecified, 1=Video, 2=Full (core::ColorRange)
} params;

void main() {
	uvec2 gid = gl_GlobalInvocationID.xy;
	if (gid.x >= params.out_width || gid.y >= params.out_height) {
		return;
	}

	// Normalised sample coordinate at the texel centre. Using normalised UVs
	// lets the sampler upsample the half-res chroma plane (bilinear) without us
	// doing any manual plane-size arithmetic.
	vec2 uv = (vec2(gid) + vec2(0.5)) / vec2(params.out_width, params.out_height);

	float y = texture(luma_plane, uv).r;
	vec2 cbcr = texture(chroma_plane, uv).rg;

	// Range normalisation — selects video or full range scaling.
	//   Video range: Y' in [16,235], Cb/Cr in [16,240]  (9 dB headroom)
	//   Full range:  Y' in [0,255],  Cb/Cr in [0,255]
	float y_scale, y_offset;
	float c_scale, c_offset;
	if (params.range_select <= 1u) {
		// Video (limited) range — also handles Unspecified (0) and Video (1)
		y_scale  = 255.0 / 219.0;
		y_offset = -16.0 / 219.0;
		c_scale  = 255.0 / 224.0;
		c_offset = -128.0 / 224.0;
	} else {
		// Full range
		y_scale  = 1.0;
		y_offset = 0.0;
		c_scale  = 1.0;
		c_offset = -128.0 / 255.0;
	}

	float yf  = y  * y_scale  + y_offset;
	float cb  = cbcr.r * c_scale + c_offset;
	float cr  = cbcr.g * c_scale + c_offset;

	// YCbCr -> RGB matrix selection.
	//
	// Coefficients from ITU-R BT.601 (SD), BT.709 (HD), BT.2020 (UHD).
	//   R = Y +                    Kr * (Cr - 0.5)
	//   G = Y - Kb * (Cb - 0.5) - Kr * (Cr - 0.5)
	//   B = Y + Kb * (Cb - 0.5)
	//
	// where Kr = 0.299,  Kb = 0.114  for BT.601  (R-Y range:  0.701, B-Y range: 0.886)
	//       Kr = 0.2126, Kb = 0.0722 for BT.709  (R-Y range:  0.7874, B-Y range: 0.9278)
	//       Kr = 0.2627, Kb = 0.0593 for BT.2020 (R-Y range: 1.4746, B-Y range: 1.8814)
	//
	// The standard inverse matrices are:
	//   BT.601:    R = Y + 1.40200 * Cr,   G = Y - 0.34414 * Cb - 0.71414 * Cr,   B = Y + 1.77200 * Cb
	//   BT.709:    R = Y + 1.57480 * Cr,   G = Y - 0.18732 * Cb - 0.46812 * Cr,   B = Y + 1.85560 * Cb
	//   BT.2020:   R = Y + 1.47460 * Cr,   G = Y - 0.16455 * Cb - 0.57135 * Cr,   B = Y + 1.88140 * Cb

	vec3 rgb;
	if (params.matrix_select == 2u) {
		// BT.601 (SD)
		rgb.r = yf + 1.40200 * cr;
		rgb.g = yf - 0.34414 * cb - 0.71414 * cr;
		rgb.b = yf + 1.77200 * cb;
	} else if (params.matrix_select == 3u) {
		// BT.2020 (UHD)
		rgb.r = yf + 1.47460 * cr;
		rgb.g = yf - 0.16455 * cb - 0.57135 * cr;
		rgb.b = yf + 1.88140 * cb;
	} else {
		// Default: BT.709 (HD) — also handles Unspecified (0) and BT.709 (1)
		rgb.r = yf + 1.57480 * cr;
		rgb.g = yf - 0.18732 * cb - 0.46812 * cr;
		rgb.b = yf + 1.85560 * cb;
	}

	rgb = clamp(rgb, 0.0, 1.0);

	imageStore(rgba_out, ivec2(gid), vec4(rgb, 1.0));
}
