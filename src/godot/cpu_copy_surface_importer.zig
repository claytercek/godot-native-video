//! cpu_copy_surface_importer.zig — Windows CPU-copy import path.
//!
//! The fallback importer for the common case: a stock Vulkan RenderingDevice
//! driver on any Godot version, where neither zero-copy path is reachable (the
//! DXGI Vulkan import is not ported, and the D3D12 path needs the d3d12 RD
//! driver). Hardware decode is untouched — the MF backend's DXGI device manager
//! still drives the decoder — and this adds a GPU->CPU readback so the decoded
//! NV12/P010 surface reaches Godot RD as ordinary R8/RG8 (8-bit) or R16/RG16
//! (10-bit) textures instead of an aliased import.
//!
//! This is the ONE import path that violates the zero-copy contract, by design.
//!
//! The readback ring, in detail: each import() writes into ring slot
//! (frame % ring_depth) via CopySubresourceRegion (GPU-side, no CPU copy), then
//! reads back the slot written ring_depth-1 frames ago — the oldest occupied
//! slot, whose GPU copy has had that many frames to drain, so Map() reads
//! resident data instead of stalling the render thread. During the first
//! ring_depth-1 frames after initialize() no slot is old enough (has_data is
//! false) and import() returns an invalid PlaneTextures; the present pipeline
//! presents nothing until the ring fills. This same accounting means every
//! frame presented on this path — not just during startup — is the pixel
//! content from ring_depth-1 frames earlier: a fixed, permanent presentation
//! lag traded for never stalling on Map().
//!
//! Mapping an NV12/P010 staging texture returns ONE pointer for the whole
//! resource: the Y plane's rows start at pData with stride RowPitch, and the
//! interleaved UV plane starts immediately after all Y rows, at
//! pData + RowPitch * height, using the SAME RowPitch. Both planes are copied
//! row-by-row into tightly packed buffers because RowPitch is generally wider
//! than a plane's exact byte width (driver row alignment) while texture_update
//! expects tightly packed data.
//!
//! P010 bit justification: each 10-bit sample is stored left-justified in a
//! 16-bit word (value = code << 6), the opposite of CoreVideo's x420 (the AVF
//! backend's 10-bit format, right-justified in the low 10 bits). The shared
//! present shader assumes the x420 convention (code = sampled * 65535), so the
//! 10-bit packing path shifts every sample right by 6 while copying, producing
//! the same right-justified layout on both platforms.

const std = @import("std");

const core = @import("core");

const godot = @import("godot");
const RenderingDevice = godot.class.RenderingDevice;
const RdTextureFormat = godot.class.RdTextureFormat;
const RdTextureView = godot.class.RdTextureView;
const Rid = godot.builtin.Rid;
const PackedByteArray = godot.builtin.PackedByteArray;

const win = @import("mf").win;
const com = win.com;
const dxgi = win.dxgi;
const d3d11 = win.d3d11;

const si = @import("surface_importer.zig");
const PlaneTextures = si.PlaneTextures;

const wic = @import("windows_import_common.zig");
const CachedTex2D = wic.CachedTex2D;

const log = std.log.scoped(.native_video_cpu_copy_import);

/// Ring depth matches PresentPipeline's frame latency: the same number of
/// rendered frames every other import path's transient surfaces survive before
/// retirement.
const readback_ring_depth: usize = 3;

const ReadbackSlot = struct {
    staging: CachedTex2D = .{},
    has_data: bool = false, // true once a CopySubresourceRegion has targeted it
    // The display-aperture crop THIS slot's frame carried, captured at write
    // time. The read side resolves it against `staging`'s own (aligned)
    // dimensions rather than whatever crop the CURRENT call() received, since
    // the slot being read back was written by an earlier, different import()
    // call -- see the ring-buffer accounting in the module doc comment.
    crop: core.backend.CropRect = .{},
};

pub const CpuCopySurfaceImporter = struct {
    allocator: std.mem.Allocator,
    rd: ?*RenderingDevice = null,

    // Bound lazily on the first import(), straight from the decoder texture —
    // no device of our own, no adapter matching: the readback runs on the SAME
    // device the decoder texture already lives on.
    device: ?*d3d11.ID3D11Device = null,
    context: ?*d3d11.ID3D11DeviceContext = null,

    ring: [readback_ring_depth]ReadbackSlot = @splat(.{}),
    frame_index: u64 = 0,
    initialized: bool = false,

    // Session-scoped: every frame actually imported through this path, honest
    // accounting for the one importer allowed to violate the zero-copy
    // contract. Persists across a mid-flight D3D12->CPU-copy degrade, since
    // the WindowsSurfaceImporter wrapper keeps reusing the same instance for
    // the rest of the session once it switches over.
    cpu_copy_count: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) CpuCopySurfaceImporter {
        return .{ .allocator = allocator };
    }

    /// Always succeeds for a non-null RD: unlike the zero-copy importers this
    /// path needs no particular RD driver or GPU extension — texture_create /
    /// texture_update are driver-agnostic.
    pub fn initialize(self: *CpuCopySurfaceImporter, rd: *RenderingDevice) bool {
        self.rd = rd;
        self.initialized = true;
        return true;
    }

    pub fn isInitialized(self: *const CpuCopySurfaceImporter) bool {
        return self.initialized;
    }

    /// Import the NV12/P010 ID3D11Texture2D (opaque handle == ID3D11Texture2D*)
    /// into two RD plane textures via a GPU->CPU readback, CROPPED to `crop`
    /// (the frame's display aperture -- see core.backend.CropRect). Returns an
    /// invalid PlaneTextures on failure OR while the readback ring is still
    /// warming up.
    pub fn import(self: *CpuCopySurfaceImporter, native_handle: ?*anyopaque, plane_slice: u32, crop: core.backend.CropRect) PlaneTextures {
        var out: PlaneTextures = .{};
        if (!self.initialized) return out;
        const handle = native_handle orelse return out;
        const decoded: *d3d11.ID3D11Texture2D = @ptrCast(@alignCast(handle));

        // Lazily bind to the SAME device the decoder texture lives on.
        if (self.device == null) {
            const bound = wic.bindDecoderDevice(decoded) orelse {
                log.err("CPU-copy importer: ID3D11Texture2D.GetDevice failed.", .{});
                return out;
            };
            self.device = bound.device;
            self.context = bound.context;
        }
        const device = self.device.?;
        const context = self.context.?;

        var src_desc: d3d11.D3D11_TEXTURE2D_DESC = undefined;
        decoded.GetDesc(&src_desc);
        const is_10bit = wic.detectBitDepth(src_desc.Format) orelse {
            log.err("CPU-copy importer: decoder texture is not NV12 or P010.", .{});
            return out;
        };
        const width: com.UINT = src_desc.Width;
        const height: com.UINT = src_desc.Height;

        const frame = self.frame_index;
        self.frame_index += 1;
        const write_slot = frame % readback_ring_depth;
        const read_slot = (frame + 1) % readback_ring_depth;

        // --- Queue this frame's GPU-side readback into the ring slot with the
        // most time left before it is read. No CPU copy here.
        const write = &self.ring[@as(usize, @intCast(write_slot))];
        if (!write.staging.ensure(device, width, height, src_desc.Format, d3d11.D3D11_USAGE_STAGING, 0, d3d11.D3D11_CPU_ACCESS_READ)) {
            log.err("CPU-copy importer: staging texture create failed.", .{});
            return out;
        }
        context.CopySubresourceRegion(
            write.staging.texture.?.asResource(),
            0,
            0,
            0,
            0,
            decoded.asResource(),
            @intCast(plane_slice),
            null,
        );
        write.has_data = true;
        write.crop = crop;

        // --- Read back the oldest slot. Still warming up: nothing old enough.
        const read = &self.ring[@as(usize, @intCast(read_slot))];
        if (!read.has_data) return out;

        var mapped = std.mem.zeroes(d3d11.D3D11_MAPPED_SUBRESOURCE);
        if (com.FAILED(context.Map(read.staging.texture.?.asResource(), 0, d3d11.D3D11_MAP_READ, 0, &mapped))) {
            log.err("CPU-copy importer: staging texture Map failed.", .{});
            return out;
        }

        // Aligned (possibly macroblock-padded) dimensions of the physical
        // readback -- the crop is resolved against THESE, and against the
        // crop THIS slot's frame carried (read.crop), not the crop passed to
        // the current call.
        const aligned_width: com.UINT = read.staging.width;
        const aligned_height: com.UINT = read.staging.height;
        const rc = wic.resolveCrop(read.crop, aligned_width, aligned_height);
        const row_pitch: usize = mapped.RowPitch;

        const luma_src: [*]const u8 = @ptrCast(mapped.pData.?);
        const chroma_src: [*]const u8 = luma_src + row_pitch * @as(usize, aligned_height);

        var luma_bytes: PackedByteArray = undefined;
        var chroma_bytes: PackedByteArray = undefined;
        if (is_10bit) {
            luma_bytes = packRows10bit(luma_src, row_pitch, rc.luma_x, rc.luma_y, rc.luma_width, rc.luma_height);
            // Interleaved U16+V16 per chroma sample.
            chroma_bytes = packRows10bit(chroma_src, row_pitch, @as(usize, rc.chroma_x) * 2, rc.chroma_y, @as(usize, rc.chroma_width) * 2, rc.chroma_height);
        } else {
            luma_bytes = packRows8bit(luma_src, row_pitch, rc.luma_x, rc.luma_y, rc.luma_width, rc.luma_height);
            // Interleaved U8+V8 per chroma sample.
            chroma_bytes = packRows8bit(chroma_src, row_pitch, @as(usize, rc.chroma_x) * 2, rc.chroma_y, @as(usize, rc.chroma_width) * 2, rc.chroma_height);
        }
        defer luma_bytes.deinit();
        defer chroma_bytes.deinit();

        context.Unmap(read.staging.texture.?.asResource(), 0);

        // --- Ordinary texture_create + texture_update — no aliased import.
        const rd = self.rd.?;
        const luma_fmt = si.planeFormat(is_10bit, false);
        const chroma_fmt = si.planeFormat(is_10bit, true);

        const luma = createPlane(rd, luma_fmt, @intCast(rc.luma_width), @intCast(rc.luma_height));
        const chroma = createPlane(rd, chroma_fmt, @intCast(rc.chroma_width), @intCast(rc.chroma_height));
        if (!luma.isValid() or !chroma.isValid()) {
            si.freePlaneRids(rd, luma, chroma);
            log.err("CPU-copy importer: texture_create failed.", .{});
            return out;
        }
        if (rd.textureUpdate(luma, 0, luma_bytes) != .ok or rd.textureUpdate(chroma, 0, chroma_bytes) != .ok) {
            si.freePlaneRids(rd, luma, chroma);
            log.err("CPU-copy importer: texture_update failed.", .{});
            return out;
        }

        const release = si.boxPlaneRelease(self.allocator, rd, luma, chroma) catch {
            si.freePlaneRids(rd, luma, chroma);
            return out;
        };

        out.luma = luma;
        out.chroma = chroma;
        out.width = @intCast(rc.luma_width);
        out.height = @intCast(rc.luma_height);
        out.release = release;
        // Honest accounting: this is the one import path allowed to violate
        // the zero-copy contract, so every frame it actually hands back counts.
        self.cpu_copy_count += 1;
        return out;
    }

    /// Frames imported through this CPU-copy path so far this session.
    pub fn cpuCopyCount(self: *const CpuCopySurfaceImporter) u64 {
        return self.cpu_copy_count;
    }

    pub fn deinit(self: *CpuCopySurfaceImporter) void {
        for (&self.ring) |*slot| slot.staging.release();
        if (self.context) |c| {
            com.release(c);
            self.context = null;
        }
        if (self.device) |d| {
            com.release(d);
            self.device = null;
        }
        self.initialized = false;
    }
};

/// Pack 8-bit plane rows tightly, cropped to `row_bytes` bytes per row
/// starting at byte offset `x_offset`, for `rows` rows starting at row
/// `y_offset` (RowPitch may exceed the tight row width even before cropping).
fn packRows8bit(src: [*]const u8, row_pitch: usize, x_offset: usize, y_offset: usize, row_bytes: usize, rows: usize) PackedByteArray {
    var out = PackedByteArray.init();
    _ = out.resize(@intCast(row_bytes * rows));
    const dst: [*]u8 = @ptrCast(out.index(0));
    var y: usize = 0;
    while (y < rows) : (y += 1) {
        const src_row = src + (y + y_offset) * row_pitch + x_offset;
        @memcpy(dst[y * row_bytes ..][0..row_bytes], src_row[0..row_bytes]);
    }
    return out;
}

/// Pack 10-bit (P010) plane rows tightly AND shift each 16-bit sample right by
/// 6, converting P010's left-justified layout to the right-justified 10-bit-in-
/// 16 layout the shared present shader expects (matching macOS x420). Cropped
/// to `samples_per_row` 16-bit samples per row starting at sample offset
/// `x_offset`, for `rows` rows starting at row `y_offset`.
fn packRows10bit(src: [*]const u8, row_pitch: usize, x_offset: usize, y_offset: usize, samples_per_row: usize, rows: usize) PackedByteArray {
    var out = PackedByteArray.init();
    _ = out.resize(@intCast(samples_per_row * rows * @sizeOf(u16)));
    const dst: [*]u16 = @ptrCast(@alignCast(out.index(0)));
    var y: usize = 0;
    while (y < rows) : (y += 1) {
        const src_row: [*]const u8 = src + (y + y_offset) * row_pitch;
        const dst_row = dst + y * samples_per_row;
        var x: usize = 0;
        while (x < samples_per_row) : (x += 1) {
            // Read the little-endian 16-bit sample without assuming alignment.
            const sx = x + x_offset;
            const lo = src_row[sx * 2];
            const hi = src_row[sx * 2 + 1];
            const sample: u16 = (@as(u16, hi) << 8) | @as(u16, lo);
            dst_row[x] = sample >> 6;
        }
    }
    return out;
}

/// Create one RD plane texture (sampling + can-update) at w x h.
fn createPlane(rd: *RenderingDevice, format: RenderingDevice.DataFormat, w: i64, h: i64) Rid {
    const tf = RdTextureFormat.init();
    defer if (tf.unreference()) tf.destroy();
    tf.setFormat(format);
    tf.setWidth(@intCast(w));
    tf.setHeight(@intCast(h));
    tf.setDepth(1);
    tf.setArrayLayers(1);
    tf.setMipmaps(1);
    tf.setTextureType(.texture_type_2d);
    tf.setUsageBits(.{ .texture_usage_sampling_bit = true, .texture_usage_can_update_bit = true });

    const view = RdTextureView.init();
    defer if (view.unreference()) view.destroy();

    return rd.textureCreate(tf, view, .{});
}
