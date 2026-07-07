// -----------------------------------------------------------------------
// surface_importer_factory_windows.cpp — runtime SurfaceImporter selection
// for Windows.
//
// Unlike macOS (always Metal, so metal_surface_importer.mm defines
// make_surface_importer() directly), Windows can run Godot's Vulkan or D3D12
// RenderingDevice driver, and this project builds three Import Paths:
// D3D12SurfaceImporter, DxgiSurfaceImporter, and CpuCopySurfaceImporter. All
// three are linked into every Windows build, so the choice has to happen at
// runtime, based on RenderingServer's active rendering driver and Godot's
// version. This is the ONE place that choice is made (surface_importer.h's
// design goal), decided once and deterministically — never a runtime
// try-and-fail probe — instead of scattering driver checks through the
// present pipeline.
//
// The decision logic itself lives in importer_selector.h as a pure function
// tested via doctest. This file is the factory shell that reads Godot
// singletons and translates the result into a concrete importer.
// -----------------------------------------------------------------------

#include "surface_importer.h"

#if defined(_WIN32)

#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/variant/dictionary.hpp>

#include "cpu_copy_surface_importer.h"
#include "d3d12_surface_importer.h"
#include "dxgi_surface_importer.h"
#include "importer_selector.h"

using namespace godot;

namespace platform_media {

namespace {

// The Vulkan Zero-Copy Path (DxgiSurfaceImporter) is fully built and linked
// into every Windows binary but deliberately hard-disabled here: even once a
// Godot build enables VK_KHR_external_memory_win32,
// texture_create_from_extension's hardcoded COLOR aspect mis-binds the NV12
// plane views (confirmed wrong colors on AMD) until godot-proposals#13969
// lands upstream. No version number or capability query safely distinguishes
// "extension present" from "extension present AND aspect fix present," so
// this stays a single hard switch instead of a runtime probe. Flip once
// #13969 ships with its own detectable signal.
constexpr bool kVulkanZeroCopyEnabled = false;

// Extract godot major/minor from the Engine singleton's version_info.
static void read_godot_version(int &major, int &minor) {
	const Dictionary version_info = Engine::get_singleton()->get_version_info();
	major = version_info.get("major", 0);
	minor = version_info.get("minor", 0);
}

} // namespace

std::unique_ptr<SurfaceImporter> make_surface_importer() {
	const String driver = RenderingServer::get_singleton()->get_current_rendering_driver_name();

	int godot_major = 0;
	int godot_minor = 0;
	read_godot_version(godot_major, godot_minor);

	const ImporterKind kind = select_importer(
			std::string_view(driver.utf8().get_data()),
			godot_major,
			godot_minor,
			kVulkanZeroCopyEnabled);

	switch (kind) {
	case ImporterKind::D3D12:
		return std::make_unique<D3D12SurfaceImporter>();
	case ImporterKind::Dxgi:
		return std::make_unique<DxgiSurfaceImporter>();
	case ImporterKind::CpuCopy:
		return std::make_unique<CpuCopySurfaceImporter>();
	}
	// Unreachable — all cases covered; return fallback for compilers that warn.
	return std::make_unique<CpuCopySurfaceImporter>();
}

} // namespace platform_media

#endif // _WIN32
