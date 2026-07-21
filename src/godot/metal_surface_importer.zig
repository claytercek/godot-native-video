//! metal_surface_importer.zig — macOS CVPixelBuffer -> Metal -> RD importer.
//!
//! Takes a hardware-decoded biplanar Y'CbCr CVPixelBuffer (NV12 8-bit or
//! x420/P010 10-bit, from the AVF backend) and produces two Godot
//! RenderingDevice plane texture RIDs — luma (R8/R16) and chroma (RG8/RG16)
//! — WITHOUT any CPU copy. It reuses Godot's *own* MTLDevice
//! (RenderingDevice.getDriverResource) so a CVMetalTextureCache wraps each
//! IOSurface-backed plane as an MTLTexture usable inside Godot's RD command
//! stream, then hands that MTLTexture handle to textureCreateFromExtension
//! — still no copy.
//!
//! CoreVideo/CoreFoundation are plain C, declared extern by hand (mirrors how
//! avf_backend.zig declares its shim ABI; gdzig projects avoid @cImport). The
//! one place that needs real ObjC messaging — creating the ownership-probe
//! MTLTexture at initialize() — goes through the libobjc runtime (objc_msgSend),
//! which is already linked via the Metal/Foundation frameworks, so no ObjC shim
//! file and no build.zig change are required.

const std = @import("std");

const godot = @import("godot");
const RenderingDevice = godot.class.RenderingDevice;
const Rid = godot.builtin.Rid;

const si = @import("surface_importer.zig");
const PlaneTextures = si.PlaneTextures;

const log = std.log.scoped(.native_video_metal_import);

// -----------------------------------------------------------------------
// CoreVideo / CoreFoundation C ABI — declared by hand (no @cImport).
// Opaque CoreFoundation/CoreVideo handles cross as ?*anyopaque:
//   ?*anyopaque == CVMetalTextureCacheRef / CVMetalTextureRef /
//   CVPixelBufferRef / CFTypeRef / id<MTLDevice> / id<MTLTexture>.
// -----------------------------------------------------------------------

// CFAllocatorRef defaults: the public APIs accept NULL for kCFAllocatorDefault,
// so we pass null and avoid importing the extern constant symbol.
const kcv_return_success: i32 = 0;

extern fn CFRetain(cf: ?*anyopaque) ?*anyopaque;
extern fn CFRelease(cf: ?*anyopaque) void;
extern fn CFGetRetainCount(cf: ?*anyopaque) isize;

extern fn CVPixelBufferGetPixelFormatType(pb: ?*anyopaque) u32;
extern fn CVPixelBufferGetPlaneCount(pb: ?*anyopaque) usize;
extern fn CVPixelBufferGetWidthOfPlane(pb: ?*anyopaque, plane: usize) usize;
extern fn CVPixelBufferGetHeightOfPlane(pb: ?*anyopaque, plane: usize) usize;

extern fn CVMetalTextureCacheCreate(
    allocator: ?*anyopaque,
    cache_attrs: ?*anyopaque,
    metal_device: ?*anyopaque,
    texture_attrs: ?*anyopaque,
    cache_out: *?*anyopaque,
) i32;
extern fn CVMetalTextureCacheCreateTextureFromImage(
    allocator: ?*anyopaque,
    texture_cache: ?*anyopaque,
    source_image: ?*anyopaque,
    texture_attrs: ?*anyopaque,
    pixel_format: usize, // MTLPixelFormat (NSUInteger)
    width: usize,
    height: usize,
    plane_index: usize,
    texture_out: *?*anyopaque,
) i32;
extern fn CVMetalTextureCacheFlush(texture_cache: ?*anyopaque, options: u64) void;
extern fn CVMetalTextureGetTexture(image: ?*anyopaque) ?*anyopaque; // id<MTLTexture>

// -----------------------------------------------------------------------
// Objective-C runtime — used solely to build the ownership-probe MTLTexture.
// objc_msgSend is declared arg-less then @ptrCast to an exact prototype at each
// call site (the standard Zig idiom; on arm64 the integer/pointer arg ABI is
// identical to a normal C call for these non-struct-returning selectors).
// -----------------------------------------------------------------------
extern fn objc_getClass(name: [*:0]const u8) ?*anyopaque;
extern fn sel_registerName(name: [*:0]const u8) ?*anyopaque;
extern fn objc_msgSend() void;

// texture2DDescriptorWithPixelFormat:width:height:mipmapped: (class method)
const SendDescriptor = *const fn (?*anyopaque, ?*anyopaque, usize, usize, usize, bool) callconv(.c) ?*anyopaque;
// setUsage: (property setter, NSUInteger)
const SendSetUsage = *const fn (?*anyopaque, ?*anyopaque, usize) callconv(.c) void;
// newTextureWithDescriptor: (returns a +1 retained id<MTLTexture>)
const SendNewTexture = *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) ?*anyopaque;

// MTLPixelFormat values (Metal is stable ABI; these never change).
const mtl_pixel_format_r8_unorm: usize = 10;
const mtl_pixel_format_rg8_unorm: usize = 30;
const mtl_pixel_format_r16_unorm: usize = 20;
const mtl_pixel_format_rg16_unorm: usize = 60;
const mtl_texture_usage_shader_read: usize = 1;

/// FourCC OSType, packed MSB-first exactly as CoreVideo defines its pixel
/// format constants.
fn fourcc(comptime s: *const [4]u8) u32 {
    return (@as(u32, s[0]) << 24) | (@as(u32, s[1]) << 16) |
        (@as(u32, s[2]) << 8) | @as(u32, s[3]);
}
const pf_420v = fourcc("420v"); // 420YpCbCr8BiPlanarVideoRange
const pf_420f = fourcc("420f"); // 420YpCbCr8BiPlanarFullRange
const pf_x420 = fourcc("x420"); // 420YpCbCr10BiPlanarVideoRange
const pf_xf20 = fourcc("xf20"); // 420YpCbCr10BiPlanarFullRange

// -----------------------------------------------------------------------
// Ownership probe.
//
// Godot 4.7 rewrote the Metal RD driver onto metal-cpp and lost refcount
// balance for imported textures: textureCreateFromExtension no longer retains
// the MTLTexture when the format already matches (it did in <= 4.6 via rid's
// __bridge_retained), but texture_free still releases it unconditionally,
// deallocating the texture out from under its real owner.
//
// Rather than gate on version numbers — which can't tell a fixed 4.7.x from a
// broken one — probe the live driver: hand it a throwaway texture and watch the
// refcount across textureCreateFromExtension. A balanced driver retains on
// import; the broken one leaves the count untouched. Returns true when the
// driver will consume a reference it never took, i.e. every import must donate
// one. CFGetRetainCount is unreliable for managing one's own references, but
// measuring whether a foreign call took ownership is the one job it does
// deterministically: nothing else can touch this texture between the two reads.
// -----------------------------------------------------------------------

/// Build a 1x1 R8Unorm ShaderRead probe MTLTexture on `device`. Returns a +1
/// retained id<MTLTexture> the caller must release, or null.
fn makeProbeTexture(device: ?*anyopaque) ?*anyopaque {
    const desc_class = objc_getClass("MTLTextureDescriptor") orelse return null;
    const send_desc: SendDescriptor = @ptrCast(&objc_msgSend);
    const desc = send_desc(
        desc_class,
        sel_registerName("texture2DDescriptorWithPixelFormat:width:height:mipmapped:"),
        mtl_pixel_format_r8_unorm,
        1,
        1,
        false,
    ) orelse return null;

    const send_usage: SendSetUsage = @ptrCast(&objc_msgSend);
    send_usage(desc, sel_registerName("setUsage:"), mtl_texture_usage_shader_read);

    const send_new: SendNewTexture = @ptrCast(&objc_msgSend);
    return send_new(device, sel_registerName("newTextureWithDescriptor:"), desc);
}

fn driverStealsImportReference(rd: *RenderingDevice, device: ?*anyopaque) bool {
    const probe = makeProbeTexture(device) orelse {
        // Can't probe. Assume broken: donating on a balanced driver leaks, but
        // not donating on the broken one crashes.
        return true;
    };

    const before = CFGetRetainCount(probe);
    const rid = rd.textureCreateFromExtension(
        .texture_type_2d,
        .data_format_r8_unorm,
        .texture_samples_1,
        .{ .texture_usage_sampling_bit = true },
        @intCast(@intFromPtr(probe)),
        1,
        1,
        1,
        1,
        .{},
    );
    if (!rid.isValid()) {
        CFRelease(probe); // release our +1 (matches ARC release-at-return)
        return true; // import path is broken anyway; pick the crash-safe default
    }
    const steals = CFGetRetainCount(probe) <= before;

    // Freeing the probe RID triggers the driver's (possibly unbalanced)
    // release, so the probe texture needs the same donation real imports get.
    if (steals) {
        _ = CFRetain(probe);
    }
    rd.freeRid(rid);
    CFRelease(probe); // release our +1 (matches ARC release-at-return)
    return steals;
}

// -----------------------------------------------------------------------
// Per-frame release payload: the two RD RIDs plus the two CVMetalTexture
// wrappers, heap-boxed by si.boxClosure() on import. Order matters in the
// teardown below: RD must be done with the MTLTexture (free_rid) before the
// CVMetalTexture that owns it is released. The retire-ring only runs this
// after N rendered frames, so the GPU is finished sampling.
// -----------------------------------------------------------------------
const ReleaseValue = struct {
    rd: *RenderingDevice,
    luma: Rid,
    chroma: Rid,
    cv_luma: ?*anyopaque,
    cv_chroma: ?*anyopaque,
};

fn releaseTeardown(v: *ReleaseValue) void {
    si.freePlaneRids(v.rd, v.luma, v.chroma);
    if (v.cv_luma) |t| CFRelease(t);
    if (v.cv_chroma) |t| CFRelease(t);
}

// -----------------------------------------------------------------------
// The concrete Metal importer. Owns the CVMetalTextureCache bound to Godot's
// MTLDevice; constructed once per present pipeline and reused across frames.
// -----------------------------------------------------------------------
pub const MetalSurfaceImporter = struct {
    allocator: std.mem.Allocator,
    rd: ?*RenderingDevice = null,
    device: ?*anyopaque = null, // borrowed: Godot owns its MTLDevice
    texture_cache: ?*anyopaque = null, // CVMetalTextureCacheRef, owned (+1)
    // Some Godot drivers (4.7's metal-cpp rewrite) release imported MTLTextures
    // they never retained; when true, importPlane hands the driver a spare
    // reference. Detected at initialize() by probing the live driver.
    donate_reference_to_godot: bool = false,

    /// Construct the importer. Held by value in the present pipeline and reused
    /// across frames; initialize() binds it to RD and deinit() releases its
    /// CVMetalTextureCache. Never fails — the fallible work happens in
    /// initialize().
    pub fn init(allocator: std.mem.Allocator) MetalSurfaceImporter {
        return .{ .allocator = allocator };
    }

    /// Bind to Godot's RenderingDevice. Returns false if the importer cannot
    /// run on this RD (e.g. a non-Metal RD on macOS). Must be called before
    /// import().
    pub fn initialize(self: *MetalSurfaceImporter, rd: *RenderingDevice) bool {
        // Already initialised (a successful init always has a cache); a prior
        // *failed* attempt left texture_cache null, so it retries fully.
        if (self.texture_cache != null) return true;

        // DRIVER_RESOURCE_LOGICAL_DEVICE returns the id<MTLDevice> as an int on
        // the Metal RD backend. On a non-Metal backend this is not a valid
        // MTLDevice and CVMetalTextureCacheCreate will fail, reported as "not
        // initialised".
        const device_handle = rd.getDriverResource(.driver_resource_logical_device, si.rid_invalid, 0);
        if (device_handle == 0) return false;
        const device: ?*anyopaque = @ptrFromInt(device_handle);

        var cache: ?*anyopaque = null;
        const cr = CVMetalTextureCacheCreate(null, null, device, null, &cache);
        if (cr != kcv_return_success or cache == null) return false;

        self.rd = rd;
        self.device = device;
        self.texture_cache = cache;
        self.donate_reference_to_godot = driverStealsImportReference(rd, device);
        log.info("Metal import ownership probe: {s}", .{
            if (self.donate_reference_to_godot)
                "driver over-releases; donating a reference per imported plane"
            else
                "driver is balanced",
        });
        return true;
    }

    /// Build one RD texture aliasing a CVMetalTexture's MTLTexture, zero-copy.
    /// Returns an invalid RID on failure. On success, `out_cv_tex` is the
    /// retained CVMetalTextureRef the caller must release after the RD texture
    /// is freed. `mtl_fmt` selects 8-bit (R8/RG8) vs 10-bit (R16/RG16) planes.
    fn importPlane(
        rd: *RenderingDevice,
        cache: ?*anyopaque,
        pb: ?*anyopaque,
        plane: usize,
        fmt: RenderingDevice.DataFormat,
        mtl_fmt: usize,
        donate: bool,
        out_cv_tex: *?*anyopaque,
    ) Rid {
        out_cv_tex.* = null;

        const w = CVPixelBufferGetWidthOfPlane(pb, plane);
        const h = CVPixelBufferGetHeightOfPlane(pb, plane);
        if (w == 0 or h == 0) return si.rid_invalid;

        var cv_tex: ?*anyopaque = null;
        const cr = CVMetalTextureCacheCreateTextureFromImage(
            null,
            cache,
            pb,
            null,
            mtl_fmt,
            w,
            h,
            plane,
            &cv_tex,
        );
        if (cr != kcv_return_success or cv_tex == null) {
            if (cv_tex) |t| CFRelease(t);
            return si.rid_invalid;
        }

        const mtl_tex = CVMetalTextureGetTexture(cv_tex);
        if (mtl_tex == null) {
            CFRelease(cv_tex);
            return si.rid_invalid;
        }

        // Import the MTLTexture into Godot RD. The `image` argument is the
        // native texture handle: the id<MTLTexture> pointer as an int. SAMPLING
        // usage is all we need — the compute pass samples these planes.
        const rid = rd.textureCreateFromExtension(
            .texture_type_2d,
            fmt,
            .texture_samples_1,
            .{ .texture_usage_sampling_bit = true },
            @intCast(@intFromPtr(mtl_tex.?)),
            @intCast(w),
            @intCast(h),
            1, // depth
            1, // layers
            .{},
        );
        if (!rid.isValid()) {
            CFRelease(cv_tex);
            return si.rid_invalid;
        }

        // An unbalanced driver (see driverStealsImportReference) releases this
        // MTLTexture in texture_free without ever retaining it. Without the
        // donated reference, free_rid over-releases the texture out from under
        // the CVMetalTextureCache and the next import crashes on the recycled
        // object (Metal abort or SIGSEGV).
        if (donate) {
            _ = CFRetain(mtl_tex);
        }

        out_cv_tex.* = cv_tex; // hand ownership to the caller's release closure
        return rid;
    }

    /// Import a decoder surface (CVPixelBufferRef) into two RD plane textures,
    /// zero-copy. Returns an invalid PlaneTextures on failure. Does NOT take
    /// ownership of the decoder surface.
    pub fn import(self: *MetalSurfaceImporter, native_handle: ?*anyopaque, _: u32) PlaneTextures {
        var out: PlaneTextures = .{};
        if (self.texture_cache == null or native_handle == null) return out;

        const pb = native_handle; // CVPixelBufferRef
        const pf = CVPixelBufferGetPixelFormatType(pb);
        const is_supported = pf == pf_420v or pf == pf_420f or pf == pf_x420 or pf == pf_xf20;
        if (!is_supported or CVPixelBufferGetPlaneCount(pb) < 2) return out;

        // Detect 10-bit vs 8-bit from the pixel format type.
        const is_10bit = pf == pf_x420 or pf == pf_xf20;

        const rd = self.rd.?;
        const cache = self.texture_cache;
        const donate = self.donate_reference_to_godot;

        var cv_luma: ?*anyopaque = null;
        var cv_chroma: ?*anyopaque = null;

        var luma: Rid = undefined;
        var chroma: Rid = undefined;

        if (is_10bit) {
            // 10-bit biplanar: each sample stored in 16 bits (lower 10 bits
            // valid). Metal texture: R16Unorm luma, RG16Unorm interleaved chroma.
            luma = importPlane(rd, cache, pb, 0, si.planeFormat(true, false), mtl_pixel_format_r16_unorm, donate, &cv_luma);
            chroma = importPlane(rd, cache, pb, 1, si.planeFormat(true, true), mtl_pixel_format_rg16_unorm, donate, &cv_chroma);
        } else {
            // 8-bit NV12: each sample a single byte. R8 + RG8.
            luma = importPlane(rd, cache, pb, 0, si.planeFormat(false, false), mtl_pixel_format_r8_unorm, donate, &cv_luma);
            chroma = importPlane(rd, cache, pb, 1, si.planeFormat(false, true), mtl_pixel_format_rg8_unorm, donate, &cv_chroma);
        }

        if (!luma.isValid()) {
            // chroma may also have failed; if it succeeded, tear it back down.
            if (chroma.isValid()) rd.freeRid(chroma);
            if (cv_luma) |t| CFRelease(t);
            if (cv_chroma) |t| CFRelease(t);
            return out;
        }
        if (!chroma.isValid()) {
            rd.freeRid(luma);
            if (cv_luma) |t| CFRelease(t);
            if (cv_chroma) |t| CFRelease(t);
            return out;
        }

        // Park the teardown in a heap box.
        const release = si.boxClosure(self.allocator, ReleaseValue{
            .rd = rd,
            .luma = luma,
            .chroma = chroma,
            .cv_luma = cv_luma,
            .cv_chroma = cv_chroma,
        }, releaseTeardown) catch {
            // Out of memory: free everything now rather than leak.
            rd.freeRid(luma);
            rd.freeRid(chroma);
            if (cv_luma) |t| CFRelease(t);
            if (cv_chroma) |t| CFRelease(t);
            return out;
        };

        out.luma = luma;
        out.chroma = chroma;
        out.width = @intCast(CVPixelBufferGetWidthOfPlane(pb, 0));
        out.height = @intCast(CVPixelBufferGetHeightOfPlane(pb, 0));
        out.release = release;
        return out;
    }

    /// Metal is always zero-copy: nothing here ever violates the contract, so
    /// the count is always zero. Present purely so PresentPipeline can query
    /// cpuCopyCount() through the same call shape on every platform.
    pub fn cpuCopyCount(self: *const MetalSurfaceImporter) u64 {
        _ = self;
        return 0;
    }

    /// Release importer state (the owned CVMetalTextureCache). The importer
    /// itself is held by value in the present pipeline, so there is nothing to
    /// free here.
    pub fn deinit(self: *MetalSurfaceImporter) void {
        if (self.texture_cache) |cache| {
            CVMetalTextureCacheFlush(cache, 0);
            CFRelease(cache);
            self.texture_cache = null;
        }
        self.device = null;
    }
};
