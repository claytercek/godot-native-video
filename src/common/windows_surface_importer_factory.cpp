// -----------------------------------------------------------------------
// windows_surface_importer_factory.cpp — runtime SurfaceImporter selection
// for Windows.
//
// Unlike macOS (always Metal, so metal_surface_importer.mm defines
// make_surface_importer() directly), Windows can run Godot's Vulkan or D3D12
// RenderingDevice driver, and this project supports a zero-copy importer for
// each (DxgiSurfaceImporter, D3D12SurfaceImporter). Both are linked into
// every Windows build, so the choice has to happen at runtime, based on
// RenderingServer's active rendering driver. This is the ONE place that
// choice is made (surface_importer.h's design goal), instead of scattering
// driver checks through the present pipeline.
// -----------------------------------------------------------------------

#include "surface_importer.h"

#if defined(_WIN32)

#include <godot_cpp/classes/rendering_server.hpp>

#include "d3d12_surface_importer.h"
#include "dxgi_surface_importer.h"

using namespace godot;

namespace platform_media {

std::unique_ptr<SurfaceImporter> make_surface_importer() {
	const String driver = RenderingServer::get_singleton()->get_current_rendering_driver_name();
	if (driver == "d3d12") {
		return std::make_unique<D3D12SurfaceImporter>();
	}
	return std::make_unique<DxgiSurfaceImporter>();
}

} // namespace platform_media

#endif // _WIN32
