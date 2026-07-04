#pragma once

// -----------------------------------------------------------------------
// cpu_copy_surface_importer.h — Windows CPU-Copy Import Path.
//
// The fallback SurfaceImporter for the common case: a stock Vulkan
// RenderingDevice driver on any Godot version. DxgiSurfaceImporter's zero-copy
// Vulkan import is unreachable there (stock Godot never enables
// VK_KHR_external_memory_win32), and D3D12SurfaceImporter needs the d3d12 RD
// driver. This importer keeps hardware decode exactly as it is — the MF
// Backend's IMFDXGIDeviceManager still drives the decoder — and adds a
// GPU->CPU readback so the decoded NV12 surface reaches Godot RD as ordinary
// R8/RG8 textures instead of an aliased import.
//
// This is the ONE Import Path that violates the zero-copy contract, by
// design: it overrides SurfaceImporter::is_zero_copy to return
// false so PresentPipeline::cpu_copy_count() counts it honestly.
//
// Mechanism (see the .cpp for the full readback-ring walkthrough):
//   1. Lazily bind to the SAME ID3D11Device the decoder texture already lives
//      on (ID3D11DeviceChild::GetDevice on the decoder texture) — no adapter
//      matching, no device of our own, no cross-API share to make openable,
//      so none of D3D11InteropDevice's machinery is needed here.
//   2. GPU-blit (CopySubresourceRegion, no CPU copy yet) the decoder's NV12
//      slice into the next slot of an N-buffered ring of CPU-readable D3D11
//      staging textures.
//   3. Map() the ring slot written N-1 frames ago — by then the GPU copy
//      queued in step 2 has had that many frames to finish, so the Map does
//      not stall under normal playback. This also means every presented frame
//      on this path lags its decoded frame by a fixed N-1 rendered frames
//      (not just during startup) — the deliberate cost of never stalling.
//   4. Copy the mapped Y and interleaved UV planes into tightly packed
//      buffers (the CPU copy this path exists to make) and Unmap.
//   5. RD::texture_create (R8 luma, RG8 chroma) + RD::texture_update. Freed by
//      the release closure the retire-ring runs after PresentPipeline::
//      kFrameLatency rendered frames, exactly like the other two Import
//      Paths' transient textures.
// -----------------------------------------------------------------------

#include <cstdint>

#include <godot_cpp/classes/rendering_device.hpp>
#include <godot_cpp/variant/rid.hpp>

#include "surface_importer.h" // PlaneTextures, SurfaceImporter

namespace platform_media {

class CpuCopySurfaceImporter final : public SurfaceImporter {
public:
	CpuCopySurfaceImporter();
	~CpuCopySurfaceImporter() override;

	CpuCopySurfaceImporter(const CpuCopySurfaceImporter &) = delete;
	CpuCopySurfaceImporter &operator=(const CpuCopySurfaceImporter &) = delete;

	// Always succeeds for a non-null RD: unlike the zero-copy importers, this
	// path needs no particular RD driver or GPU extension — RD::texture_create /
	// texture_update are driver-agnostic Godot APIs.
	bool initialize(godot::RenderingDevice *rd) override;

	bool is_initialized() const override;

	// The one Import Path that is not zero-copy, by design; see the file header.
	bool is_zero_copy() const override { return false; }

	// Import the NV12 ID3D11Texture2D (passed as an opaque void* ==
	// ID3D11Texture2D*) into two RD plane textures via a GPU->CPU readback.
	// Returns an invalid PlaneTextures on failure, OR while the readback ring
	// is still warming up (the first few frames after initialize()).
	//
	// `plane_slice` is the texture-array slice holding THIS frame (see
	// surface_importer.h for why).
	PlaneTextures import(void *d3d11_texture, uint32_t plane_slice) override;

private:
	struct Impl;
	Impl *impl_ = nullptr; // raw owning PImpl so the header stays plain C++
};

} // namespace platform_media
