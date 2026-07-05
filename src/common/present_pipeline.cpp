// -----------------------------------------------------------------------
// present_pipeline.cpp — zero-copy NV12->RGB present pipeline (ADR-0003).
// -----------------------------------------------------------------------

#include "present_pipeline.h"

#include <cstring>

#include <godot_cpp/classes/rd_sampler_state.hpp>
#include <godot_cpp/classes/rd_shader_source.hpp>
#include <godot_cpp/classes/rd_shader_spirv.hpp>
#include <godot_cpp/classes/rd_texture_format.hpp>
#include <godot_cpp/classes/rd_texture_view.hpp>
#include <godot_cpp/classes/rd_uniform.hpp>
#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/core/error_macros.hpp>
#include <godot_cpp/variant/typed_array.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

using namespace godot;

namespace platform_media {

// The compute shader source. Kept in sync with nv12_to_rgb.glsl (the .glsl
// file is the human-readable authored copy + the import artifact for tooling;
// we compile this embedded copy at runtime so the pipeline is self-contained
// and does not depend on the resource import step). BT.709 8-bit video-range.
static const char *kNv12ToRgbCompute = R"GLSL(
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D luma_plane;
layout(set = 0, binding = 1) uniform sampler2D chroma_plane;
layout(set = 0, binding = 2, rgba8) uniform restrict writeonly image2D rgba_out;

layout(push_constant, std430) uniform Params {
	uint out_width;
	uint out_height;
	uint pad0; // explicit pad to 16 bytes: Godot 4.7+ validates the supplied
	uint pad1; // push-constant size against the shader's exact declared size
} params;

void main() {
	uvec2 gid = gl_GlobalInvocationID.xy;
	if (gid.x >= params.out_width || gid.y >= params.out_height) {
		return;
	}
	vec2 uv = (vec2(gid) + vec2(0.5)) / vec2(params.out_width, params.out_height);
	float y = texture(luma_plane, uv).r;
	vec2 cbcr = texture(chroma_plane, uv).rg;
	float yf = (y * 255.0 - 16.0) / 219.0;
	float cb = (cbcr.r * 255.0 - 128.0) / 224.0;
	float cr = (cbcr.g * 255.0 - 128.0) / 224.0;
	vec3 rgb;
	rgb.r = yf + 1.5748 * cr;
	rgb.g = yf - 0.1873 * cb - 0.4681 * cr;
	rgb.b = yf + 1.8556 * cb;
	rgb = clamp(rgb, 0.0, 1.0);
	imageStore(rgba_out, ivec2(gid), vec4(rgb, 1.0));
}
)GLSL";

PresentPipeline::~PresentPipeline() {
	shutdown();
}

bool PresentPipeline::ensure_ready(int width, int height) {
	if (width <= 0 || height <= 0) {
		return false;
	}
	if (ready_ && width == width_ && height == height_) {
		return true;
	}
	// Dimensions changed (or first use): rebuild. Drain held surfaces first so
	// we don't leak the old ring's transient textures.
	if (ready_) {
		retire_ring_.drain();
		free_resources();
	}
	return build_resources(width, height);
}

bool PresentPipeline::build_resources(int width, int height) {
	// Use the global RenderingDevice — the present output must live on the same
	// device Godot samples from when compositing the VideoStreamPlayer.
	RenderingServer *rs = RenderingServer::get_singleton();
	ERR_FAIL_NULL_V_MSG(rs, false, "RenderingServer unavailable");
	rd_ = rs->get_rendering_device();
	ERR_FAIL_NULL_V_MSG(rd_, false,
			"No RenderingDevice — requires a Forward+/Mobile renderer (ADR-0002).");

	// Build the per-platform surface importer (Metal on macOS, DXGI->Vulkan on
	// Windows) lazily, then bind it to Godot's RD.
	if (!importer_) {
		importer_ = make_surface_importer();
	}
	if (!importer_ || !importer_->initialize(rd_)) {
		ERR_PRINT("Surface importer init failed (RD backend not supported by importer?).");
		return false;
	}

	// --- Compile the NV12->RGB compute shader from embedded GLSL source. ---
	Ref<RDShaderSource> src;
	src.instantiate();
	src->set_language(RenderingDevice::SHADER_LANGUAGE_GLSL);
	src->set_stage_source(RenderingDevice::SHADER_STAGE_COMPUTE, String(kNv12ToRgbCompute));

	Ref<RDShaderSPIRV> spirv = rd_->shader_compile_spirv_from_source(src);
	ERR_FAIL_COND_V_MSG(spirv.is_null(), false, "NV12->RGB shader compile returned null.");
	const String compile_err = spirv->get_stage_compile_error(RenderingDevice::SHADER_STAGE_COMPUTE);
	ERR_FAIL_COND_V_MSG(!compile_err.is_empty(), false,
			"NV12->RGB shader compile error: " + compile_err);

	shader_ = rd_->shader_create_from_spirv(spirv, "nv12_to_rgb");
	ERR_FAIL_COND_V_MSG(!shader_.is_valid(), false, "shader_create_from_spirv failed.");

	pipeline_ = rd_->compute_pipeline_create(shader_);
	ERR_FAIL_COND_V_MSG(!pipeline_.is_valid(), false, "compute_pipeline_create failed.");

	// Bilinear sampler so the half-res chroma plane upsamples smoothly.
	Ref<RDSamplerState> ss;
	ss.instantiate();
	ss->set_mag_filter(RenderingDevice::SAMPLER_FILTER_LINEAR);
	ss->set_min_filter(RenderingDevice::SAMPLER_FILTER_LINEAR);
	sampler_ = rd_->sampler_create(ss);
	ERR_FAIL_COND_V_MSG(!sampler_.is_valid(), false, "sampler_create failed.");

	// --- N engine-owned RGBA8 storage textures + their Texture2DRD wrappers. ---
	for (size_t i = 0; i < kRingDepth; ++i) {
		Ref<RDTextureFormat> fmt;
		fmt.instantiate();
		fmt->set_format(RenderingDevice::DATA_FORMAT_R8G8B8A8_UNORM);
		fmt->set_width(width);
		fmt->set_height(height);
		fmt->set_depth(1);
		fmt->set_array_layers(1);
		fmt->set_mipmaps(1);
		fmt->set_texture_type(RenderingDevice::TEXTURE_TYPE_2D);
		fmt->set_usage_bits(
				RenderingDevice::TEXTURE_USAGE_STORAGE_BIT |
				RenderingDevice::TEXTURE_USAGE_SAMPLING_BIT |
				RenderingDevice::TEXTURE_USAGE_CAN_COPY_FROM_BIT);

		Ref<RDTextureView> view;
		view.instantiate();

		RID rgba = rd_->texture_create(fmt, view, TypedArray<PackedByteArray>());
		ERR_FAIL_COND_V_MSG(!rgba.is_valid(), false, "RGBA output texture_create failed.");

		ring_[i].rgba_rid = rgba;
	}

	width_ = width;
	height_ = height;
	ring_index_ = 0;
	// Point the stable output texture at slot 0 (creates it if the player has
	// not asked for it yet). This fires `changed`, so the cached texture in
	// VideoStreamPlayer picks up the real dimensions.
	get_texture()->set_texture_rd_rid(ring_[0].rgba_rid);
	ready_ = true;
	return true;
}

bool PresentPipeline::present(core::VideoFrame &&frame) {
	if (!ensure_ready(frame.width, frame.height)) {
		// Couldn't build the pipeline; still run the frame's own release so the
		// decoder pool can recycle the surface (parked in the ring below would be
		// cleaner, but the ring isn't ready). Retire immediately.
		if (frame.release) {
			frame.release();
		}
		return false;
	}

	// Age the retire-ring by one rendered frame BEFORE parking this frame's
	// surfaces. advance() releases whatever was parked kFrameLatency frames ago.
	retire_ring_.advance();

	// Import the decoder surface zero-copy into two RD plane textures. No CPU
	// copy happens here — the importer aliases the decoder's surface memory
	// (CVMetalTextureCache on macOS; a Vulkan image opened from the DXGI shared
	// handle on Windows). cpu_pixels_size carries the texture-array slice index
	// on Windows (see surface_importer.h); the Metal importer ignores it.
	PlaneTextures planes = importer_->import(
			frame.native_handle, static_cast<uint32_t>(frame.cpu_pixels_size));
	if (!planes.valid()) {
		// Import failed (wrong format / non-Metal). Retire the frame now.
		if (frame.release) {
			frame.release();
		}
		return false;
	}

	// Advance the output ring slot.
	ring_index_ = (ring_index_ + 1) % kRingDepth;
	RingSlot &slot = ring_[ring_index_];

	// --- Build the uniform set: luma(0), chroma(1), rgba_out(2). ---
	Ref<RDUniform> u_luma;
	u_luma.instantiate();
	u_luma->set_uniform_type(RenderingDevice::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE);
	u_luma->set_binding(0);
	u_luma->add_id(sampler_);
	u_luma->add_id(planes.luma);

	Ref<RDUniform> u_chroma;
	u_chroma.instantiate();
	u_chroma->set_uniform_type(RenderingDevice::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE);
	u_chroma->set_binding(1);
	u_chroma->add_id(sampler_);
	u_chroma->add_id(planes.chroma);

	Ref<RDUniform> u_out;
	u_out.instantiate();
	u_out->set_uniform_type(RenderingDevice::UNIFORM_TYPE_IMAGE);
	u_out->set_binding(2);
	u_out->add_id(slot.rgba_rid);

	TypedArray<RDUniform> uniforms;
	uniforms.push_back(u_luma);
	uniforms.push_back(u_chroma);
	uniforms.push_back(u_out);

	RID uniform_set = rd_->uniform_set_create(uniforms, shader_, 0);
	if (!uniform_set.is_valid()) {
		// Import succeeded but the set didn't; retire planes + frame now.
		if (planes.release) {
			planes.release();
		}
		if (frame.release) {
			frame.release();
		}
		return false;
	}

	// Push constant: output dimensions + explicit shader-side padding = 16 bytes.
	// Must exactly match the shader's declared Params size (Godot 4.7+ validates).
	PackedByteArray pc;
	pc.resize(16);
	{
		uint8_t *w = pc.ptrw();
		const uint32_t ow = static_cast<uint32_t>(width_);
		const uint32_t oh = static_cast<uint32_t>(height_);
		memcpy(w + 0, &ow, sizeof(uint32_t)); // shader/uniform metadata, NOT a pixel copy
		memcpy(w + 4, &oh, sizeof(uint32_t));
		memset(w + 8, 0, 8);
	}

	// On platforms that share the decoder surface across two GPU APIs, wait for
	// the exporting side's work to be visible before we sample it: a CPU-blocking
	// wait on a shared D3D11/D3D12 fence on the D3D12 RD path (may stall this
	// thread until the D3D11 plane-split compute pass finishes on the GPU), or a
	// DXGI keyed mutex acquire on DxgiSurfaceImporter's Vulkan zero-copy path —
	// built and linked but not currently selectable by the factory (ADR-0007).
	// No-op on the CPU-Copy Import Path and on macOS (acquire is null: no
	// cross-API handoff needed, either because there's nothing left for the GPU
	// to do by the time this runs, or because one shared Metal device is used).
	if (planes.acquire) {
		planes.acquire();
	}

	// --- ONE compute dispatch: NV12 -> RGBA into the engine-owned slot. ---
	const int gx = (width_ + 7) / 8;
	const int gy = (height_ + 7) / 8;

	int64_t cl = rd_->compute_list_begin();
	rd_->compute_list_bind_compute_pipeline(cl, pipeline_);
	rd_->compute_list_bind_uniform_set(cl, uniform_set, 0);
	rd_->compute_list_set_push_constant(cl, pc, pc.size());
	rd_->compute_list_dispatch(cl, gx, gy, 1);
	rd_->compute_list_end();

	// Release the keyed mutex back to the decoder (no-op on macOS). The
	// retire-ring still holds the surface for kFrameLatency frames so the GPU
	// has finished the dispatch above before the wrappers are torn down.
	if (planes.release_sync) {
		planes.release_sync();
	}

	// Re-point the stable output texture at the slot the dispatch above wrote.
	// Texture2DRD keeps its RenderingServer-side RID stable across this call, so
	// the player's cached draw commands keep working; only the contents swap.
	current_texture_->set_texture_rd_rid(slot.rgba_rid);

	// Count this frame if the CPU-Copy Import Path produced the
	// planes we just sampled. Stays 0 for the two zero-copy Import Paths.
	if (planes.is_cpu_copy) {
		++cpu_copy_count_;
	}

	// Park this frame's surfaces in the retire-ring for kFrameLatency frames.
	// We bundle: the transient plane textures + CVMetalTexture wrappers, the
	// uniform set, and the decoder VideoFrame's own release closure. They are
	// freed together once the GPU is guaranteed done (N frames later).
	auto plane_release = std::move(planes.release);
	auto frame_release = std::move(frame.release);
	RenderingDevice *rd = rd_;
	retire_ring_.retain([rd, uniform_set, plane_release, frame_release]() {
		if (uniform_set.is_valid()) {
			rd->free_rid(uniform_set);
		}
		if (plane_release) {
			plane_release();
		}
		if (frame_release) {
			frame_release();
		}
	});

	return true;
}

void PresentPipeline::free_resources() {
	if (rd_ == nullptr) {
		return;
	}
	// Detach the stable output texture BEFORE freeing the ring textures so it
	// never dangles. Keep the object itself alive: VideoStreamPlayer holds a
	// cached ref to it, and a rebuild (dimension change) re-points it.
	if (current_texture_.is_valid()) {
		current_texture_->set_texture_rd_rid(RID());
	}
	for (size_t i = 0; i < kRingDepth; ++i) {
		if (ring_[i].rgba_rid.is_valid()) {
			rd_->free_rid(ring_[i].rgba_rid);
			ring_[i].rgba_rid = RID();
		}
	}
	if (pipeline_.is_valid()) {
		rd_->free_rid(pipeline_);
		pipeline_ = RID();
	}
	if (sampler_.is_valid()) {
		rd_->free_rid(sampler_);
		sampler_ = RID();
	}
	if (shader_.is_valid()) {
		rd_->free_rid(shader_);
		shader_ = RID();
	}
	ready_ = false;
	width_ = 0;
	height_ = 0;
}

void PresentPipeline::shutdown() {
	// Release any surfaces still parked in the ring before tearing down RD
	// resources, so plane textures are freed before their owning shader/device.
	retire_ring_.drain();
	free_resources();
	rd_ = nullptr;
}

} // namespace platform_media
