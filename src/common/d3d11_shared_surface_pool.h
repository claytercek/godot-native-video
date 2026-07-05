#pragma once

// -----------------------------------------------------------------------
// d3d11_shared_surface_pool.h — D3D11 bootstrap + decoder-slice-blit shared
// by every graphics-API-specific surface importer (Vulkan's DxgiSurfaceImporter
// and D3D12's D3D12SurfaceImporter).
//
// Owns a D3D11 device created on a caller-chosen adapter (matched by LUID so
// the device shares GPU memory with the caller's own graphics device — a
// requirement for cross-API shared handles to be openable) and knows how to
// GPU-blit a decoder's NV12 texture (which is not directly shareable) into a
// fresh shareable NV12 texture, exporting it as a DXGI NT handle the caller
// can open in whatever API it drives (Vulkan via VK_KHR_external_memory_win32;
// D3D12 via ID3D12Device::OpenSharedHandle).
//
// This type knows nothing about Vulkan, D3D12, or Godot's RenderingDevice —
// that keeps it reusable by composition instead of duplicating the D3D11
// setup across importers.
// -----------------------------------------------------------------------

#if defined(_WIN32)

#include <d3d11_1.h> // ID3D11Device, IDXGIKeyedMutex
#include <windows.h>

#include "../backends/mf/com_raii.h" // mf::ComPtr

namespace platform_media {

class D3D11SharedSurfacePool {
public:
	D3D11SharedSurfacePool() = default;

	// Move-only (holds move-only ComPtr members); movable so it can be
	// composed by value into a future importer instead of only by pointer.
	D3D11SharedSurfacePool(const D3D11SharedSurfacePool &) = delete;
	D3D11SharedSurfacePool &operator=(const D3D11SharedSurfacePool &) = delete;
	D3D11SharedSurfacePool(D3D11SharedSurfacePool &&) = default;
	D3D11SharedSurfacePool &operator=(D3D11SharedSurfacePool &&) = default;

	// Creates our own ID3D11Device on the adapter whose LUID matches `*luid`
	// (falls back to the first enumerated adapter if `luid` is null or no
	// adapter matches), so the device shares GPU memory with the caller's own
	// graphics device. Returns false on failure; safe to retry.
	bool initialize(const LUID *luid);

	bool is_initialized() const { return static_cast<bool>(d3d_device_); }

	// Borrowed accessors for callers (e.g. D3D12SurfaceImporter) that need to
	// drive the D3D11 device directly for work this pool doesn't wrap itself,
	// such as a plane-split compute pass or a shared-fence bootstrap.
	ID3D11Device *device() const { return d3d_device_.get(); }
	ID3D11DeviceContext *context() const { return d3d_context_.get(); }

	// One shareable NV12 surface produced by blit_into_shared(): the keyed
	// mutex serializing cross-API access (key 0 == D3D side, key 1 == the
	// caller's side, already released to 1 on return), the exported NT handle
	// (the caller imports it into its own API, then closes it), and the
	// texture itself (kept alive for as long as the caller needs the shared
	// handle to stay valid).
	struct SharedSurface {
		mf::ComPtr<ID3D11Texture2D> texture;
		mf::ComPtr<IDXGIKeyedMutex> keyed_mutex;
		HANDLE shared_handle = nullptr;

		bool valid() const { return texture && shared_handle != nullptr; }
	};

	// GPU-blits (CopySubresourceRegion — no CPU copy) `src_subresource` of
	// `decoder_texture` into a freshly created `width` x `height` shareable
	// NV12 texture, then exports it as a DXGI NT shared handle. Returns an
	// invalid SharedSurface on failure.
	SharedSurface blit_into_shared(ID3D11Texture2D *decoder_texture, UINT src_subresource,
			UINT width, UINT height);

private:
	mf::ComPtr<ID3D11Device> d3d_device_;
	mf::ComPtr<ID3D11DeviceContext> d3d_context_;
};

} // namespace platform_media

#endif // _WIN32
