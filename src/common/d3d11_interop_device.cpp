#include "d3d11_interop_device.h"

#if defined(_WIN32)

#include <godot_cpp/core/error_macros.hpp>

#include <cstring> // std::memcmp
#include <utility> // std::move

#include <dxgi1_2.h>

using mf::ComPtr;

namespace native_video {

bool D3D11InteropDevice::initialize(const LUID *luid) {
	ComPtr<IDXGIFactory1> factory;
	if (FAILED(CreateDXGIFactory1(IID_PPV_ARGS(factory.put())))) {
		ERR_PRINT("D3D11InteropDevice init: CreateDXGIFactory1 failed.");
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
		ERR_PRINT("D3D11InteropDevice init: D3D11CreateDevice failed on the matched adapter.");
		return false;
	}

	return true;
}

} // namespace native_video

#endif // _WIN32
