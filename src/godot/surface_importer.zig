//! surface_importer.zig — platform-neutral vocabulary for surface import.
//!
//! The zero-copy present pipeline imports a hardware-decoded biplanar
//! Y'CbCr surface (NV12 8-bit, or P010/x420 10-bit) into Godot's
//! RenderingDevice as two plane textures WITHOUT any CPU copy, then runs
//! the single NV12->RGB compute pass. The concrete importer lives in
//! metal_surface_importer.zig (CVPixelBuffer IOSurface -> MTLTexture via
//! CVMetalTextureCache -> RenderingDevice.textureCreateFromExtension);
//! Windows import paths (DXGI/D3D12/CPU-Copy) are a non-goal on this
//! macOS-only build.
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

    /// Multiplier the present shader applies when recovering 10-bit code values
    /// from a sampled plane texel: code = texel * 65535 * sample_scale. Every
    /// Import Path that materialises its planes right-justified leaves this at
    /// 1.0; the Windows DXGI P010 import (out of scope here) is the exception.
    sample_scale: f32 = 1.0,

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
