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

#include "../core/backend.h" // core::PixelFormat

#include <godot_cpp/variant/utility_functions.hpp>

#import <CoreVideo/CoreVideo.h>
#import <Metal/Metal.h>

using namespace godot;

namespace native_video {

// PImpl holding the ObjC/CoreVideo state. Raw owning pointer so the header can
// stay plain C++; freed in MetalSurfaceImporter::~MetalSurfaceImporter.
struct MetalSurfaceImporter::Impl {
	RenderingDevice *rd = nullptr;
	id<MTLDevice> device = nil; // borrowed: Godot owns it
	CVMetalTextureCacheRef texture_cache = nullptr; // owned (+1)
	// Some Godot drivers (4.7's metal-cpp rewrite) release imported MTLTextures
	// they never retained; when true, import_plane hands the driver a spare
	// reference. Detected at initialize() by probing the live driver.
	bool donate_reference_to_godot = false;

	~Impl() {
		if (texture_cache) {
			CVMetalTextureCacheFlush(texture_cache, 0);
			CFRelease(texture_cache);
			texture_cache = nullptr;
		}
		device = nil;
	}
};

// Godot 4.7 rewrote the Metal RD driver onto metal-cpp and lost refcount
// balance for imported textures: texture_create_from_extension no longer
// retains the MTLTexture when the format already matches (it did in <= 4.6 via
// rid::make's __bridge_retained), but texture_free still releases it
// unconditionally, deallocating the texture out from under its real owner.
//
// Rather than gate on version numbers — which can't tell a fixed 4.7.x from a
// broken one — probe the live driver: hand it a throwaway texture and watch
// the refcount across texture_create_from_extension. A balanced driver
// retains on import; the broken one leaves the count untouched. Returns true
// when the driver will consume a reference it never took, i.e. every import
// must donate one. CFGetRetainCount is unreliable for managing one's own
// references, but measuring whether a foreign call took ownership is the one
// job it does deterministically: nothing else can touch this texture between
// the two reads.
static bool driver_steals_import_reference(RenderingDevice *rd, id<MTLDevice> device) {
	MTLTextureDescriptor *desc =
			[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm
															   width:1
															  height:1
														   mipmapped:NO];
	desc.usage = MTLTextureUsageShaderRead;
	id<MTLTexture> probe = [device newTextureWithDescriptor:desc];
	if (probe == nil) {
		// Can't probe. Assume broken: donating on a balanced driver leaks, but
		// not donating on the broken one crashes.
		return true;
	}

	const CFIndex before = CFGetRetainCount((__bridge CFTypeRef)probe);
	RID rid = rd->texture_create_from_extension(
			RenderingDevice::TEXTURE_TYPE_2D,
			RenderingDevice::DATA_FORMAT_R8_UNORM,
			RenderingDevice::TEXTURE_SAMPLES_1,
			RenderingDevice::TEXTURE_USAGE_SAMPLING_BIT,
			reinterpret_cast<int64_t>((__bridge void *)probe),
			1, 1, 1, 1);
	if (!rid.is_valid()) {
		return true; // import path is broken anyway; pick the crash-safe default
	}
	const bool steals = CFGetRetainCount((__bridge CFTypeRef)probe) <= before;

	// Freeing the probe RID triggers the driver's (possibly unbalanced)
	// release, so the probe texture needs the same donation real imports get.
	if (steals) {
		CFRetain((__bridge CFTypeRef)probe);
	}
	rd->free_rid(rid);
	return steals;
}

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

	impl->donate_reference_to_godot = driver_steals_import_reference(rd, impl->device);
	UtilityFunctions::print_verbose(String("[native-video] Metal import ownership probe: ") +
			(impl->donate_reference_to_godot
							? "driver over-releases; donating a reference per imported plane"
							: "driver is balanced"));

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
		RenderingDevice::DataFormat fmt, MTLPixelFormat mtl_fmt,
		bool donate_reference, CVMetalTextureRef *out_cv_tex) {
	*out_cv_tex = nullptr;

	const size_t w = CVPixelBufferGetWidthOfPlane(pb, plane);
	const size_t h = CVPixelBufferGetHeightOfPlane(pb, plane);
	if (w == 0 || h == 0) {
		return RID();
	}

	// The caller passes the MTLPixelFormat so 8-bit (R8/RG8) and 10-bit
	// (R16Unorm/RG16Unorm) planes are both handled by this helper.

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
			1, // depth
			1); // layers
	if (!rid.is_valid()) {
		CFRelease(cv_tex);
		return RID();
	}

	// An unbalanced driver (see driver_steals_import_reference) releases this
	// MTLTexture in texture_free without ever retaining it. Without the
	// donated reference, free_rid over-releases the texture out from under
	// the CVMetalTextureCache and the next import crashes on the recycled
	// object (Metal abort or SIGSEGV).
	if (donate_reference) {
		CFRetain((__bridge CFTypeRef)mtl_tex);
	}

	*out_cv_tex = cv_tex; // hand ownership to the caller's release closure
	return rid;
}

PlaneTextures MetalSurfaceImporter::import(void *cv_pixel_buffer, uint32_t /*plane_slice*/) {
	PlaneTextures out;
	if (!is_initialized() || cv_pixel_buffer == nullptr) {
		return out;
	}

	CVPixelBufferRef pb = reinterpret_cast<CVPixelBufferRef>(cv_pixel_buffer);

	const OSType pf = CVPixelBufferGetPixelFormatType(pb);
	const bool is_supported =
			pf == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
			pf == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
			pf == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
			pf == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange;
	if (!is_supported || CVPixelBufferGetPlaneCount(pb) < 2) {
		return out;
	}

	// Detect 10-bit vs 8-bit from the pixel format type.
	const bool is_10bit =
			pf == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
			pf == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange;

	RenderingDevice *rd = impl_->rd;
	CVMetalTextureCacheRef cache = impl_->texture_cache;

	CVMetalTextureRef cv_luma = nullptr;
	CVMetalTextureRef cv_chroma = nullptr;

	RID luma;
	RID chroma;

	const bool donate = impl_->donate_reference_to_godot;

	if (is_10bit) {
		// 10-bit biplanar: each sample stored in 16 bits (lower 10 bits valid).
		// Metal texture: R16Unorm luma, RG16Unorm interleaved chroma.
		luma = import_plane(rd, cache, pb, 0,
				RenderingDevice::DATA_FORMAT_R16_UNORM,
				MTLPixelFormatR16Unorm, donate, &cv_luma);
		chroma = import_plane(rd, cache, pb, 1,
				RenderingDevice::DATA_FORMAT_R16G16_UNORM,
				MTLPixelFormatRG16Unorm, donate, &cv_chroma);
	} else {
		// 8-bit NV12: each sample a single byte. R8 + RG8.
		luma = import_plane(rd, cache, pb, 0,
				RenderingDevice::DATA_FORMAT_R8_UNORM,
				MTLPixelFormatR8Unorm, donate, &cv_luma);
		chroma = import_plane(rd, cache, pb, 1,
				RenderingDevice::DATA_FORMAT_R8G8_UNORM,
				MTLPixelFormatRG8Unorm, donate, &cv_chroma);
	}

	if (!luma.is_valid()) {
		return out;
	}
	if (!chroma.is_valid()) {
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
// definition of make_surface_importer() in surface_importer_factory_windows.cpp
// (it picks between D3D12SurfaceImporter, DxgiSurfaceImporter, and
// CpuCopySurfaceImporter at runtime); exactly one definition is linked per
// platform (the SConstruct picks the right source set), so the present
// pipeline links against the correct importer without any #ifdef.
// -----------------------------------------------------------------------
std::unique_ptr<SurfaceImporter> make_surface_importer() {
	return std::make_unique<MetalSurfaceImporter>();
}

} // namespace native_video
