#pragma once

// -----------------------------------------------------------------------
// metal_surface_importer.h — macOS/Metal half of the zero-copy import.
//
// Takes a hardware-decoded NV12 CVPixelBuffer (from the AVFoundation Backend)
// and produces two Godot RenderingDevice texture RIDs — the luma (R8) and
// chroma (RG8) planes — WITHOUT any CPU copy of the pixel data. It does this
// by wrapping the CVPixelBuffer's IOSurface-backed planes as MTLTextures via a
// CVMetalTextureCache bound to Godot's own MTLDevice, then handing those
// MTLTexture handles to RenderingDevice::texture_create_from_extension.
//
// This is the ONLY file that knows about both Metal/CoreVideo AND Godot's
// RenderingDevice. The implementation is Objective-C++ (.mm). The header is
// plain C++ so the rest of the Binding can include it.
//
// Lifetime: each import produces a PlaneTextures whose .release() frees the
// transient RD texture RIDs and drops the CVMetalTexture retains. The present
// pipeline parks that release closure in the retire-ring for N frames so the
// GPU is done sampling before the wrappers are torn down.
// -----------------------------------------------------------------------

#include <cstdint>
#include <functional>

#include <godot_cpp/classes/rendering_device.hpp>
#include <godot_cpp/variant/rid.hpp>

#include "surface_importer.h" // PlaneTextures, SurfaceImporter

namespace platform_media {

// Owns the CVMetalTextureCache bound to Godot's MTLDevice. Construct once per
// present pipeline; reuse across frames (the cache pools the transient
// MTLTexture wrappers efficiently).
class MetalSurfaceImporter final : public SurfaceImporter {
public:
	MetalSurfaceImporter();
	~MetalSurfaceImporter() override;

	MetalSurfaceImporter(const MetalSurfaceImporter &) = delete;
	MetalSurfaceImporter &operator=(const MetalSurfaceImporter &) = delete;

	// Bind to the RenderingDevice and its underlying MTLDevice. Returns false if
	// the device is not Metal (e.g. a non-Apple RD) or the cache could not be
	// created. Must be called before import().
	bool initialize(godot::RenderingDevice *rd) override;

	bool is_initialized() const override;

	// Import the NV12 CVPixelBuffer (passed as an opaque void* == CVPixelBufferRef)
	// into two RD plane textures, zero-copy. Returns an invalid PlaneTextures on
	// failure (e.g. wrong pixel format). The importer does NOT take ownership of
	// the CVPixelBuffer; the caller's VideoFrame::release still owns it and is
	// kept alive by the retire-ring alongside the returned release closure.
	PlaneTextures import(void *cv_pixel_buffer) override;

private:
	struct Impl;
	Impl *impl_ = nullptr; // raw ObjC-holding PImpl, deleted in dtor
};

} // namespace platform_media
