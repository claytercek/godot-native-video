#pragma once

// -----------------------------------------------------------------------
// dxgi_surface_importer.h — Windows half of the zero-copy import.
//
// The Windows analog of metal_surface_importer. It takes a hardware-decoded
// NV12 ID3D11Texture2D (from the Media Foundation Backend) and produces two
// Godot RenderingDevice plane textures — luma (R8) and chroma (RG8) — that the
// SAME nv12_to_rgb.glsl compute pass consumes, WITHOUT any CPU copy of the
// pixel data.
//
// Mechanism (documented in the .cpp; UNVERIFIED on a macOS host):
//   1. Godot's RenderingDevice on Windows is Vulkan. We obtain its VkDevice /
//      VkPhysicalDevice / VkInstance via RenderingDevice::get_driver_resource.
//   2. The MF decoder hands us an ID3D11Texture2D that is NOT shareable, so we
//      blit (GPU-side, no CPU copy) the decoded NV12 slice into an
//      importer-owned D3D11 NV12 texture created with
//      D3D11_RESOURCE_MISC_SHARED_NTHANDLE | ..._SHARED_KEYEDMUTEX.
//   3. We open that texture's DXGI NT shared handle in Vulkan via
//      VK_KHR_external_memory_win32 to get a VkImage aliasing the same GPU
//      memory, then import that VkImage into Godot RD via
//      texture_create_from_extension (one per NV12 plane / aspect).
//   4. A DXGI keyed mutex (or external semaphore) serializes the D3D11 blit
//      against the Vulkan compute pass so neither side reads a surface the other
//      is still writing. The present pipeline drives this via PlaneTextures
//      acquire()/release_sync().
//
// This is the ONLY Windows file that knows about both D3D11/DXGI AND Godot's
// RenderingDevice/Vulkan. The header is plain C++ so the rest of the Binding can
// include it; the implementation is plain C++ (.cpp) using the Win32/D3D/Vulkan
// C APIs.
//
// Lifetime: each import produces a PlaneTextures whose release() frees the
// transient RD texture RIDs and the per-frame Vulkan/DXGI wrappers. The present
// pipeline parks that closure in the retire-ring for N frames so the GPU is done
// sampling before teardown.
//
// STATUS: implemented but NOT compiled/run/verified — no Windows toolchain on
// the authoring host. The GPU-interop chain is novel (see the parent PRD: this
// is a Human-in-the-Loop slice) and needs on-device visual + correctness checks.
// -----------------------------------------------------------------------

#include <cstdint>

#include <godot_cpp/classes/rendering_device.hpp>
#include <godot_cpp/variant/rid.hpp>

#include "surface_importer.h" // PlaneTextures, SurfaceImporter

namespace platform_media {

class DxgiSurfaceImporter final : public SurfaceImporter {
public:
	DxgiSurfaceImporter();
	~DxgiSurfaceImporter() override;

	DxgiSurfaceImporter(const DxgiSurfaceImporter &) = delete;
	DxgiSurfaceImporter &operator=(const DxgiSurfaceImporter &) = delete;

	// Bind to the RenderingDevice and its underlying Vulkan device. Returns false
	// if the RD is not Vulkan or the required external-memory extensions are
	// unavailable. Must be called before import().
	bool initialize(godot::RenderingDevice *rd) override;

	bool is_initialized() const override;

	// Import the NV12 ID3D11Texture2D (passed as an opaque void* ==
	// ID3D11Texture2D*) into two RD plane textures, zero-copy (GPU-only). Returns
	// an invalid PlaneTextures on failure. The importer does NOT take ownership of
	// the decoder texture; the caller's VideoFrame::release still owns it.
	PlaneTextures import(void *d3d11_texture) override;

private:
	struct Impl;
	Impl *impl_ = nullptr; // raw owning PImpl so the header stays plain C++
};

} // namespace platform_media
