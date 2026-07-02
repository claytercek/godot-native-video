// -----------------------------------------------------------------------
// backend_factory_mf.cpp — Windows implementation of make_backend().
// Compiled only on Windows; returns the Media Foundation decoder Backend.
// -----------------------------------------------------------------------

// Windows-only: on other platforms this is an empty TU so the common/*.cpp glob
// can include it everywhere without producing a duplicate make_backend()
// (the macOS make_backend lives in backend_factory_avf.mm).
#if defined(_WIN32)

#include "backend_factory.h"

#include "../backends/mf/mf_backend.h"

namespace platform_media {

std::unique_ptr<core::Backend> make_backend() {
	return std::make_unique<mf::MfBackend>();
}

} // namespace platform_media

#endif // _WIN32
