// -----------------------------------------------------------------------
// cpu_copy_surface_importer.cpp — GPU->CPU readback NV12 D3D11 texture -> RD
// textures (Windows CPU-Copy Import Path). See cpu_copy_surface_importer.h.
//
// The readback ring, in detail:
//
//   Each import() call writes into ring slot (frame_index % kReadbackRingDepth)
//   via CopySubresourceRegion (GPU-side, no CPU copy), then reads back the
//   slot at (frame_index + 1) % kReadbackRingDepth — the slot written
//   kReadbackRingDepth-1 frames ago, i.e. the OLDEST occupied slot, which by
//   construction is about to be overwritten one frame from now. That slot's
//   GPU copy has had kReadbackRingDepth-1 further frames of GPU work to drain
//   behind it, so Map() reads data that is already resident instead of
//   blocking on the GPU. During the first kReadbackRingDepth-1 frames after
//   initialize() no slot is old enough yet (has_data is false), and import()
//   reports an invalid PlaneTextures; the present pipeline simply presents
//   nothing until the ring fills. This same accounting means every frame
//   presented on this path — not just during that startup fill — is the
//   pixel content from kReadbackRingDepth-1 frames earlier than the frame
//   handed to import(): a fixed, permanent presentation lag traded for never
//   stalling the render thread on Map().
//
//   Mapping an NV12 staging texture returns ONE pointer for the whole
//   resource: the Y (luma) plane's rows starting at pData with stride
//   RowPitch, and the interleaved UV (chroma) plane starting immediately
//   after all of the Y plane's rows, at pData + RowPitch * height, using the
//   SAME RowPitch (NV12 is semi-planar: both planes share one physical
//   texture's row stride). Both planes are copied row-by-row into tightly
//   packed buffers because RowPitch is generally wider than the plane's exact
//   byte width (driver row alignment) while RD::texture_update expects tightly
//   packed pixel data.
//
// NOTE ON "CPU COPY": this is the one Import Path permitted, by design, to
// violate the zero-copy contract. The row-packing loop below is exactly the
// CPU copy the is_zero_copy() override exists to report.
// -----------------------------------------------------------------------

#include "cpu_copy_surface_importer.h"

#if defined(_WIN32)

#include <godot_cpp/classes/rd_texture_format.hpp>
#include <godot_cpp/classes/rd_texture_view.hpp>
#include <godot_cpp/core/error_macros.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/typed_array.hpp>

#include <cstring> // std::memcpy
#include <utility> // std::move

#include <d3d11.h>

#include "../backends/mf/com_raii.h" // mf::ComPtr

using namespace godot;
using mf::ComPtr;

namespace platform_media {

// PImpl holding the D3D11 readback state. Raw owning pointer so the header
// stays plain C++; freed in CpuCopySurfaceImporter::~CpuCopySurfaceImporter.
struct CpuCopySurfaceImporter::Impl {
	// Ring depth matches PresentPipeline::kFrameLatency: the same
	// number of rendered frames every other Import Path's transient surfaces
	// are guaranteed to survive before retirement.
	static constexpr size_t kReadbackRingDepth = 3;

	struct ReadbackSlot {
		ComPtr<ID3D11Texture2D> staging;
		int width = 0;
		int height = 0;
		bool has_data = false; // true once a CopySubresourceRegion has targeted it
	};

	RenderingDevice *rd = nullptr;

	// Bound lazily on the first import(), straight from the decoder texture —
	// see the file header for why this importer creates no device of its own.
	ComPtr<ID3D11Device> device;
	ComPtr<ID3D11DeviceContext> context;

	ReadbackSlot ring[kReadbackRingDepth];
	uint64_t frame_index = 0;

	bool initialized = false;
};

CpuCopySurfaceImporter::CpuCopySurfaceImporter() = default;

CpuCopySurfaceImporter::~CpuCopySurfaceImporter() {
	delete impl_;
	impl_ = nullptr;
}

bool CpuCopySurfaceImporter::initialize(RenderingDevice *rd) {
	if (impl_) {
		return impl_->initialized;
	}
	if (rd == nullptr) {
		return false;
	}

	auto *impl = new Impl();
	impl->rd = rd;
	impl->initialized = true;
	impl_ = impl;
	return true;
}

bool CpuCopySurfaceImporter::is_initialized() const {
	return impl_ != nullptr && impl_->initialized;
}

PlaneTextures CpuCopySurfaceImporter::import(void *d3d11_texture, uint32_t plane_slice) {
	PlaneTextures out;
	if (!is_initialized() || d3d11_texture == nullptr) {
		return out;
	}

	Impl *impl = impl_;
	auto *decoded = static_cast<ID3D11Texture2D *>(d3d11_texture);

	// Lazily bind to the SAME device the decoder texture lives on.
	// GetDevice()/GetImmediateContext() both return a +1 reference per COM
	// convention, matching ComPtr::put()'s out-parameter pattern.
	if (!impl->device) {
		decoded->GetDevice(impl->device.put());
		if (!impl->device) {
			ERR_PRINT("CPU-copy importer: ID3D11Texture2D::GetDevice failed.");
			return out;
		}
		impl->device->GetImmediateContext(impl->context.put());
	}

	D3D11_TEXTURE2D_DESC src_desc = {};
	decoded->GetDesc(&src_desc);
	if (src_desc.Format != DXGI_FORMAT_NV12) {
		ERR_PRINT("CPU-copy importer: decoder texture is not NV12.");
		return out;
	}
	const UINT width = src_desc.Width;
	const UINT height = src_desc.Height;

	const uint64_t frame = impl->frame_index++;
	const size_t write_slot = frame % Impl::kReadbackRingDepth;
	const size_t read_slot = (frame + 1) % Impl::kReadbackRingDepth;

	// --- Queue this frame's GPU-side readback into the ring slot that has the
	// most time left before it is read (see the file header). No CPU copy here.
	Impl::ReadbackSlot &write = impl->ring[write_slot];
	if (!write.staging || write.width != static_cast<int>(width) || write.height != static_cast<int>(height)) {
		D3D11_TEXTURE2D_DESC desc = {};
		desc.Width = width;
		desc.Height = height;
		desc.MipLevels = 1;
		desc.ArraySize = 1;
		desc.Format = DXGI_FORMAT_NV12;
		desc.SampleDesc.Count = 1;
		desc.Usage = D3D11_USAGE_STAGING;
		desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
		ComPtr<ID3D11Texture2D> tex;
		if (FAILED(impl->device->CreateTexture2D(&desc, nullptr, tex.put()))) {
			ERR_PRINT("CPU-copy importer: staging texture create failed.");
			return out;
		}
		write.staging = std::move(tex);
		write.width = static_cast<int>(width);
		write.height = static_cast<int>(height);
	}
	impl->context->CopySubresourceRegion(
			write.staging.get(), 0, 0, 0, 0,
			decoded, static_cast<UINT>(plane_slice), nullptr);
	write.has_data = true;

	// --- Read back the oldest slot. Still warming up: nothing old enough yet.
	Impl::ReadbackSlot &read = impl->ring[read_slot];
	if (!read.has_data) {
		return out;
	}

	D3D11_MAPPED_SUBRESOURCE mapped = {};
	if (FAILED(impl->context->Map(read.staging.get(), 0, D3D11_MAP_READ, 0, &mapped))) {
		ERR_PRINT("CPU-copy importer: staging texture Map failed.");
		return out;
	}

	const int luma_width = read.width;
	const int luma_height = read.height;
	const int chroma_width = luma_width / 2;
	const int chroma_height = luma_height / 2;

	// The CPU copy this Import Path exists to make: pack the mapped
	// rows (RowPitch may exceed the plane's tight row width) into tightly
	// packed buffers RD::texture_update accepts.
	auto pack_plane_rows = [](const uint8_t *src, UINT row_pitch, int row_bytes, int rows) {
		PackedByteArray out_bytes;
		out_bytes.resize(row_bytes * rows);
		uint8_t *dst = out_bytes.ptrw();
		for (int y = 0; y < rows; ++y) {
			std::memcpy(dst + y * row_bytes, src + y * row_pitch, row_bytes);
		}
		return out_bytes;
	};

	const auto *luma_src = static_cast<const uint8_t *>(mapped.pData);
	PackedByteArray luma_bytes = pack_plane_rows(luma_src, mapped.RowPitch, luma_width, luma_height);

	const int chroma_row_bytes = chroma_width * 2; // interleaved U/V, one byte each
	const uint8_t *chroma_src = luma_src + mapped.RowPitch * luma_height;
	PackedByteArray chroma_bytes = pack_plane_rows(chroma_src, mapped.RowPitch, chroma_row_bytes, chroma_height);

	impl->context->Unmap(read.staging.get(), 0);

	// --- Ordinary RD::texture_create + RD::texture_update — no aliased import.
	RenderingDevice *rd = impl->rd;

	auto make_plane_format = [](RenderingDevice::DataFormat format, int w, int h) {
		Ref<RDTextureFormat> fmt;
		fmt.instantiate();
		fmt->set_format(format);
		fmt->set_width(w);
		fmt->set_height(h);
		fmt->set_depth(1);
		fmt->set_array_layers(1);
		fmt->set_mipmaps(1);
		fmt->set_texture_type(RenderingDevice::TEXTURE_TYPE_2D);
		fmt->set_usage_bits(
				RenderingDevice::TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice::TEXTURE_USAGE_CAN_UPDATE_BIT);
		return fmt;
	};

	Ref<RDTextureView> view;
	view.instantiate();

	RID luma = rd->texture_create(
			make_plane_format(RenderingDevice::DATA_FORMAT_R8_UNORM, luma_width, luma_height), view,
			TypedArray<PackedByteArray>());
	RID chroma = rd->texture_create(
			make_plane_format(RenderingDevice::DATA_FORMAT_R8G8_UNORM, chroma_width, chroma_height), view,
			TypedArray<PackedByteArray>());
	if (!luma.is_valid() || !chroma.is_valid()) {
		free_plane_rids(rd, luma, chroma);
		ERR_PRINT("CPU-copy importer: texture_create failed.");
		return out;
	}
	if (rd->texture_update(luma, 0, luma_bytes) != OK || rd->texture_update(chroma, 0, chroma_bytes) != OK) {
		free_plane_rids(rd, luma, chroma);
		ERR_PRINT("CPU-copy importer: texture_update failed.");
		return out;
	}

	out.luma = luma;
	out.chroma = chroma;
	out.width = luma_width;
	out.height = luma_height;
	out.release = [rd, luma, chroma]() {
		free_plane_rids(rd, luma, chroma);
	};

	return out;
}

} // namespace platform_media

#endif // _WIN32
