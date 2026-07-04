// -----------------------------------------------------------------------
// d3d12_surface_importer.cpp — zero-copy NV12 D3D11 texture -> RD textures
// (Windows / D3D12). See d3d12_surface_importer.h.
//
// The interop chain:
//
//   initialize() once:
//     - Pull Godot's ID3D12Device out of RD (RD driver == d3d12).
//     - Create our OWN ID3D11Device on the same adapter (matched by LUID via
//       ID3D12Device::GetAdapterLuid) via D3D11InteropDevice, so shared
//       handles are openable cross-API.
//     - Create a D3D11.4 fence (ID3D11Device5::CreateFence, SHARED), export
//       its NT handle, and open it on the D3D12 side (ID3D12Device::
//       OpenSharedHandle) as an ID3D12Fence. One fence persists for the
//       importer's lifetime; only its signal value increments per frame.
//     - Compile the plane-split compute shader (embedded HLSL) and create the
//       D3D11 compute pipeline state.
//
//   import(frame) per frame:
//     1. Decoder hands us an NV12 ID3D11Texture2D (possibly a texture-array
//        slice). GPU-blit (CopySubresourceRegion — no CPU copy) the slice into
//        a plain intermediate NV12 texture on our D3D11 device, cached in Impl
//        and reused across frames (recreated only when the frame size
//        changes). The intermediate never leaves the D3D11 device — a
//        multi-planar texture cannot be opened as one D3D12 resource in the
//        shape Godot's RD expects (two independent single-plane textures) —
//        so it carries no sharing flags and no keyed mutex.
//     2. Create PlaneSlice shader-resource views on the intermediate texture
//        (ID3D11Device3::CreateShaderResourceView1: R8_UNORM/PlaneSlice=0 for
//        luma, R8G8_UNORM/PlaneSlice=1 for chroma).
//     3. Run one compute dispatch that copies both planes into two freshly
//        created, independently NT-shareable output textures (R8 full-res,
//        RG8 half-res). Both are created with D3D11_BIND_RENDER_TARGET in
//        addition to SHADER_RESOURCE/UNORDERED_ACCESS (root-caused against
//        godot#117115): RenderingDeviceDriverD3D12::
//        texture_create_from_extension() unconditionally tracks the imported
//        texture's initial state as D3D12_RESOURCE_STATE_RENDER_TARGET, which
//        a resource without a render-target-capable flag cannot legally
//        occupy — even though we never actually render to it.
//     4. Signal the shared fence on the D3D11 immediate context
//        (ID3D11DeviceContext4::Signal) with a monotonically increasing
//        value, then Flush() so the GPU actually processes it.
//     5. Export both output textures as NT shared handles and open them on
//        the D3D12 side (ID3D12Device::OpenSharedHandle) as ID3D12Resource.
//     6. Hand each ID3D12Resource to RenderingDevice::texture_create_from_
//        extension with TEXTURE_USAGE_SAMPLING_BIT | COLOR_ATTACHMENT_BIT —
//        COLOR_ATTACHMENT_BIT is required for the same reason as the
//        RENDER_TARGET bind flag above.
//     7. PlaneTextures.acquire carries the fence handoff for the present
//        pipeline: it CPU-waits (SetEventOnCompletion + WaitForSingleObject)
//        on the D3D12-side fence for this frame's signal value before the
//        compute dispatch that samples the planes runs — a real GPU-work
//        completion point (a few frames of latency is not sufficient: the
//        wait must observe the actual D3D11-side signal). There is no
//        release_sync: the plane textures are single-use (destroyed by the
//        retire-ring, never reused), so nothing needs to hand access back to
//        the D3D11 side.
//
//   release closure (parked in the retire-ring for N frames):
//     free the RD texture RIDs, then release the D3D12 resources. The D3D11-
//     side textures/views are NOT captured here — they are safe to release at
//     the end of import() because the shared allocation stays alive via the
//     D3D12-side reference we keep, exactly as an NT-shared handle is meant
//     to work.
//
// NOTE ON "ZERO COPY": as with DxgiSurfaceImporter, the CopySubresourceRegion
// into the intermediate texture and the plane-split compute pass are GPU->GPU
// only; neither touches the CPU. cpu_copy_count() stays 0.
// -----------------------------------------------------------------------

#include "d3d12_surface_importer.h"

#if defined(_WIN32)

#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/core/error_macros.hpp>
#include <godot_cpp/variant/string.hpp>

#include <cstring> // strlen

#include <d3d11_4.h>  // ID3D11Device3/5, ID3D11DeviceContext4, ID3D11Fence
#include <d3d12.h>    // ID3D12Device, ID3D12Resource, ID3D12Fence
#include <d3dcompiler.h>
#include <dxgi1_2.h> // IDXGIResource1

#include "../backends/mf/com_raii.h" // mf::ComPtr
#include "d3d11_interop_device.h"

using namespace godot;
using mf::ComPtr;

namespace platform_media {

namespace {

// Reads two source planes (PlaneSlice SRVs over the intermediate NV12
// texture) and copies each into its own standalone output texture.
// Dispatched once at the luma (full) resolution; the chroma bounds check
// keeps the half-res writes in range within the same dispatch.
const char *kPlaneSplitCS = R"HLSL(
Texture2D<float>    SrcLuma    : register(t0);
Texture2D<float2>   SrcChroma  : register(t1);
RWTexture2D<float>   DstLuma   : register(u0);
RWTexture2D<float2>  DstChroma : register(u1);

cbuffer Params : register(b0) {
	uint luma_width;
	uint luma_height;
	uint chroma_width;
	uint chroma_height;
};

[numthreads(8, 8, 1)]
void CSMain(uint3 tid : SV_DispatchThreadID) {
	if (tid.x < luma_width && tid.y < luma_height) {
		DstLuma[tid.xy] = SrcLuma.Load(int3(tid.xy, 0));
	}
	if (tid.x < chroma_width && tid.y < chroma_height) {
		DstChroma[tid.xy] = SrcChroma.Load(int3(tid.xy, 0));
	}
}
)HLSL";

struct PlaneSplitParams {
	uint32_t luma_width;
	uint32_t luma_height;
	uint32_t chroma_width;
	uint32_t chroma_height;
};

} // namespace

// PImpl holding the D3D11/D3D12 interop state. Raw owning pointer so the
// header stays plain C++; freed in D3D12SurfaceImporter::~D3D12SurfaceImporter.
struct D3D12SurfaceImporter::Impl {
	RenderingDevice *rd = nullptr;

	// Borrowed from Godot but COM-retained for as long as we hold it: Godot's
	// D3D12 device, used to open shared handles.
	ComPtr<ID3D12Device> d3d12_device;

	// D3D11 bootstrap (own device on the same adapter as Godot's D3D12 device),
	// shared with DxgiSurfaceImporter by composition instead of duplication.
	D3D11InteropDevice interop;

	// Intermediate NV12 texture the decoder slice is blitted into each frame,
	// cached and reused across frames (recreated only when the frame size
	// changes). Plain — no sharing flags, no keyed mutex — because it never
	// leaves this D3D11 device. Reuse is safe: the next frame's blit and the
	// previous frame's plane-split dispatch run on the same immediate context,
	// so they are ordered.
	ComPtr<ID3D11Texture2D> intermediate_nv12;
	UINT intermediate_width = 0;
	UINT intermediate_height = 0;

	// Shared D3D11.4/D3D12 fence: one persistent object for the importer's
	// lifetime; import() increments next_fence_value and signals it after the
	// plane-split pass. fence_event is reused for every CPU-side wait.
	ComPtr<ID3D11Fence> d3d11_fence;
	ComPtr<ID3D12Fence> d3d12_fence;
	HANDLE fence_event = nullptr;
	uint64_t next_fence_value = 0;

	// Persistent plane-split compute pipeline state.
	ComPtr<ID3D11ComputeShader> plane_split_cs;
	ComPtr<ID3D11Buffer> params_cb;

	// Extended device/context interfaces queried once and reused every frame
	// (CreateShaderResourceView1 and Signal are both per-frame hot-path calls).
	ComPtr<ID3D11Device3> device3;
	ComPtr<ID3D11DeviceContext4> context4;

	bool initialized = false;

	~Impl() {
		if (fence_event != nullptr) {
			CloseHandle(fence_event);
		}
	}
};

D3D12SurfaceImporter::D3D12SurfaceImporter() = default;

D3D12SurfaceImporter::~D3D12SurfaceImporter() {
	delete impl_;
	impl_ = nullptr;
}

bool D3D12SurfaceImporter::initialize(RenderingDevice *rd) {
	if (impl_) {
		return impl_->initialized;
	}
	if (rd == nullptr) {
		return false;
	}

	auto *impl = new Impl();
	impl->rd = rd;

	// Pull Godot's D3D12 device out of RD. On a non-D3D12 RD this comes back
	// null and we report "not initialized" (the runtime factory should not
	// have picked this importer in that case, but stay defensive).
	auto *raw_device = reinterpret_cast<ID3D12Device *>(
			rd->get_driver_resource(RenderingDevice::DRIVER_RESOURCE_LOGICAL_DEVICE, RID(), 0));
	if (raw_device == nullptr) {
		ERR_PRINT("D3D12 importer init: RD did not yield a D3D12 device (non-D3D12 RD driver?).");
		delete impl;
		return false;
	}
	impl->d3d12_device = ComPtr<ID3D12Device>::retain(raw_device);

	// Bootstrap our own D3D11 device on the same adapter as Godot's D3D12
	// device so shared handles are openable cross-API.
	const LUID luid = impl->d3d12_device->GetAdapterLuid();
	if (!impl->interop.initialize(&luid)) {
		delete impl;
		return false;
	}

	// --- Shared fence bootstrap. ---
	ComPtr<ID3D11Device5> device5;
	if (FAILED(impl->interop.device()->QueryInterface(IID_PPV_ARGS(device5.put())))) {
		ERR_PRINT("D3D12 importer init: ID3D11Device5 not available (needs Windows 10 1809+).");
		delete impl;
		return false;
	}
	if (FAILED(device5->CreateFence(0, D3D11_FENCE_FLAG_SHARED, IID_PPV_ARGS(impl->d3d11_fence.put())))) {
		ERR_PRINT("D3D12 importer init: ID3D11Device5::CreateFence failed.");
		delete impl;
		return false;
	}
	HANDLE fence_handle = nullptr;
	if (FAILED(impl->d3d11_fence->CreateSharedHandle(nullptr, GENERIC_ALL, nullptr, &fence_handle)) ||
			fence_handle == nullptr) {
		ERR_PRINT("D3D12 importer init: ID3D11Fence::CreateSharedHandle failed.");
		delete impl;
		return false;
	}
	const HRESULT open_fence_hr =
			impl->d3d12_device->OpenSharedHandle(fence_handle, IID_PPV_ARGS(impl->d3d12_fence.put()));
	CloseHandle(fence_handle);
	if (FAILED(open_fence_hr)) {
		ERR_PRINT("D3D12 importer init: ID3D12Device::OpenSharedHandle (fence) failed.");
		delete impl;
		return false;
	}
	impl->fence_event = CreateEventW(nullptr, FALSE, FALSE, nullptr);
	if (impl->fence_event == nullptr) {
		ERR_PRINT("D3D12 importer init: CreateEventW failed.");
		delete impl;
		return false;
	}

	// --- Extended device/context interfaces used every frame in import(). ---
	if (FAILED(impl->interop.device()->QueryInterface(IID_PPV_ARGS(impl->device3.put())))) {
		ERR_PRINT("D3D12 importer init: ID3D11Device3 not available (needs Windows 10+).");
		delete impl;
		return false;
	}
	if (FAILED(impl->interop.context()->QueryInterface(IID_PPV_ARGS(impl->context4.put())))) {
		ERR_PRINT("D3D12 importer init: ID3D11DeviceContext4 not available (needs Windows 10 1809+).");
		delete impl;
		return false;
	}

	// --- Plane-split compute shader bootstrap. ---
	ComPtr<ID3DBlob> bytecode;
	ComPtr<ID3DBlob> compile_errors;
	const HRESULT compile_hr = D3DCompile(
			kPlaneSplitCS, std::strlen(kPlaneSplitCS), "plane_split_cs", nullptr, nullptr,
			"CSMain", "cs_5_0", D3DCOMPILE_OPTIMIZATION_LEVEL3, 0,
			bytecode.put(), compile_errors.put());
	if (FAILED(compile_hr)) {
		if (compile_errors) {
			ERR_PRINT(String("D3D12 importer init: plane-split shader compile failed: ") +
					String(static_cast<const char *>(compile_errors->GetBufferPointer())));
		} else {
			ERR_PRINT("D3D12 importer init: plane-split shader compile failed.");
		}
		delete impl;
		return false;
	}
	if (FAILED(impl->interop.device()->CreateComputeShader(
				bytecode->GetBufferPointer(), bytecode->GetBufferSize(), nullptr, impl->plane_split_cs.put()))) {
		ERR_PRINT("D3D12 importer init: CreateComputeShader (plane-split) failed.");
		delete impl;
		return false;
	}

	D3D11_BUFFER_DESC cb_desc = {};
	cb_desc.ByteWidth = sizeof(PlaneSplitParams);
	cb_desc.Usage = D3D11_USAGE_DEFAULT;
	cb_desc.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
	if (FAILED(impl->interop.device()->CreateBuffer(&cb_desc, nullptr, impl->params_cb.put()))) {
		ERR_PRINT("D3D12 importer init: CreateBuffer (plane-split params) failed.");
		delete impl;
		return false;
	}

	impl->initialized = true;
	impl_ = impl;
	return true;
}

bool D3D12SurfaceImporter::is_initialized() const {
	return impl_ != nullptr && impl_->initialized;
}

PlaneTextures D3D12SurfaceImporter::import(void *d3d11_texture, uint32_t plane_slice) {
	PlaneTextures out;
	if (!is_initialized() || d3d11_texture == nullptr) {
		return out;
	}

	Impl *impl = impl_;
	RenderingDevice *rd = impl->rd;
	ID3D11Device *device = impl->interop.device();
	ID3D11DeviceContext *context = impl->interop.context();

	// Borrow (do not own) the decoder's NV12 texture; the caller's VideoFrame
	// release still owns it.
	ComPtr<ID3D11Texture2D> decoded =
			ComPtr<ID3D11Texture2D>::retain(static_cast<ID3D11Texture2D *>(d3d11_texture));

	D3D11_TEXTURE2D_DESC src_desc = {};
	decoded->GetDesc(&src_desc);
	if (src_desc.Format != DXGI_FORMAT_NV12) {
		ERR_PRINT("D3D12 importer: decoder texture is not NV12.");
		return out;
	}
	const UINT width = src_desc.Width;
	const UINT height = src_desc.Height;
	const UINT chroma_width = width / 2;
	const UINT chroma_height = height / 2;

	// --- 1. GPU-blit the decoder slice into the cached intermediate NV12
	// texture (recreated only when the frame size changes). It never leaves
	// this D3D11 device — it exists only to be read by the plane-split pass
	// below — so it carries no sharing flags and no keyed mutex, and the blit
	// needs no explicit sync: this frame's copy and the previous frame's
	// plane-split dispatch run on the same immediate context, so they are
	// ordered.
	if (!impl->intermediate_nv12 || impl->intermediate_width != width ||
			impl->intermediate_height != height) {
		D3D11_TEXTURE2D_DESC inter_desc = {};
		inter_desc.Width = width;
		inter_desc.Height = height;
		inter_desc.MipLevels = 1;
		inter_desc.ArraySize = 1;
		inter_desc.Format = DXGI_FORMAT_NV12;
		inter_desc.SampleDesc.Count = 1;
		inter_desc.Usage = D3D11_USAGE_DEFAULT;
		inter_desc.BindFlags = D3D11_BIND_SHADER_RESOURCE;
		if (FAILED(device->CreateTexture2D(&inter_desc, nullptr, impl->intermediate_nv12.put()))) {
			ERR_PRINT("D3D12 importer: intermediate NV12 texture create failed.");
			impl->intermediate_width = 0;
			impl->intermediate_height = 0;
			return out;
		}
		impl->intermediate_width = width;
		impl->intermediate_height = height;
	}
	context->CopySubresourceRegion(
			impl->intermediate_nv12.get(), 0, 0, 0, 0,
			decoded.get(), static_cast<UINT>(plane_slice), nullptr);

	// --- 2. PlaneSlice SRVs over the intermediate NV12 texture. ---
	ID3D11Device3 *device3 = impl->device3.get();

	D3D11_SHADER_RESOURCE_VIEW_DESC1 luma_srv_desc = {};
	luma_srv_desc.Format = DXGI_FORMAT_R8_UNORM;
	luma_srv_desc.ViewDimension = D3D11_SRV_DIMENSION_TEXTURE2D;
	luma_srv_desc.Texture2D.MostDetailedMip = 0;
	luma_srv_desc.Texture2D.MipLevels = 1;
	luma_srv_desc.Texture2D.PlaneSlice = 0;
	ComPtr<ID3D11ShaderResourceView1> luma_srv;
	if (FAILED(device3->CreateShaderResourceView1(impl->intermediate_nv12.get(), &luma_srv_desc, luma_srv.put()))) {
		ERR_PRINT("D3D12 importer: luma PlaneSlice SRV create failed.");
		return out;
	}

	D3D11_SHADER_RESOURCE_VIEW_DESC1 chroma_srv_desc = luma_srv_desc;
	chroma_srv_desc.Format = DXGI_FORMAT_R8G8_UNORM;
	chroma_srv_desc.Texture2D.PlaneSlice = 1;
	ComPtr<ID3D11ShaderResourceView1> chroma_srv;
	if (FAILED(device3->CreateShaderResourceView1(impl->intermediate_nv12.get(), &chroma_srv_desc, chroma_srv.put()))) {
		ERR_PRINT("D3D12 importer: chroma PlaneSlice SRV create failed.");
		return out;
	}

	// --- 3. Standalone, independently shareable output textures. Both bind
	// RENDER_TARGET purely to satisfy the D3D12 driver's hardcoded initial-
	// state assumption (see file header); neither is ever actually rendered
	// to.
	auto make_output_texture = [&](DXGI_FORMAT format, UINT w, UINT h) -> ComPtr<ID3D11Texture2D> {
		D3D11_TEXTURE2D_DESC desc = {};
		desc.Width = w;
		desc.Height = h;
		desc.MipLevels = 1;
		desc.ArraySize = 1;
		desc.Format = format;
		desc.SampleDesc.Count = 1;
		desc.Usage = D3D11_USAGE_DEFAULT;
		desc.BindFlags = D3D11_BIND_SHADER_RESOURCE | D3D11_BIND_UNORDERED_ACCESS | D3D11_BIND_RENDER_TARGET;
		// D3D11_RESOURCE_MISC_SHARED_NTHANDLE is invalid on its own — the API
		// requires pairing it with SHARED or SHARED_KEYEDMUTEX (CreateTexture2D
		// fails E_INVALIDARG otherwise, confirmed on-device). Pair with plain
		// SHARED, not SHARED_KEYEDMUTEX: this pass never Acquire/ReleaseSync's a
		// keyed mutex on these textures (sync is entirely the shared fence), and
		// pairing with SHARED_KEYEDMUTEX made CSSetUnorderedAccessViews hang
		// forever on-device (AMD driver enforcing an implicit, never-acquired
		// lock) — confirmed by bisecting with per-call diagnostics.
		desc.MiscFlags = D3D11_RESOURCE_MISC_SHARED_NTHANDLE | D3D11_RESOURCE_MISC_SHARED;
		ComPtr<ID3D11Texture2D> tex;
		if (FAILED(device->CreateTexture2D(&desc, nullptr, tex.put()))) {
			return {};
		}
		return tex;
	};

	ComPtr<ID3D11Texture2D> luma_out = make_output_texture(DXGI_FORMAT_R8_UNORM, width, height);
	ComPtr<ID3D11Texture2D> chroma_out = make_output_texture(DXGI_FORMAT_R8G8_UNORM, chroma_width, chroma_height);
	if (!luma_out || !chroma_out) {
		ERR_PRINT("D3D12 importer: plane-split output texture create failed.");
		return out;
	}

	D3D11_UNORDERED_ACCESS_VIEW_DESC luma_uav_desc = {};
	luma_uav_desc.Format = DXGI_FORMAT_R8_UNORM;
	luma_uav_desc.ViewDimension = D3D11_UAV_DIMENSION_TEXTURE2D;
	ComPtr<ID3D11UnorderedAccessView> luma_uav;
	if (FAILED(device->CreateUnorderedAccessView(luma_out.get(), &luma_uav_desc, luma_uav.put()))) {
		ERR_PRINT("D3D12 importer: luma UAV create failed.");
		return out;
	}
	D3D11_UNORDERED_ACCESS_VIEW_DESC chroma_uav_desc = {};
	chroma_uav_desc.Format = DXGI_FORMAT_R8G8_UNORM;
	chroma_uav_desc.ViewDimension = D3D11_UAV_DIMENSION_TEXTURE2D;
	ComPtr<ID3D11UnorderedAccessView> chroma_uav;
	if (FAILED(device->CreateUnorderedAccessView(chroma_out.get(), &chroma_uav_desc, chroma_uav.put()))) {
		ERR_PRINT("D3D12 importer: chroma UAV create failed.");
		return out;
	}

	// --- Dispatch the plane-split pass. ---
	const PlaneSplitParams params = { width, height, chroma_width, chroma_height };
	context->UpdateSubresource(impl->params_cb.get(), 0, nullptr, &params, 0, 0);

	ID3D11ShaderResourceView *srvs[2] = { luma_srv.get(), chroma_srv.get() };
	ID3D11UnorderedAccessView *uavs[2] = { luma_uav.get(), chroma_uav.get() };
	ID3D11Buffer *cb = impl->params_cb.get();
	context->CSSetShaderResources(0, 2, srvs);
	context->CSSetUnorderedAccessViews(0, 2, uavs, nullptr);
	context->CSSetConstantBuffers(0, 1, &cb);
	context->CSSetShader(impl->plane_split_cs.get(), nullptr, 0);
	context->Dispatch((width + 7) / 8, (height + 7) / 8, 1);

	ID3D11ShaderResourceView *null_srvs[2] = { nullptr, nullptr };
	ID3D11UnorderedAccessView *null_uavs[2] = { nullptr, nullptr };
	context->CSSetShaderResources(0, 2, null_srvs);
	context->CSSetUnorderedAccessViews(0, 2, null_uavs, nullptr);
	context->CSSetShader(nullptr, nullptr, 0);

	// --- 4. Signal the shared fence for this frame and flush so the GPU
	// actually processes the signal (the D3D12 side's CPU wait below depends
	// on it having been submitted, not just enqueued). A failed Signal must not
	// hand out a PlaneTextures whose acquire() would wait forever on a value
	// the fence will never reach.
	const uint64_t signal_value = ++impl->next_fence_value;
	if (FAILED(impl->context4->Signal(impl->d3d11_fence.get(), signal_value))) {
		ERR_PRINT("D3D12 importer: shared-fence Signal failed.");
		return out;
	}
	context->Flush();

	// --- 5. Export both output textures and open them on the D3D12 side. ---
	auto export_and_open = [&](ID3D11Texture2D *tex) -> ComPtr<ID3D12Resource> {
		ComPtr<IDXGIResource1> dxgi_res;
		if (FAILED(tex->QueryInterface(IID_PPV_ARGS(dxgi_res.put())))) {
			return {};
		}
		HANDLE handle = nullptr;
		if (FAILED(dxgi_res->CreateSharedHandle(
					nullptr, DXGI_SHARED_RESOURCE_READ | DXGI_SHARED_RESOURCE_WRITE, nullptr, &handle)) ||
				handle == nullptr) {
			return {};
		}
		ComPtr<ID3D12Resource> resource;
		const HRESULT hr = impl->d3d12_device->OpenSharedHandle(handle, IID_PPV_ARGS(resource.put()));
		CloseHandle(handle);
		if (FAILED(hr)) {
			return {};
		}
		return resource;
	};

	ComPtr<ID3D12Resource> d3d12_luma = export_and_open(luma_out.get());
	ComPtr<ID3D12Resource> d3d12_chroma = export_and_open(chroma_out.get());
	if (!d3d12_luma || !d3d12_chroma) {
		ERR_PRINT("D3D12 importer: OpenSharedHandle (plane texture) failed.");
		return out;
	}

	// --- 6. Hand each ID3D12Resource to Godot RD as a plane texture.
	// COLOR_ATTACHMENT_BIT works around the driver's hardcoded RENDER_TARGET
	// initial-state tracking; see the file header.
	const BitField<RenderingDevice::TextureUsageBits> usage =
			RenderingDevice::TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice::TEXTURE_USAGE_COLOR_ATTACHMENT_BIT;
	const int64_t luma_handle_value = reinterpret_cast<int64_t>(d3d12_luma.get());
	const int64_t chroma_handle_value = reinterpret_cast<int64_t>(d3d12_chroma.get());

	RID luma = rd->texture_create_from_extension(
			RenderingDevice::TEXTURE_TYPE_2D, RenderingDevice::DATA_FORMAT_R8_UNORM,
			RenderingDevice::TEXTURE_SAMPLES_1, usage, luma_handle_value,
			static_cast<int64_t>(width), static_cast<int64_t>(height), 1, 1);
	RID chroma = rd->texture_create_from_extension(
			RenderingDevice::TEXTURE_TYPE_2D, RenderingDevice::DATA_FORMAT_R8G8_UNORM,
			RenderingDevice::TEXTURE_SAMPLES_1, usage, chroma_handle_value,
			static_cast<int64_t>(chroma_width), static_cast<int64_t>(chroma_height), 1, 1);
	if (!luma.is_valid() || !chroma.is_valid()) {
		if (luma.is_valid()) {
			rd->free_rid(luma);
		}
		if (chroma.is_valid()) {
			rd->free_rid(chroma);
		}
		ERR_PRINT("D3D12 importer: texture_create_from_extension failed.");
		return out;
	}

	out.luma = luma;
	out.chroma = chroma;
	out.width = static_cast<int>(width);
	out.height = static_cast<int>(height);

	// --- 7. Fence handoff: acquire() CPU-waits for this frame's signal value
	// before the present pipeline's compute dispatch samples the planes. No
	// release_sync — these plane textures are single-use.
	//
	// The wait is bounded (not INFINITE): if the fence is never signaled — a
	// driver/GPU-hang scenario — the present pipeline proceeds anyway (risking
	// one stale/torn frame) rather than freezing the whole process forever.
	ID3D12Fence *fence = impl->d3d12_fence.get();
	HANDLE fence_event = impl->fence_event;
	out.acquire = [fence, fence_event, signal_value]() {
		if (fence->GetCompletedValue() < signal_value) {
			fence->SetEventOnCompletion(signal_value, fence_event);
			if (WaitForSingleObject(fence_event, 5000) != WAIT_OBJECT_0) {
				ERR_PRINT("D3D12 importer: shared-fence wait timed out; sampling planes without confirmed GPU sync.");
			}
		}
	};

	auto luma_holder = std::make_shared<ComPtr<ID3D12Resource>>(std::move(d3d12_luma));
	auto chroma_holder = std::make_shared<ComPtr<ID3D12Resource>>(std::move(d3d12_chroma));
	out.release = [rd, luma, chroma, luma_holder, chroma_holder]() {
		if (luma.is_valid()) {
			rd->free_rid(luma);
		}
		if (chroma.is_valid()) {
			rd->free_rid(chroma);
		}
		luma_holder->reset();
		chroma_holder->reset();
	};

	return out;
}

} // namespace platform_media

#endif // _WIN32
