//! mf.zig — Media Foundation functions, interfaces, and GUID constants.
//!
//! Hand-transcribed from mfapi.h, mfobjects.h, mfidl.h, mfreadwrite.h. Vtable
//! slot order is copied verbatim from the mingw-w64 `*Vtbl` C structs; parent
//! interface methods lead, then the interface's own methods, in declared order.
//! Methods this port never calls are kept as opaque `*const anyopaque` slots so
//! the indices of the ones we do call stay exact — do not reorder or remove
//! slots when adding a typed method.
//!
//! All GUIDs are Zig consts with literal DEFINE_GUID values (the mingw import
//! libs omit many of these symbols, so we never link against them).

const std = @import("std");
const com = @import("com.zig");

const GUID = com.GUID;
const HRESULT = com.HRESULT;
const ULONG = com.ULONG;
const UINT = com.UINT;
const DWORD = com.DWORD;
const BOOL = com.BOOL;
const WORD = com.WORD;
const IUnknown = com.IUnknown;
const PROPVARIANT = com.PROPVARIANT;

pub const UINT32 = u32;
pub const UINT64 = u64;
pub const LONGLONG = i64;

// ===========================================================================
// GUID constants
// ===========================================================================

// --- Media type attribute keys (mfapi.h) ---
pub const MF_MT_MAJOR_TYPE = GUID.parse("{48EBA18E-F8C9-4687-BF11-0A74C9F96A8F}");
pub const MF_MT_SUBTYPE = GUID.parse("{F7E34C9A-42E8-4714-B74B-CB29D72C35E5}");
pub const MF_MT_MPEG2_PROFILE = GUID.parse("{AD76A80B-2D5C-4E0B-B375-64E520137036}");
pub const MF_MT_YUV_MATRIX = GUID.parse("{3E23D450-2C75-4D25-A00E-B91670D12327}");
pub const MF_MT_VIDEO_PRIMARIES = GUID.parse("{DBFBE4D7-0740-4EE0-8192-850AB0E21935}");
pub const MF_MT_TRANSFER_FUNCTION = GUID.parse("{5FB0FCE9-BE5C-4935-A811-EC838F8EED93}");
pub const MF_MT_VIDEO_NOMINAL_RANGE = GUID.parse("{C21B8EE5-B956-4071-8DAF-325EDF5CAB11}");
pub const MF_MT_FRAME_SIZE = GUID.parse("{1652C33D-D6B2-4012-B834-72030849A37D}");
// Display/clean-aperture attributes -- MFVideoArea-typed blobs (see
// getVideoArea below). MINIMUM_DISPLAY_APERTURE is what decoders actually
// populate for cropped H.264/HEVC content; GEOMETRIC_APERTURE is the older,
// less commonly set sibling, tried as a fallback.
pub const MF_MT_MINIMUM_DISPLAY_APERTURE = GUID.parse("{D7388766-18FE-48C6-A177-EE894867C8C4}");
pub const MF_MT_GEOMETRIC_APERTURE = GUID.parse("{66758743-7E5F-400D-980A-931332D3A9EE}");
pub const MF_MT_AUDIO_NUM_CHANNELS = GUID.parse("{37E48BF5-645E-4C5B-89DE-ADA9E29B696A}");
pub const MF_MT_AUDIO_SAMPLES_PER_SECOND = GUID.parse("{5FAEEAE7-0290-4C31-9E8A-C534F68D9DBA}");

// --- Major-type and subtype value GUIDs (resolved from FOURCC/WAVE_FORMAT) ---
pub const MFMediaType_Video = GUID.parse("{73646976-0000-0010-8000-00AA00389B71}");
pub const MFMediaType_Audio = GUID.parse("{73647561-0000-0010-8000-00AA00389B71}");
pub const MFVideoFormat_NV12 = GUID.parse("{3231564E-0000-0010-8000-00AA00389B71}"); // FCC('NV12')
pub const MFVideoFormat_P010 = GUID.parse("{30313050-0000-0010-8000-00AA00389B71}"); // FCC('P010')
pub const MFAudioFormat_Float = GUID.parse("{00000003-0000-0010-8000-00AA00389B71}"); // WAVE_FORMAT_IEEE_FLOAT

// --- Source-reader configuration attributes (mfreadwrite.h) ---
pub const MF_SOURCE_READER_D3D_MANAGER = GUID.parse("{EC822DA2-E1E9-4B29-A0D8-563C719F5269}");
pub const MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS = GUID.parse("{A634A91C-822B-41B9-A494-4DE4643612B0}");
pub const MF_SOURCE_READER_ENABLE_ADVANCED_VIDEO_PROCESSING = GUID.parse("{0F81DA2C-B537-4672-A8B2-A681B17307A3}");

// --- Stream-descriptor / presentation attributes (mfidl.h) ---
pub const MF_SD_LANGUAGE = GUID.parse("{00AF2180-BDC2-423C-ABCA-F503593BC121}");
pub const MF_SD_STREAM_NAME = GUID.parse("{4F1B099D-D314-41E5-A781-7FEFAA4C501F}");
pub const MF_PD_DURATION = GUID.parse("{6C990D33-BB8E-477A-8598-0D5D96FCD88A}");

// All-zero GUID. MinGW's import lib omits GUID_NULL, so we define it here and
// pass it as the "time format" for SetCurrentPosition (100ns-unit default).
pub const GUID_NULL = GUID.parse("{00000000-0000-0000-0000-000000000000}");

// ===========================================================================
// Colorimetry attribute value enums (mfobjects.h). These are plain UINT32
// attribute values, not GUIDs.
// ===========================================================================
pub const MFVideoTransferMatrix_BT709: UINT32 = 1;
pub const MFVideoTransferMatrix_BT601: UINT32 = 2;
pub const MFVideoTransferMatrix_BT2020_10: UINT32 = 4;
pub const MFVideoTransferMatrix_BT2020_12: UINT32 = 5;

pub const MFVideoPrimaries_BT709: UINT32 = 2;
pub const MFVideoPrimaries_BT470_2_SysBG: UINT32 = 4;
pub const MFVideoPrimaries_SMPTE170M: UINT32 = 5;
pub const MFVideoPrimaries_EBU3213: UINT32 = 7;
pub const MFVideoPrimaries_SMPTE_C: UINT32 = 8;
pub const MFVideoPrimaries_BT2020: UINT32 = 9;
pub const MFVideoPrimaries_DCI_P3: UINT32 = 11;

pub const MFVideoTransFunc_709: UINT32 = 5;
pub const MFVideoTransFunc_sRGB: UINT32 = 7;
pub const MFVideoTransFunc_2084: UINT32 = 15;
pub const MFVideoTransFunc_HLG: UINT32 = 16;

pub const MFNominalRange_0_255: UINT32 = 1;
pub const MFNominalRange_16_235: UINT32 = 2;

// codecapi.h — compared against MF_MT_MPEG2_PROFILE for HEVC Main 10.
pub const eAVEncH265VProfile_Main_420_10: UINT32 = 2;

// ===========================================================================
// Startup / stream-index / flag constants
// ===========================================================================
pub const MF_SDK_VERSION: ULONG = 0x2;
pub const MF_API_VERSION: ULONG = 0x0070;
pub const MF_VERSION: ULONG = (MF_SDK_VERSION << 16) | MF_API_VERSION; // 0x00020070
pub const MFSTARTUP_NOSOCKET: DWORD = 0x1;
pub const MFSTARTUP_LITE: DWORD = MFSTARTUP_NOSOCKET;
pub const MFSTARTUP_FULL: DWORD = 0;

pub const MF_SOURCE_READER_ALL_STREAMS: DWORD = 0xFFFFFFFE;
pub const MF_SOURCE_READER_FIRST_AUDIO_STREAM: DWORD = 0xFFFFFFFD;
pub const MF_SOURCE_READER_FIRST_VIDEO_STREAM: DWORD = 0xFFFFFFFC;
pub const MF_SOURCE_READER_MEDIASOURCE: DWORD = 0xFFFFFFFF;

pub const MF_SOURCE_READERF_ENDOFSTREAM: DWORD = 0x2;

// ===========================================================================
// IMFAttributes — the attribute get/set workhorse. IMFMediaType and IMFSample
// inherit its full 30-method surface. Typed here: the common getters/setters
// the port uses; the rest are opaque slots.
// ===========================================================================
pub const MF_ATTRIBUTE_TYPE = i32;

pub const IMFAttributes = extern struct {
    lpVtbl: *const Vtbl,
    const Self = @This();
    pub const IID = GUID.parse("{2CD2D921-C447-44A7-A13C-4ADABFC247E3}");

    pub const Vtbl = extern struct {
        // IUnknown
        QueryInterface: *const fn (*Self, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*Self) callconv(.winapi) ULONG,
        Release: *const fn (*Self) callconv(.winapi) ULONG,
        // IMFAttributes
        GetItem: *const fn (*Self, *const GUID, ?*PROPVARIANT) callconv(.winapi) HRESULT,
        GetItemType: *const anyopaque,
        CompareItem: *const anyopaque,
        Compare: *const anyopaque,
        GetUINT32: *const fn (*Self, *const GUID, *UINT32) callconv(.winapi) HRESULT,
        GetUINT64: *const fn (*Self, *const GUID, *UINT64) callconv(.winapi) HRESULT,
        GetDouble: *const anyopaque,
        GetGUID: *const fn (*Self, *const GUID, *GUID) callconv(.winapi) HRESULT,
        GetStringLength: *const fn (*Self, *const GUID, *UINT32) callconv(.winapi) HRESULT,
        GetString: *const fn (*Self, *const GUID, [*]u16, UINT32, ?*UINT32) callconv(.winapi) HRESULT,
        GetAllocatedString: *const fn (*Self, *const GUID, *?[*:0]u16, *UINT32) callconv(.winapi) HRESULT,
        GetBlobSize: *const anyopaque,
        GetBlob: *const fn (*Self, *const GUID, [*]u8, UINT32, ?*UINT32) callconv(.winapi) HRESULT,
        GetAllocatedBlob: *const anyopaque,
        GetUnknown: *const fn (*Self, *const GUID, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        SetItem: *const anyopaque,
        DeleteItem: *const anyopaque,
        DeleteAllItems: *const anyopaque,
        SetUINT32: *const fn (*Self, *const GUID, UINT32) callconv(.winapi) HRESULT,
        SetUINT64: *const fn (*Self, *const GUID, UINT64) callconv(.winapi) HRESULT,
        SetDouble: *const anyopaque,
        SetGUID: *const fn (*Self, *const GUID, *const GUID) callconv(.winapi) HRESULT,
        SetString: *const fn (*Self, *const GUID, [*:0]const u16) callconv(.winapi) HRESULT,
        SetBlob: *const anyopaque,
        SetUnknown: *const fn (*Self, *const GUID, ?*IUnknown) callconv(.winapi) HRESULT,
        LockStore: *const anyopaque,
        UnlockStore: *const anyopaque,
        GetCount: *const anyopaque,
        GetItemByIndex: *const anyopaque,
        CopyAllItems: *const anyopaque,
    };

    pub inline fn GetItem(self: *Self, key: *const GUID, value: ?*PROPVARIANT) HRESULT {
        return self.lpVtbl.GetItem(self, key, value);
    }
    pub inline fn GetUINT32(self: *Self, key: *const GUID, value: *UINT32) HRESULT {
        return self.lpVtbl.GetUINT32(self, key, value);
    }
    pub inline fn GetUINT64(self: *Self, key: *const GUID, value: *UINT64) HRESULT {
        return self.lpVtbl.GetUINT64(self, key, value);
    }
    pub inline fn GetGUID(self: *Self, key: *const GUID, value: *GUID) HRESULT {
        return self.lpVtbl.GetGUID(self, key, value);
    }
    pub inline fn GetAllocatedString(self: *Self, key: *const GUID, value: *?[*:0]u16, len: *UINT32) HRESULT {
        return self.lpVtbl.GetAllocatedString(self, key, value, len);
    }
    pub inline fn SetUINT32(self: *Self, key: *const GUID, value: UINT32) HRESULT {
        return self.lpVtbl.SetUINT32(self, key, value);
    }
    pub inline fn SetGUID(self: *Self, key: *const GUID, value: *const GUID) HRESULT {
        return self.lpVtbl.SetGUID(self, key, value);
    }
    pub inline fn SetUnknown(self: *Self, key: *const GUID, unk: ?*IUnknown) HRESULT {
        return self.lpVtbl.SetUnknown(self, key, unk);
    }

    /// MF_MT_FRAME_SIZE packs width in the high 32 bits and height in the low
    /// 32 bits of a UINT64 (the MFGetAttributeSize inline helper). Implemented
    /// in Zig to avoid depending on the header-inline / propsys export.
    pub inline fn getFrameSize(self: *Self, width: *UINT32, height: *UINT32) HRESULT {
        var packed_val: UINT64 = 0;
        const hr = self.GetUINT64(&MF_MT_FRAME_SIZE, &packed_val);
        if (com.SUCCEEDED(hr)) {
            width.* = @truncate(packed_val >> 32);
            height.* = @truncate(packed_val & 0xFFFFFFFF);
        }
        return hr;
    }

    /// Read `key` as an MFVideoArea blob (MF_MT_MINIMUM_DISPLAY_APERTURE /
    /// MF_MT_GEOMETRIC_APERTURE): 16 bytes, laid out as two MFOffsets
    /// (`{ WORD fract; SHORT value; }`, 4 bytes each -- OffsetX then OffsetY)
    /// followed by a SIZE (`{ LONG cx; LONG cy; }`). Only the whole-pixel
    /// `value` half of each MFOffset is read; MF decoders report whole-pixel
    /// apertures, so the sub-pixel `fract` half is unused. Returns null if the
    /// attribute is absent or a different size than expected (parsed by hand,
    /// not @bitCast, to sidestep any struct-layout assumption).
    pub inline fn getVideoArea(self: *Self, key: *const GUID) ?MFVideoArea {
        var buf: [16]u8 = undefined;
        var got: UINT32 = 0;
        const hr = self.lpVtbl.GetBlob(self, key, &buf, @intCast(buf.len), &got);
        if (com.FAILED(hr) or got < buf.len) return null;
        return .{
            .offset_x = std.mem.readInt(i16, buf[2..4], .little),
            .offset_y = std.mem.readInt(i16, buf[6..8], .little),
            .width = std.mem.readInt(i32, buf[8..12], .little),
            .height = std.mem.readInt(i32, buf[12..16], .little),
        };
    }
};

/// Decoded MF_MT_MINIMUM_DISPLAY_APERTURE / MF_MT_GEOMETRIC_APERTURE payload:
/// the display rect's whole-pixel offset and extent, in luma pixels. See
/// IMFAttributes.getVideoArea for the wire layout this is parsed from.
pub const MFVideoArea = struct {
    offset_x: i16,
    offset_y: i16,
    width: i32,
    height: i32,
};

// ===========================================================================
// IMFMediaType : IMFAttributes — adds 5 methods after the 30 attribute slots.
// ===========================================================================
pub const IMFMediaType = extern struct {
    lpVtbl: *const Vtbl,
    const Self = @This();
    pub const IID = GUID.parse("{44AE0FA8-EA31-4109-8D2E-4CAE4997C555}");

    pub const Vtbl = extern struct {
        attributes: IMFAttributes.Vtbl,
        GetMajorType: *const anyopaque,
        IsCompressedFormat: *const anyopaque,
        IsEqual: *const anyopaque,
        GetRepresentation: *const anyopaque,
        FreeRepresentation: *const anyopaque,
    };

    /// Reinterpret as the base IMFAttributes (identical prefix layout) to reach
    /// the attribute getters/setters.
    pub inline fn asAttributes(self: *Self) *IMFAttributes {
        return @ptrCast(self);
    }
};

// ===========================================================================
// IMFSample : IMFAttributes — 14 own methods. Typed: GetBufferByIndex,
// ConvertToContiguousBuffer, GetSampleTime.
// ===========================================================================
pub const IMFSample = extern struct {
    lpVtbl: *const Vtbl,
    const Self = @This();
    pub const IID = GUID.parse("{C40A00F2-B93A-4D80-AE8C-5A1C634F58E4}");

    pub const Vtbl = extern struct {
        attributes: IMFAttributes.Vtbl,
        GetSampleFlags: *const anyopaque,
        SetSampleFlags: *const anyopaque,
        GetSampleTime: *const fn (*Self, *LONGLONG) callconv(.winapi) HRESULT,
        SetSampleTime: *const anyopaque,
        GetSampleDuration: *const anyopaque,
        SetSampleDuration: *const anyopaque,
        GetBufferCount: *const anyopaque,
        GetBufferByIndex: *const fn (*Self, DWORD, *?*IMFMediaBuffer) callconv(.winapi) HRESULT,
        ConvertToContiguousBuffer: *const fn (*Self, *?*IMFMediaBuffer) callconv(.winapi) HRESULT,
        AddBuffer: *const anyopaque,
        RemoveBufferByIndex: *const anyopaque,
        RemoveAllBuffers: *const anyopaque,
        GetTotalLength: *const anyopaque,
        CopyToBuffer: *const anyopaque,
    };

    pub inline fn GetSampleTime(self: *Self, time: *LONGLONG) HRESULT {
        return self.lpVtbl.GetSampleTime(self, time);
    }
    pub inline fn GetBufferByIndex(self: *Self, index: DWORD, out: *?*IMFMediaBuffer) HRESULT {
        return self.lpVtbl.GetBufferByIndex(self, index, out);
    }
    pub inline fn ConvertToContiguousBuffer(self: *Self, out: *?*IMFMediaBuffer) HRESULT {
        return self.lpVtbl.ConvertToContiguousBuffer(self, out);
    }
};

// ===========================================================================
// IMFMediaBuffer : IUnknown — Lock/Unlock/GetCurrentLength.
// ===========================================================================
pub const IMFMediaBuffer = extern struct {
    lpVtbl: *const Vtbl,
    const Self = @This();
    pub const IID = GUID.parse("{045FA593-8799-42B8-BC8D-8968C6453507}");

    pub const Vtbl = extern struct {
        QueryInterface: *const fn (*Self, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*Self) callconv(.winapi) ULONG,
        Release: *const fn (*Self) callconv(.winapi) ULONG,
        Lock: *const fn (*Self, *?[*]u8, ?*DWORD, ?*DWORD) callconv(.winapi) HRESULT,
        Unlock: *const fn (*Self) callconv(.winapi) HRESULT,
        GetCurrentLength: *const fn (*Self, *DWORD) callconv(.winapi) HRESULT,
        SetCurrentLength: *const anyopaque,
        GetMaxLength: *const anyopaque,
    };

    pub inline fn Lock(self: *Self, data: *?[*]u8, max_len: ?*DWORD, cur_len: ?*DWORD) HRESULT {
        return self.lpVtbl.Lock(self, data, max_len, cur_len);
    }
    pub inline fn Unlock(self: *Self) HRESULT {
        return self.lpVtbl.Unlock(self);
    }
    pub inline fn GetCurrentLength(self: *Self, len: *DWORD) HRESULT {
        return self.lpVtbl.GetCurrentLength(self, len);
    }
};

// ===========================================================================
// IMFDXGIBuffer : IUnknown — GetResource / GetSubresourceIndex.
// ===========================================================================
pub const IMFDXGIBuffer = extern struct {
    lpVtbl: *const Vtbl,
    const Self = @This();
    pub const IID = GUID.parse("{E7174CFA-1C9E-48B1-8866-626226BFC258}");

    pub const Vtbl = extern struct {
        QueryInterface: *const fn (*Self, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*Self) callconv(.winapi) ULONG,
        Release: *const fn (*Self) callconv(.winapi) ULONG,
        GetResource: *const fn (*Self, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        GetSubresourceIndex: *const fn (*Self, *UINT) callconv(.winapi) HRESULT,
        GetUnknown: *const anyopaque,
        SetUnknown: *const anyopaque,
    };

    pub inline fn GetResource(self: *Self, riid: *const GUID, out: *?*anyopaque) HRESULT {
        return self.lpVtbl.GetResource(self, riid, out);
    }
    pub inline fn GetSubresourceIndex(self: *Self, index: *UINT) HRESULT {
        return self.lpVtbl.GetSubresourceIndex(self, index);
    }
};

// ===========================================================================
// IMFSourceReader : IUnknown — the decode driver.
// ===========================================================================
pub const IMFSourceReader = extern struct {
    lpVtbl: *const Vtbl,
    const Self = @This();
    pub const IID = GUID.parse("{70AE66F2-C809-4E4F-8915-BDCB406B7993}");

    pub const Vtbl = extern struct {
        QueryInterface: *const fn (*Self, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*Self) callconv(.winapi) ULONG,
        Release: *const fn (*Self) callconv(.winapi) ULONG,
        GetStreamSelection: *const anyopaque,
        SetStreamSelection: *const fn (*Self, DWORD, BOOL) callconv(.winapi) HRESULT,
        GetNativeMediaType: *const fn (*Self, DWORD, DWORD, *?*IMFMediaType) callconv(.winapi) HRESULT,
        GetCurrentMediaType: *const fn (*Self, DWORD, *?*IMFMediaType) callconv(.winapi) HRESULT,
        SetCurrentMediaType: *const fn (*Self, DWORD, ?*DWORD, *IMFMediaType) callconv(.winapi) HRESULT,
        SetCurrentPosition: *const fn (*Self, *const GUID, *const PROPVARIANT) callconv(.winapi) HRESULT,
        ReadSample: *const fn (*Self, DWORD, DWORD, ?*DWORD, ?*DWORD, ?*LONGLONG, *?*IMFSample) callconv(.winapi) HRESULT,
        Flush: *const anyopaque,
        GetServiceForStream: *const anyopaque,
        GetPresentationAttribute: *const fn (*Self, DWORD, *const GUID, *PROPVARIANT) callconv(.winapi) HRESULT,
    };

    pub inline fn SetStreamSelection(self: *Self, stream: DWORD, selected: BOOL) HRESULT {
        return self.lpVtbl.SetStreamSelection(self, stream, selected);
    }
    pub inline fn GetNativeMediaType(self: *Self, stream: DWORD, type_index: DWORD, out: *?*IMFMediaType) HRESULT {
        return self.lpVtbl.GetNativeMediaType(self, stream, type_index, out);
    }
    pub inline fn GetCurrentMediaType(self: *Self, stream: DWORD, out: *?*IMFMediaType) HRESULT {
        return self.lpVtbl.GetCurrentMediaType(self, stream, out);
    }
    pub inline fn SetCurrentMediaType(self: *Self, stream: DWORD, reserved: ?*DWORD, mt: *IMFMediaType) HRESULT {
        return self.lpVtbl.SetCurrentMediaType(self, stream, reserved, mt);
    }
    pub inline fn SetCurrentPosition(self: *Self, format: *const GUID, pos: *const PROPVARIANT) HRESULT {
        return self.lpVtbl.SetCurrentPosition(self, format, pos);
    }
    pub inline fn ReadSample(
        self: *Self,
        stream: DWORD,
        control_flags: DWORD,
        actual_stream: ?*DWORD,
        stream_flags: ?*DWORD,
        timestamp: ?*LONGLONG,
        sample: *?*IMFSample,
    ) HRESULT {
        return self.lpVtbl.ReadSample(self, stream, control_flags, actual_stream, stream_flags, timestamp, sample);
    }
    pub inline fn GetPresentationAttribute(self: *Self, stream: DWORD, key: *const GUID, value: *PROPVARIANT) HRESULT {
        return self.lpVtbl.GetPresentationAttribute(self, stream, key, value);
    }
};

// ===========================================================================
// IMFDXGIDeviceManager : IUnknown — only ResetDevice is used.
// ===========================================================================
pub const IMFDXGIDeviceManager = extern struct {
    lpVtbl: *const Vtbl,
    const Self = @This();
    pub const IID = GUID.parse("{EB533D5D-2DB6-40F8-97A9-494692014F07}");

    pub const Vtbl = extern struct {
        QueryInterface: *const fn (*Self, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*Self) callconv(.winapi) ULONG,
        Release: *const fn (*Self) callconv(.winapi) ULONG,
        CloseDeviceHandle: *const anyopaque,
        GetVideoService: *const anyopaque,
        LockDevice: *const anyopaque,
        OpenDeviceHandle: *const anyopaque,
        ResetDevice: *const fn (*Self, ?*IUnknown, UINT) callconv(.winapi) HRESULT,
        TestDevice: *const anyopaque,
        UnlockDevice: *const anyopaque,
    };

    pub inline fn ResetDevice(self: *Self, device: ?*IUnknown, reset_token: UINT) HRESULT {
        return self.lpVtbl.ResetDevice(self, device, reset_token);
    }
};

// ===========================================================================
// Free functions
// ===========================================================================
pub extern "mfplat" fn MFStartup(Version: ULONG, dwFlags: DWORD) callconv(.winapi) HRESULT;
pub extern "mfplat" fn MFShutdown() callconv(.winapi) HRESULT;
pub extern "mfplat" fn MFCreateAttributes(ppMFAttributes: *?*IMFAttributes, cInitialSize: UINT32) callconv(.winapi) HRESULT;
pub extern "mfplat" fn MFCreateMediaType(ppMFType: *?*IMFMediaType) callconv(.winapi) HRESULT;
pub extern "mfplat" fn MFCreateDXGIDeviceManager(resetToken: *UINT, ppDeviceManager: *?*IMFDXGIDeviceManager) callconv(.winapi) HRESULT;
pub extern "mfreadwrite" fn MFCreateSourceReaderFromURL(
    pwszURL: [*:0]const u16,
    pAttributes: ?*IMFAttributes,
    ppSourceReader: *?*IMFSourceReader,
) callconv(.winapi) HRESULT;
