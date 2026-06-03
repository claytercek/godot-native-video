// -----------------------------------------------------------------------
// backend_factory_avf.mm — macOS implementation of make_backend().
// Compiled only on macOS/iOS; returns the AVFoundation decoder Backend.
// (.mm because avf_backend.h pulls in nothing ObjC, but keeping it .mm groups
// it with the macOS source set the SConstruct globs.)
// -----------------------------------------------------------------------

#include "backend_factory.h"

#include "../backends/avf/avf_backend.h"

namespace platform_media {

std::unique_ptr<core::Backend> make_backend() {
	return std::make_unique<avf::AvfBackend>();
}

} // namespace platform_media
