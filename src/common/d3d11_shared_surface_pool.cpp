#include "d3d11_shared_surface_pool.h"

#if defined(_WIN32)

#include <godot_cpp/core/error_macros.hpp>

#include <cstring> // std::memcmp
#include <utility> // std::move

#include <dxgi1_2.h>

using mf::ComPtr;

namespace platform_media {

bool D3D11SharedSurfacePool::initialize(const LUID *luid) {
	ComPtr<IDXGIFactory1> factory;
	if (FAILED(CreateDXGIFactory1(IID_PPV_ARGS(factory.put())))) {
		ERR_PRINT("D3D11SharedSurfacePool init: CreateDXGIFactory1 failed.");
		return false;
	}

	ComPtr<IDXGIAdapter1> chosen;
	for (UINT i = 0;; ++i) {
		ComPtr<IDXGIAdapter1> adapter;
		if (factory->EnumAdapters1(i, adapter.put()) == DXGI_ERROR_NOT_FOUND) {
			break;
		}
		DXGI_ADAPTER_DESC1 desc = {};
		adapter->GetDesc1(&desc);
		if (luid != nullptr && std::memcmp(&desc.AdapterLuid, luid, sizeof(LUID)) == 0) {
			chosen = std::move(adapter);
			break;
		}
		if (!chosen) {
			chosen = std::move(adapter); // fallback to the first adapter
		}
	}

	UINT d3d_flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT;
	D3D_FEATURE_LEVEL got = D3D_FEATURE_LEVEL_11_1;
	HRESULT hr = D3D11CreateDevice(
			chosen.get(),
			chosen ? D3D_DRIVER_TYPE_UNKNOWN : D3D_DRIVER_TYPE_HARDWARE,
			nullptr, d3d_flags, nullptr, 0, D3D11_SDK_VERSION,
			d3d_device_.put(), &got, d3d_context_.put());
	if (FAILED(hr) || !d3d_device_) {
		ERR_PRINT("D3D11SharedSurfacePool init: D3D11CreateDevice failed on the matched adapter.");
		return false;
	}

	return true;
}

D3D11SharedSurfacePool::SharedSurface D3D11SharedSurfacePool::blit_into_shared(
		ID3D11Texture2D *decoder_texture, UINT src_subresource, UINT width, UINT height) {
	SharedSurface out;
	if (!is_initialized() || decoder_texture == nullptr) {
		return out;
	}

	// --- Create a shareable NV12 staging texture on our D3D device. ---
	D3D11_TEXTURE2D_DESC shared_desc = {};
	shared_desc.Width = width;
	shared_desc.Height = height;
	shared_desc.MipLevels = 1;
	shared_desc.ArraySize = 1;
	shared_desc.Format = DXGI_FORMAT_NV12;
	shared_desc.SampleDesc.Count = 1;
	shared_desc.Usage = D3D11_USAGE_DEFAULT;
	shared_desc.BindFlags = D3D11_BIND_SHADER_RESOURCE;
	shared_desc.MiscFlags =
			D3D11_RESOURCE_MISC_SHARED_NTHANDLE | D3D11_RESOURCE_MISC_SHARED_KEYEDMUTEX;

	ComPtr<ID3D11Texture2D> shared_tex;
	if (FAILED(d3d_device_->CreateTexture2D(&shared_desc, nullptr, shared_tex.put()))) {
		ERR_PRINT("D3D11SharedSurfacePool: shareable NV12 texture create failed.");
		return out;
	}

	// Keyed mutex for cross-API sync. Key 0 == "D3D owns it", key 1 == "the
	// caller's API owns it". We acquire 0 here on the D3D side, blit, release
	// to 1.
	ComPtr<IDXGIKeyedMutex> keyed;
	if (FAILED(shared_tex->QueryInterface(IID_PPV_ARGS(keyed.put())))) {
		ERR_PRINT("D3D11SharedSurfacePool: keyed mutex query failed.");
		return out;
	}

	// --- GPU blit the decoded frame into the shared texture. No CPU copy. ---
	if (FAILED(keyed->AcquireSync(0, INFINITE))) {
		ERR_PRINT("D3D11SharedSurfacePool: D3D keyed AcquireSync(0) failed.");
		return out;
	}
	d3d_context_->CopySubresourceRegion(
			shared_tex.get(), 0, 0, 0, 0,
			decoder_texture, src_subresource, nullptr);
	d3d_context_->Flush();
	keyed->ReleaseSync(1); // hand to the caller's API

	// --- Export an NT shared handle for the caller to open elsewhere. ---
	ComPtr<IDXGIResource1> dxgi_res;
	if (FAILED(shared_tex->QueryInterface(IID_PPV_ARGS(dxgi_res.put())))) {
		ERR_PRINT("D3D11SharedSurfacePool: IDXGIResource1 query failed.");
		return out;
	}
	HANDLE shared_handle = nullptr;
	if (FAILED(dxgi_res->CreateSharedHandle(
				nullptr, DXGI_SHARED_RESOURCE_READ | DXGI_SHARED_RESOURCE_WRITE,
				nullptr, &shared_handle)) ||
			shared_handle == nullptr) {
		ERR_PRINT("D3D11SharedSurfacePool: CreateSharedHandle failed.");
		return out;
	}

	out.texture = std::move(shared_tex);
	out.keyed_mutex = std::move(keyed);
	out.shared_handle = shared_handle;
	return out;
}

} // namespace platform_media

#endif // _WIN32
