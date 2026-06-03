#pragma once

// -----------------------------------------------------------------------
// present_pipeline.h — the zero-copy NV12->RGB present pipeline (ADR-0003).
//
// Owns, on Godot's RenderingDevice:
//   - the NV12->RGB compute shader + pipeline + sampler,
//   - an N-buffered ring of engine-owned RGBA8 storage textures, each wrapped
//     in a Texture2DRD that Godot samples,
//   - a SurfaceImporter (Metal on macOS, DXGI->Vulkan on Windows; chosen by the
//     make_surface_importer() factory) that turns a decoder surface into two RD
//     plane textures with no CPU copy,
//   - a RetireRing<N> that holds each frame's transient surfaces for N
//     rendered frames so the GPU never reads a freed surface.
//
// present(frame) runs ONE compute dispatch (NV12->RGB) into the next ring
// slot and returns the matching Texture2DRD via get_texture(). There is NO
// Image / ImageTexture / memcpy on this path — the only data movement is on
// the GPU. A debug cpu_copy_count() counter stays at 0 to make that auditable.
// -----------------------------------------------------------------------

#include <cstdint>
#include <memory>

#include <godot_cpp/classes/rendering_device.hpp>
#include <godot_cpp/classes/texture2drd.hpp>
#include <godot_cpp/variant/rid.hpp>

#include "../core/backend.h"    // core::VideoFrame
#include "../core/retire_ring.h"
#include "surface_importer.h"   // SurfaceImporter, PlaneTextures, factory

namespace platform_media {

class PresentPipeline {
public:
	// Number of rendered frames a decoder surface is held before retirement,
	// and the depth of the engine-owned RGBA output ring. Godot's render
	// pipeline is at most a few frames deep; 3 is a safe, cheap bound.
	static constexpr size_t kFrameLatency = 3;
	static constexpr size_t kRingDepth = kFrameLatency;

	PresentPipeline() = default;
	~PresentPipeline();

	PresentPipeline(const PresentPipeline &) = delete;
	PresentPipeline &operator=(const PresentPipeline &) = delete;

	// Lazily build the RD resources for a `width`x`height` frame. Safe to call
	// every frame; rebuilds only when the dimensions change or on first use.
	// Returns false if RD is unavailable or the device is not Metal.
	bool ensure_ready(int width, int height);

	bool is_ready() const { return ready_; }

	// Present one decoded frame: import its NV12 planes zero-copy, run the
	// NV12->RGB compute pass into the next RGBA ring slot, and retire surfaces
	// that have aged out. Call once per rendered frame on the render thread.
	// `frame.native_handle` is the platform decoder surface (CVPixelBufferRef on
	// macOS, ID3D11Texture2D* on Windows). Returns true if a GPU pass ran. The
	// frame's own release() is parked in the retire-ring.
	bool present(core::VideoFrame &&frame);

	// The engine-owned RGBA Texture2DRD currently holding the latest frame.
	// Returned from VideoStreamPlayback::_get_texture(). Never the decoder
	// surface — Godot samples only this.
	godot::Ref<godot::Texture2DRD> get_texture() const { return current_texture_; }

	// Debug instrumentation: number of CPU pixel copies performed on the present
	// path. MUST stay 0 — the perf contract (ADR-0003) forbids CPU copies.
	uint64_t cpu_copy_count() const { return cpu_copy_count_; }

	// Tear down all RD resources and drain the retire-ring.
	void shutdown();

private:
	struct RingSlot {
		godot::RID rgba_rid;                  // RD storage texture (rgba8)
		godot::Ref<godot::Texture2DRD> tex;   // Texture2DRD wrapping rgba_rid
	};

	bool build_resources(int width, int height);
	void free_resources();

	godot::RenderingDevice *rd_ = nullptr; // borrowed: the global RD
	// Per-platform importer chosen at link time by make_surface_importer().
	std::unique_ptr<SurfaceImporter> importer_;

	godot::RID shader_;
	godot::RID pipeline_;
	godot::RID sampler_;

	RingSlot ring_[kRingDepth];
	size_t ring_index_ = 0;

	godot::Ref<godot::Texture2DRD> current_texture_;

	// Holds each presented frame's surfaces (plane-texture release + the
	// VideoFrame's own decoder release) for kFrameLatency rendered frames.
	core::RetireRing<kFrameLatency> retire_ring_;

	int width_ = 0;
	int height_ = 0;
	bool ready_ = false;

	uint64_t cpu_copy_count_ = 0; // invariant: always 0 on the present path
};

} // namespace platform_media
