// -----------------------------------------------------------------------
// metal_surface_importer.mm — zero-copy NV12 CVPixelBuffer -> RD textures.
//
// See metal_surface_importer.h. The trick is to reuse Godot's *own* MTLDevice
// (obtained via RenderingDevice::get_driver_resource) so the MTLTextures we
// create from the decoder's IOSurface are usable inside Godot's RD command
// stream without a device-to-device copy. CVMetalTextureCache wraps each NV12
// plane as an MTLTexture that aliases the IOSurface memory — no pixel copy.
// We then hand the MTLTexture handle to texture_create_from_extension, which
// builds an RD texture that aliases the same MTLTexture — still no copy.
// -----------------------------------------------------------------------

#include "metal_surface_importer.h"

#import <CoreVideo/CoreVideo.h>
#import <Metal/Metal.h>

using namespace godot;

namespace platform_media {

// PImpl holding the ObjC/CoreVideo state. Raw owning pointer so the header can
// stay plain C++; freed in MetalSurfaceImporter::~MetalSurfaceImporter.
struct MetalSurfaceImporter::Impl {
	RenderingDevice *rd = nullptr;
	id<MTLDevice> device = nil;             // borrowed: Godot owns it
	CVMetalTextureCacheRef texture_cache = nullptr; // owned (+1)

	~Impl() {
		if (texture_cache) {
			CVMetalTextureCacheFlush(texture_cache, 0);
			CFRelease(texture_cache);
			texture_cache = nullptr;
		}
		device = nil;
	}
};

MetalSurfaceImporter::MetalSurfaceImporter() = default;

MetalSurfaceImporter::~MetalSurfaceImporter() {
	delete impl_;
	impl_ = nullptr;
}

bool MetalSurfaceImporter::initialize(RenderingDevice *rd) {
	if (impl_) {
		return impl_->texture_cache != nullptr;
	}
	if (rd == nullptr) {
		return false;
	}

	// DRIVER_RESOURCE_LOGICAL_DEVICE returns the id<MTLDevice> as an int64 on the
	// Metal RD backend. On a non-Metal backend this is not a valid MTLDevice and
	// CVMetalTextureCacheCreate will fail, which we report as "not initialised".
	int64_t device_handle =
			rd->get_driver_resource(RenderingDevice::DRIVER_RESOURCE_LOGICAL_DEVICE, RID(), 0);
	if (device_handle == 0) {
		return false;
	}

	auto *impl = new Impl();
	impl->rd = rd;
	// __bridge: we do NOT take ownership of Godot's device.
	impl->device = (__bridge id<MTLDevice>)reinterpret_cast<void *>(device_handle);

	CVMetalTextureCacheRef cache = nullptr;
	CVReturn cr = CVMetalTextureCacheCreate(
			kCFAllocatorDefault, nullptr, impl->device, nullptr, &cache);
	if (cr != kCVReturnSuccess || cache == nullptr) {
		delete impl;
		return false;
	}
	impl->texture_cache = cache;
	impl_ = impl;
	return true;
}

bool MetalSurfaceImporter::is_initialized() const {
	return impl_ != nullptr && impl_->texture_cache != nullptr;
}

// Build one RD texture aliasing a CVMetalTexture's MTLTexture, zero-copy.
// Returns an invalid RID on failure. On success, `out_cv_tex` is the retained
// CVMetalTextureRef the caller must release after the RD texture is freed.
static RID import_plane(RenderingDevice *rd, CVMetalTextureCacheRef cache,
		CVPixelBufferRef pb, size_t plane,
		RenderingDevice::DataFormat fmt, CVMetalTextureRef *out_cv_tex) {
	*out_cv_tex = nullptr;

	const size_t w = CVPixelBufferGetWidthOfPlane(pb, plane);
	const size_t h = CVPixelBufferGetHeightOfPlane(pb, plane);
	if (w == 0 || h == 0) {
		return RID();
	}

	// The Metal pixel format MUST match the RD DataFormat we declare below.
	MTLPixelFormat mtl_fmt = MTLPixelFormatR8Unorm;
	if (fmt == RenderingDevice::DATA_FORMAT_R8G8_UNORM) {
		mtl_fmt = MTLPixelFormatRG8Unorm;
	}

	CVMetalTextureRef cv_tex = nullptr;
	CVReturn cr = CVMetalTextureCacheCreateTextureFromImage(
			kCFAllocatorDefault, cache, pb, nullptr, mtl_fmt, w, h, plane, &cv_tex);
	if (cr != kCVReturnSuccess || cv_tex == nullptr) {
		if (cv_tex) {
			CFRelease(cv_tex);
		}
		return RID();
	}

	id<MTLTexture> mtl_tex = CVMetalTextureGetTexture(cv_tex);
	if (mtl_tex == nil) {
		CFRelease(cv_tex);
		return RID();
	}

	// Import the MTLTexture into Godot RD. The `image` argument is the native
	// texture handle: the id<MTLTexture> pointer reinterpreted as an int64.
	// SAMPLING usage is all we need — the compute pass samples these planes.
	const int64_t mtl_handle = reinterpret_cast<int64_t>((__bridge void *)mtl_tex);
	RID rid = rd->texture_create_from_extension(
			RenderingDevice::TEXTURE_TYPE_2D,
			fmt,
			RenderingDevice::TEXTURE_SAMPLES_1,
			RenderingDevice::TEXTURE_USAGE_SAMPLING_BIT,
			mtl_handle,
			static_cast<int64_t>(w),
			static_cast<int64_t>(h),
			1,  // depth
			1); // layers
	if (!rid.is_valid()) {
		CFRelease(cv_tex);
		return RID();
	}

	*out_cv_tex = cv_tex; // hand ownership to the caller's release closure
	return rid;
}

PlaneTextures MetalSurfaceImporter::import(void *cv_pixel_buffer) {
	PlaneTextures out;
	if (!is_initialized() || cv_pixel_buffer == nullptr) {
		return out;
	}

	CVPixelBufferRef pb = reinterpret_cast<CVPixelBufferRef>(cv_pixel_buffer);

	const OSType pf = CVPixelBufferGetPixelFormatType(pb);
	const bool is_nv12 =
			pf == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
			pf == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
	if (!is_nv12 || CVPixelBufferGetPlaneCount(pb) < 2) {
		return out;
	}

	RenderingDevice *rd = impl_->rd;
	CVMetalTextureCacheRef cache = impl_->texture_cache;

	CVMetalTextureRef cv_luma = nullptr;
	CVMetalTextureRef cv_chroma = nullptr;

	RID luma = import_plane(rd, cache, pb, 0, RenderingDevice::DATA_FORMAT_R8_UNORM, &cv_luma);
	if (!luma.is_valid()) {
		return out;
	}
	RID chroma = import_plane(rd, cache, pb, 1, RenderingDevice::DATA_FORMAT_R8G8_UNORM, &cv_chroma);
	if (!chroma.is_valid()) {
		// Roll back the luma import to avoid a leak.
		rd->free_rid(luma);
		if (cv_luma) {
			CFRelease(cv_luma);
		}
		return out;
	}

	out.luma = luma;
	out.chroma = chroma;
	out.width = static_cast<int>(CVPixelBufferGetWidthOfPlane(pb, 0));
	out.height = static_cast<int>(CVPixelBufferGetHeightOfPlane(pb, 0));

	// Release closure: free the transient RD textures, then drop the
	// CVMetalTexture wrappers. Order matters — RD must be done with the MTLTexture
	// before we release the CVMetalTexture that owns it. The retire-ring only
	// invokes this after N rendered frames, so the GPU is finished sampling.
	out.release = [rd, luma, chroma, cv_luma, cv_chroma]() {
		if (luma.is_valid()) {
			rd->free_rid(luma);
		}
		if (chroma.is_valid()) {
			rd->free_rid(chroma);
		}
		if (cv_luma) {
			CFRelease(cv_luma);
		}
		if (cv_chroma) {
			CFRelease(cv_chroma);
		}
	};

	return out;
}

// -----------------------------------------------------------------------
// Platform factory (macOS build). The Windows build provides its own
// definition of make_surface_importer() in dxgi_surface_importer.cpp; exactly
// one is compiled per platform (the SConstruct picks the right source set), so
// the present pipeline links against the correct importer without any #ifdef.
// -----------------------------------------------------------------------
std::unique_ptr<SurfaceImporter> make_surface_importer() {
	return std::make_unique<MetalSurfaceImporter>();
}

} // namespace platform_media
