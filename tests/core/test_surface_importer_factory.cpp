// -----------------------------------------------------------------------
// test_surface_importer_factory.cpp — decision-table tests for the Windows
// importer selector.
//
// select_importer() is a pure function of (driver_name, godot_version,
// vulkan_zero_copy_enabled). These tests exercise every row of the decision
// table so a logic error in driver/version matching — which currently would
// silently fall through to the wrong importer with no crash — is caught.
// -----------------------------------------------------------------------

#include "vendor/doctest.h"

#include "importer_selector.h"

using native_video::ImporterKind;
using native_video::select_importer;

// =======================================================================
// D3D12 driver
// =======================================================================

TEST_CASE("D3D12 on Godot 4.5 selects D3D12 importer") {
	const auto kind = select_importer("d3d12", 4, 5, false);
	CHECK(kind == ImporterKind::D3D12);
}

TEST_CASE("D3D12 on Godot 4.6 selects D3D12 importer") {
	const auto kind = select_importer("d3d12", 4, 6, false);
	CHECK(kind == ImporterKind::D3D12);
}

TEST_CASE("D3D12 on Godot 5.0 selects D3D12 importer") {
	const auto kind = select_importer("d3d12", 5, 0, false);
	CHECK(kind == ImporterKind::D3D12);
}

TEST_CASE("D3D12 on Godot 4.4 falls back to CPU copy") {
	const auto kind = select_importer("d3d12", 4, 4, false);
	CHECK(kind == ImporterKind::CpuCopy);
}

TEST_CASE("D3D12 on Godot 4.0 falls back to CPU copy") {
	const auto kind = select_importer("d3d12", 4, 0, false);
	CHECK(kind == ImporterKind::CpuCopy);
}

TEST_CASE("D3D12 on Godot 3.x falls back to CPU copy") {
	const auto kind = select_importer("d3d12", 3, 17, false);
	CHECK(kind == ImporterKind::CpuCopy);
}

// =======================================================================
// D3D12 driver with vulkan_zero_copy_enabled = true (shouldn't matter)
// =======================================================================

TEST_CASE("D3D12 path ignores vulkan_zero_copy flag") {
	// Even if someone flips the Vulkan flag, the D3D12 driver branch
	// should still short-circuit to its own importer selection.
	const auto kind = select_importer("d3d12", 4, 5, true);
	CHECK(kind == ImporterKind::D3D12);

	const auto kind_old = select_importer("d3d12", 4, 4, true);
	CHECK(kind_old == ImporterKind::CpuCopy);
}

// =======================================================================
// Vulkan (non-D3D12) driver with Vulkan zero copy DISABLED (current state)
// =======================================================================

TEST_CASE("Vulkan driver with zero-copy disabled selects CPU copy") {
	const auto kind = select_importer("vulkan", 4, 5, false);
	CHECK(kind == ImporterKind::CpuCopy);
}

TEST_CASE("Vulkan driver with zero-copy disabled, any version, selects CPU copy") {
	CHECK(select_importer("vulkan", 4, 0, false) == ImporterKind::CpuCopy);
	CHECK(select_importer("vulkan", 4, 4, false) == ImporterKind::CpuCopy);
	CHECK(select_importer("vulkan", 4, 100, false) == ImporterKind::CpuCopy);
}

// =======================================================================
// Vulkan (non-D3D12) driver with Vulkan zero copy ENABLED (future state)
// =======================================================================

TEST_CASE("Vulkan driver with zero-copy enabled selects DXGI importer") {
	const auto kind = select_importer("vulkan", 4, 5, true);
	CHECK(kind == ImporterKind::Dxgi);
}

TEST_CASE("Vulkan driver with zero-copy enabled, any version, selects DXGI") {
	CHECK(select_importer("vulkan", 4, 0, true) == ImporterKind::Dxgi);
	CHECK(select_importer("vulkan", 4, 4, true) == ImporterKind::Dxgi);
	CHECK(select_importer("vulkan", 3, 20, true) == ImporterKind::Dxgi);
}

// =======================================================================
// Unknown or future driver names fall to CPU copy.
// =======================================================================

TEST_CASE("Unknown driver name selects CPU copy") {
	const auto kind = select_importer("metal", 4, 5, false);
	CHECK(kind == ImporterKind::CpuCopy);
}

TEST_CASE("Empty driver name selects CPU copy") {
	const auto kind = select_importer("", 4, 5, false);
	CHECK(kind == ImporterKind::CpuCopy);
}

// =======================================================================
// Vulkan zero-copy flag only matters for non-D3D12 drivers.
// =======================================================================

TEST_CASE("Zero-copy flag has no effect on D3D12 driver path") {
	CHECK(select_importer("d3d12", 4, 5, false) == ImporterKind::D3D12);
	CHECK(select_importer("d3d12", 4, 5, true)  == ImporterKind::D3D12);
	CHECK(select_importer("d3d12", 4, 4, false) == ImporterKind::CpuCopy);
	CHECK(select_importer("d3d12", 4, 4, true)  == ImporterKind::CpuCopy);
}

// =======================================================================
// The Vulkan zero-copy kill-switch branch: Vulkan on Godot 4.5+ with
// the flag both true and false — documentation that the flag is orthogonal
// to the engine-version check.
// =======================================================================
TEST_CASE("Vulkan zero-copy decision is independent of Godot version") {
	// With flag enabled: always DXGI regardless of version.
	CHECK(select_importer("vulkan", 4, 0, true) == ImporterKind::Dxgi);
	CHECK(select_importer("vulkan", 4, 4, true) == ImporterKind::Dxgi);
	CHECK(select_importer("vulkan", 4, 5, true) == ImporterKind::Dxgi);

	// With flag disabled: always CPU copy regardless of version.
	CHECK(select_importer("vulkan", 4, 0, false) == ImporterKind::CpuCopy);
	CHECK(select_importer("vulkan", 4, 4, false) == ImporterKind::CpuCopy);
	CHECK(select_importer("vulkan", 4, 5, false) == ImporterKind::CpuCopy);
}
