#pragma once

// -----------------------------------------------------------------------
// surface_importer.h — platform-agnostic surface-import interface.
//
// The zero-copy present pipeline (ADR-0003) imports a hardware-decoded NV12
// surface into Godot's RenderingDevice as two plane textures (luma R8 +
// chroma RG8) WITHOUT any CPU copy, then runs the single NV12->RGB compute
// pass. The *mechanism* of that import is platform-specific:
//
//   - macOS:   CVPixelBuffer IOSurface -> MTLTexture (CVMetalTextureCache)
//              -> RenderingDevice::texture_create_from_extension.
//              (MetalSurfaceImporter, metal_surface_importer.mm)
//   - Windows (Vulkan RD): ID3D11Texture2D NV12 -> DXGI NT shared handle
//              -> Vulkan VK_KHR_external_memory_win32 image
//              -> RenderingDevice::texture_create_from_extension.
//              (DxgiSurfaceImporter, dxgi_surface_importer.cpp)
//   - Windows (D3D12 RD): ID3D11Texture2D NV12 -> D3D11 plane-split compute
//              pass -> two standalone NT-shareable D3D11 textures
//              -> ID3D12Device::OpenSharedHandle -> ID3D12Resource
//              -> RenderingDevice::texture_create_from_extension, synced via
//              a shared D3D11.4/D3D12 fence.
//              (D3D12SurfaceImporter, d3d12_surface_importer.cpp)
//
// This header is the seam between the platform-agnostic Binding (present
// pipeline, video-stream playback) and the per-platform importer. The present
// pipeline holds a SurfaceImporter* obtained from make_surface_importer();
// nothing in the shared path knows which concrete importer is in use. Importer
// selection lives in exactly ONE place (the factory) instead of being
// scattered through the pipeline as #ifdefs — on Windows that selection is a
// runtime check of the active RenderingDevice driver (both DxgiSurfaceImporter
// and D3D12SurfaceImporter are linked in; see
// windows_surface_importer_factory.cpp), since macOS/iOS always run Metal.
//
// PlaneTextures (the import result) is defined here so both importers and the
// present pipeline share one definition.
// -----------------------------------------------------------------------

#include <cstdint>
#include <functional>
#include <memory>

#include <godot_cpp/classes/rendering_device.hpp>
#include <godot_cpp/variant/rid.hpp>

namespace platform_media {

// The two imported plane textures for one NV12 frame, plus a release closure
// that tears down everything created during the import (RD RIDs + the native
// wrapper objects). The caller invokes release() exactly once; the present
// pipeline parks it in the retire-ring for N rendered frames so the GPU is done
// sampling before the wrappers are freed.
struct PlaneTextures {
	godot::RID luma;   // R8, full resolution
	godot::RID chroma; // RG8, half resolution
	int width = 0;     // luma (frame) width
	int height = 0;    // luma (frame) height

	// Frees the RD texture RIDs and releases the native import wrappers.
	// Call exactly once (the retire-ring does this after N frames).
	std::function<void()> release;

	// Optional GPU-sync hooks for platforms that gate decoder<->Godot access on
	// a shared keyed mutex / external semaphore / fence (Windows). On macOS
	// these stay null: CoreVideo + Metal share one device so no cross-device
	// sync object is needed. The present pipeline, if these are set, calls
	// acquire() before the compute dispatch that samples the planes and
	// release_sync() after, so the decoder cannot recycle the surface while the
	// GPU reads it.
	//
	// The blocking behavior of acquire() is importer-specific: DxgiSurfaceImporter's
	// is a non-blocking DXGI keyed-mutex acquire, while D3D12SurfaceImporter's
	// CPU-blocks (SetEventOnCompletion + WaitForSingleObject) until the D3D11
	// plane-split compute pass it depends on has finished on the GPU. Callers
	// must not assume acquire() returns quickly.
	//
	// NOTE: acquire/release_sync are GPU-submission ordering hooks, distinct from
	// the lifetime `release` closure above (which frees the wrappers).
	std::function<void()> acquire;       // keyed-mutex acquire or fence wait (Windows)
	std::function<void()> release_sync;  // keyed-mutex release (Windows)

	bool valid() const { return luma.is_valid() && chroma.is_valid(); }
};

// -----------------------------------------------------------------------
// SurfaceImporter — abstract per-platform NV12 surface importer.
//
// One instance per present pipeline; reused across frames. Concrete importers
// own whatever cache/device state their platform needs (a CVMetalTextureCache
// on macOS; the imported-Vulkan-image bookkeeping on Windows).
// -----------------------------------------------------------------------
class SurfaceImporter {
public:
	virtual ~SurfaceImporter() = default;

	// Bind to Godot's RenderingDevice (and, through it, the underlying GPU
	// device/driver). Returns false if the importer cannot run on this RD (e.g.
	// a non-Metal RD on macOS, or a non-Vulkan RD on Windows). Must be called
	// before import().
	virtual bool initialize(godot::RenderingDevice *rd) = 0;

	virtual bool is_initialized() const = 0;

	// Import a decoder surface (the core::VideoFrame::native_handle: a
	// CVPixelBufferRef on macOS, an ID3D11Texture2D* on Windows) into two RD
	// plane textures, zero-copy. Returns an invalid PlaneTextures on failure.
	// The importer does NOT take ownership of the decoder surface; the caller's
	// VideoFrame::release still owns it.
	//
	// `plane_slice` is the subresource/array-slice index of the frame within
	// native_handle. Windows DXVA decoders hand out frames as slices of one
	// shared D3D11 texture *array*; the MF backend records the slice for each
	// frame in core::VideoFrame::cpu_pixels_size and the present pipeline
	// forwards it here. On macOS a CVPixelBuffer is always a single surface, so
	// the Metal importer ignores it (callers pass 0).
	virtual PlaneTextures import(void *native_handle, uint32_t plane_slice) = 0;
};

// Factory: returns the importer for the current platform and (on Windows)
// RenderingDevice driver. Exactly one implementation of this function is
// linked per platform (metal_surface_importer.mm on macOS/iOS,
// windows_surface_importer_factory.cpp on Windows), so the shared present
// pipeline never sees a platform #ifdef.
std::unique_ptr<SurfaceImporter> make_surface_importer();

} // namespace platform_media
