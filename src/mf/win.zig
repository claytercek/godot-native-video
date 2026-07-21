//! win.zig — root of the hand-written Windows bindings for the Media Foundation
//! decoder backend. This is the foundation the eventual `mf_backend.zig` and the
//! D3D11/D3D12 surface importers build on; for now it is a pure bindings layer.
//!
//! Repo rule (hard): NO `@cImport` anywhere. Every OS type, GUID, function, and
//! COM interface below is transcribed by hand from the mingw-w64 headers Zig
//! bundles. The AVFoundation backend follows the same discipline on macOS
//! (src/avf/avf_backend.zig); this mirrors it for Windows.
//!
//! How the bindings are organised:
//!  - com.zig         — IUnknown, ComPtr, HRESULT helpers, PROPVARIANT, COM
//!                      apartment lifecycle, and the misc Win32 (handles,
//!                      events, code-page/locale conversion) used by the port.
//!  - mf.zig          — Media Foundation: MFStartup/Shutdown, the source
//!                      reader/media-type/sample/buffer interfaces, the DXGI
//!                      device manager, and every MF GUID constant.
//!  - dxgi.zig        — factory/adapter/resource interfaces + the DXGI_FORMAT
//!                      subset, for LUID matching and shared-handle export.
//!  - d3d11.zig       — the D3D11 device/context/texture/fence surface and the
//!                      descriptor structs the interop + compute path fills.
//!  - d3d12.zig       — the three D3D12 interfaces the zero-copy importer opens
//!                      shared handles through.
//!  - d3dcompiler.zig — runtime HLSL compile of the plane-split compute shader.
//!
//! Design conventions used throughout (see com.zig for the rationale):
//!  - Interfaces are `extern struct { lpVtbl: *const Vtbl }`. Each Vtbl lists
//!    EVERY slot in the exact C-header order (parent methods first); methods the
//!    port never calls are opaque `*const anyopaque` placeholders so the typed
//!    methods keep their real slot index. Deeper interfaces embed the shallower
//!    vtable as their first field so the slot arithmetic can't drift.
//!  - GUIDs are Zig consts with literal values — the mingw import libs omit many
//!    of these symbols, so nothing links against them.

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

    // CreateFence must be the very last (69th) slot of ID3D11Device5.
    try t.expectEqual(68 * ptr, @offsetOf(d3d11.ID3D11Device5.Vtbl, "CreateFence"));
    // Signal must be the second-to-last (148th) slot of ID3D11DeviceContext4.
    try t.expectEqual(147 * ptr, @offsetOf(d3d11.ID3D11DeviceContext4.Vtbl, "Signal"));
    // GetAdapterLuid is the 44th (last) slot of ID3D12Device.
    try t.expectEqual(43 * ptr, @offsetOf(d3d12.ID3D12Device.Vtbl, "GetAdapterLuid"));
}

test "MF_VERSION is 0x00020070" {
    try std.testing.expectEqual(@as(u32, 0x00020070), mf.MF_VERSION);
}

// ---------------------------------------------------------------------------
// Runtime smoke test — proves linkage, calling conventions, and the hot-path
// vtable slot positions on real hardware. Requires a D3D11-capable GPU; this
// repo's CI is macOS-only, so gating on hardware here is fine.
//
// Path: CoInitializeEx -> MFStartup -> MFCreateAttributes (+ set/get a UINT32
// attribute) -> D3D11CreateDevice (hardware, VIDEO|BGRA) -> QI ID3D10Multithread
// -> SetMultithreadProtected(TRUE) -> MFCreateDXGIDeviceManager + ResetDevice ->
// release everything -> MFShutdown -> CoUninitialize.
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
    defer _ = attrs.?.Release();
    try t.expect(com.SUCCEEDED(attrs.?.SetUINT32(&mf.MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS, 1)));
    var got: u32 = 0;
    try t.expect(com.SUCCEEDED(attrs.?.GetUINT32(&mf.MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS, &got)));
    try t.expectEqual(@as(u32, 1), got);

    // --- D3D11 hardware device with the video-decode flags. ---
    var device: ?*d3d11.ID3D11Device = null;
    var context: ?*d3d11.ID3D11DeviceContext = null;
    var feature_level: d3d11.D3D_FEATURE_LEVEL = d3d11.D3D_FEATURE_LEVEL_11_0;
    const hr_dev = d3d11.D3D11CreateDevice(
        null,
        d3d11.D3D_DRIVER_TYPE_HARDWARE,
        null,
        d3d11.D3D11_CREATE_DEVICE_BGRA_SUPPORT | d3d11.D3D11_CREATE_DEVICE_VIDEO_SUPPORT,
        null,
        0,
        d3d11.D3D11_SDK_VERSION,
        &device,
        &feature_level,
        &context,
    );
    if (com.FAILED(hr_dev)) return error.SkipZigTest; // no D3D11 GPU available
    defer _ = device.?.Release();
    defer _ = context.?.Release();

    // --- QI ID3D10Multithread and enable protection (slot 5 = SetMultithreadProtected). ---
    const mt = com.queryInterface(d3d11.ID3D10Multithread, device.?) orelse return error.QueryMultithread;
    defer _ = mt.Release();
    _ = mt.SetMultithreadProtected(com.TRUE);

    // --- DXGI device manager + ResetDevice (slot 8). ---
    var reset_token: u32 = 0;
    var manager: ?*mf.IMFDXGIDeviceManager = null;
    try t.expect(com.SUCCEEDED(mf.MFCreateDXGIDeviceManager(&reset_token, &manager)));
    defer _ = manager.?.Release();
    const dev_unk: *com.IUnknown = @ptrCast(device.?);
    try t.expect(com.SUCCEEDED(manager.?.ResetDevice(dev_unk, reset_token)));
}
