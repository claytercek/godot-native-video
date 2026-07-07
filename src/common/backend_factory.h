#pragma once

// -----------------------------------------------------------------------
// backend_factory.h — platform-agnostic decoder Backend factory.
//
// The Binding (NativeVideoStreamPlayback) must not name a concrete backend
// type, so adding a platform doesn't touch shared logic. make_backend() returns
// the right core::Backend for the platform this translation unit was compiled
// for:
//
//   - macOS:   avf::AvfBackend  (AVFoundation / AVAssetReader)  — backend_factory_avf.mm
//   - Windows: mf::MfBackend    (Media Foundation / IMFSourceReader) — backend_factory_mf.cpp
//
// Exactly one implementation is compiled per platform (the SConstruct picks the
// source set), mirroring make_surface_importer() in surface_importer.h. The
// factory itself is Godot-free; only the Binding that calls it knows about Godot.
// -----------------------------------------------------------------------

#include <memory>

#include "../core/backend.h" // core::Backend

namespace native_video {

// Construct the decoder Backend for this platform. Never returns null; the
// returned Backend is closed/unopened until open() succeeds.
std::unique_ptr<core::Backend> make_backend();

} // namespace native_video
