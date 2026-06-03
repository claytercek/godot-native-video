#[compute]
#version 450

// -----------------------------------------------------------------------
// nv12_to_rgb.glsl — the single GPU pass of the zero-copy present pipeline
// (ADR-0003).
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
// Colour math: BT.709, 8-bit, *video range* (Y' in [16,235], Cb/Cr in
// [16,240]) — this matches kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
// requested by the AVFoundation backend.
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

	// Video-range -> full-range normalisation.
	//   Y'  : (255*Y - 16) / 219
	//   Cb/Cr: (255*C - 128) / 224, centred at 0.
	float yf = (y * 255.0 - 16.0) / 219.0;
	float cb = (cbcr.r * 255.0 - 128.0) / 224.0;
	float cr = (cbcr.g * 255.0 - 128.0) / 224.0;

	// BT.709 YCbCr -> linear-ish RGB (the standard non-linear-to-display matrix;
	// we keep the encoded transfer, i.e. output is BT.709 gamma-encoded RGB,
	// which is what a stock sRGB-ish sampling pipeline expects for SDR video).
	vec3 rgb;
	rgb.r = yf + 1.5748 * cr;
	rgb.g = yf - 0.1873 * cb - 0.4681 * cr;
	rgb.b = yf + 1.8556 * cb;

	rgb = clamp(rgb, 0.0, 1.0);

	imageStore(rgba_out, ivec2(gid), vec4(rgb, 1.0));
}
