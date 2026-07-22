//! pipeline.zig — the Media Foundation object graph owned by MfBackend.
//!
//! MfPipeline is the Windows analog of the AVFoundation shim: it owns the
//! COM/D3D plumbing (the D3D11 device + context, the DXGI device manager, the
//! shared source reader, and the optional dedicated audio-only reader) and the
//! low-level operations that create and configure them. MfBackend composes one
//! as a field and keeps all policy (track tables, selection state, colorimetry,
//! EOS/error interpretation) to itself — the same policy/plumbing seam the AVF
//! backend gets for free by having its object graph behind a C ABI.
//!
//! The COM/MF apartment lifecycle (CoInitializeEx/MFStartup) is NOT owned here:
//! MfBackend runs it on its ComExecutor's MTA thread, which is also where these
//! objects are created and torn down. This struct only owns COM *objects*.

const std = @import("std");

const win = @import("win.zig");
const com = win.com;
const mf = win.mf;
const d3d11 = win.d3d11;

/// Interleaved-float PCM format read back off a negotiated audio media type.
pub const PcmFormat = struct {
    channels: i32,
    rate: i32,
};

pub const PreparedAudioReader = struct {
    reader: *mf.IMFSourceReader,
    stream_index: i32,
    format: PcmFormat,

    pub fn discard(self: *PreparedAudioReader) void {
        com.release(self.reader);
        self.* = undefined;
    }
};

pub const PreparedReader = struct {
    reader: *mf.IMFSourceReader,

    pub fn discard(self: *PreparedReader) void {
        com.release(self.reader);
        self.* = undefined;
    }
};

pub const MfPipeline = struct {
    // D3D11 device + the DXGI device manager the source reader uses to
    // hardware-decode into D3D11 NV12/P010 textures. Created once per open(),
    // torn down in teardown().
    d3d_device: ?*d3d11.ID3D11Device = null,
    d3d_context: ?*d3d11.ID3D11DeviceContext = null,
    dxgi_manager: ?*mf.IMFDXGIDeviceManager = null,
    reader: ?*mf.IMFSourceReader = null,

    // Non-null only after a reselect: a dedicated audio-only reader so a
    // mid-decode track switch can prime the new track at the requested position
    // without repositioning (and thus disturbing) the shared reader's video
    // stream. nextAudioChunk() reads from this when it is non-null.
    audio_reader: ?*mf.IMFSourceReader = null,
    // The dedicated audio reader's OWN source-reader stream index. Kept here
    // rather than reusing the backend's shared audio_stream_index so the two
    // readers never have to be assumed to enumerate the source identically.
    audio_reader_stream_index: i32 = -1,

    // ---- device / reader construction ----

    // Create a hardware D3D11 device with BGRA + video support, mark it
    // multithread-protected (shared across MF's decoder thread and our pump),
    // and wrap it in an IMFDXGIDeviceManager keyed by a reset token.
    pub fn createDevice(self: *MfPipeline) !void {
        const flags = d3d11.D3D11_CREATE_DEVICE_BGRA_SUPPORT | d3d11.D3D11_CREATE_DEVICE_VIDEO_SUPPORT;
        var got_level: d3d11.D3D_FEATURE_LEVEL = d3d11.D3D_FEATURE_LEVEL_11_0;
        var device: ?*d3d11.ID3D11Device = null;
        var context: ?*d3d11.ID3D11DeviceContext = null;
        const hr = d3d11.D3D11CreateDevice(
            null, // default adapter
            d3d11.D3D_DRIVER_TYPE_HARDWARE,
            null,
            flags,
            null,
            0, // default feature levels
            d3d11.D3D11_SDK_VERSION,
            &device,
            &got_level,
            &context,
        );
        if (com.FAILED(hr) or device == null) return error.DeviceCreate;
        self.d3d_device = device;
        self.d3d_context = context;

        if (com.queryInterface(d3d11.ID3D10Multithread, device.?)) |mt| {
            _ = mt.SetMultithreadProtected(com.TRUE);
            com.release(mt);
        }

        var reset_token: com.UINT = 0;
        var manager: ?*mf.IMFDXGIDeviceManager = null;
        if (com.FAILED(mf.MFCreateDXGIDeviceManager(&reset_token, &manager)) or manager == null) {
            return error.DxgiManager;
        }
        self.dxgi_manager = manager;
        const dev_unk: *com.IUnknown = @ptrCast(device.?);
        if (com.FAILED(manager.?.ResetDevice(dev_unk, reset_token))) return error.ResetDevice;
    }

    // Build the shared source reader bound to the DXGI device manager so decode
    // output is D3D11-backed. Enables advanced video processing + hardware
    // transforms. `path16` is the UTF-16, NUL-terminated source path.
    pub fn prepareReader(self: *MfPipeline, path16: [:0]const u16) !PreparedReader {
        var attrs: ?*mf.IMFAttributes = null;
        if (com.FAILED(mf.MFCreateAttributes(&attrs, 4)) or attrs == null) return error.Attributes;
        defer com.release(attrs.?);
        const a = attrs.?;
        _ = a.SetUnknown(&mf.MF_SOURCE_READER_D3D_MANAGER, @ptrCast(self.dxgi_manager.?));
        _ = a.SetUINT32(&mf.MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS, 1);
        _ = a.SetUINT32(&mf.MF_SOURCE_READER_ENABLE_ADVANCED_VIDEO_PROCESSING, 1);

        var reader: ?*mf.IMFSourceReader = null;
        if (com.FAILED(mf.MFCreateSourceReaderFromURL(path16.ptr, a, &reader)) or reader == null) {
            return error.Reader;
        }
        return .{ .reader = reader.? };
    }

    pub fn createReader(self: *MfPipeline, path16: [:0]const u16) !void {
        const prepared = try self.prepareReader(path16);
        self.reader = prepared.reader;
    }

    pub fn commitReader(self: *MfPipeline, prepared: *PreparedReader) void {
        const old_reader = self.reader;
        self.reader = prepared.reader;
        prepared.* = undefined;
        self.resetAudioReader();
        if (old_reader) |reader| com.release(reader);
    }

    // Create an output media type of `subtype` and set it on the video stream.
    // Returns true on success. The reader inserts a video-processor MFT if the
    // decoder can't natively output that subtype.
    pub fn requestSubtype(self: *MfPipeline, vidx: com.DWORD, subtype: com.GUID) bool {
        return requestSubtypeOn(self.reader.?, vidx, subtype);
    }

    pub fn requestSubtypeOn(reader: *mf.IMFSourceReader, vidx: com.DWORD, subtype: com.GUID) bool {
        var out_type: ?*mf.IMFMediaType = null;
        if (com.FAILED(mf.MFCreateMediaType(&out_type)) or out_type == null) return false;
        defer com.release(out_type.?);
        const ot = out_type.?.asAttributes();
        _ = ot.SetGUID(&mf.MF_MT_MAJOR_TYPE, &mf.MFMediaType_Video);
        _ = ot.SetGUID(&mf.MF_MT_SUBTYPE, &subtype);
        return com.SUCCEEDED(reader.SetCurrentMediaType(vidx, null, out_type.?));
    }

    // Build a dedicated audio-only source reader for `mf_stream_index`, primed
    // at `start_ticks` (100ns units). No DXGI device manager — audio decodes on
    // the CPU. Returns a validated candidate without touching the active
    // reader; the backend commits it with the corresponding selection state.
    pub fn prepareAudioReader(_: *MfPipeline, path16: [:0]const u16, mf_stream_index: i32, start_ticks: i64) ?PreparedAudioReader {
        const aidx: com.DWORD = @intCast(mf_stream_index);

        var ar: ?*mf.IMFSourceReader = null;
        if (com.FAILED(mf.MFCreateSourceReaderFromURL(path16.ptr, null, &ar)) or ar == null) return null;
        if (com.FAILED(ar.?.SetStreamSelection(mf.MF_SOURCE_READER_ALL_STREAMS, com.FALSE))) {
            com.release(ar.?);
            return null;
        }

        const format = configurePcmOutput(ar.?, aidx) orelse {
            com.release(ar.?);
            return null;
        };

        var pos = com.initPropVariantFromInt64(start_ticks);
        const hr = ar.?.SetCurrentPosition(&mf.GUID_NULL, &pos);
        _ = com.PropVariantClear(&pos);
        if (com.FAILED(hr)) {
            com.release(ar.?);
            return null;
        }

        return .{ .reader = ar.?, .stream_index = mf_stream_index, .format = format };
    }

    pub fn commitAudioReader(self: *MfPipeline, prepared: *PreparedAudioReader) void {
        self.resetAudioReader();
        self.audio_reader = prepared.reader;
        self.audio_reader_stream_index = prepared.stream_index;
        prepared.* = undefined;
    }

    pub fn resetAudioReader(self: *MfPipeline) void {
        if (self.audio_reader) |ar| {
            com.release(ar);
            self.audio_reader = null;
        }
        self.audio_reader_stream_index = -1;
    }

    // Release the whole object graph. Dependents (readers) before the device,
    // mirroring the C++ Impl::teardown order. The COM/MF apartment shutdown is
    // the backend's job, not this struct's.
    pub fn teardown(self: *MfPipeline) void {
        self.resetAudioReader();
        if (self.reader) |p| {
            com.release(p);
            self.reader = null;
        }
        if (self.dxgi_manager) |p| {
            com.release(p);
            self.dxgi_manager = null;
        }
        if (self.d3d_context) |p| {
            com.release(p);
            self.d3d_context = null;
        }
        if (self.d3d_device) |p| {
            com.release(p);
            self.d3d_device = null;
        }
    }
};

// Select `aidx` on `target` and negotiate interleaved float32 PCM, returning
// the channel count / sample rate read back off the negotiated type, or null on
// failure. Free-standing (touches no MfPipeline state) so it serves both the
// shared reader and the dedicated audio-only reader.
pub fn configurePcmOutput(target: *mf.IMFSourceReader, aidx: com.DWORD) ?PcmFormat {
    if (com.FAILED(target.SetStreamSelection(aidx, com.TRUE))) return null;
    var configured = false;
    defer if (!configured) {
        _ = target.SetStreamSelection(aidx, com.FALSE);
    };

    var pcm: ?*mf.IMFMediaType = null;
    if (com.FAILED(mf.MFCreateMediaType(&pcm)) or pcm == null) return null;
    defer com.release(pcm.?);
    const pa = pcm.?.asAttributes();
    if (com.FAILED(pa.SetGUID(&mf.MF_MT_MAJOR_TYPE, &mf.MFMediaType_Audio))) return null;
    if (com.FAILED(pa.SetGUID(&mf.MF_MT_SUBTYPE, &mf.MFAudioFormat_Float))) return null;
    if (com.FAILED(target.SetCurrentMediaType(aidx, null, pcm.?))) return null;

    var current: ?*mf.IMFMediaType = null;
    if (com.FAILED(target.GetCurrentMediaType(aidx, &current)) or current == null) return null;
    defer com.release(current.?);
    var ch: u32 = 0;
    var rate: u32 = 0;
    const attrs = current.?.asAttributes();
    if (com.FAILED(attrs.GetUINT32(&mf.MF_MT_AUDIO_NUM_CHANNELS, &ch))) return null;
    if (com.FAILED(attrs.GetUINT32(&mf.MF_MT_AUDIO_SAMPLES_PER_SECOND, &rate))) return null;
    if (ch == 0 or rate == 0) return null;
    configured = true;
    return .{ .channels = @intCast(ch), .rate = @intCast(rate) };
}
