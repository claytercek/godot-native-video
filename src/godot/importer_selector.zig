//! Select the Windows importer from the RD driver name and Godot version.
//! This pure function needs no Godot or platform SDK, so it can be tested on
//! any host. windows_surface_importer.zig supplies the live singleton values.
//!
//! D3D12 zero-copy requires the d3d12 driver and Godot >= 4.5; all other cases
//! use CPU-copy. Vulkan's DXGI shared-handle path is not ported: a Godot
//! texture_create_from_extension aspect bug misbinds NV12 planes.

const std = @import("std");

/// The two Windows import paths this build supports.
pub const ImporterKind = enum {
    // D3D12 RD driver, Godot >= 4.5: the D3D12 zero-copy path.
    // Unavailable before 4.5 because texture_create_from_extension is
    // unimplemented for the D3D12 RD driver.
    d3d12,

    // Other drivers/versions: D3D11 NV12/P010 readback, then texture_update
    // into RD R8/RG8 or R16/RG16 textures.
    cpu_copy,
};

/// Select an import path without side effects.
/// driver_name is matched exactly ("d3d12", "vulkan", or another driver).
/// godot_major/godot_minor are the engine version, e.g. 4 and 5 for Godot 4.5.
pub fn selectImporter(driver_name: []const u8, godot_major: i32, godot_minor: i32) ImporterKind {
    if (std.mem.eql(u8, driver_name, "d3d12")) {
        if (godot_major > 4 or (godot_major == 4 and godot_minor >= 5)) {
            return .d3d12;
        }
        return .cpu_copy;
    }
    return .cpu_copy;
}

// D3D12 driver.

test "D3D12 on Godot 4.5 selects D3D12 importer" {
    try std.testing.expectEqual(ImporterKind.d3d12, selectImporter("d3d12", 4, 5));
}

test "D3D12 on Godot 4.6 selects D3D12 importer" {
    try std.testing.expectEqual(ImporterKind.d3d12, selectImporter("d3d12", 4, 6));
}

test "D3D12 on Godot 5.0 selects D3D12 importer" {
    try std.testing.expectEqual(ImporterKind.d3d12, selectImporter("d3d12", 5, 0));
}

test "D3D12 on Godot 4.4 falls back to CPU copy" {
    try std.testing.expectEqual(ImporterKind.cpu_copy, selectImporter("d3d12", 4, 4));
}

test "D3D12 on Godot 4.0 falls back to CPU copy" {
    try std.testing.expectEqual(ImporterKind.cpu_copy, selectImporter("d3d12", 4, 0));
}

test "D3D12 on Godot 3.x falls back to CPU copy" {
    try std.testing.expectEqual(ImporterKind.cpu_copy, selectImporter("d3d12", 3, 17));
}

// Vulkan always uses CPU-copy; its DXGI zero-copy path is not ported.

test "Vulkan driver selects CPU copy" {
    try std.testing.expectEqual(ImporterKind.cpu_copy, selectImporter("vulkan", 4, 5));
}

test "Vulkan driver, any version, selects CPU copy" {
    try std.testing.expectEqual(ImporterKind.cpu_copy, selectImporter("vulkan", 4, 0));
    try std.testing.expectEqual(ImporterKind.cpu_copy, selectImporter("vulkan", 4, 4));
    try std.testing.expectEqual(ImporterKind.cpu_copy, selectImporter("vulkan", 4, 100));
}

// Unknown driver names use CPU-copy.

test "Unknown driver name selects CPU copy" {
    try std.testing.expectEqual(ImporterKind.cpu_copy, selectImporter("metal", 4, 5));
}

test "Empty driver name selects CPU copy" {
    try std.testing.expectEqual(ImporterKind.cpu_copy, selectImporter("", 4, 5));
}
