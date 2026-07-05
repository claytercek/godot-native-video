// -----------------------------------------------------------------------
// windows_surface_importer_factory.cpp — runtime SurfaceImporter selection
// for Windows (ADR-0007).
//
// Unlike macOS (always Metal, so metal_surface_importer.mm defines
// make_surface_importer() directly), Windows can run Godot's Vulkan or D3D12
// RenderingDevice driver, and this project builds three Import Paths:
// D3D12SurfaceImporter, DxgiSurfaceImporter, and CpuCopySurfaceImporter. All
// three are linked into every Windows build, so the choice has to happen at
// runtime, based on RenderingServer's active rendering driver. This is the
// ONE place that choice is made (surface_importer.h's design goal), instead
// of scattering driver checks through the present pipeline.
// -----------------------------------------------------------------------

#include "surface_importer.h"

#if defined(_WIN32)

#include <godot_cpp/classes/rendering_server.hpp>

#include "cpu_copy_surface_importer.h"
#include "d3d12_surface_importer.h"

using namespace godot;

namespace platform_media {

std::unique_ptr<SurfaceImporter> make_surface_importer() {
	const String driver = RenderingServer::get_singleton()->get_current_rendering_driver_name();
	if (driver == "d3d12") {
		return std::make_unique<D3D12SurfaceImporter>();
	}
	// Vulkan (the common case) and anything else: DxgiSurfaceImporter is fully
	// built and linked into this binary but hard-disabled here per ADR-0007 —
	// texture_create_from_extension's hardcoded COLOR aspect mis-binds NV12
	// plane views until godot-proposals#13969 lands upstream, and no capability
	// query safely distinguishes "extension present" from "extension present
	// AND aspect fix present". CpuCopySurfaceImporter is the fallback: same
	// hardware decode, a GPU->CPU readback instead of a zero-copy import.
	return std::make_unique<CpuCopySurfaceImporter>();
}

} // namespace platform_media

#endif // _WIN32
