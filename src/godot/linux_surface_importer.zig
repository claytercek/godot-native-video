//! Linux's stock-RenderingDevice upload path. The GStreamer backend supplies
//! retained CPU-readable NV12/P010 planes; upload ordinary R/RG textures and
//! reuse the shared color/HDR compute pass. No native Vulkan handles, readback
//! ring, warmup frames, or dependency on the backend's lifetime.
const std = @import("std");
const core = @import("core");
const gst = @import("gst");
const godot = @import("godot");
const RenderingDevice = godot.class.RenderingDevice;
const RdTextureFormat = godot.class.RdTextureFormat;
const RdTextureView = godot.class.RdTextureView;
const Rid = godot.builtin.Rid;
const PackedByteArray = godot.builtin.PackedByteArray;
const si = @import("surface_importer.zig");
const packing = @import("linux_plane_packing.zig");
const log = std.log.scoped(.native_video_linux_import);

pub const LinuxSurfaceImporter = struct {
    allocator: std.mem.Allocator,
    rd: ?*RenderingDevice = null,
    cpu_copy_count: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) LinuxSurfaceImporter {
        return .{ .allocator = allocator };
    }

    pub fn initialize(self: *LinuxSurfaceImporter, rd: *RenderingDevice) bool {
        self.rd = rd;
        return true;
    }

    pub fn isInitialized(self: *const LinuxSurfaceImporter) bool {
        return self.rd != null;
    }

    /// The caller retains ownership of frame and runs its release hook, even
    /// on failure. This importer owns only the two new RD RIDs it hands back.
    pub fn import(self: *LinuxSurfaceImporter, frame: core.backend.VideoFrame, submission: u64) si.ImportResult {
        const rd = self.rd orelse return .transient_failure;
        const handle = frame.native_handle orelse return .bad_frame;
        const is_10bit = switch (frame.pixel_format) {
            .nv12 => false,
            .x420 => true, // Linux's x420 tag carries P010_10LE (code << 6).
            else => return .bad_frame,
        };
        const layout = packing.frameLayout(frame.width, frame.height, .{
            .x = frame.crop.x,
            .y = frame.crop.y,
            .width = frame.crop.width,
            .height = frame.crop.height,
        }, is_10bit) catch return .bad_frame;
        const view = gst.frameView(handle);
        // Validate BOTH planes before creating upload buffers or RD objects.
        for (0..2) |i| {
            packing.validatePlane(view.planes[i], view.strides[i], layout.planes[i]) catch |err| {
                log.err("Invalid GStreamer plane {d}: {s}.", .{ i, @errorName(err) });
                return .bad_frame;
            };
        }

        var luma_bytes = packBytes(view.planes[0], view.strides[0], layout.planes[0]) catch {
            log.err("Could not allocate Linux luma upload bytes.", .{});
            return .transient_failure;
        };
        defer luma_bytes.deinit();
        var chroma_bytes = packBytes(view.planes[1], view.strides[1], layout.planes[1]) catch {
            log.err("Could not allocate Linux chroma upload bytes.", .{});
            return .transient_failure;
        };
        defer chroma_bytes.deinit();

        const luma = createPlane(rd, si.planeFormat(is_10bit, false), layout.width, layout.height);
        const chroma = createPlane(rd, si.planeFormat(is_10bit, true), layout.chroma_width, layout.chroma_height);
        if (!luma.isValid() or !chroma.isValid()) {
            si.freePlaneRids(rd, luma, chroma);
            log.err("Linux plane texture creation failed.", .{});
            return .transient_failure;
        }
        if (rd.textureUpdate(luma, 0, luma_bytes) != .ok or rd.textureUpdate(chroma, 0, chroma_bytes) != .ok) {
            si.freePlaneRids(rd, luma, chroma);
            log.err("Linux plane texture upload failed.", .{});
            return .transient_failure;
        }
        const release = si.boxPlaneRelease(self.allocator, rd, luma, chroma) catch {
            si.freePlaneRids(rd, luma, chroma);
            return .transient_failure;
        };
        var metadata = si.PresentationMetadata.fromFrame(frame, submission);
        // The pixel format determines storage depth even if optional stream
        // tags were absent; preserve every other color field and the PTS.
        metadata.color.bit_depth = if (is_10bit) 10 else 8;
        self.cpu_copy_count += 1;
        return .{ .success = .{
            .luma = luma,
            .chroma = chroma,
            .width = @intCast(layout.width),
            .height = @intCast(layout.height),
            .metadata = metadata,
            .release = release,
        } };
    }

    pub fn cpuCopyCount(self: *const LinuxSurfaceImporter) u64 {
        return self.cpu_copy_count;
    }

    pub fn deinit(self: *LinuxSurfaceImporter) void {
        // Plane RIDs belong to each result's release closure, not this object.
        self.rd = null;
    }
};

fn packBytes(src: []const u8, stride: usize, region: packing.PlaneRegion) !PackedByteArray {
    const size = try region.packedSize();
    if (size > std.math.maxInt(i64)) return error.OutOfMemory;
    var out = PackedByteArray.init();
    errdefer out.deinit();
    if (out.resize(@intCast(size)) != 0) return error.OutOfMemory;
    const dst: [*]u8 = @ptrCast(out.index(0));
    try packing.packPlane(dst[0..size], src, stride, region);
    return out;
}

fn createPlane(rd: *RenderingDevice, format: RenderingDevice.DataFormat, width: usize, height: usize) Rid {
    const tf = RdTextureFormat.init();
    defer if (tf.unreference()) tf.destroy();
    tf.setFormat(format);
    tf.setWidth(@intCast(width));
    tf.setHeight(@intCast(height));
    tf.setDepth(1);
    tf.setArrayLayers(1);
    tf.setMipmaps(1);
    tf.setTextureType(.texture_type_2d);
    tf.setUsageBits(.{ .texture_usage_sampling_bit = true, .texture_usage_can_update_bit = true });
    const view = RdTextureView.init();
    defer if (view.unreference()) view.destroy();
    return rd.textureCreate(tf, view, .{});
}
