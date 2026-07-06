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
// -----------------------------------------------------------------------

#include "surface_importer.h"

#if defined(_WIN32)

#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/variant/dictionary.hpp>

#include "cpu_copy_surface_importer.h"
#include "d3d12_surface_importer.h"
#include "dxgi_surface_importer.h"

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

bool is_godot_4_5_or_newer() {
	const Dictionary version_info = Engine::get_singleton()->get_version_info();
	const int major = version_info.get("major", 0);
	const int minor = version_info.get("minor", 0);
	return major > 4 || (major == 4 && minor >= 5);
}

} // namespace

std::unique_ptr<SurfaceImporter> make_surface_importer() {
	const String driver = RenderingServer::get_singleton()->get_current_rendering_driver_name();

	if (driver == "d3d12") {
		// D3D12 Path: zero-copy, but texture_create_from_extension is unimplemented
		// for the D3D12 RD driver before Godot 4.5 — the Godot 4.4 + "d3d12"-driver
		// combination falls through to the CPU-Copy Path below instead of a failed
		// D3D12 attempt.
		if (is_godot_4_5_or_newer()) {
			return std::make_unique<D3D12SurfaceImporter>();
		}
	} else if (kVulkanZeroCopyEnabled) {
		// Vulkan Zero-Copy Path: only ever a candidate on a non-d3d12 (i.e. Vulkan)
		// RenderingDevice driver — DxgiSurfaceImporter's whole mechanism is Vulkan
		// external-memory interop and has no D3D12 counterpart.
		return std::make_unique<DxgiSurfaceImporter>();
	}

	// CPU-Copy Path: the fallback for everything else — stock Vulkan driver (the
	// common case), the D3D12 driver on Godot < 4.5, or the Vulkan Zero-Copy Path
	// while it's disabled. Same hardware decode, a GPU->CPU readback instead of a
	// zero-copy import.
	return std::make_unique<CpuCopySurfaceImporter>();
}

} // namespace platform_media

#endif // _WIN32
