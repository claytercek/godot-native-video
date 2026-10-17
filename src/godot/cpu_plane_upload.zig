//! Shared checked CPU-plane packing and stock RenderingDevice upload.
//! Source mappings belong to the caller and need survive only init(); uploaded
//! RIDs belong exclusively to the returned surface's canonical release hook.
const std = @import("std");
const godot = @import("godot");
const RenderingDevice = godot.class.RenderingDevice;
const RdTextureFormat = godot.class.RdTextureFormat;
const RdTextureView = godot.class.RdTextureView;
const Rid = godot.builtin.Rid;
const PackedByteArray = godot.builtin.PackedByteArray;
const packing = @import("cpu_plane_packing.zig");
const si = @import("surface_importer.zig");

pub const PackedPlanes = struct {
    luma: PackedByteArray,
    chroma: PackedByteArray,
    layout: packing.Layout,

    pub fn init(view: packing.BiplanarView) !PackedPlanes {
        var luma = try packBytes(view.planes[0], view.strides[0], view.layout.planes[0]);
        errdefer luma.deinit();
        const chroma = try packBytes(view.planes[1], view.strides[1], view.layout.planes[1]);
        return .{ .luma = luma, .chroma = chroma, .layout = view.layout };
    }

    pub fn deinit(self: *PackedPlanes) void {
        self.luma.deinit();
        self.chroma.deinit();
    }

    /// All partial failures free both RIDs. Only a complete successful upload
    /// transfers ownership to boxPlaneRelease; no importer keeps these RIDs.
    pub fn upload(self: PackedPlanes, allocator: std.mem.Allocator, rd: *RenderingDevice, metadata: si.PresentationMetadata) !si.PlaneTextures {
        const is_10bit = self.layout.format.is10Bit();
        const luma = createPlane(rd, si.planeFormat(is_10bit, false), self.layout.width, self.layout.height);
        const chroma = createPlane(rd, si.planeFormat(is_10bit, true), self.layout.chroma_width, self.layout.chroma_height);
        errdefer si.freePlaneRids(rd, luma, chroma);
        if (!luma.isValid() or !chroma.isValid()) return error.TextureCreationFailed;
        if (rd.textureUpdate(luma, 0, self.luma) != .ok or rd.textureUpdate(chroma, 0, self.chroma) != .ok)
            return error.TextureUploadFailed;
        const release = try si.boxPlaneRelease(allocator, rd, luma, chroma);
        return .{
            .luma = luma,
            .chroma = chroma,
            .width = @intCast(self.layout.width),
            .height = @intCast(self.layout.height),
            .metadata = metadata,
            .release = release,
        };
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
