#pragma once

// -----------------------------------------------------------------------
// d3d11_interop_device.h — the LUID-matched D3D11 device both Windows
// zero-copy surface importers (Vulkan's DxgiSurfaceImporter and D3D12's
// D3D12SurfaceImporter) compose.
//
// Owns a D3D11 device created on a caller-chosen adapter (matched by LUID so
// the device shares GPU memory with the caller's own graphics device — the
// LUID match is what makes cross-API shared handles openable). What each
// importer does with the device — blits, keyed mutexes, NT-handle exports,
// compute passes, shared fences — is the importer's own business; this type
// knows nothing about Vulkan, D3D12, or Godot's RenderingDevice.
// -----------------------------------------------------------------------

#if defined(_WIN32)

#include <d3d11_1.h> // ID3D11Device
#include <windows.h>

#include "../backends/mf/com_raii.h" // mf::ComPtr

namespace platform_media {

class D3D11InteropDevice {
public:
	D3D11InteropDevice() = default;

	// Move-only (holds move-only ComPtr members); movable so it can be
	// composed by value into a future importer instead of only by pointer.
	D3D11InteropDevice(const D3D11InteropDevice &) = delete;
	D3D11InteropDevice &operator=(const D3D11InteropDevice &) = delete;
	D3D11InteropDevice(D3D11InteropDevice &&) = default;
	D3D11InteropDevice &operator=(D3D11InteropDevice &&) = default;

	// Creates our own ID3D11Device on the adapter whose LUID matches `*luid`
	// (falls back to the first enumerated adapter if `luid` is null or no
	// adapter matches), so the device shares GPU memory with the caller's own
	// graphics device. Returns false on failure; safe to retry.
	bool initialize(const LUID *luid);

	bool is_initialized() const { return static_cast<bool>(d3d_device_); }

	// Borrowed accessors for the composing importer, which drives the device
	// directly for its own per-frame work (blits, compute passes, shared-
	// resource exports, fence bootstrap).
	ID3D11Device *device() const { return d3d_device_.get(); }
	ID3D11DeviceContext *context() const { return d3d_context_.get(); }

private:
	mf::ComPtr<ID3D11Device> d3d_device_;
	mf::ComPtr<ID3D11DeviceContext> d3d_context_;
};

} // namespace platform_media

#endif // _WIN32
