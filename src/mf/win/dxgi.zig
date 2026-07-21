//! dxgi.zig — DXGI factory/adapter/resource interfaces and the format subset
//! the importers need. Transcribed from dxgi.h, dxgi1_2.h, dxgiformat.h.
//!
//! Used for LUID-based adapter matching (pick the DXGI adapter whose LUID
//! matches the D3D12 device Godot handed us) and for exporting shared NT
//! handles from D3D11 textures/fences to D3D12.

const std = @import("std");
const com = @import("com.zig");

const GUID = com.GUID;
const HRESULT = com.HRESULT;
const ULONG = com.ULONG;
const UINT = com.UINT;
const DWORD = com.DWORD;
const HANDLE = com.HANDLE;
const LPCWSTR = com.LPCWSTR;

// ---------------------------------------------------------------------------
// DXGI_FORMAT — only the values the NV12/P010 plane math touches (dxgiformat.h).
// ---------------------------------------------------------------------------
pub const DXGI_FORMAT = i32;
pub const DXGI_FORMAT_UNKNOWN: DXGI_FORMAT = 0;
pub const DXGI_FORMAT_R16G16_UNORM: DXGI_FORMAT = 0x23;
pub const DXGI_FORMAT_R8G8_UNORM: DXGI_FORMAT = 0x31;
pub const DXGI_FORMAT_R16_UNORM: DXGI_FORMAT = 0x38;
pub const DXGI_FORMAT_R8_UNORM: DXGI_FORMAT = 0x3d;
pub const DXGI_FORMAT_NV12: DXGI_FORMAT = 0x67;
pub const DXGI_FORMAT_P010: DXGI_FORMAT = 0x68;

// CreateSharedHandle access flags (dxgi1_2.h).
pub const DXGI_SHARED_RESOURCE_READ: DWORD = 0x80000000;
pub const DXGI_SHARED_RESOURCE_WRITE: DWORD = 0x1;

// ---------------------------------------------------------------------------
// LUID — locally uniquely identifies an adapter. Compared whole-struct against
// the D3D12 device's LUID; layout is { DWORD LowPart; LONG HighPart; }.
// ---------------------------------------------------------------------------
pub const LUID = extern struct {
    LowPart: u32,
    HighPart: i32,
};

pub const DXGI_ADAPTER_DESC1 = extern struct {
    Description: [128]u16,
    VendorId: UINT,
    DeviceId: UINT,
    SubSysId: UINT,
    Revision: UINT,
    DedicatedVideoMemory: usize,
    DedicatedSystemMemory: usize,
    SharedSystemMemory: usize,
    AdapterLuid: LUID,
    Flags: UINT,
};

comptime {
    std.debug.assert(@sizeOf(DXGI_ADAPTER_DESC1) == 312);
    std.debug.assert(@offsetOf(DXGI_ADAPTER_DESC1, "AdapterLuid") == 296);
}

// ---------------------------------------------------------------------------
// IDXGIFactory1 : IDXGIFactory : IDXGIObject : IUnknown. Only EnumAdapters1.
// ---------------------------------------------------------------------------
pub const IDXGIFactory1 = extern struct {
    lpVtbl: *const Vtbl,
    const Self = @This();
    pub const IID = GUID.parse("{770AAE78-F26F-4DBA-A829-253C83D1B387}");

    pub const Vtbl = extern struct {
        QueryInterface: *const fn (*Self, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*Self) callconv(.winapi) ULONG,
        Release: *const fn (*Self) callconv(.winapi) ULONG,
        // IDXGIObject
        SetPrivateData: *const anyopaque,
        SetPrivateDataInterface: *const anyopaque,
        GetPrivateData: *const anyopaque,
        GetParent: *const anyopaque,
        // IDXGIFactory
        EnumAdapters: *const anyopaque,
        MakeWindowAssociation: *const anyopaque,
        GetWindowAssociation: *const anyopaque,
        CreateSwapChain: *const anyopaque,
        CreateSoftwareAdapter: *const anyopaque,
        // IDXGIFactory1
        EnumAdapters1: *const fn (*Self, UINT, *?*IDXGIAdapter1) callconv(.winapi) HRESULT,
        IsCurrent: *const anyopaque,
    };

    pub inline fn Release(self: *Self) ULONG {
        return self.lpVtbl.Release(self);
    }
    pub inline fn EnumAdapters1(self: *Self, index: UINT, out: *?*IDXGIAdapter1) HRESULT {
        return self.lpVtbl.EnumAdapters1(self, index, out);
    }
};

// ---------------------------------------------------------------------------
// IDXGIAdapter1 : IDXGIAdapter : IDXGIObject : IUnknown. Only GetDesc1.
// ---------------------------------------------------------------------------
pub const IDXGIAdapter1 = extern struct {
    lpVtbl: *const Vtbl,
    const Self = @This();
    pub const IID = GUID.parse("{29038F61-3839-4626-91FD-086879011A05}");

    pub const Vtbl = extern struct {
        QueryInterface: *const fn (*Self, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*Self) callconv(.winapi) ULONG,
        Release: *const fn (*Self) callconv(.winapi) ULONG,
        // IDXGIObject
        SetPrivateData: *const anyopaque,
        SetPrivateDataInterface: *const anyopaque,
        GetPrivateData: *const anyopaque,
        GetParent: *const anyopaque,
        // IDXGIAdapter
        EnumOutputs: *const anyopaque,
        GetDesc: *const anyopaque,
        CheckInterfaceSupport: *const anyopaque,
        // IDXGIAdapter1
        GetDesc1: *const fn (*Self, *DXGI_ADAPTER_DESC1) callconv(.winapi) HRESULT,
    };

    pub inline fn Release(self: *Self) ULONG {
        return self.lpVtbl.Release(self);
    }
    pub inline fn GetDesc1(self: *Self, desc: *DXGI_ADAPTER_DESC1) HRESULT {
        return self.lpVtbl.GetDesc1(self, desc);
    }
};

// ---------------------------------------------------------------------------
// IDXGIResource1 : IDXGIResource : IDXGIDeviceSubObject : IDXGIObject :
// IUnknown. Only CreateSharedHandle (obtained by QI from an ID3D11Texture2D).
// ---------------------------------------------------------------------------
pub const IDXGIResource1 = extern struct {
    lpVtbl: *const Vtbl,
    const Self = @This();
    pub const IID = GUID.parse("{30961379-4609-4A41-998E-54FE567EE0C1}");

    pub const Vtbl = extern struct {
        QueryInterface: *const fn (*Self, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*Self) callconv(.winapi) ULONG,
        Release: *const fn (*Self) callconv(.winapi) ULONG,
        // IDXGIObject
        SetPrivateData: *const anyopaque,
        SetPrivateDataInterface: *const anyopaque,
        GetPrivateData: *const anyopaque,
        GetParent: *const anyopaque,
        // IDXGIDeviceSubObject
        GetDevice: *const anyopaque,
        // IDXGIResource
        GetSharedHandle: *const anyopaque,
        GetUsage: *const anyopaque,
        SetEvictionPriority: *const anyopaque,
        GetEvictionPriority: *const anyopaque,
        // IDXGIResource1
        CreateSubresourceSurface: *const anyopaque,
        CreateSharedHandle: *const fn (*Self, ?*anyopaque, DWORD, LPCWSTR, *HANDLE) callconv(.winapi) HRESULT,
    };

    pub inline fn Release(self: *Self) ULONG {
        return self.lpVtbl.Release(self);
    }
    pub inline fn CreateSharedHandle(self: *Self, attrs: ?*anyopaque, access: DWORD, name: LPCWSTR, handle: *HANDLE) HRESULT {
        return self.lpVtbl.CreateSharedHandle(self, attrs, access, name, handle);
    }
};

pub extern "dxgi" fn CreateDXGIFactory1(riid: *const GUID, ppFactory: *?*anyopaque) callconv(.winapi) HRESULT;
