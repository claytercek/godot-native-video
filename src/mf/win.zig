//! Hand-written Windows bindings for MF decoding and D3D11/D3D12 import.
//! Declarations follow Zig's bundled mingw-w64 headers without @cImport.
//!
//! Modules:
//! - com.zig: IUnknown, ComPtr, HRESULT, PROPVARIANT, apartments, and Win32 helpers.
//! - mf.zig: MF lifecycle, readers, media types, samples, buffers, and GUIDs.
//! - dxgi.zig: resource interfaces and formats for shared handles.
//! - d3d11.zig: devices, contexts, textures, fences, and descriptors.
//! - d3d12.zig: interfaces for opening shared resources and waiting on fences.
//! - d3dcompiler.zig: HLSL compilation for the plane-split compute shader.
//!
//! Interfaces use `extern struct { lpVtbl: *const Vtbl }`. Preserve every slot
//! in C-header order, with parent methods first and unused methods represented
//! by *const anyopaque. Derived vtables embed the base as their first field.
//! GUIDs use literal Zig constants because MinGW import libraries omit many
//! GUID symbols.

const std = @import("std");

pub const com = @import("win/com.zig");
pub const mf = @import("win/mf.zig");
pub const dxgi = @import("win/dxgi.zig");
pub const d3d11 = @import("win/d3d11.zig");
pub const d3d12 = @import("win/d3d12.zig");
pub const d3dcompiler = @import("win/d3dcompiler.zig");

test {
    // Force analysis of every submodule so their file-scope comptime layout
    // asserts (struct sizes/offsets) run and every extern symbol is linked.
    std.testing.refAllDecls(com);
    std.testing.refAllDecls(mf);
    std.testing.refAllDecls(dxgi);
    std.testing.refAllDecls(d3d11);
    std.testing.refAllDecls(d3d12);
    std.testing.refAllDecls(d3dcompiler);
}

// ---------------------------------------------------------------------------
// Comptime ABI sanity: a handful of representative slot-position and size
// checks that would fail loudly if a vtable field were dropped/reordered or a
// struct mis-transcribed. (Most size/offset asserts live next to their type.)
// ---------------------------------------------------------------------------
test "vtable slot counts match the C headers" {
    const t = std.testing;
    const ptr = @sizeOf(*const anyopaque);

    // IMFAttributes: 3 IUnknown + 30 own = 33 slots.
    try t.expectEqual(33 * ptr, @sizeOf(mf.IMFAttributes.Vtbl));
    // IMFMediaType embeds all 33 + 5 own = 38.
    try t.expectEqual(38 * ptr, @sizeOf(mf.IMFMediaType.Vtbl));
    // IMFSample: 33 + 14 = 47.
    try t.expectEqual(47 * ptr, @sizeOf(mf.IMFSample.Vtbl));
    // IMFSourceReader: 3 IUnknown + 10 own = 13.
    try t.expectEqual(13 * ptr, @sizeOf(mf.IMFSourceReader.Vtbl));

    // ID3D11Device base: 3 + 40 = 43.
    try t.expectEqual(43 * ptr, @sizeOf(d3d11.ID3D11Device.Vtbl));
    // ID3D11Device3: 43 + 22 = 65.
    try t.expectEqual(65 * ptr, @sizeOf(d3d11.ID3D11Device3.Vtbl));
    // ID3D11Device5: 65 + 4 = 69.
    try t.expectEqual(69 * ptr, @sizeOf(d3d11.ID3D11Device5.Vtbl));
    // ID3D11DeviceContext base: 3 + 4 + 108 = 115.
    try t.expectEqual(115 * ptr, @sizeOf(d3d11.ID3D11DeviceContext.Vtbl));
    // ID3D11DeviceContext4: 115 + 34 = 149.
    try t.expectEqual(149 * ptr, @sizeOf(d3d11.ID3D11DeviceContext4.Vtbl));
    // ID3D12Device: 44 slots.
    try t.expectEqual(44 * ptr, @sizeOf(d3d12.ID3D12Device.Vtbl));
    // IDXGIResource1: 3 IUnknown + 4 IDXGIObject + 1 IDXGIDeviceSubObject +
    // 4 IDXGIResource + 2 own = 14.
    try t.expectEqual(14 * ptr, @sizeOf(dxgi.IDXGIResource1.Vtbl));

    // CreateFence must be the very last (69th) slot of ID3D11Device5.
    try t.expectEqual(68 * ptr, @offsetOf(d3d11.ID3D11Device5.Vtbl, "CreateFence"));
    // Signal must be the second-to-last (148th) slot of ID3D11DeviceContext4.
    try t.expectEqual(147 * ptr, @offsetOf(d3d11.ID3D11DeviceContext4.Vtbl, "Signal"));
    // GetAdapterLuid is the 44th (last) slot of ID3D12Device.
    try t.expectEqual(43 * ptr, @offsetOf(d3d12.ID3D12Device.Vtbl, "GetAdapterLuid"));
    // CreateSharedHandle is the 14th (last) slot of IDXGIResource1.
    try t.expectEqual(13 * ptr, @offsetOf(dxgi.IDXGIResource1.Vtbl, "CreateSharedHandle"));
}

test "MF_VERSION is 0x00020070" {
    try std.testing.expectEqual(@as(u32, 0x00020070), mf.MF_VERSION);
}

// ---------------------------------------------------------------------------
// Runtime smoke test — proves linkage, calling conventions, and the hot-path
// vtable slot positions. Prefers a real hardware D3D11 device, but CI runners
// have no GPU, so it falls back to the WARP software rasterizer (and, since
// WARP doesn't reliably support VIDEO_SUPPORT, to WARP without that flag) so
// the vtable/linkage checks below still run; if every driver fails to come up
// the test skips rather than failing.
//
// Path: CoInitializeEx -> MFStartup -> MFCreateAttributes (+ set/get a UINT32
// attribute) -> D3D11CreateDevice (hardware, falling back to WARP, VIDEO|BGRA)
// -> QI ID3D10Multithread -> SetMultithreadProtected(TRUE) ->
// MFCreateDXGIDeviceManager + ResetDevice -> release everything -> MFShutdown
// -> CoUninitialize.
// ---------------------------------------------------------------------------
test "runtime: MF + D3D11 device manager round-trip" {
    const t = std.testing;

    const hr_co = com.CoInitializeEx(null, com.COINIT_MULTITHREADED);
    try t.expect(com.SUCCEEDED(hr_co) or hr_co == com.S_FALSE);
    defer com.CoUninitialize();

    try t.expect(com.SUCCEEDED(mf.MFStartup(mf.MF_VERSION, mf.MFSTARTUP_LITE)));
    defer _ = mf.MFShutdown();

    // --- Attributes: set then read back a UINT32 (exercises SetUINT32 slot 21
    // and GetUINT32 slot 7, and the MFCreateAttributes export). ---
    var attrs: ?*mf.IMFAttributes = null;
    try t.expect(com.SUCCEEDED(mf.MFCreateAttributes(&attrs, 1)));
    defer com.release(attrs.?);
    try t.expect(com.SUCCEEDED(attrs.?.SetUINT32(&mf.MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS, 1)));
    var got: u32 = 0;
    try t.expect(com.SUCCEEDED(attrs.?.GetUINT32(&mf.MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS, &got)));
    try t.expectEqual(@as(u32, 1), got);

    // --- D3D11 device with the video-decode flags. Hardware first, so this
    // machine (which has a GPU) still exercises the real path; fall back to
    // WARP for GPU-less CI runners, and if WARP rejects VIDEO_SUPPORT too,
    // drop it — this test is proving vtable slots/linkage, not decode. ---
    var device: ?*d3d11.ID3D11Device = null;
    var context: ?*d3d11.ID3D11DeviceContext = null;
    var feature_level: d3d11.D3D_FEATURE_LEVEL = d3d11.D3D_FEATURE_LEVEL_11_0;
    const video_flags = d3d11.D3D11_CREATE_DEVICE_BGRA_SUPPORT | d3d11.D3D11_CREATE_DEVICE_VIDEO_SUPPORT;

    var hr_dev = d3d11.D3D11CreateDevice(
        null,
        d3d11.D3D_DRIVER_TYPE_HARDWARE,
        null,
        video_flags,
        null,
        0,
        d3d11.D3D11_SDK_VERSION,
        &device,
        &feature_level,
        &context,
    );
    if (com.FAILED(hr_dev)) {
        hr_dev = d3d11.D3D11CreateDevice(
            null,
            d3d11.D3D_DRIVER_TYPE_WARP,
            null,
            video_flags,
            null,
            0,
            d3d11.D3D11_SDK_VERSION,
            &device,
            &feature_level,
            &context,
        );
    }
    if (com.FAILED(hr_dev)) {
        hr_dev = d3d11.D3D11CreateDevice(
            null,
            d3d11.D3D_DRIVER_TYPE_WARP,
            null,
            d3d11.D3D11_CREATE_DEVICE_BGRA_SUPPORT,
            null,
            0,
            d3d11.D3D11_SDK_VERSION,
            &device,
            &feature_level,
            &context,
        );
    }
    if (com.FAILED(hr_dev)) return error.SkipZigTest; // no D3D11 device available (hardware or WARP)
    defer com.release(device.?);
    defer com.release(context.?);

    // --- QI ID3D10Multithread and enable protection (slot 5 = SetMultithreadProtected). ---
    const mt = com.queryInterface(d3d11.ID3D10Multithread, device.?) orelse return error.QueryMultithread;
    defer com.release(mt);
    _ = mt.SetMultithreadProtected(com.TRUE);

    // --- DXGI device manager + ResetDevice (slot 8). ---
    var reset_token: u32 = 0;
    var manager: ?*mf.IMFDXGIDeviceManager = null;
    try t.expect(com.SUCCEEDED(mf.MFCreateDXGIDeviceManager(&reset_token, &manager)));
    defer com.release(manager.?);
    const dev_unk: *com.IUnknown = @ptrCast(device.?);
    try t.expect(com.SUCCEEDED(manager.?.ResetDevice(dev_unk, reset_token)));
}
