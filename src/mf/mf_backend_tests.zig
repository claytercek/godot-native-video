const std = @import("std");
const core = @import("core").backend;
const win = @import("win.zig");
const com = win.com;
const d3d11 = win.d3d11;

fn hashFrameTexture(tex: *d3d11.ID3D11Texture2D) ?u64 {
    var dev: ?*d3d11.ID3D11Device = null;
    tex.GetDevice(&dev);
    const device = dev orelse return null;
    defer com.release(device);
    var ctx: ?*d3d11.ID3D11DeviceContext = null;
    device.GetImmediateContext(&ctx);
    const context = ctx orelse return null;
    defer com.release(context);

    var desc: d3d11.D3D11_TEXTURE2D_DESC = undefined;
    tex.GetDesc(&desc);
    var sdesc = desc;
    sdesc.ArraySize = 1;
    sdesc.MipLevels = 1;
    sdesc.Usage = d3d11.D3D11_USAGE_STAGING;
    sdesc.BindFlags = 0;
    sdesc.CPUAccessFlags = d3d11.D3D11_CPU_ACCESS_READ;
    sdesc.MiscFlags = 0;
    var stage: ?*d3d11.ID3D11Texture2D = null;
    if (com.FAILED(device.CreateTexture2D(&sdesc, null, &stage)) or stage == null) return null;
    defer com.release(stage.?);

    context.CopySubresourceRegion(stage.?.asResource(), 0, 0, 0, 0, tex.asResource(), 0, null);
    var mapped = std.mem.zeroes(d3d11.D3D11_MAPPED_SUBRESOURCE);
    if (com.FAILED(context.Map(stage.?.asResource(), 0, d3d11.D3D11_MAP_READ, 0, &mapped))) return null;
    defer context.Unmap(stage.?.asResource(), 0);

    const base: [*]const u8 = @ptrCast(mapped.pData.?);
    const row_bytes: usize = if (desc.Format == win.dxgi.DXGI_FORMAT_P010) @as(usize, desc.Width) * 2 else desc.Width;
    var hasher = std.hash.Wyhash.init(0);
    for (0..desc.Height) |y| hasher.update(base[y * mapped.RowPitch ..][0..row_bytes]);
    return hasher.final();
}

fn requireFixture(path: []const u8) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.Dir.cwd().access(io, path, .{}) catch return error.SkipZigTest;
}

pub fn queuedVideoFrames(createBackend: anytype) !void {
    const t = std.testing;
    try requireFixture("project/bframes.mp4");
    const backend = createBackend(t.allocator) catch return error.SkipZigTest;
    defer backend.deinit();
    if (!backend.open("project/bframes.mp4")) return error.SkipZigTest;

    var frames: std.ArrayList(core.VideoFrame) = .empty;
    defer {
        for (frames.items) |frame| frame.release();
        frames.deinit(t.allocator);
    }
    const first = backend.nextVideoFrame() orelse return error.SkipZigTest;
    try frames.append(t.allocator, first);
    try t.expectEqual(@as(u32, 0), first.plane_slice);
    const texture: *d3d11.ID3D11Texture2D = @ptrCast(@alignCast(first.native_handle.?));
    const before = hashFrameTexture(texture) orelse return error.SkipZigTest;
    for (0..14) |_| {
        const frame = backend.nextVideoFrame() orelse break;
        try frames.append(t.allocator, frame);
    }
    if (frames.items.len < 3) return error.SkipZigTest;
    try t.expectEqual(before, hashFrameTexture(texture) orelse return error.SkipZigTest);
}

pub fn displayAperture(createBackend: anytype) !void {
    const t = std.testing;
    const path = "tests/fixtures/stress/nonmod16_854x480.mp4";
    try requireFixture(path);
    const backend = createBackend(t.allocator) catch return error.SkipZigTest;
    defer backend.deinit();
    if (!backend.open(path)) return error.SkipZigTest;
    const frame = backend.nextVideoFrame() orelse return error.SkipZigTest;
    defer frame.release();

    const texture: *d3d11.ID3D11Texture2D = @ptrCast(@alignCast(frame.native_handle.?));
    var desc: d3d11.D3D11_TEXTURE2D_DESC = undefined;
    texture.GetDesc(&desc);
    try t.expectEqual(@as(com.UINT, 864), desc.Width);
    try t.expectEqual(@as(i32, 854), frame.width);
    try t.expectEqual(@as(u32, 854), frame.crop.width);
    try t.expectEqual(@as(u32, 0), frame.crop.x);
}
