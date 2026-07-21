//! mf_backend.zig — Media Foundation Decoder-mode Backend (Windows).
//!
//! The Windows analog of avf::AvfBackend. Drives an IMFSourceReader bound to an
//! IMFDXGIDeviceManager as a pure hardware decoder: video decodes straight into
//! D3D11 textures (DXGI_FORMAT_NV12 for 8-bit sources, DXGI_FORMAT_P010 for
//! 10-bit HEVC Main10), audio into interleaved float32 PCM. Every decoded frame
//! hands out the underlying ID3D11Texture2D as a native surface handle whose
//! single +1 reference is released via VideoFrame.release. No Godot /
//! RenderingDevice symbols appear here — this is a decode pump only.
//!
//! This is a straight port of src/backends/mf/{mf_backend,mf_audio}.cpp; the
//! two C++ translation units are fused into this one file because Zig cannot
//! split a struct's methods across files the way the shared MfBackend::Impl
//! did. Structural mirror of avf_backend.zig; policy decisions (bit-depth
//! negotiation, colorimetry-from-native-type, reversed audio enumeration,
//! dedicated-reader reselect) match the C++ exactly — each is a
//! verified-on-Windows-11 workaround, noted inline where it matters.
//!
//! Ownership at the boundaries:
//!  - Video frames: GetResource yields a +1 ID3D11Texture2D adopted into
//!    native_handle; the release hook Releases it exactly once.
//!  - Audio samples: copied into backend-owned scratch, valid until the next
//!    nextAudioChunk()/close() — the AudioChunk slice borrows it.
//!  - AudioTrackInfo strings: normalized/duplicated into backend-owned storage
//!    at open, freed at close; slices stay valid until close().
//!
//! COM/MF lifecycle is per-open(): CoInitializeEx + MFStartup in open, paired
//! MFShutdown + CoUninitialize in close, on whatever thread calls them — the
//! core scheduler pumps backends on worker threads, so the lifecycle must ride
//! with the open/close calls rather than a fixed thread.

const std = @import("std");
// Reach core through the build.zig-wired "core" named module: a module root
// forbids cross-directory @import, and routing through the shared module keeps
// core.Backend one identity across the mf backend, the engine core, and the
// Godot glue. Mirrors avf_backend.zig.
const core = @import("core").backend;

const win = @import("win.zig");
const com = win.com;
const mf = win.mf;
const d3d11 = win.d3d11;

const log = std.log.scoped(.mf_backend);

// MF sample/duration times are in 100-nanosecond units (10^7 per second), the
// Media Foundation time base. PTS in seconds = ticks / 1e7.
const ticks_per_second: f64 = 10_000_000.0;

fn ticksToSeconds(ticks: i64) f64 {
    return @as(f64, @floatFromInt(ticks)) / ticks_per_second;
}
fn secondsToTicks(seconds: f64) i64 {
    return @intFromFloat(seconds * ticks_per_second + 0.5);
}

fn guidEql(a: com.GUID, b: com.GUID) bool {
    return std.meta.eql(a, b);
}

// ---------------------------------------------------------------------------
// Colorimetry translation — map MF_MT_YUV_MATRIX / _VIDEO_PRIMARIES /
// _TRANSFER_FUNCTION / _VIDEO_NOMINAL_RANGE attribute values to the core enums.
// Unrecognised/absent values map to Unspecified so the caller's BT.709
// video-range defaults stay in effect. Structural mirror of the C++ parsers.
// ---------------------------------------------------------------------------
fn parseMatrix(v: u32) core.ColorMatrix {
    return switch (v) {
        mf.MFVideoTransferMatrix_BT709 => .bt709,
        mf.MFVideoTransferMatrix_BT601 => .bt601,
        mf.MFVideoTransferMatrix_BT2020_10, mf.MFVideoTransferMatrix_BT2020_12 => .bt2020,
        else => .unspecified,
    };
}

fn parsePrimaries(v: u32) core.ColorPrimaries {
    return switch (v) {
        mf.MFVideoPrimaries_BT709 => .bt709,
        mf.MFVideoPrimaries_BT470_2_SysBG, mf.MFVideoPrimaries_EBU3213 => .bt601_625,
        mf.MFVideoPrimaries_SMPTE170M, mf.MFVideoPrimaries_SMPTE_C => .bt601_525,
        mf.MFVideoPrimaries_BT2020 => .bt2020,
        mf.MFVideoPrimaries_DCI_P3 => .dci_p3,
        else => .unspecified,
    };
}

fn parseTransfer(v: u32) core.TransferFunction {
    return switch (v) {
        mf.MFVideoTransFunc_709, mf.MFVideoTransFunc_sRGB => .bt709,
        mf.MFVideoTransFunc_2084 => .pq,
        mf.MFVideoTransFunc_HLG => .hlg,
        else => .unspecified,
    };
}

fn parseRange(v: u32) core.ColorRange {
    return switch (v) {
        mf.MFNominalRange_0_255 => .full,
        mf.MFNominalRange_16_235 => .video,
        else => .unspecified,
    };
}

// The core enums' integer values are load-bearing here (frame color is passed
// straight to the present shader): pin the ones the parsers above depend on so
// either side moving out of step is a compile error, not a silently wrong
// colour on screen. Mirrors avf_backend.zig's assertion block.
comptime {
    std.debug.assert(@intFromEnum(core.ColorMatrix.unspecified) == 0);
    std.debug.assert(@intFromEnum(core.ColorMatrix.bt709) == 1);
    std.debug.assert(@intFromEnum(core.ColorMatrix.bt601) == 2);
    std.debug.assert(@intFromEnum(core.ColorMatrix.bt2020) == 3);

    std.debug.assert(@intFromEnum(core.ColorPrimaries.unspecified) == 0);
    std.debug.assert(@intFromEnum(core.ColorPrimaries.bt709) == 1);
    std.debug.assert(@intFromEnum(core.ColorPrimaries.bt601_625) == 2);
    std.debug.assert(@intFromEnum(core.ColorPrimaries.bt601_525) == 3);
    std.debug.assert(@intFromEnum(core.ColorPrimaries.bt2020) == 4);
    std.debug.assert(@intFromEnum(core.ColorPrimaries.dci_p3) == 5);

    std.debug.assert(@intFromEnum(core.TransferFunction.unspecified) == 0);
    std.debug.assert(@intFromEnum(core.TransferFunction.bt709) == 1);
    std.debug.assert(@intFromEnum(core.TransferFunction.pq) == 2);
    std.debug.assert(@intFromEnum(core.TransferFunction.hlg) == 3);

    std.debug.assert(@intFromEnum(core.ColorRange.unspecified) == 0);
    std.debug.assert(@intFromEnum(core.ColorRange.video) == 1);
    std.debug.assert(@intFromEnum(core.ColorRange.full) == 2);

    std.debug.assert(@intFromEnum(core.PixelFormat.nv12) == 1);
    std.debug.assert(@intFromEnum(core.PixelFormat.x420) == 2);
}

// Detect the source's bit depth from the native (pre-conversion) video media
// type. MF_MT_MPEG2_PROFILE carries the demuxer-parsed HEVC general_profile_idc;
// profile 2 (eAVEncH265VProfile_Main_420_10) identifies a 10-bit 4:2:0 source.
// Absent or any other value defaults to 8-bit.
fn detectBitDepth(native: *mf.IMFMediaType) i32 {
    var profile: u32 = 0;
    if (com.SUCCEEDED(native.asAttributes().GetUINT32(&mf.MF_MT_MPEG2_PROFILE, &profile))) {
        if (profile == mf.eAVEncH265VProfile_Main_420_10) return 10;
    }
    return 8;
}

// ---------------------------------------------------------------------------
// MfBackend — the concrete implementation behind the Backend vtable.
// ---------------------------------------------------------------------------
pub const MfBackend = struct {
    allocator: std.mem.Allocator,

    // D3D11 device + the DXGI device manager the source reader uses to
    // hardware-decode into D3D11 NV12/P010 textures. Created once per open(),
    // torn down in close().
    d3d_device: ?*d3d11.ID3D11Device = null,
    d3d_context: ?*d3d11.ID3D11DeviceContext = null,
    dxgi_manager: ?*mf.IMFDXGIDeviceManager = null,
    reader: ?*mf.IMFSourceReader = null,

    // Non-null only after reselectAudioTrack(); reset by open()/seek(). A
    // dedicated audio-only reader so a mid-decode track switch can prime the
    // new track at the requested position without repositioning (and thus
    // disturbing) the shared reader's video stream. nextAudioChunk() reads from
    // this when it is non-null.
    audio_reader: ?*mf.IMFSourceReader = null,

    // UTF-16, NUL-terminated source path for MFCreateSourceReaderFromURL.
    path16: ?[:0]u16 = null,

    duration: f64 = 0.0,
    width: i32 = 0,
    height: i32 = 0,
    audio_channels: i32 = 0,
    audio_rate: i32 = 0,

    video_stream_index: i32 = -1,
    audio_stream_index: i32 = -1,

    // Negotiated colorimetry (read from the video stream's NATIVE media type at
    // open — the video-processor MFT strips these attributes off its negotiated
    // output type). Defaults to BT.709 video range 8-bit; bit_depth is set to
    // 10 when P010 negotiation succeeds.
    color: core.Colorimetry = core.Colorimetry.bt709_defaults,

    // Set true when a decode pump / seek hits a FAILED HRESULT (vs. a clean
    // EOS). Mirrors the C++ error flag; the vtable boundary reports it as
    // null/false coarsely.
    err_flag: bool = false,
    com_initialized: bool = false,
    mf_started: bool = false,

    // Per-track audio metadata, populated during the open-time stream scan.
    audio_tracks: std.ArrayList(core.AudioTrackInfo) = .empty,
    // Maps audio track index (position in audio_tracks) to the MF source-reader
    // stream index used by SetStreamSelection / SetCurrentMediaType.
    audio_stream_indices: std.ArrayList(i32) = .empty,
    // Backend-owned language/name strings the AudioTrackInfo slices point into;
    // freed at close().
    owned_strings: std.ArrayList([]u8) = .empty,

    // Desired vs. actually-applied audio track. A selectAudioTrack() call only
    // records `selected`; the shared reader is caught up (switchAudioTrack) on
    // the next seek(), which is when `applied` reconverges.
    selected_audio_track: i32 = 0,
    applied_audio_track: i32 = 0,

    // Backing store for the most recent decoded audio chunk; the returned
    // AudioChunk borrows it until the next nextAudioChunk() call.
    audio_scratch: std.ArrayList(f32) = .empty,

    // ---- vtable glue ----
    const vtable: core.Backend.VTable = .{
        .open = vtOpen,
        .close = vtClose,
        .deinit = vtDeinit,
        .duration_seconds = vtDuration,
        .video_width = vtWidth,
        .video_height = vtHeight,
        .audio_channel_count = vtAudioChannels,
        .audio_sample_rate = vtAudioRate,
        .colorimetry = vtColorimetry,
        .audio_track_count = vtAudioTrackCount,
        .audio_track_info = vtAudioTrackInfo,
        .select_audio_track = vtSelectAudioTrack,
        .reselect_audio_track = vtReselectAudioTrack,
        .seek = vtSeek,
        .next_video_frame = vtNextVideoFrame,
        .next_audio_chunk = vtNextAudioChunk,
    };

    fn fromPtr(p: *anyopaque) *MfBackend {
        return @ptrCast(@alignCast(p));
    }

    // ---- MF/D3D setup helpers (per-open) ----

    // Create a hardware D3D11 device with BGRA + video support, mark it
    // multithread-protected (shared across MF's decoder thread and our pump),
    // and wrap it in an IMFDXGIDeviceManager keyed by a reset token.
    fn createDevice(self: *MfBackend) !void {
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
            _ = mt.Release();
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

    // Build the source reader bound to the DXGI device manager so decode output
    // is D3D11-backed. Enables advanced video processing + hardware transforms.
    fn createReader(self: *MfBackend) !void {
        var attrs: ?*mf.IMFAttributes = null;
        if (com.FAILED(mf.MFCreateAttributes(&attrs, 4)) or attrs == null) return error.Attributes;
        defer _ = attrs.?.Release();
        const a = attrs.?;
        _ = a.SetUnknown(&mf.MF_SOURCE_READER_D3D_MANAGER, @ptrCast(self.dxgi_manager.?));
        _ = a.SetUINT32(&mf.MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS, 1);
        _ = a.SetUINT32(&mf.MF_SOURCE_READER_ENABLE_ADVANCED_VIDEO_PROCESSING, 1);

        var reader: ?*mf.IMFSourceReader = null;
        if (com.FAILED(mf.MFCreateSourceReaderFromURL(self.path16.?.ptr, a, &reader)) or reader == null) {
            return error.Reader;
        }
        self.reader = reader;
    }

    // Scan every stream: pick the first video stream (reading colorimetry + bit
    // depth off its NATIVE type), and collect audio-track metadata. Then
    // reorder audio tracks to container order, negotiate the video output
    // subtype matched to bit depth (P010 with NV12 fallback), and read back
    // frame dimensions. Returns false when there is no usable video stream (the
    // caller decides whether that's fatal).
    fn configureVideoStream(self: *MfBackend) !bool {
        const reader = self.reader.?;
        var i: com.DWORD = 0;
        while (true) : (i += 1) {
            var native: ?*mf.IMFMediaType = null;
            const hr = reader.GetNativeMediaType(i, 0, &native);
            if (hr == com.MF_E_INVALIDSTREAMNUMBER) break; // no more streams
            if (com.FAILED(hr) or native == null) continue;
            const nt = native.?;
            defer _ = nt.Release();

            var major: com.GUID = std.mem.zeroes(com.GUID);
            _ = nt.asAttributes().GetGUID(&mf.MF_MT_MAJOR_TYPE, &major);

            if (guidEql(major, mf.MFMediaType_Video) and self.video_stream_index < 0) {
                self.video_stream_index = @intCast(i);
                // Colorimetry + bit depth live on the native (pre-conversion)
                // type; the NV12/P010 output type does not carry them forward.
                self.readColorimetry(nt);
                self.color.bit_depth = detectBitDepth(nt);
            } else if (guidEql(major, mf.MFMediaType_Audio)) {
                var ch: u32 = 0;
                var rate: u32 = 0;
                _ = nt.asAttributes().GetUINT32(&mf.MF_MT_AUDIO_NUM_CHANNELS, &ch);
                _ = nt.asAttributes().GetUINT32(&mf.MF_MT_AUDIO_SAMPLES_PER_SECOND, &rate);

                var lang: []const u8 = "";
                if (try self.readStreamString(i, &mf.MF_SD_LANGUAGE)) |rl| {
                    defer self.allocator.free(rl);
                    const norm = try self.normalizeLanguageTag(rl);
                    try self.owned_strings.append(self.allocator, norm);
                    lang = norm;
                }
                var name: []const u8 = "";
                if (try self.readStreamString(i, &mf.MF_SD_STREAM_NAME)) |nm| {
                    try self.owned_strings.append(self.allocator, nm);
                    name = nm;
                }

                try self.audio_tracks.append(self.allocator, .{
                    .language = lang,
                    .name = name,
                    .channels = @intCast(ch),
                    .sample_rate = @intCast(rate),
                    .is_default = self.audio_tracks.items.len == 0,
                });
                try self.audio_stream_indices.append(self.allocator, @intCast(i));
                if (self.audio_stream_index < 0) self.audio_stream_index = @intCast(i);
            }
        }

        if (self.video_stream_index < 0) return false;

        self.reorderAudioTracksByContainerOrder();

        const vidx: com.DWORD = @intCast(self.video_stream_index);
        // Request the output subtype matching detected bit depth; fall back to
        // NV12 (correcting bit_depth) if the P010 request fails.
        var ok = self.requestSubtype(vidx, if (self.color.bit_depth >= 10) mf.MFVideoFormat_P010 else mf.MFVideoFormat_NV12);
        if (!ok and self.color.bit_depth >= 10) {
            self.color.bit_depth = 8;
            ok = self.requestSubtype(vidx, mf.MFVideoFormat_NV12);
        }
        if (!ok) return false;

        _ = reader.SetStreamSelection(vidx, com.TRUE);

        var current: ?*mf.IMFMediaType = null;
        if (com.SUCCEEDED(reader.GetCurrentMediaType(vidx, &current)) and current != null) {
            defer _ = current.?.Release();
            var w: u32 = 0;
            var h: u32 = 0;
            if (com.SUCCEEDED(current.?.asAttributes().getFrameSize(&w, &h))) {
                self.width = @intCast(w);
                self.height = @intCast(h);
            }
        }
        return true;
    }

    // Create an output media type of `subtype` and set it on the video stream.
    // Returns true on success. The reader inserts a video-processor MFT if the
    // decoder can't natively output that subtype.
    fn requestSubtype(self: *MfBackend, vidx: com.DWORD, subtype: com.GUID) bool {
        var out_type: ?*mf.IMFMediaType = null;
        if (com.FAILED(mf.MFCreateMediaType(&out_type)) or out_type == null) return false;
        defer _ = out_type.?.Release();
        const ot = out_type.?.asAttributes();
        _ = ot.SetGUID(&mf.MF_MT_MAJOR_TYPE, &mf.MFMediaType_Video);
        _ = ot.SetGUID(&mf.MF_MT_SUBTYPE, &subtype);
        return com.SUCCEEDED(self.reader.?.SetCurrentMediaType(vidx, null, out_type.?));
    }

    // Read colorimetry attributes off a video media type. Absent attributes
    // leave the existing default untouched.
    fn readColorimetry(self: *MfBackend, t: *mf.IMFMediaType) void {
        const attrs = t.asAttributes();
        var val: u32 = 0;
        if (com.SUCCEEDED(attrs.GetUINT32(&mf.MF_MT_YUV_MATRIX, &val))) self.color.matrix = parseMatrix(val);
        if (com.SUCCEEDED(attrs.GetUINT32(&mf.MF_MT_VIDEO_PRIMARIES, &val))) self.color.primaries = parsePrimaries(val);
        if (com.SUCCEEDED(attrs.GetUINT32(&mf.MF_MT_TRANSFER_FUNCTION, &val))) self.color.transfer = parseTransfer(val);
        if (com.SUCCEEDED(attrs.GetUINT32(&mf.MF_MT_VIDEO_NOMINAL_RANGE, &val))) self.color.range = parseRange(val);
    }

    // Select `aidx` on `target` and negotiate interleaved float32 PCM, updating
    // audio_channels/audio_rate from the negotiated type. Shared by the combined
    // reader and the dedicated audio-only reader.
    fn configurePcmOutput(self: *MfBackend, target: *mf.IMFSourceReader, aidx: com.DWORD) bool {
        _ = target.SetStreamSelection(aidx, com.TRUE);

        var pcm: ?*mf.IMFMediaType = null;
        if (com.FAILED(mf.MFCreateMediaType(&pcm)) or pcm == null) return false;
        defer _ = pcm.?.Release();
        const pa = pcm.?.asAttributes();
        _ = pa.SetGUID(&mf.MF_MT_MAJOR_TYPE, &mf.MFMediaType_Audio);
        _ = pa.SetGUID(&mf.MF_MT_SUBTYPE, &mf.MFAudioFormat_Float);
        if (com.FAILED(target.SetCurrentMediaType(aidx, null, pcm.?))) return false;

        var current: ?*mf.IMFMediaType = null;
        if (com.SUCCEEDED(target.GetCurrentMediaType(aidx, &current)) and current != null) {
            defer _ = current.?.Release();
            var ch: u32 = 0;
            var rate: u32 = 0;
            _ = current.?.asAttributes().GetUINT32(&mf.MF_MT_AUDIO_NUM_CHANNELS, &ch);
            _ = current.?.asAttributes().GetUINT32(&mf.MF_MT_AUDIO_SAMPLES_PER_SECOND, &rate);
            self.audio_channels = @intCast(ch);
            self.audio_rate = @intCast(rate);
        }
        return true;
    }

    // Configure the open-time audio stream to float32 PCM. Non-fatal: on
    // failure, audio is simply left unselected (silent clip / audio-less pump).
    fn configureAudioStream(self: *MfBackend) void {
        if (self.audio_stream_index < 0) return;
        const aidx: com.DWORD = @intCast(self.audio_stream_index);
        if (!self.configurePcmOutput(self.reader.?, aidx)) {
            self.audio_stream_index = -1;
        }
    }

    // Read total duration from the presentation descriptor (100ns -> seconds).
    fn readDuration(self: *MfBackend) void {
        var pv = com.PROPVARIANT.zeroed();
        const hr = self.reader.?.GetPresentationAttribute(mf.MF_SOURCE_READER_MEDIASOURCE, &mf.MF_PD_DURATION, &pv);
        if (com.SUCCEEDED(hr) and pv.vt == com.VT_UI8) {
            self.duration = ticksToSeconds(@intCast(pv.val.uhVal));
        }
        _ = com.PropVariantClear(&pv);
    }

    // Read a wide-string stream-descriptor attribute (MF_SD_LANGUAGE /
    // MF_SD_STREAM_NAME) and return it as newly-allocated UTF-8, or null if
    // absent/empty. Caller owns the returned slice.
    fn readStreamString(self: *MfBackend, stream_index: com.DWORD, guid: *const com.GUID) !?[]u8 {
        var pv = com.PROPVARIANT.zeroed();
        const hr = self.reader.?.GetPresentationAttribute(stream_index, guid, &pv);
        defer _ = com.PropVariantClear(&pv);
        if (com.SUCCEEDED(hr) and pv.vt == com.VT_LPWSTR) {
            if (pv.val.pwszVal) |w| {
                const span = std.mem.span(w);
                if (span.len == 0) return null;
                return try std.unicode.utf16LeToUtf8Alloc(self.allocator, span);
            }
        }
        return null;
    }

    // MF reports MF_SD_LANGUAGE as an RFC 1766 tag ("en"); AVF/the container
    // report ISO 639-2 ("eng"). Convert via GetLocaleInfoEx so track metadata
    // is identical across backends; unknown tags pass through unchanged. Caller
    // owns the returned slice.
    fn normalizeLanguageTag(self: *MfBackend, tag: []const u8) ![]u8 {
        const a = self.allocator;
        if (tag.len == 0) return a.dupe(u8, tag);

        const tag_z = try a.dupeZ(u8, tag);
        defer a.free(tag_z);

        var wide: [com.LOCALE_NAME_MAX_LENGTH]u16 = [_]u16{0} ** com.LOCALE_NAME_MAX_LENGTH;
        if (com.MultiByteToWideChar(com.CP_UTF8, 0, tag_z.ptr, -1, &wide, @intCast(wide.len)) <= 0) {
            return a.dupe(u8, tag);
        }
        var iso: [9]u16 = [_]u16{0} ** 9;
        if (com.GetLocaleInfoEx(@ptrCast(&wide), com.LOCALE_SISO639LANGNAME2, &iso, 9) <= 0) {
            return a.dupe(u8, tag);
        }
        var narrow: [9]u8 = undefined;
        const n = com.WideCharToMultiByte(com.CP_UTF8, 0, &iso, -1, &narrow, narrow.len, null, null);
        if (n <= 1) return a.dupe(u8, tag); // n counts the trailing NUL
        return a.dupe(u8, narrow[0..@intCast(n - 1)]);
    }

    // MF's MP4/MOV source enumerates audio streams in the REVERSE of the
    // container's trak order; reverse both parallel arrays so audio track index
    // N lines up with the file (and the AVF backend). The real trak IDs aren't
    // recoverable, so reversing is the only lever.
    fn reorderAudioTracksByContainerOrder(self: *MfBackend) void {
        if (self.audio_tracks.items.len < 2) return;
        std.mem.reverse(core.AudioTrackInfo, self.audio_tracks.items);
        std.mem.reverse(i32, self.audio_stream_indices.items);
        for (self.audio_tracks.items, 0..) |*t, k| t.is_default = (k == 0);
        self.audio_stream_index = self.audio_stream_indices.items[0];
    }

    // Deselect the old audio stream, select track_index, renegotiate PCM. This
    // IS the application of a selection, so selected/applied both converge.
    fn switchAudioTrack(self: *MfBackend, track_index: i32) bool {
        if (self.audio_stream_indices.items.len == 0) return false;
        if (track_index < 0 or track_index >= @as(i32, @intCast(self.audio_stream_indices.items.len))) return false;

        if (self.audio_stream_index >= 0) {
            _ = self.reader.?.SetStreamSelection(@intCast(self.audio_stream_index), com.FALSE);
        }
        const new_mf_index = self.audio_stream_indices.items[@intCast(track_index)];
        self.audio_stream_index = new_mf_index;
        const aidx: com.DWORD = @intCast(new_mf_index);
        if (!self.configurePcmOutput(self.reader.?, aidx)) {
            _ = self.reader.?.SetStreamSelection(aidx, com.FALSE);
            self.audio_stream_index = -1;
            return false;
        }
        self.selected_audio_track = track_index;
        self.applied_audio_track = track_index;
        return true;
    }

    // Build a dedicated audio-only source reader for track_index, primed at
    // start_time. No DXGI device manager needed — audio decodes on the CPU.
    fn buildAudioReader(self: *MfBackend, track_index: i32, start_time: f64) bool {
        self.resetAudioReader();

        var ar: ?*mf.IMFSourceReader = null;
        if (com.FAILED(mf.MFCreateSourceReaderFromURL(self.path16.?.ptr, null, &ar)) or ar == null) return false;
        _ = ar.?.SetStreamSelection(mf.MF_SOURCE_READER_ALL_STREAMS, com.FALSE);

        const aidx: com.DWORD = @intCast(self.audio_stream_indices.items[@intCast(track_index)]);
        if (!self.configurePcmOutput(ar.?, aidx)) {
            _ = ar.?.Release();
            return false;
        }

        var pos = com.initPropVariantFromInt64(secondsToTicks(start_time));
        const hr = ar.?.SetCurrentPosition(&mf.GUID_NULL, &pos);
        _ = com.PropVariantClear(&pos);
        if (com.FAILED(hr)) {
            _ = ar.?.Release();
            return false;
        }
        self.audio_reader = ar;
        return true;
    }

    fn resetAudioReader(self: *MfBackend) void {
        if (self.audio_reader) |ar| {
            _ = ar.Release();
            self.audio_reader = null;
        }
    }

    // ---- lifecycle ----

    fn openImpl(self: *MfBackend, url_or_path: []const u8) bool {
        self.openInner(url_or_path) catch |e| {
            log.debug("open failed: {s}", .{@errorName(e)});
            self.closeImpl();
            return false;
        };
        return true;
    }

    fn openInner(self: *MfBackend, url_or_path: []const u8) !void {
        // The sole reset-to-closed point before opening.
        self.closeImpl();

        // COM + MF must be initialized on this thread before any MF call; paired
        // with MFShutdown/CoUninitialize in teardown.
        const hr_co = com.CoInitializeEx(null, com.COINIT_MULTITHREADED);
        if (com.SUCCEEDED(hr_co) or hr_co == com.S_FALSE) self.com_initialized = true;

        if (com.FAILED(mf.MFStartup(mf.MF_VERSION, mf.MFSTARTUP_LITE))) return error.MFStartup;
        self.mf_started = true;

        self.path16 = try std.unicode.utf8ToUtf16LeAllocZ(self.allocator, url_or_path);

        try self.createDevice();
        try self.createReader();

        // Deselect all streams, then enable just the ones we configure.
        _ = self.reader.?.SetStreamSelection(mf.MF_SOURCE_READER_ALL_STREAMS, com.FALSE);

        const has_video = try self.configureVideoStream();
        // Match AVF: fail only if there is neither audio nor video.
        if (!has_video and self.audio_stream_index < 0) return error.NoStreams;

        self.configureAudioStream();
        self.readDuration();
    }

    fn closeImpl(self: *MfBackend) void {
        // Teardown order mirrors the C++ Impl::teardown: dependents before the
        // device, then MF then COM.
        self.resetAudioReader();
        if (self.reader) |p| {
            _ = p.Release();
            self.reader = null;
        }
        if (self.dxgi_manager) |p| {
            _ = p.Release();
            self.dxgi_manager = null;
        }
        if (self.d3d_context) |p| {
            _ = p.Release();
            self.d3d_context = null;
        }
        if (self.d3d_device) |p| {
            _ = p.Release();
            self.d3d_device = null;
        }
        if (self.mf_started) {
            _ = mf.MFShutdown();
            self.mf_started = false;
        }
        if (self.com_initialized) {
            com.CoUninitialize();
            self.com_initialized = false;
        }

        for (self.owned_strings.items) |s| self.allocator.free(s);
        self.owned_strings.clearRetainingCapacity();
        self.audio_tracks.clearRetainingCapacity();
        self.audio_stream_indices.clearRetainingCapacity();
        if (self.path16) |p| {
            self.allocator.free(p);
            self.path16 = null;
        }

        self.duration = 0.0;
        self.width = 0;
        self.height = 0;
        self.audio_channels = 0;
        self.audio_rate = 0;
        self.video_stream_index = -1;
        self.audio_stream_index = -1;
        self.selected_audio_track = 0;
        self.applied_audio_track = 0;
        self.color = core.Colorimetry.bt709_defaults;
        self.err_flag = false;
    }

    fn seekImpl(self: *MfBackend, pts_seconds: f64) bool {
        if (self.reader == null) return false;
        const target = @max(pts_seconds, 0.0);

        // Tear down any dedicated audio-only reader and re-home audio on the
        // shared reader.
        var audio_reader_torn = false;
        if (self.audio_reader != null) {
            self.resetAudioReader();
            audio_reader_torn = true;
        }
        // Catch the shared reader up to a pending selectAudioTrack(), and/or
        // re-home audio after a dedicated reselect reader. Safe here because
        // SetCurrentPosition below restarts the media source, which is what
        // makes a newly (re)selected stream actually deliver samples.
        if (audio_reader_torn or self.applied_audio_track != self.selected_audio_track) {
            _ = self.switchAudioTrack(self.selected_audio_track);
        }

        var pos = com.initPropVariantFromInt64(secondsToTicks(target));
        const hr = self.reader.?.SetCurrentPosition(&mf.GUID_NULL, &pos);
        _ = com.PropVariantClear(&pos);
        if (com.FAILED(hr)) {
            self.err_flag = true;
            return false;
        }
        return true;
    }

    fn selectAudioTrackImpl(self: *MfBackend, index: i32) void {
        if (self.audio_stream_indices.items.len == 0) return;
        const count: i32 = @intCast(self.audio_tracks.items.len);
        if (count == 0) return;
        const clamped = std.math.clamp(index, 0, count - 1);
        self.selected_audio_track = clamped;
        // Selection takes effect on the next seek()/open(); update channel/rate
        // metadata immediately so a caller inspecting them pre-playback sees the
        // selected track's format.
        const meta = self.audio_tracks.items[@intCast(clamped)];
        self.audio_channels = meta.channels;
        self.audio_rate = meta.sample_rate;
    }

    fn reselectAudioTrackImpl(self: *MfBackend, index: i32, pts_seconds: f64) bool {
        if (self.audio_stream_indices.items.len == 0) return false;
        const count: i32 = @intCast(self.audio_tracks.items.len);
        if (count == 0) return false;
        const clamped = std.math.clamp(index, 0, count - 1);
        const target = @max(pts_seconds, 0.0);

        // Dedicated audio-only reader for the new track, primed at target, while
        // the shared reader keeps decoding video from its current position.
        if (!self.buildAudioReader(clamped, target)) return false;

        // Stop the shared reader from queueing the old track's audio.
        if (self.audio_stream_index >= 0) {
            _ = self.reader.?.SetStreamSelection(@intCast(self.audio_stream_index), com.FALSE);
        }
        self.audio_stream_index = self.audio_stream_indices.items[@intCast(clamped)];
        self.selected_audio_track = clamped;
        self.applied_audio_track = clamped;
        return true;
    }

    fn nextVideoFrameImpl(self: *MfBackend) ?core.VideoFrame {
        if (self.reader == null or self.video_stream_index < 0) return null;
        const vidx: com.DWORD = @intCast(self.video_stream_index);

        while (true) {
            var stream_flags: com.DWORD = 0;
            var timestamp: mf.LONGLONG = 0;
            var sample: ?*mf.IMFSample = null;
            const hr = self.reader.?.ReadSample(vidx, 0, null, &stream_flags, &timestamp, &sample);
            if (com.FAILED(hr)) {
                self.err_flag = true;
                return null;
            }
            if ((stream_flags & mf.MF_SOURCE_READERF_ENDOFSTREAM) != 0) return null; // clean EOS
            // No sample this call (stream tick / native-type change): loop.
            // Known limitation preserved from the C++: a mid-stream native type
            // change does not re-probe colorimetry.
            const s = sample orelse continue;
            defer _ = s.Release();

            var media_buffer: ?*mf.IMFMediaBuffer = null;
            if (com.FAILED(s.GetBufferByIndex(0, &media_buffer)) or media_buffer == null) {
                self.err_flag = true;
                return null;
            }
            const mb = media_buffer.?;
            defer _ = mb.Release();

            const dxgi_buffer = com.queryInterface(mf.IMFDXGIBuffer, mb) orelse {
                // Not a D3D11-backed sample — the DXGI device manager wasn't honored.
                self.err_flag = true;
                return null;
            };
            defer _ = dxgi_buffer.Release();

            // GetResource returns a +1 reference we adopt into native_handle.
            var raw: ?*anyopaque = null;
            if (com.FAILED(dxgi_buffer.GetResource(&d3d11.ID3D11Texture2D.IID, &raw)) or raw == null) {
                self.err_flag = true;
                return null;
            }
            const tex: *d3d11.ID3D11Texture2D = @ptrCast(@alignCast(raw.?));

            // The decoder packs frames as slices of one texture array; the
            // subresource index tells the importer which slice this frame is.
            var subresource: com.UINT = 0;
            _ = dxgi_buffer.GetSubresourceIndex(&subresource);

            return .{
                .pts_seconds = ticksToSeconds(timestamp),
                .native_handle = @ptrCast(tex),
                .plane_slice = subresource,
                .width = self.width,
                .height = self.height,
                // 8-bit -> NV12; 10-bit HEVC Main10 -> P010 tagged x420, the
                // same logical tag the AVF backend uses for 10-bit surfaces.
                .pixel_format = if (self.color.bit_depth >= 10) .x420 else .nv12,
                .color = self.color,
                .release_hook = .{ .ctx = @ptrCast(tex), .func = frameRelease },
            };
        }
    }

    fn frameRelease(ctx: ?*anyopaque) void {
        if (ctx) |p| {
            const tex: *d3d11.ID3D11Texture2D = @ptrCast(@alignCast(p));
            _ = tex.Release();
        }
    }

    fn nextAudioChunkImpl(self: *MfBackend) ?core.AudioChunk {
        if (self.reader == null or self.audio_stream_index < 0) return null;
        // When a dedicated audio-only reader is active (from reselect), read
        // from it; otherwise the shared reader. Both enumerate the same source,
        // so the stream index matches.
        const active = if (self.audio_reader) |ar| ar else self.reader.?;
        const aidx: com.DWORD = @intCast(self.audio_stream_index);

        while (true) {
            var stream_flags: com.DWORD = 0;
            var timestamp: mf.LONGLONG = 0;
            var sample: ?*mf.IMFSample = null;
            const hr = active.ReadSample(aidx, 0, null, &stream_flags, &timestamp, &sample);
            if (com.FAILED(hr)) {
                self.err_flag = true;
                return null;
            }
            if ((stream_flags & mf.MF_SOURCE_READERF_ENDOFSTREAM) != 0) return null; // clean EOS
            const s = sample orelse continue;
            defer _ = s.Release();

            // Flatten into one contiguous block and lock it.
            var media_buffer: ?*mf.IMFMediaBuffer = null;
            if (com.FAILED(s.ConvertToContiguousBuffer(&media_buffer)) or media_buffer == null) {
                self.err_flag = true;
                return null;
            }
            const mb = media_buffer.?;
            defer _ = mb.Release();

            var data: ?[*]u8 = null;
            var cur_len: com.DWORD = 0;
            if (com.FAILED(mb.Lock(&data, null, &cur_len)) or data == null) {
                self.err_flag = true;
                return null;
            }

            const channels: i32 = if (self.audio_channels > 0) self.audio_channels else 1;
            const float_count: usize = cur_len / @sizeOf(f32);

            // Copy into scratch so the borrowed pointer outlives the locked
            // buffer (unlocked before we return).
            self.audio_scratch.resize(self.allocator, float_count) catch {
                _ = mb.Unlock();
                self.err_flag = true;
                return null;
            };
            const src: [*]const f32 = @ptrCast(@alignCast(data.?));
            @memcpy(self.audio_scratch.items[0..float_count], src[0..float_count]);
            _ = mb.Unlock();

            const frame_count: i32 = @intCast(float_count / @as(usize, @intCast(channels)));

            return .{
                .pts_seconds = ticksToSeconds(timestamp),
                .samples = self.audio_scratch.items[0..float_count],
                .frame_count = frame_count,
                .channel_count = channels,
                .sample_rate = self.audio_rate,
            };
        }
    }

    // ---- vtable thunks ----
    fn vtOpen(p: *anyopaque, url_or_path: []const u8) bool {
        return fromPtr(p).openImpl(url_or_path);
    }
    fn vtClose(p: *anyopaque) void {
        fromPtr(p).closeImpl();
    }
    fn vtDeinit(p: *anyopaque) void {
        const self = fromPtr(p);
        self.closeImpl();
        const allocator = self.allocator;
        self.audio_tracks.deinit(allocator);
        self.audio_stream_indices.deinit(allocator);
        self.owned_strings.deinit(allocator);
        self.audio_scratch.deinit(allocator);
        allocator.destroy(self);
    }
    fn vtDuration(p: *anyopaque) f64 {
        return fromPtr(p).duration;
    }
    fn vtWidth(p: *anyopaque) i32 {
        return fromPtr(p).width;
    }
    fn vtHeight(p: *anyopaque) i32 {
        return fromPtr(p).height;
    }
    fn vtAudioChannels(p: *anyopaque) i32 {
        return fromPtr(p).audio_channels;
    }
    fn vtAudioRate(p: *anyopaque) i32 {
        return fromPtr(p).audio_rate;
    }
    fn vtColorimetry(p: *anyopaque) core.Colorimetry {
        return fromPtr(p).color;
    }
    fn vtAudioTrackCount(p: *anyopaque) i32 {
        return @intCast(fromPtr(p).audio_tracks.items.len);
    }
    fn vtAudioTrackInfo(p: *anyopaque, index: i32) core.AudioTrackInfo {
        const self = fromPtr(p);
        if (index < 0 or index >= @as(i32, @intCast(self.audio_tracks.items.len))) return .{};
        return self.audio_tracks.items[@intCast(index)];
    }
    fn vtSelectAudioTrack(p: *anyopaque, index: i32) void {
        fromPtr(p).selectAudioTrackImpl(index);
    }
    fn vtReselectAudioTrack(p: *anyopaque, index: i32, pts_seconds: f64) bool {
        return fromPtr(p).reselectAudioTrackImpl(index, pts_seconds);
    }
    fn vtSeek(p: *anyopaque, pts_seconds: f64) bool {
        return fromPtr(p).seekImpl(pts_seconds);
    }
    fn vtNextVideoFrame(p: *anyopaque) ?core.VideoFrame {
        return fromPtr(p).nextVideoFrameImpl();
    }
    fn vtNextAudioChunk(p: *anyopaque) ?core.AudioChunk {
        return fromPtr(p).nextAudioChunkImpl();
    }
};

/// Construct a Media Foundation backend and return it as the core.Backend
/// ptr+vtable interface. The returned Backend owns its heap allocation; the COM
/// / MF / D3D11 pipeline is created lazily in open() and torn down in close().
/// Backend.deinit() closes and frees everything.
pub fn create(allocator: std.mem.Allocator) !core.Backend {
    const self = try allocator.create(MfBackend);
    self.* = .{ .allocator = allocator };
    return .{ .ptr = self, .vtable = &MfBackend.vtable };
}
