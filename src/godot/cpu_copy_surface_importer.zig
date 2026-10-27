//! Windows CPU-copy fallback for RenderingDevice drivers without zero-copy
//! import, including Vulkan. MF still decodes on hardware; this path reads back
//! NV12/P010 and uploads R8/RG8 or R16/RG16 plane textures.
//!
//! Each import() queues CopySubresourceRegion into slot (frame % ring_depth),
//! then maps the oldest slot, written ring_depth-1 calls earlier. The first
//! ring_depth-1 calls return `not_ready`. After warmup, every result retains
//! that fixed lag, giving the GPU copy time to finish before Map(). Each slot
//! carries its original presentation metadata, including its crop.
//!
//! An NV12/P010 staging mapping has one pointer: Y starts at pData and UV at
//! pData + RowPitch * height. Both use RowPitch, which may include alignment
//! padding. Row-by-row packing removes that padding for texture_update.
//!
//! P010 stores each 10-bit code left-justified in a 16-bit word (code << 6).
//! Packing shifts it right by 6 to match CoreVideo x420 and the present shader's
//! right-justified convention (code = sampled * 65535).

const std = @import("std");

const core = @import("core");

const godot = @import("godot");
const RenderingDevice = godot.class.RenderingDevice;

const win = @import("mf").win;
const com = win.com;
const dxgi = win.dxgi;
const d3d11 = win.d3d11;

const si = @import("surface_importer.zig");
const ImportResult = si.ImportResult;
const packing = @import("cpu_plane_packing.zig");
const upload = @import("cpu_plane_upload.zig");

const wic = @import("windows_import_common.zig");
const CachedTex2D = wic.CachedTex2D;

const log = std.log.scoped(.native_video_cpu_copy_import);

/// Matches PresentPipeline's transient-surface retirement latency.
const readback_ring_depth: usize = 3;

const ReadbackSlot = struct {
    staging: CachedTex2D = .{},
    has_data: bool = false, // true once a CopySubresourceRegion has targeted it
    // Captured when written. Readback resolves this delayed frame's crop
    // against its own staging dimensions, not the current import's crop.
    metadata: si.PresentationMetadata = .{},
};

pub const CpuCopySurfaceImporter = struct {
    allocator: std.mem.Allocator,
    rd: ?*RenderingDevice = null,

    // Bound on first import to the decoder texture's device. D3D11 readback
    // must use that device, even if another device matches its adapter.
    device: ?*d3d11.ID3D11Device = null,
    context: ?*d3d11.ID3D11DeviceContext = null,

    ring: [readback_ring_depth]ReadbackSlot = @splat(.{}),
    frame_index: u64 = 0,
    source_width: com.UINT = 0,
    source_height: com.UINT = 0,
    source_format: dxgi.DXGI_FORMAT = dxgi.DXGI_FORMAT_UNKNOWN,
    initialized: bool = false,

    // Successful CPU-copy imports for this session. After D3D12 fallback,
    // WindowsSurfaceImporter keeps this instance for the rest of the session.
    cpu_copy_count: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) CpuCopySurfaceImporter {
        return .{ .allocator = allocator };
    }

    /// Always succeeds: texture_create/texture_update work with any RD driver.
    pub fn initialize(self: *CpuCopySurfaceImporter, rd: *RenderingDevice) bool {
        self.rd = rd;
        self.initialized = true;
        return true;
    }

    pub fn isInitialized(self: *const CpuCopySurfaceImporter) bool {
        return self.initialized;
    }

    /// Read back an NV12/P010 ID3D11Texture2D into two RD plane textures,
    /// cropped to the delayed frame's display aperture (core.backend.CropRect).
    /// Returns a typed failure on error or `not_ready` during ring warmup.
    pub fn import(self: *CpuCopySurfaceImporter, frame_info: core.backend.VideoFrame, submission: u64) ImportResult {
        if (!self.initialized) return .transient_failure;
        const handle = frame_info.native_handle orelse return .bad_frame;
        const decoded: *d3d11.ID3D11Texture2D = @ptrCast(@alignCast(handle));

        // Bind lazily to the decoder texture's device.
        if (self.device == null) {
            const bound = wic.bindDecoderDevice(decoded) orelse {
                log.err("CPU-copy importer: ID3D11Texture2D.GetDevice failed.", .{});
                return .transient_failure;
            };
            self.device = bound.device;
            self.context = bound.context;
        }
        const device = self.device.?;
        const context = self.context.?;

        var src_desc: d3d11.D3D11_TEXTURE2D_DESC = undefined;
        decoded.GetDesc(&src_desc);
        _ = wic.detectBitDepth(src_desc.Format) orelse {
            log.err("CPU-copy importer: decoder texture is not NV12 or P010.", .{});
            return .bad_frame;
        };
        const width: com.UINT = src_desc.Width;
        const height: com.UINT = src_desc.Height;

        // A ring generation has one physical shape/format. Never allow a slot
        // from the previous generation to emerge beside metadata from a new
        // decoder configuration.
        if (width != self.source_width or height != self.source_height or src_desc.Format != self.source_format) {
            for (&self.ring) |*slot| {
                slot.staging.release();
                slot.has_data = false;
                slot.metadata = .{};
            }
            self.frame_index = 0;
            self.source_width = width;
            self.source_height = height;
            self.source_format = src_desc.Format;
        }

        const frame = self.frame_index;
        self.frame_index += 1;
        const write_slot = frame % readback_ring_depth;
        const read_slot = (frame + 1) % readback_ring_depth;

        // Queue a GPU copy into the slot with the longest time until readback.
        const write = &self.ring[@as(usize, @intCast(write_slot))];
        if (!write.staging.ensure(device, width, height, src_desc.Format, d3d11.D3D11_USAGE_STAGING, 0, d3d11.D3D11_CPU_ACCESS_READ)) {
            log.err("CPU-copy importer: staging texture create failed.", .{});
            return .transient_failure;
        }
        context.CopySubresourceRegion(
            write.staging.texture.?.asResource(),
            0,
            0,
            0,
            0,
            decoded.asResource(),
            @intCast(frame_info.plane_slice),
            null,
        );
        write.has_data = true;
        write.metadata = si.PresentationMetadata.fromFrame(frame_info, submission);

        // Read the oldest slot; return not_ready during warmup.
        const read = &self.ring[@as(usize, @intCast(read_slot))];
        if (!read.has_data) return .not_ready;

        // Keep staging/Map lifetime platform-specific. Shared packing borrows
        // the mapping only inside this scope; RD upload happens after Unmap.
        var packed_planes = mapped_planes: {
            var mapped = std.mem.zeroes(d3d11.D3D11_MAPPED_SUBRESOURCE);
            if (com.FAILED(context.Map(read.staging.texture.?.asResource(), 0, d3d11.D3D11_MAP_READ, 0, &mapped))) {
                log.err("CPU-copy importer: staging texture Map failed.", .{});
                return .transient_failure;
            }
            defer context.Unmap(read.staging.texture.?.asResource(), 0);

            // Resolve the delayed slot's crop against its own dimensions.
            const aligned_width = std.math.cast(i32, read.staging.width) orelse return .bad_frame;
            const aligned_height = std.math.cast(i32, read.staging.height) orelse return .bad_frame;
            const rc = wic.resolveCrop(read.metadata.crop, read.staging.width, read.staging.height);
            const read_is_10bit = wic.detectBitDepth(read.staging.format) orelse return .bad_frame;
            const layout = packing.frameLayout(aligned_width, aligned_height, .{
                .x = rc.luma_x,
                .y = rc.luma_y,
                .width = rc.luma_width,
                .height = rc.luma_height,
            }, if (read_is_10bit) .p010_le else .nv12) catch return .bad_frame;
            const row_pitch: usize = mapped.RowPitch;
            const data: [*]const u8 = @ptrCast(mapped.pData orelse return .bad_frame);
            // D3D guarantees one contiguous mapping, with UV immediately after
            // all aligned Y rows. Bound each plane separately before packing.
            const luma_size = std.math.mul(usize, row_pitch, read.staging.height) catch return .bad_frame;
            const chroma_size = std.math.mul(usize, row_pitch, @as(usize, read.staging.height) / 2) catch return .bad_frame;
            _ = std.math.add(usize, luma_size, chroma_size) catch return .bad_frame;
            const cpu_view = packing.BiplanarView.init(.{
                data[0..luma_size],
                (data + luma_size)[0..chroma_size],
            }, .{ row_pitch, row_pitch }, layout) catch |err| {
                log.err("CPU-copy importer: invalid mapped planes: {s}.", .{@errorName(err)});
                return .bad_frame;
            };
            break :mapped_planes upload.PackedPlanes.init(cpu_view) catch |err| {
                log.err("CPU-copy importer: plane packing failed: {s}.", .{@errorName(err)});
                return .transient_failure;
            };
        };
        defer packed_planes.deinit();
        const out = packed_planes.upload(self.allocator, self.rd.?, read.metadata) catch |err| {
            log.err("CPU-copy importer: plane texture upload failed: {s}.", .{@errorName(err)});
            return .transient_failure;
        };
        // Count only completed CPU-copy imports.
        self.cpu_copy_count += 1;
        return .{ .success = out };
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
