//! surface_importer.zig — platform-neutral vocabulary for surface import.
//!
//! The zero-copy present pipeline imports a hardware-decoded biplanar
//! Y'CbCr surface (NV12 8-bit, or P010/x420 10-bit) into Godot's
//! RenderingDevice as two plane textures WITHOUT any CPU copy, then runs
//! the single NV12->RGB compute pass. The concrete importer lives in
//! metal_surface_importer.zig on macOS (CVPixelBuffer IOSurface -> MTLTexture
//! via CVMetalTextureCache -> RenderingDevice.textureCreateFromExtension); on
//! Windows, a D3D12 zero-copy importer and a CPU-copy fallback are chosen at
//! runtime by importer_selector from the active RenderingDevice driver
//! and Godot version. A third Windows path — a Vulkan external-memory /
//! DXGI shared-handle zero-copy importer — is a known limitation: it is not
//! ported, blocked on an upstream Godot texture-import aspect fix (see
//! importer_selector's module doc comment).
//!
//! This module holds the types shared across that module boundary — the
//! PlaneTextures import result and the small RID/closure helpers — so the
//! present pipeline never reaches into CoreVideo/Metal directly. Zig has no
//! capturing closures, so teardown hooks are ctx + fn-pointer Closures.

const std = @import("std");

const godot = @import("godot");
const RenderingDevice = godot.class.RenderingDevice;
const Rid = godot.builtin.Rid;

const core = @import("core");

/// An invalid (zero) RID for struct-field defaults. isValid() is false.
pub const rid_invalid: Rid = std.mem.zeroes(Rid);

/// Release/sync hook for an imported surface: ctx + fn pointer, shared with
/// every other type-erased callback in the codebase.
pub const Closure = core.backend.VoidClosure;

/// Heap-boxes `value` and returns a Closure whose thunk runs `teardown`
/// against the boxed value, then frees the box. Every heap-boxed-teardown
/// closure in the present pipeline goes through here, so the allocate /
/// teardown / free ordering lives in exactly one place.
pub fn boxClosure(
    allocator: std.mem.Allocator,
    value: anytype,
    comptime teardown: fn (*@TypeOf(value)) void,
) !Closure {
    const Box = struct {
        allocator: std.mem.Allocator,
        value: @TypeOf(value),

        fn run(ctx: ?*anyopaque) void {
            const box: *@This() = @ptrCast(@alignCast(ctx.?));
            teardown(&box.value);
            box.allocator.destroy(box);
        }
    };
    const box = try allocator.create(Box);
    box.* = .{ .allocator = allocator, .value = value };
    return .{ .ctx = box, .func = Box.run };
}

// -----------------------------------------------------------------------
// PlaneTextures — the import result for one frame.
//
// The two imported plane textures, plus a release closure that tears down
// everything created during the import (RD RIDs + native wrapper objects).
// The caller invokes release() exactly once; the present pipeline parks it in
// the retire-ring for N rendered frames so the GPU is done sampling before the
// wrappers are freed.
// -----------------------------------------------------------------------
pub const PlaneTextures = struct {
    luma: Rid = rid_invalid, // R8 (8-bit) or R16 (10-bit), full resolution
    chroma: Rid = rid_invalid, // RG8 (8-bit) or RG16 (10-bit), half resolution
    width: i32 = 0, // luma (frame) width
    height: i32 = 0, // luma (frame) height

    /// Optional GPU-submission-ordering hook the present pipeline calls once,
    /// BEFORE the compute dispatch that samples the planes. Empty (a no-op) for
    /// importers that share one device with the decoder (Metal) or copy through
    /// the CPU (Windows CPU-copy): no cross-device sync object exists there. The
    /// Windows D3D12 zero-copy importer sets it to a CPU-blocking fence wait that
    /// does not return until the D3D11 plane-split pass it depends on has
    /// finished on the GPU — so callers must not assume acquire returns quickly.
    ///
    /// This is a submission-ordering hook, distinct from `release` below (which
    /// frees the wrappers). There is no matching release-sync hook: the only
    /// path that would have needed one is the DXGI keyed-mutex import, which is
    /// not ported (see importer_selector's module doc comment); the D3D12 path's
    /// plane textures are single-use, so nothing hands access back.
    acquire: Closure = .{},

    /// Frees the RD texture RIDs and releases the native import wrappers. Call
    /// exactly once (the retire-ring does this after N frames).
    release: Closure = .{},

    pub fn valid(self: PlaneTextures) bool {
        return self.luma.isValid() and self.chroma.isValid();
    }
};

/// Frees whichever of the two plane RIDs are valid. Shared by importers'
/// failure paths (one RID created, the other failed) and their release
/// closures.
pub fn freePlaneRids(rd: *RenderingDevice, luma: Rid, chroma: Rid) void {
    if (luma.isValid()) rd.freeRid(luma);
    if (chroma.isValid()) rd.freeRid(chroma);
}

/// The RD plane-texture DataFormat for one plane: r8/r16 for luma, rg8/rg16
/// for chroma, selected by bit depth. Every importer that materialises
/// ordinary right-justified R/RG plane textures (CPU-copy, D3D12, Metal)
/// picks its formats through here.
pub fn planeFormat(is_10bit: bool, is_chroma: bool) RenderingDevice.DataFormat {
    return if (is_chroma)
        (if (is_10bit) .data_format_r16g16_unorm else .data_format_r8g8_unorm)
    else
        (if (is_10bit) .data_format_r16_unorm else .data_format_r8_unorm);
}

/// Release payload for the common case: two RD plane RIDs and nothing else
/// (no native import wrapper to tear down). Importers with extra teardown
/// work (D3D12's shared resources, Metal's CVMetalTexture wrappers) box
/// their own richer release value instead.
const PlaneReleaseValue = struct {
    rd: *RenderingDevice,
    luma: Rid,
    chroma: Rid,
};

fn planeReleaseTeardown(v: *PlaneReleaseValue) void {
    freePlaneRids(v.rd, v.luma, v.chroma);
}

/// Box a release Closure that just frees the two plane RIDs via
/// freePlaneRids. Shared by every importer whose plane textures need no
/// other teardown.
pub fn boxPlaneRelease(allocator: std.mem.Allocator, rd: *RenderingDevice, luma: Rid, chroma: Rid) !Closure {
    return boxClosure(allocator, PlaneReleaseValue{ .rd = rd, .luma = luma, .chroma = chroma }, planeReleaseTeardown);
}
