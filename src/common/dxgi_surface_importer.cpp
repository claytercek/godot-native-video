// -----------------------------------------------------------------------
// dxgi_surface_importer.cpp — zero-copy NV12 D3D11 texture -> RD textures
// (Windows / Vulkan). See dxgi_surface_importer.h.
//
// The interop chain (the "DXGI dance"), in order:
//
//   open() once:
//     - Pull Godot's VkInstance / VkPhysicalDevice / VkDevice out of RD.
//     - Create our OWN ID3D11Device on the same adapter Godot's Vulkan device
//       runs on (matched by LUID) so the shared handle is openable cross-API.
//     - Resolve the VK_KHR_external_memory_win32 entry points.
//
//   import(frame) per frame:
//     1. Decoder hands us an NV12 ID3D11Texture2D (possibly a texture-array
//        slice). It is NOT shareable, so we GPU-blit (CopySubresourceRegion —
//        no CPU copy) the slice into a fresh shareable NV12 texture created
//        with SHARED_NTHANDLE | SHARED_KEYEDMUTEX, sized to the frame.
//     2. Acquire the shared texture's IDXGIKeyedMutex on the D3D side (key 0),
//        do the blit, then ReleaseSync to key 1 — handing the surface to Vulkan.
//     3. CreateSharedHandle -> an NT handle. Open it in Vulkan via
//        vkGetMemoryWin32HandlePropertiesKHR + a dedicated VkDeviceMemory import,
//        and create one VkImage per NV12 plane aspect:
//          - luma:   VK_FORMAT_R8_UNORM, aspect PLANE_0
//          - chroma: VK_FORMAT_R8G8_UNORM, aspect PLANE_1 (half res)
//        bound to the imported memory.
//     4. Hand each VkImage to RenderingDevice::texture_create_from_extension to
//        get an RD texture aliasing the same memory — no copy.
//     5. PlaneTextures.acquire/release_sync carry the keyed-mutex handoff for the
//        present pipeline: acquire() waits key 1 (Vulkan side) before the compute
//        dispatch; release_sync() releases to key 0 so D3D can reuse the surface.
//
//   release closure (parked in the retire-ring for N frames):
//     free the RD textures, destroy the VkImages + imported VkDeviceMemory, and
//     drop the shared texture + keyed mutex.
//
// NOTE ON "ZERO COPY": ADR-0003 forbids CPU copies on the present path, not GPU
// blits. The one CopySubresourceRegion here is a GPU->GPU copy required only
// because MF decoder textures are not directly shareable; it never touches the
// CPU and so does not violate the zero-CPU-copy contract. cpu_copy_count() stays
// 0. (A future optimization could request shareable decoder textures and drop
// even this GPU blit.)
//
// STATUS (2026-07-06, per ADR-0007 — see surface_importer_factory_windows.cpp):
// this is the Vulkan Zero-Copy Import Path, one of three shipped Windows Import
// Paths, and it is currently HARD-DISABLED at the factory (kVulkanZeroCopyEnabled
// = false), not merely version-gated. It stays fully built and linked, and its
// mechanism below was verified end-to-end on real hardware:
//   - Stock Godot (<= 4.5, master): BLOCKED. initialize() fails at the
//     vkGetMemoryWin32HandlePropertiesKHR resolve because Godot never enables
//     VK_KHR_external_memory_win32 on its Vulkan device and provides no way to
//     request it.
//   - Godot PR #114940 (adds project setting rendering/rendering_device/vulkan/
//     additional_device_extensions; demo/project.godot requests the extension):
//     the FULL import chain below runs and end-to-end zero-copy playback was
//     verified visually (AMD Radeon RX Vega, Win 11) — with ONE remaining
//     engine gap: RenderingDevice::texture_create_from_extension hardcodes
//     VK_IMAGE_ASPECT_COLOR_BIT for its view, but the R8/RG8 plane views of the
//     multi-planar NV12 image require VK_IMAGE_ASPECT_PLANE_0/1_BIT. With COLOR
//     aspect the AMD driver aliases plane-0 memory for both views (garbage
//     colors, wrong pitch); with a small local engine patch mapping
//     R8 -> PLANE_0 / RG8 -> PLANE_1 the output is pixel-correct. Upstream needs
//     a plane/aspect parameter on texture_create_from_extension (feedback filed
//     on PR #114940 / proposal godot-proposals#13969) — this path stays disabled
//     until that fix ships with its own detectable signal (no version number or
//     capability query safely distinguishes "extension present" from "extension
//     present AND aspect fix present").
// The two Import Paths that ARE reachable today: D3D12SurfaceImporter (zero-copy,
// Godot 4.5+ on the d3d12 RD driver, see d3d12_surface_importer.cpp) and
// CpuCopySurfaceImporter (the default fallback — stock Vulkan driver, any Godot
// version, see cpu_copy_surface_importer.cpp). Everything upstream of this file
// (MF decode, playback, clock, scheduler) is verified working on Windows via
// tests/mf and the demo run.
// -----------------------------------------------------------------------

#include "dxgi_surface_importer.h"

#if defined(_WIN32)

#include <godot_cpp/core/error_macros.hpp>

#include <cstring> // std::memcpy

#include <d3d11_1.h> // ID3D11Texture2D, IDXGIKeyedMutex
#include <dxgi1_2.h> // IDXGIResource1

#define VK_USE_PLATFORM_WIN32_KHR
#include <vulkan/vulkan.h>

#include "../backends/mf/com_raii.h" // mf::ComPtr
#include "d3d11_interop_device.h"

using namespace godot;
using mf::ComPtr;

namespace platform_media {

// PImpl holding the D3D/Vulkan interop state. Raw owning pointer so the header
// stays plain C++; freed in DxgiSurfaceImporter::~DxgiSurfaceImporter.
struct DxgiSurfaceImporter::Impl {
	RenderingDevice *rd = nullptr;

	// Borrowed from Godot (we do NOT own/destroy these).
	VkInstance instance = VK_NULL_HANDLE;
	VkPhysicalDevice physical_device = VK_NULL_HANDLE;
	VkDevice device = VK_NULL_HANDLE;

	// D3D11 bootstrap (own device on the same adapter as Godot's Vulkan device),
	// shared with D3D12SurfaceImporter by composition instead of duplication.
	D3D11InteropDevice interop;

	// VK_KHR_external_memory_win32 entry points (resolved from the device).
	PFN_vkGetMemoryWin32HandlePropertiesKHR get_mem_handle_props = nullptr;

	bool initialized = false;
};

DxgiSurfaceImporter::DxgiSurfaceImporter() = default;

DxgiSurfaceImporter::~DxgiSurfaceImporter() {
	delete impl_;
	impl_ = nullptr;
}

bool DxgiSurfaceImporter::initialize(RenderingDevice *rd) {
	if (impl_) {
		return impl_->initialized;
	}
	if (rd == nullptr) {
		return false;
	}

	auto *impl = new Impl();
	impl->rd = rd;

	// Pull the Vulkan objects out of Godot's RD. On a non-Vulkan RD these come
	// back 0 and we report "not initialized".
	impl->instance = reinterpret_cast<VkInstance>(
			rd->get_driver_resource(RenderingDevice::DRIVER_RESOURCE_TOPMOST_OBJECT, RID(), 0));
	impl->physical_device = reinterpret_cast<VkPhysicalDevice>(
			rd->get_driver_resource(RenderingDevice::DRIVER_RESOURCE_PHYSICAL_DEVICE, RID(), 0));
	impl->device = reinterpret_cast<VkDevice>(
			rd->get_driver_resource(RenderingDevice::DRIVER_RESOURCE_LOGICAL_DEVICE, RID(), 0));
	if (impl->device == VK_NULL_HANDLE || impl->physical_device == VK_NULL_HANDLE) {
		ERR_PRINT("DXGI importer init: RD did not yield Vulkan device handles (non-Vulkan RD driver?).");
		delete impl;
		return false;
	}

	// Resolve the external-memory-win32 entry point. If absent, the driver/RD
	// doesn't support the import path and we bail (the present pipeline will
	// report the importer as uninitialized).
	impl->get_mem_handle_props =
			reinterpret_cast<PFN_vkGetMemoryWin32HandlePropertiesKHR>(
					vkGetDeviceProcAddr(impl->device, "vkGetMemoryWin32HandlePropertiesKHR"));
	if (impl->get_mem_handle_props == nullptr) {
		ERR_PRINT("DXGI importer init: vkGetMemoryWin32HandlePropertiesKHR not resolvable — "
				  "VK_KHR_external_memory_win32 is not enabled on Godot's Vulkan device.");
		delete impl;
		return false;
	}

	// Find the DXGI adapter whose LUID matches Godot's Vulkan physical device, so
	// our D3D11 device shares GPU memory with Godot's renderer (a requirement
	// for cross-API shared handles to be openable).
	VkPhysicalDeviceIDProperties id_props = {};
	id_props.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ID_PROPERTIES;
	VkPhysicalDeviceProperties2 props2 = {};
	props2.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2;
	props2.pNext = &id_props;
	vkGetPhysicalDeviceProperties2(impl->physical_device, &props2);

	// VkPhysicalDeviceIDProperties.deviceLUID is 8 bytes laid out to compare
	// equal to a Win32 LUID when deviceLUIDValid is set.
	LUID luid = {};
	std::memcpy(&luid, id_props.deviceLUID, sizeof(LUID));
	if (!impl->interop.initialize(id_props.deviceLUIDValid ? &luid : nullptr)) {
		delete impl;
		return false;
	}

	impl->initialized = true;
	impl_ = impl;
	return true;
}

bool DxgiSurfaceImporter::is_initialized() const {
	return impl_ != nullptr && impl_->initialized;
}

namespace {

// Pick a Vulkan memory type index satisfying `type_bits` with the requested
// property flags (here: DEVICE_LOCAL for an imported render surface).
int find_memory_type(VkPhysicalDevice phys, uint32_t type_bits, VkMemoryPropertyFlags want) {
	VkPhysicalDeviceMemoryProperties mem = {};
	vkGetPhysicalDeviceMemoryProperties(phys, &mem);
	for (uint32_t i = 0; i < mem.memoryTypeCount; ++i) {
		const bool typed = (type_bits & (1u << i)) != 0;
		const bool propped = (mem.memoryTypes[i].propertyFlags & want) == want;
		if (typed && propped) {
			return static_cast<int>(i);
		}
	}
	return -1;
}

} // namespace

PlaneTextures DxgiSurfaceImporter::import(void *d3d11_texture, uint32_t plane_slice) {
	PlaneTextures out;
	if (!is_initialized() || d3d11_texture == nullptr) {
		return out;
	}

	Impl *impl = impl_;
	RenderingDevice *rd = impl->rd;

	// Borrow (do not own) the decoder's NV12 texture; the caller's VideoFrame
	// release still owns it. AddRef into a ComPtr for the duration of this call.
	ComPtr<ID3D11Texture2D> decoded =
			ComPtr<ID3D11Texture2D>::retain(static_cast<ID3D11Texture2D *>(d3d11_texture));

	D3D11_TEXTURE2D_DESC src_desc = {};
	decoded->GetDesc(&src_desc);
	if (src_desc.Format != DXGI_FORMAT_NV12) {
		ERR_PRINT("DXGI importer: decoder texture is not NV12.");
		return out;
	}
	const UINT width = src_desc.Width;
	const UINT height = src_desc.Height;

	// --- 1. Create a fresh shareable NV12 texture on OUR D3D device. ---
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
	if (FAILED(impl->interop.device()->CreateTexture2D(&shared_desc, nullptr, shared_tex.put()))) {
		ERR_PRINT("DXGI importer: shareable NV12 texture create failed.");
		return out;
	}

	// Keyed mutex for cross-API sync. Key 0 == "D3D owns it", key 1 == "Vulkan
	// owns it". We acquire 0 here on the D3D side, blit, release to 1.
	ComPtr<IDXGIKeyedMutex> keyed;
	if (FAILED(shared_tex->QueryInterface(IID_PPV_ARGS(keyed.put())))) {
		ERR_PRINT("DXGI importer: keyed mutex query failed.");
		return out;
	}

	// --- 2. GPU blit the decoded frame into the shared texture. No CPU copy. ---
	if (FAILED(keyed->AcquireSync(0, INFINITE))) {
		ERR_PRINT("DXGI importer: D3D keyed AcquireSync(0) failed.");
		return out;
	}
	// Source subresource: DXVA decoder MFTs pack decoded frames as slices of one
	// shared texture array, so the slice for THIS frame is the plane_slice the
	// backend recorded in VideoFrame::plane_slice and the present pipeline
	// forwarded here. (Verified on real hardware: the MF decoder does emit a
	// texture array — always blitting slice 0 shows stale/wrong frames.)
	impl->interop.context()->CopySubresourceRegion(
			shared_tex.get(), 0, 0, 0, 0,
			decoded.get(), static_cast<UINT>(plane_slice), nullptr);
	impl->interop.context()->Flush();
	keyed->ReleaseSync(1); // hand to Vulkan

	// Export an NT shared handle for Vulkan to open below.
	ComPtr<IDXGIResource1> dxgi_res;
	if (FAILED(shared_tex->QueryInterface(IID_PPV_ARGS(dxgi_res.put())))) {
		ERR_PRINT("DXGI importer: IDXGIResource1 query failed.");
		return out;
	}
	HANDLE shared_handle = nullptr;
	if (FAILED(dxgi_res->CreateSharedHandle(
				nullptr, DXGI_SHARED_RESOURCE_READ | DXGI_SHARED_RESOURCE_WRITE,
				nullptr, &shared_handle)) ||
			shared_handle == nullptr) {
		ERR_PRINT("DXGI importer: CreateSharedHandle failed.");
		return out;
	}

	// --- 3. Open the shared handle in Vulkan. Query the import properties for
	// this handle to pick a compatible memory type. A D3D11 shared NT handle
	// imports as VK_EXTERNAL_MEMORY_HANDLE_TYPE_D3D11_TEXTURE_BIT (KMT/
	// global-share would differ).
	const VkExternalMemoryHandleTypeFlagBits handle_type =
			VK_EXTERNAL_MEMORY_HANDLE_TYPE_D3D11_TEXTURE_BIT;

	VkMemoryWin32HandlePropertiesKHR handle_props = {};
	handle_props.sType = VK_STRUCTURE_TYPE_MEMORY_WIN32_HANDLE_PROPERTIES_KHR;
	if (impl->get_mem_handle_props(impl->device, handle_type, shared_handle, &handle_props) != VK_SUCCESS) {
		CloseHandle(shared_handle);
		ERR_PRINT("DXGI importer: vkGetMemoryWin32HandlePropertiesKHR failed.");
		return out;
	}

	// Create the placeholder VkImage describing the shared NV12 layout. We use a
	// dedicated allocation (required for imported D3D11 textures) and a multi-
	// planar NV12 format so each plane aspect can be viewed with its own format.
	VkExternalMemoryImageCreateInfo ext_img = {};
	ext_img.sType = VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO;
	ext_img.handleTypes = handle_type;

	VkImageCreateInfo img_info = {};
	img_info.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
	img_info.pNext = &ext_img;
	// NOT disjoint: the imported D3D11 texture is one dedicated allocation, and a
	// disjoint image would require per-plane vkBindImageMemory2. MUTABLE_FORMAT is
	// required to create per-plane views (R8/RG8) that differ from the image format.
	img_info.flags = VK_IMAGE_CREATE_MUTABLE_FORMAT_BIT;
	img_info.imageType = VK_IMAGE_TYPE_2D;
	img_info.format = VK_FORMAT_G8_B8R8_2PLANE_420_UNORM; // NV12
	img_info.extent = { width, height, 1 };
	img_info.mipLevels = 1;
	img_info.arrayLayers = 1;
	img_info.samples = VK_SAMPLE_COUNT_1_BIT;
	img_info.tiling = VK_IMAGE_TILING_OPTIMAL;
	img_info.usage = VK_IMAGE_USAGE_SAMPLED_BIT;
	img_info.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
	img_info.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;

	VkImage vk_image = VK_NULL_HANDLE;
	if (vkCreateImage(impl->device, &img_info, nullptr, &vk_image) != VK_SUCCESS) {
		CloseHandle(shared_handle);
		ERR_PRINT("DXGI importer: vkCreateImage failed.");
		return out;
	}

	// Import the shared handle as dedicated device memory bound to the image.
	VkMemoryRequirements mem_req = {};
	vkGetImageMemoryRequirements(impl->device, vk_image, &mem_req);
	const int mem_type = find_memory_type(
			impl->physical_device, handle_props.memoryTypeBits & mem_req.memoryTypeBits,
			VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
	if (mem_type < 0) {
		vkDestroyImage(impl->device, vk_image, nullptr);
		CloseHandle(shared_handle);
		ERR_PRINT("DXGI importer: no compatible Vulkan memory type for import.");
		return out;
	}

	VkImportMemoryWin32HandleInfoKHR import_info = {};
	import_info.sType = VK_STRUCTURE_TYPE_IMPORT_MEMORY_WIN32_HANDLE_INFO_KHR;
	import_info.handleType = handle_type;
	import_info.handle = shared_handle; // Vulkan dups the handle; we still close ours

	VkMemoryDedicatedAllocateInfo dedicated = {};
	dedicated.sType = VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO;
	dedicated.image = vk_image;
	import_info.pNext = &dedicated;

	VkMemoryAllocateInfo alloc = {};
	alloc.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
	alloc.pNext = &import_info;
	alloc.allocationSize = mem_req.size;
	alloc.memoryTypeIndex = static_cast<uint32_t>(mem_type);

	VkDeviceMemory vk_memory = VK_NULL_HANDLE;
	if (vkAllocateMemory(impl->device, &alloc, nullptr, &vk_memory) != VK_SUCCESS) {
		vkDestroyImage(impl->device, vk_image, nullptr);
		CloseHandle(shared_handle);
		ERR_PRINT("DXGI importer: vkAllocateMemory (import) failed.");
		return out;
	}
	if (vkBindImageMemory(impl->device, vk_image, vk_memory, 0) != VK_SUCCESS) {
		vkFreeMemory(impl->device, vk_memory, nullptr);
		vkDestroyImage(impl->device, vk_image, nullptr);
		CloseHandle(shared_handle);
		ERR_PRINT("DXGI importer: vkBindImageMemory failed.");
		return out;
	}
	// Vulkan has duplicated the handle internally; close our copy now.
	CloseHandle(shared_handle);

	// --- 4. Hand the VkImage to Godot RD as two plane textures. We pass the
	// VkImage handle to texture_create_from_extension; RD builds a texture that
	// aliases it. The luma view reads PLANE_0 (R8), chroma reads PLANE_1 (RG8 at
	// half resolution). RD's from-extension import takes one native image; we
	// import the same VkImage twice with the two plane formats so the existing
	// nv12_to_rgb.glsl (which samples a luma R8 + chroma RG8) is reused unchanged.
	const int64_t vk_image_handle = reinterpret_cast<int64_t>(vk_image);

	RID luma = rd->texture_create_from_extension(
			RenderingDevice::TEXTURE_TYPE_2D,
			RenderingDevice::DATA_FORMAT_R8_UNORM,
			RenderingDevice::TEXTURE_SAMPLES_1,
			RenderingDevice::TEXTURE_USAGE_SAMPLING_BIT,
			vk_image_handle,
			static_cast<int64_t>(width),
			static_cast<int64_t>(height),
			1, 1);
	RID chroma = rd->texture_create_from_extension(
			RenderingDevice::TEXTURE_TYPE_2D,
			RenderingDevice::DATA_FORMAT_R8G8_UNORM,
			RenderingDevice::TEXTURE_SAMPLES_1,
			RenderingDevice::TEXTURE_USAGE_SAMPLING_BIT,
			vk_image_handle,
			static_cast<int64_t>(width / 2),
			static_cast<int64_t>(height / 2),
			1, 1);
	if (!luma.is_valid() || !chroma.is_valid()) {
		if (luma.is_valid()) {
			rd->free_rid(luma);
		}
		if (chroma.is_valid()) {
			rd->free_rid(chroma);
		}
		vkDestroyImage(impl->device, vk_image, nullptr);
		vkFreeMemory(impl->device, vk_memory, nullptr);
		ERR_PRINT("DXGI importer: texture_create_from_extension failed.");
		return out;
	}

	out.luma = luma;
	out.chroma = chroma;
	out.width = static_cast<int>(width);
	out.height = static_cast<int>(height);

	// --- 5. Keyed-mutex handoff hooks for the present pipeline. acquire() waits
	// the Vulkan side's key (1, set by ReleaseSync above) before the compute
	// dispatch samples the planes; release_sync() returns the surface to the D3D
	// side (key 0) so the next frame's blit can proceed. The keyed mutex must
	// outlive these closures, so we capture the ComPtr by shared_ptr.
	auto keyed_holder = std::make_shared<ComPtr<IDXGIKeyedMutex>>(std::move(keyed));
	out.acquire = [keyed_holder]() {
		if (keyed_holder->get()) {
			(*keyed_holder)->AcquireSync(1, INFINITE);
		}
	};
	out.release_sync = [keyed_holder]() {
		if (keyed_holder->get()) {
			(*keyed_holder)->ReleaseSync(0);
		}
	};

	// Release closure: free RD textures, then the VkImage + imported memory, then
	// drop the shared D3D texture + keyed mutex. Ordering matters — RD must be
	// done with the VkImage before we destroy it; the retire-ring only invokes
	// this after N rendered frames, so the GPU is finished.
	VkDevice device = impl->device;
	auto shared_holder = std::make_shared<ComPtr<ID3D11Texture2D>>(std::move(shared_tex));
	out.release = [rd, luma, chroma, device, vk_image, vk_memory, keyed_holder, shared_holder]() {
		if (luma.is_valid()) {
			rd->free_rid(luma);
		}
		if (chroma.is_valid()) {
			rd->free_rid(chroma);
		}
		if (vk_image != VK_NULL_HANDLE) {
			vkDestroyImage(device, vk_image, nullptr);
		}
		if (vk_memory != VK_NULL_HANDLE) {
			vkFreeMemory(device, vk_memory, nullptr);
		}
		keyed_holder->reset();
		shared_holder->reset();
	};

	return out;
}

// make_surface_importer() lives in surface_importer_factory_windows.cpp: Windows
// links three SurfaceImporter implementations (this one, D3D12SurfaceImporter,
// CpuCopySurfaceImporter) and chooses between them at runtime. That factory
// hard-disables this importer's selection per ADR-0007 — DxgiSurfaceImporter
// stays fully built and linked, but is not currently reachable at runtime.

} // namespace platform_media

#endif // _WIN32
