//! Platform-neutral surface import types and RID/teardown helpers.
//! Importers provide NV12 (8-bit) or P010/x420 (10-bit) luma/chroma textures for
//! the shared Y'CbCr-to-RGB compute pass, hiding native APIs from presentation.
//!
//! Metal aliases IOSurface planes through CVMetalTextureCache. Windows selects
//! D3D12 zero-copy or CPU-copy by RD driver and Godot version; Vulkan's DXGI
//! import path is not ported (see importer_selector.zig). Linux uploads CPU
//! planes. Teardown uses ctx + function-pointer Closures because Zig has no
//! capturing closures.

const std = @import("std");

const godot = @import("godot");
const RenderingDevice = godot.class.RenderingDevice;
const Rid = godot.builtin.Rid;

const core = @import("core");

pub const PresentationMetadata = struct {
    /// Presentation identity, preserved through delayed importer slots. This is
    /// not decoder state: equal PTS can belong to different seek submissions.
    submission: u64 = 0,
    pts_seconds: f64 = 0.0,
    width: i32 = 0,
    height: i32 = 0,
    pixel_format: core.backend.PixelFormat = .unknown,
    crop: core.backend.CropRect = .{},
    color: core.backend.Colorimetry = .{},

    pub fn fromFrame(frame: core.backend.VideoFrame, submission: u64) PresentationMetadata {
        return .{
            .submission = submission,
            .pts_seconds = frame.pts_seconds,
            .width = frame.width,
            .height = frame.height,
            .pixel_format = frame.pixel_format,
            .crop = frame.crop,
            .color = frame.color,
        };
    }
};

/// An invalid (zero) RID for struct-field defaults. isValid() is false.
pub const rid_invalid: Rid = std.mem.zeroes(Rid);

/// Imported-surface release/sync hook: context plus function pointer.
pub const Closure = core.backend.VoidClosure;

/// Heap-box value; return a Closure that runs teardown on it, then frees the
/// box. Shared by the present pipeline's boxed teardown hooks.
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

// Imported planes and their release hook, which frees RD RIDs and native
// wrappers exactly once. For dispatched frames, the present pipeline defers
// release by N rendered frames so GPU sampling finishes first.
pub const PlaneTextures = struct {
    luma: Rid = rid_invalid, // R8 (8-bit) or R16 (10-bit), full resolution
    chroma: Rid = rid_invalid, // RG8 (8-bit) or RG16 (10-bit), half resolution
    width: i32 = 0, // luma (frame) width
    height: i32 = 0, // luma (frame) height
    metadata: PresentationMetadata = .{},

    /// Frees the RD texture RIDs and releases the native import wrappers. Call
    /// exactly once (the retire-ring does this after N frames).
    release: Closure = .{},

    pub fn valid(self: PlaneTextures) bool {
        return self.luma.isValid() and self.chroma.isValid();
    }

    /// Abandon an imported frame and consume its release hook exactly once.
    pub fn discard(self: *PlaneTextures) void {
        const release = self.release;
        self.release = .{};
        release.call();
    }
};

/// Typed import outcome. Only `capability_unavailable` authorizes the Windows
/// selector to permanently abandon D3D12; malformed or transient frames must
/// not silently change the session's presentation architecture.
pub const ImportResult = union(enum) {
    success: PlaneTextures,
    not_ready,
    bad_frame,
    transient_failure,
    capability_unavailable,
};

/// Free valid plane RIDs, including partially created pairs on import failure.
pub fn freePlaneRids(rd: *RenderingDevice, luma: Rid, chroma: Rid) void {
    if (luma.isValid()) rd.freeRid(luma);
    if (chroma.isValid()) rd.freeRid(chroma);
}

/// RD plane format: R8/R16 luma or RG8/RG16 chroma, selected by bit depth.
/// All importers provide right-justified samples in these formats.
pub fn planeFormat(is_10bit: bool, is_chroma: bool) RenderingDevice.DataFormat {
    return if (is_chroma)
        (if (is_10bit) .data_format_r16g16_unorm else .data_format_r8g8_unorm)
    else
        (if (is_10bit) .data_format_r16_unorm else .data_format_r8_unorm);
}

/// Teardown payload for RD-only planes. D3D12 and Metal box separate payloads
/// that also release shared resources or CVMetalTexture wrappers.
const PlaneReleaseValue = struct {
    rd: *RenderingDevice,
    luma: Rid,
    chroma: Rid,
};

fn planeReleaseTeardown(v: *PlaneReleaseValue) void {
    freePlaneRids(v.rd, v.luma, v.chroma);
}

/// Box a release hook for planes that need only freePlaneRids teardown.
pub fn boxPlaneRelease(allocator: std.mem.Allocator, rd: *RenderingDevice, luma: Rid, chroma: Rid) !Closure {
    return boxClosure(allocator, PlaneReleaseValue{ .rd = rd, .luma = luma, .chroma = chroma }, planeReleaseTeardown);
}
