#pragma once

// -----------------------------------------------------------------------
// d3d12_surface_importer.h — Windows/D3D12 half of the zero-copy import.
//
// The D3D12-RD analog of DxgiSurfaceImporter (which targets Godot's Vulkan
// RD). Takes a hardware-decoded NV12 or P010 ID3D11Texture2D (from the Media
// Foundation Backend) and produces two Godot RenderingDevice plane
// textures — luma (R8/R16) and chroma (RG8/RG16) — that the SAME
// nv12_to_rgb.glsl compute pass consumes, WITHOUT any CPU copy of the pixel
// data.
//
// Mechanism (see the .cpp for the full chain and design rationale):
//   1. Compose D3D11InteropDevice for the LUID-matched D3D11 bootstrap, then
//      GPU-blit the decoder slice into a plain intermediate texture of the
//      same format on that device (cached and reused across frames).
//   2. Split that texture's planes into two STANDALONE, independently
//      shareable single-plane textures (R8/RG8 for NV12, R16/RG16 for P010 —
//      rescaled to the right-justified 10-bit-in-16 layout the CPU-Copy
//      Import Path also produces) via a D3D11 compute pass reading PlaneSlice
//      shader-resource views (ID3D11Device3::CreateShaderResourceView1) — a
//      multi-planar texture cannot itself be shared into D3D12 as one
//      resource.
//   3. Share both plane textures via DXGI NT handle and open them on the
//      D3D12 side (ID3D12Device::OpenSharedHandle) as ID3D12Resource, then
//      hand each to RenderingDevice::texture_create_from_extension.
//   4. Synchronize the D3D11 write with the D3D12 read via a shared
//      D3D11.4/D3D12 fence (ID3D11Device5::CreateFence), waited with a
//      CPU-side SetEventOnCompletion + WaitForSingleObject before Godot's
//      compute dispatch runs. No keyed mutex: unsupported for
//      D3D12-opened resources.
//
// This is the D3D12 analog of dxgi_surface_importer.h's role: the only
// Windows file that knows about both D3D11/D3D12 AND Godot's
// RenderingDevice. Selected at runtime (not compile time) by
// make_surface_importer() based on RenderingServer's active rendering
// driver, since both this importer and DxgiSurfaceImporter can be linked
// into the same Windows binary.
// -----------------------------------------------------------------------

#include <cstdint>

#include <godot_cpp/classes/rendering_device.hpp>
#include <godot_cpp/variant/rid.hpp>

#include "surface_importer.h" // PlaneTextures, SurfaceImporter

namespace native_video {

class D3D12SurfaceImporter final : public SurfaceImporter {
public:
	D3D12SurfaceImporter();
	~D3D12SurfaceImporter() override;

	D3D12SurfaceImporter(const D3D12SurfaceImporter &) = delete;
	D3D12SurfaceImporter &operator=(const D3D12SurfaceImporter &) = delete;

	// Bind to the RenderingDevice and its underlying D3D12 device. Returns false
	// if the RD is not D3D12 or the shared-fence/compute-shader bootstrap fails.
	// Must be called before import().
	bool initialize(godot::RenderingDevice *rd) override;

	bool is_initialized() const override;

	// Import the NV12/P010 ID3D11Texture2D (passed as an opaque void* ==
	// ID3D11Texture2D*) into two RD plane textures, zero-copy (GPU-only).
	// Returns an invalid PlaneTextures on failure. The importer does NOT take
	// ownership of the decoder texture; the caller's VideoFrame::release still
	// owns it.
	//
	// `plane_slice` is the texture-array slice holding THIS frame (see
	// surface_importer.h / dxgi_surface_importer.h for why).
	PlaneTextures import(void *d3d11_texture, uint32_t plane_slice) override;

private:
	struct Impl;
	Impl *impl_ = nullptr; // raw owning PImpl so the header stays plain C++
};

} // namespace native_video
