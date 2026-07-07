// -----------------------------------------------------------------------
// importer_selector.h — pure-function importer selection for Windows.
//
// On Windows, three SurfaceImporter implementations are linked into every
// build: D3D12SurfaceImporter, DxgiSurfaceImporter, and
// CpuCopySurfaceImporter. The choice between them depends on the active
// RenderingDevice driver, the Godot engine version, and a kill-switch for
// the Vulkan zero-copy path.
//
// This header defines a pure function select_importer() that makes that
// decision from extracted scalar parameters (no Godot API calls, no
// platform header dependencies). The singleton-reading factory shell that
// calls it lives in src/common/surface_importer_factory_windows.cpp. The
// pure function can be doctested from the core test target on any host
// without linking godot-cpp.
// -----------------------------------------------------------------------

#pragma once

#include <cstdint>
#include <string_view>

namespace platform_media {

// -----------------------------------------------------------------------
// ImporterKind — the three Windows import paths.
// -----------------------------------------------------------------------
enum class ImporterKind : uint8_t {
	// D3D12 RD driver, Godot >= 4.5: the D3D12 zero-copy path.
	// Unavailable before 4.5 because texture_create_from_extension is
	// unimplemented for the D3D12 RD driver.
	D3D12,

	// Vulkan RD driver, zero-copy enabled: the Vulkan external-memory
	// path through DXGI shared handles.
	// Currently hard-disabled (see kVulkanZeroCopyEnabled in the factory).
	Dxgi,

	// Fallback for everything else: a CPU readback from the decoder's
	// D3D11 NV12 texture into RD R8/RG8 textures via texture_update.
	CpuCopy,
};

// -----------------------------------------------------------------------
// select_importer — pure decision function.
//
// Parameters:
//   driver_name   — the RenderingDevice driver name
//                   ("d3d12", "vulkan", or anything else).
//   godot_major   — Engine version major (e.g., 4 for Godot 4.x).
//   godot_minor   — Engine version minor (e.g., 5 for "4.5").
//   vulkan_zero_copy_enabled — whether the Vulkan zero-copy path is
//                   available (compile-time or runtime flag). Currently
//                   always false (see factory).
//
// Returns:
//   The ImporterKind that the factory should instantiate.
//
// This function is a pure function of its inputs: no singletons, no
// platform API calls, no side effects.
// -----------------------------------------------------------------------
inline ImporterKind select_importer(
		std::string_view driver_name,
		int godot_major,
		int godot_minor,
		bool vulkan_zero_copy_enabled) noexcept {
	if (driver_name == "d3d12") {
		if (godot_major > 4 || (godot_major == 4 && godot_minor >= 5)) {
			return ImporterKind::D3D12;
		}
		return ImporterKind::CpuCopy;
	}
	if (vulkan_zero_copy_enabled) {
		return ImporterKind::Dxgi;
	}
	return ImporterKind::CpuCopy;
}

} // namespace platform_media
