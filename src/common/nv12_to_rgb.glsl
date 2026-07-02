#[compute]
#version 450

// -----------------------------------------------------------------------
// nv12_to_rgb.glsl — the single GPU pass of the zero-copy present pipeline.
//
// Inputs are the two planes of a hardware-decoded biplanar Y'CbCr surface,
// imported zero-copy from the decoder's CVPixelBuffer/IOSurface via
// RenderingDevice::texture_create_from_extension (no CPU upload):
//   - binding 0: luma plane  Y   — R8 or R16   (full resolution, value in .r)
//   - binding 1: chroma plane CbCr — RG8 or RG16 (half res, Cb in .r, Cr in .g)
//
// Output is an engine-owned RGBA8 storage image that Godot samples through a
// Texture2DRD. Godot never samples the decoder planes directly.
//
// Colour math: the YCbCr matrix and video/full-range normalisation are
// selected by the push constants from per-frame metadata (matrix_select,
// range_select, bit_depth), so BT.601 SD clips, BT.2020 UHD clips, and 10-bit
// sources all decode correctly. Untagged clips default to BT.709 video range
// 8-bit (matching the old hard-coded behaviour).
// -----------------------------------------------------------------------

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// Sampled image bindings (combined sampler + texture). We sample with
// normalised coordinates so the half-resolution chroma plane is bilinearly
// upsampled for free by the sampler.
layout(set = 0, binding = 0) uniform sampler2D luma_plane;   // Y  (R8 or R16)
layout(set = 0, binding = 1) uniform sampler2D chroma_plane; // CbCr (RG8 or RG16)

// Engine-owned output. rgba8 storage image.
layout(set = 0, binding = 2, rgba8) uniform restrict writeonly image2D rgba_out;

layout(push_constant, std430) uniform Params {
	uint out_width;
	uint out_height;
	uint matrix_select; // 0=Unspecified, 1=BT.709, 2=BT.601, 3=BT.2020 (core::ColorMatrix)
	uint range_select;  // 0=Unspecified, 1=Video, 2=Full (core::ColorRange)
	uint bit_depth;     // 8 or 10
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

	// Range normalisation — selects video or full range scaling, adjusted for
	// the bit depth of the source. 8-bit samples are R8Unorm (stored as single
	// byte, GPU normalises by /255); 10-bit samples are R16Unorm/RG16Unorm
	// (stored as 16-bit uint with the 10-bit value in the low bits, GPU
	// normalises by /65535). We rescale the GPU read back to the actual code
	// value and apply the bit-depth-correct range limits.
	//
	//     8-bit video: Y [16,235], Cb/Cr [16,240]
	//    10-bit video: Y [64,940], Cb/Cr [64,960]
	//     8-bit full:  Y [0,255],  Cb/Cr [0,255]
	//    10-bit full:  Y [0,1023], Cb/Cr [0,1023]
	float yf, cb, cr;
	if (params.bit_depth == 10u) {
		// 10-bit: R16Unorm gives us stored_value / 65535 in [0,1]. The 10-bit
		// value occupies the low 10 bits of the 16-bit container, so the actual
		// code value is stored_value = gpu_read * 65535 (resulting in [0,1023]).
		float y10 = y * 65535.0;
		float cb10 = cbcr.r * 65535.0;
		float cr10 = cbcr.g * 65535.0;
		if (params.range_select <= 1u) {
			// Video (limited) range — also handles Unspecified (0) and Video (1)
			yf = (y10 - 64.0) / 876.0;
			cb = (cb10 - 512.0) / 896.0;
			cr = (cr10 - 512.0) / 896.0;
		} else {
			// Full range (2): 10-bit [0,1023]
			yf = y10 / 1023.0;
			cb = (cb10 - 512.0) / 1023.0;
			cr = (cr10 - 512.0) / 1023.0;
		}
	} else {
		// 8-bit: R8Unorm gives us stored_value / 255 in [0,1]; the code value
		// is gpu_read * 255 (resulting in [0,255]).
		float y8 = y * 255.0;
		float cb8 = cbcr.r * 255.0;
		float cr8 = cbcr.g * 255.0;
		if (params.range_select <= 1u) {
			// Video (limited) range — also handles Unspecified (0) and Video (1)
			yf = (y8 - 16.0) / 219.0;
			cb = (cb8 - 128.0) / 224.0;
			cr = (cr8 - 128.0) / 224.0;
		} else {
			// Full range (2): 8-bit [0,255]
			yf = y8 / 255.0;
			cb = (cb8 - 128.0) / 255.0;
			cr = (cr8 - 128.0) / 255.0;
		}
	}

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
