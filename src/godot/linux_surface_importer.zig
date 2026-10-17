//! Linux's stock-RenderingDevice upload path. The GStreamer backend supplies
//! retained CPU-readable NV12/P010 planes; upload ordinary R/RG textures and
//! reuse the shared color/HDR compute pass. No native Vulkan handles, readback
//! ring, warmup frames, or dependency on the backend's lifetime.
const std = @import("std");
const core = @import("core");
const gst = @import("gst");
const godot = @import("godot");
const RenderingDevice = godot.class.RenderingDevice;
const si = @import("surface_importer.zig");
const packing = @import("cpu_plane_packing.zig");
const upload = @import("cpu_plane_upload.zig");
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
        const format: packing.SampleFormat = switch (frame.pixel_format) {
            .nv12 => .nv12,
            .x420 => .p010_le, // Linux's x420 tag carries P010_10LE (code << 6).
            else => return .bad_frame,
        };
        const layout = packing.frameLayout(frame.width, frame.height, .{
            .x = frame.crop.x,
            .y = frame.crop.y,
            .width = frame.crop.width,
            .height = frame.crop.height,
        }, format) catch return .bad_frame;
        const view = gst.frameView(handle);
        const cpu_view = packing.BiplanarView.init(view.planes, view.strides, layout) catch |err| {
            log.err("Invalid GStreamer CPU planes: {s}.", .{@errorName(err)});
            return .bad_frame;
        };
        var packed_planes = upload.PackedPlanes.init(cpu_view) catch |err| {
            log.err("Could not pack Linux CPU planes: {s}.", .{@errorName(err)});
            return .transient_failure;
        };
        defer packed_planes.deinit();
        var metadata = si.PresentationMetadata.fromFrame(frame, submission);
        // The pixel format determines storage depth even if optional stream
        // tags were absent; preserve every other color field and the PTS.
        metadata.color.bit_depth = if (format.is10Bit()) 10 else 8;
        const planes = packed_planes.upload(self.allocator, rd, metadata) catch |err| {
            log.err("Linux plane texture upload failed: {s}.", .{@errorName(err)});
            return .transient_failure;
        };
        self.cpu_copy_count += 1;
        return .{ .success = planes };
    }

    pub fn cpuCopyCount(self: *const LinuxSurfaceImporter) u64 {
        return self.cpu_copy_count;
    }

    pub fn deinit(self: *LinuxSurfaceImporter) void {
        // Plane RIDs belong to each result's release closure, not this object.
        self.rd = null;
    }
};
