//! surface_importer.zig — platform-agnostic surface-import interface.
//!
//! Port of src/common/surface_importer.h (+ importer_selector.h). The zero-copy
//! present pipeline imports a hardware-decoded biplanar Y'CbCr surface (NV12
//! 8-bit, or P010/x420 10-bit) into Godot's RenderingDevice as two plane
//! textures WITHOUT any CPU copy, then runs the single NV12->RGB compute pass.
//! The *mechanism* of that import is platform-specific:
//!
//!   - macOS: CVPixelBuffer IOSurface -> MTLTexture (CVMetalTextureCache)
//!            -> RenderingDevice.textureCreateFromExtension. (MetalSurfaceImporter)
//!   - Windows: the DXGI/D3D12/CPU-Copy import paths.
//!
//! This is the seam between the platform-agnostic Binding (present pipeline,
//! video-stream playback) and the per-platform importer. Importer selection
//! lives in exactly ONE place (make_surface_importer); nothing in the shared
//! path knows which concrete importer is in use.
//!
//! SCOPE: this build is macOS-only. Only the Metal importer is wired (see
//! metal_surface_importer.zig — currently a compiling stub). The Windows
//! D3D11/D3D12/DXGI and CPU-Copy import paths are a non-goal; there is no
//! importer selection logic here because there is nothing to select between.
//!
//! The C++ pure-virtual class becomes a ptr + vtable interface (composition,
//! not inheritance), matching src/core/backend.zig's style. std::function
//! release/acquire hooks become ctx + fn-pointer Closures.

const std = @import("std");

const godot = @import("godot");
const RenderingDevice = godot.class.RenderingDevice;
const Rid = godot.builtin.Rid;

const metal = @import("metal_surface_importer.zig");

/// An invalid (zero) RID for struct-field defaults. isValid() is false.
pub const rid_invalid: Rid = std.mem.zeroes(Rid);

/// C++ std::function<void()> hook → ctx + fn pointer. An empty value
/// (func == null) is the "no hook" state, ignored by call().
pub const Closure = struct {
    ctx: ?*anyopaque = null,
    func: ?*const fn (?*anyopaque) void = null,

    pub fn call(self: Closure) void {
        if (self.func) |f| f(self.ctx);
    }
};

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

    /// Optional GPU-sync hooks for platforms that gate decoder<->Godot access
    /// on a keyed mutex / fence (Windows). On macOS these stay empty: CoreVideo
    /// + Metal share one device so no cross-device sync object is needed.
    acquire: Closure = .{}, // keyed-mutex acquire or fence wait (Windows)
    release_sync: Closure = .{}, // keyed-mutex release (Windows)

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

// -----------------------------------------------------------------------
// SurfaceImporter — abstract per-platform decoder-surface importer.
//
// One instance per present pipeline; reused across frames. Concrete importers
// own whatever cache/device state their platform needs (a CVMetalTextureCache
// on macOS).
// -----------------------------------------------------------------------
pub const SurfaceImporter = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Bind to Godot's RenderingDevice. Returns false if the importer
        /// cannot run on this RD (e.g. a non-Metal RD on macOS). Must be called
        /// before import().
        initialize: *const fn (*anyopaque, rd: *RenderingDevice) bool,
        is_initialized: *const fn (*anyopaque) bool,
        /// Whether this importer's planes reach RD without a CPU pixel copy.
        /// Fixed per importer. Optional: null → true (zero-copy default).
        is_zero_copy: ?*const fn (*anyopaque) bool = null,
        /// Import a decoder surface (CVPixelBufferRef on macOS) into two RD
        /// plane textures, zero-copy. Returns an invalid PlaneTextures on
        /// failure. Does NOT take ownership of the decoder surface.
        import: *const fn (*anyopaque, native_handle: ?*anyopaque, plane_slice: u32) PlaneTextures,
        /// Virtual destructor: release importer state and free the instance.
        deinit: *const fn (*anyopaque) void,
    };

    pub fn initialize(self: SurfaceImporter, rd: *RenderingDevice) bool {
        return self.vtable.initialize(self.ptr, rd);
    }
    pub fn isInitialized(self: SurfaceImporter) bool {
        return self.vtable.is_initialized(self.ptr);
    }
    pub fn isZeroCopy(self: SurfaceImporter) bool {
        if (self.vtable.is_zero_copy) |f| return f(self.ptr);
        return true;
    }
    pub fn import(self: SurfaceImporter, native_handle: ?*anyopaque, plane_slice: u32) PlaneTextures {
        return self.vtable.import(self.ptr, native_handle, plane_slice);
    }
    pub fn deinit(self: SurfaceImporter) void {
        self.vtable.deinit(self.ptr);
    }
};

/// Factory: returns the importer for the current build. Metal is the only
/// importer this codebase implements — other platforms' import paths are a
/// non-goal, so there is no selection logic here. Returns null if the
/// importer cannot be constructed.
pub fn makeSurfaceImporter(allocator: std.mem.Allocator) ?SurfaceImporter {
    return metal.create(allocator);
}
