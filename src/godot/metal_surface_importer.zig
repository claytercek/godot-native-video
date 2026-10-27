//! Zero-copy CVPixelBuffer -> Metal -> RenderingDevice import for AVF's
//! biplanar NV12 (8-bit) and x420 (10-bit) surfaces. CVMetalTextureCache uses
//! Godot's MTLDevice to wrap IOSurface planes as MTLTextures, then imports them
//! through textureCreateFromExtension as R8/R16 luma and RG8/RG16 chroma.
//!
//! CoreVideo/CoreFoundation use handwritten C externs, without @cImport.
//! The ownership-probe texture uses objc_msgSend through libobjc, already
//! linked by Metal/Foundation; no Objective-C shim is needed.

const std = @import("std");

const core = @import("core");

const godot = @import("godot");
const RenderingDevice = godot.class.RenderingDevice;
const Rid = godot.builtin.Rid;

const si = @import("surface_importer.zig");
const PlaneTextures = si.PlaneTextures;

const log = std.log.scoped(.native_video_metal_import);

// CoreVideo/CoreFoundation C ABI. ?*anyopaque carries CVMetalTextureCacheRef,
// CVMetalTextureRef, CVPixelBufferRef, CFTypeRef, id<MTLDevice>, or id<MTLTexture>.

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

// Objective-C runtime for the ownership-probe MTLTexture. Cast the argumentless
// objc_msgSend declaration to each selector's exact prototype. On arm64 these
// integer/pointer calls, with no struct returns, use the normal C ABI.
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

// Probe import ownership on the live driver. Godot 4.7's metal-cpp rewrite
// stopped retaining format-matched MTLTextures in textureCreateFromExtension,
// though texture_free still releases them. Godot <= 4.6 retained via
// __bridge_retained. Affected drivers need a donated reference per import.
//
// Compare a throwaway texture's refcount across import instead of checking
// versions, which cannot distinguish fixed 4.7.x builds. A balanced driver
// retains; an affected driver leaves the count unchanged. Nothing else can
// access the probe between these CFGetRetainCount reads; this measurement
// does not replace explicit ownership accounting for shared textures.

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

// Heap-boxed per-frame teardown. After N rendered frames, the retire ring
// frees RD RIDs before releasing the CVMetalTexture wrappers that own their
// MTLTextures. This keeps wrappers alive until GPU sampling is finished.
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

// Owns a CVMetalTextureCache on Godot's MTLDevice, reused across frames.
pub const MetalSurfaceImporter = struct {
    allocator: std.mem.Allocator,
    rd: ?*RenderingDevice = null,
    device: ?*anyopaque = null, // borrowed: Godot owns its MTLDevice
    texture_cache: ?*anyopaque = null, // CVMetalTextureCacheRef, owned (+1)
    // Some Godot drivers (4.7's metal-cpp rewrite) release imported MTLTextures
    // they never retained; when true, importPlane hands the driver a spare
    // reference. Detected at initialize() by probing the live driver.
    donate_reference_to_godot: bool = false,

    /// Construct by value without allocating. initialize() binds RD and creates
    /// the cache; deinit() releases it.
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

        // The Metal backend returns id<MTLDevice> as an integer. A non-Metal
        // handle is invalid here and cannot initialize CVMetalTextureCache.
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

        // Pass id<MTLTexture> as an integer handle. Only SAMPLING is needed.
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

        // Donate the reference consumed by an unbalanced driver's texture_free.
        // Without it, free_rid over-releases the cache's MTLTexture and the next
        // import can crash on the recycled object.
        if (donate) {
            _ = CFRetain(mtl_tex);
        }

        out_cv_tex.* = cv_tex; // hand ownership to the caller's release closure
        return rid;
    }

    /// Borrow a CVPixelBufferRef and import two RD planes without copying.
    /// VideoToolbox already crops AVF buffers to the display/clean aperture:
    /// avf_shim.m's CVPixelBufferGetWidth/Height and this importer's per-plane
    /// size queries read cropped dimensions, so no padding crop is needed.
    pub fn import(self: *MetalSurfaceImporter, frame_info: core.backend.VideoFrame, submission: u64) si.ImportResult {
        var out: PlaneTextures = .{};
        if (self.texture_cache == null) return .transient_failure;
        if (frame_info.native_handle == null) return .bad_frame;

        const pb = frame_info.native_handle; // CVPixelBufferRef
        const pf = CVPixelBufferGetPixelFormatType(pb);
        const is_supported = pf == pf_420v or pf == pf_420f or pf == pf_x420 or pf == pf_xf20;
        if (!is_supported or CVPixelBufferGetPlaneCount(pb) < 2) return .bad_frame;

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
            return .transient_failure;
        }
        if (!chroma.isValid()) {
            rd.freeRid(luma);
            if (cv_luma) |t| CFRelease(t);
            if (cv_chroma) |t| CFRelease(t);
            return .transient_failure;
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
            return .transient_failure;
        };

        out.luma = luma;
        out.chroma = chroma;
        out.width = @intCast(CVPixelBufferGetWidthOfPlane(pb, 0));
        out.height = @intCast(CVPixelBufferGetHeightOfPlane(pb, 0));
        out.metadata = si.PresentationMetadata.fromFrame(frame_info, submission);
        out.release = release;
        return .{ .success = out };
    }

    /// Always zero; keeps PresentPipeline's importer interface platform-neutral.
    pub fn cpuCopyCount(self: *const MetalSurfaceImporter) u64 {
        _ = self;
        return 0;
    }

    /// Release the owned CVMetalTextureCache; the importer itself is a value.
    pub fn deinit(self: *MetalSurfaceImporter) void {
        if (self.texture_cache) |cache| {
            CVMetalTextureCacheFlush(cache, 0);
            CFRelease(cache);
            self.texture_cache = null;
        }
        self.device = null;
    }
};
