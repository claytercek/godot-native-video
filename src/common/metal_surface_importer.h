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

namespace platform_media {

// The two imported plane textures for one NV12 frame, plus a release closure
// that tears down everything created during the import (RD RIDs + CVMetalTexture
// wrappers). Move-only-ish via the closure; copy is fine because the closure is
// std::function and the caller is responsible for invoking release() once.
struct PlaneTextures {
	godot::RID luma;   // R8, full resolution
	godot::RID chroma; // RG8, half resolution
	int width = 0;     // luma (frame) width
	int height = 0;    // luma (frame) height

	// Frees the RD texture RIDs and releases the CVMetalTexture wrappers.
	// Call exactly once (the retire-ring does this after N frames).
	std::function<void()> release;

	bool valid() const { return luma.is_valid() && chroma.is_valid(); }
};

// Owns the CVMetalTextureCache bound to Godot's MTLDevice. Construct once per
// present pipeline; reuse across frames (the cache pools the transient
// MTLTexture wrappers efficiently).
class MetalSurfaceImporter {
public:
	MetalSurfaceImporter();
	~MetalSurfaceImporter();

	MetalSurfaceImporter(const MetalSurfaceImporter &) = delete;
	MetalSurfaceImporter &operator=(const MetalSurfaceImporter &) = delete;

	// Bind to the RenderingDevice and its underlying MTLDevice. Returns false if
	// the device is not Metal (e.g. a non-Apple RD) or the cache could not be
	// created. Must be called before import().
	bool initialize(godot::RenderingDevice *rd);

	bool is_initialized() const;

	// Import the NV12 CVPixelBuffer (passed as an opaque void* == CVPixelBufferRef)
	// into two RD plane textures, zero-copy. Returns an invalid PlaneTextures on
	// failure (e.g. wrong pixel format). The importer does NOT take ownership of
	// the CVPixelBuffer; the caller's VideoFrame::release still owns it and is
	// kept alive by the retire-ring alongside the returned release closure.
	PlaneTextures import(void *cv_pixel_buffer);

private:
	struct Impl;
	Impl *impl_ = nullptr; // raw ObjC-holding PImpl, deleted in dtor
};

} // namespace platform_media
