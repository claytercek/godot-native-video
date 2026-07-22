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
//! This file owns policy only, exactly as avf_backend.zig does: the reader
//! state machine, track selection/clamping, EOS/error interpretation, and the
//! translation of MF results into VideoFrame / AudioChunk. The COM/D3D object
//! graph (device, DXGI manager, source readers) lives behind `pipeline.MfPipeline`,
//! composed in as a field — the Windows counterpart to AVF's C-ABI shim. Zig
//! splits a struct across files by composition, not by scattering one struct's
//! methods; that seam is what keeps this core small. The pure colorimetry /
//! time-base parsers live in colorimetry.zig. Policy decisions (bit-depth
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

const pipe = @import("pipeline.zig");
const colorimetry = @import("colorimetry.zig");

const log = std.log.scoped(.mf_backend);

// ---------------------------------------------------------------------------
// MfBackend — the concrete implementation behind the Backend vtable.
// ---------------------------------------------------------------------------
pub const MfBackend = struct {
    allocator: std.mem.Allocator,

    // The COM/D3D object graph: device, DXGI manager, shared reader, optional
    // dedicated audio-only reader. Created per open(), torn down in close().
    pipeline: pipe.MfPipeline = .{},

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

    // ---- open-time stream configuration (policy) ----

    // Scan every stream: pick the first video stream (reading colorimetry + bit
    // depth off its NATIVE type), and collect audio-track metadata. Then
    // reorder audio tracks to container order, negotiate the video output
    // subtype matched to bit depth (P010 with NV12 fallback), and read back
    // frame dimensions. Returns false when there is no usable video stream (the
    // caller decides whether that's fatal).
    fn configureVideoStream(self: *MfBackend) !bool {
        const reader = self.pipeline.reader.?;
        var i: com.DWORD = 0;
        while (true) : (i += 1) {
            var native: ?*mf.IMFMediaType = null;
            const hr = reader.GetNativeMediaType(i, 0, &native);
            if (hr == com.MF_E_INVALIDSTREAMNUMBER) break; // no more streams
            if (com.FAILED(hr) or native == null) continue;
            const nt = native.?;
            defer com.release(nt);

            var major: com.GUID = std.mem.zeroes(com.GUID);
            _ = nt.asAttributes().GetGUID(&mf.MF_MT_MAJOR_TYPE, &major);

            if (std.meta.eql(major, mf.MFMediaType_Video) and self.video_stream_index < 0) {
                self.video_stream_index = @intCast(i);
                // Colorimetry + bit depth live on the native (pre-conversion)
                // type; the NV12/P010 output type does not carry them forward.
                self.readColorimetry(nt);
                self.color.bit_depth = colorimetry.detectBitDepth(nt);
            } else if (std.meta.eql(major, mf.MFMediaType_Audio)) {
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
        var ok = self.pipeline.requestSubtype(vidx, if (self.color.bit_depth >= 10) mf.MFVideoFormat_P010 else mf.MFVideoFormat_NV12);
        if (!ok and self.color.bit_depth >= 10) {
            self.color.bit_depth = 8;
            ok = self.pipeline.requestSubtype(vidx, mf.MFVideoFormat_NV12);
        }
        if (!ok) return false;

        _ = reader.SetStreamSelection(vidx, com.TRUE);

        var current: ?*mf.IMFMediaType = null;
        if (com.SUCCEEDED(reader.GetCurrentMediaType(vidx, &current)) and current != null) {
            defer com.release(current.?);
            var w: u32 = 0;
            var h: u32 = 0;
            if (com.SUCCEEDED(current.?.asAttributes().getFrameSize(&w, &h))) {
                self.width = @intCast(w);
                self.height = @intCast(h);
            }
        }
        return true;
    }

    // Read colorimetry attributes off a video media type. Absent attributes
    // leave the existing default untouched.
    fn readColorimetry(self: *MfBackend, t: *mf.IMFMediaType) void {
        const attrs = t.asAttributes();
        var val: u32 = 0;
        if (com.SUCCEEDED(attrs.GetUINT32(&mf.MF_MT_YUV_MATRIX, &val))) self.color.matrix = colorimetry.parseMatrix(val);
        if (com.SUCCEEDED(attrs.GetUINT32(&mf.MF_MT_VIDEO_PRIMARIES, &val))) self.color.primaries = colorimetry.parsePrimaries(val);
        if (com.SUCCEEDED(attrs.GetUINT32(&mf.MF_MT_TRANSFER_FUNCTION, &val))) self.color.transfer = colorimetry.parseTransfer(val);
        if (com.SUCCEEDED(attrs.GetUINT32(&mf.MF_MT_VIDEO_NOMINAL_RANGE, &val))) self.color.range = colorimetry.parseRange(val);
    }

    // Configure the open-time audio stream to float32 PCM. Non-fatal: on
    // failure, audio is simply left unselected (silent clip / audio-less pump).
    fn configureAudioStream(self: *MfBackend) void {
        if (self.audio_stream_index < 0) return;
        const aidx: com.DWORD = @intCast(self.audio_stream_index);
        if (pipe.configurePcmOutput(self.pipeline.reader.?, aidx)) |fmt| {
            self.audio_channels = fmt.channels;
            self.audio_rate = fmt.rate;
        } else {
            self.audio_stream_index = -1;
        }
    }

    // Read total duration from the presentation descriptor (100ns -> seconds).
    fn readDuration(self: *MfBackend) void {
        var pv = com.PROPVARIANT.zeroed();
        const hr = self.pipeline.reader.?.GetPresentationAttribute(mf.MF_SOURCE_READER_MEDIASOURCE, &mf.MF_PD_DURATION, &pv);
        if (com.SUCCEEDED(hr) and pv.vt == com.VT_UI8) {
            self.duration = colorimetry.ticksToSeconds(@intCast(pv.val.uhVal));
        }
        _ = com.PropVariantClear(&pv);
    }

    // Read a wide-string stream-descriptor attribute (MF_SD_LANGUAGE /
    // MF_SD_STREAM_NAME) and return it as newly-allocated UTF-8, or null if
    // absent/empty. Caller owns the returned slice.
    fn readStreamString(self: *MfBackend, stream_index: com.DWORD, guid: *const com.GUID) !?[]u8 {
        var pv = com.PROPVARIANT.zeroed();
        const hr = self.pipeline.reader.?.GetPresentationAttribute(stream_index, guid, &pv);
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

    // ---- audio track selection (policy) ----

    // Clamp `index` to the valid track range, record it as the selected track,
    // and refresh audio_channels/audio_rate from the cached track table. Callers
    // must guarantee at least one audio track exists. Returns the clamped index.
    // The single home for the clamp + metadata refresh, shared by select and
    // reselect so the two stay symmetric (mirrors avf_backend.zig).
    fn applyTrackSelection(self: *MfBackend, index: i32) i32 {
        const count: i32 = @intCast(self.audio_tracks.items.len);
        const clamped = std.math.clamp(index, 0, count - 1);
        self.selected_audio_track = clamped;
        const meta = self.audio_tracks.items[@intCast(clamped)];
        self.audio_channels = meta.channels;
        self.audio_rate = meta.sample_rate;
        return clamped;
    }

    // Select track_index on the shared reader and renegotiate PCM, deselecting
    // the old audio stream only once the new one is known-good. This IS the
    // application of a selection, so selected and applied both converge here.
    //
    // Select-then-negotiate happens entirely on the new stream before the old
    // one is touched, mirroring the build-then-swap pattern buildAudioReader
    // uses for the dedicated reader: on failure, the old stream's selection
    // and media type are exactly as they were before the call, so audio keeps
    // playing on the old track. configurePcmOutput selects `aidx` as a side
    // effect regardless of outcome, so a failed negotiation still needs the
    // new stream explicitly deselected again.
    fn switchAudioTrack(self: *MfBackend, track_index: i32) bool {
        if (track_index < 0 or track_index >= @as(i32, @intCast(self.audio_stream_indices.items.len))) return false;

        const new_mf_index = self.audio_stream_indices.items[@intCast(track_index)];
        const aidx: com.DWORD = @intCast(new_mf_index);

        const fmt = pipe.configurePcmOutput(self.pipeline.reader.?, aidx) orelse {
            _ = self.pipeline.reader.?.SetStreamSelection(aidx, com.FALSE);
            return false;
        };

        // Known-good: retire the old stream now, then commit.
        if (self.audio_stream_index >= 0 and self.audio_stream_index != new_mf_index) {
            _ = self.pipeline.reader.?.SetStreamSelection(@intCast(self.audio_stream_index), com.FALSE);
        }
        self.audio_stream_index = new_mf_index;
        _ = self.applyTrackSelection(track_index);
        self.audio_channels = fmt.channels;
        self.audio_rate = fmt.rate;
        self.applied_audio_track = track_index;
        return true;
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

        try com.check(mf.MFStartup(mf.MF_VERSION, mf.MFSTARTUP_LITE));
        self.mf_started = true;

        self.path16 = try std.unicode.utf8ToUtf16LeAllocZ(self.allocator, url_or_path);

        try self.pipeline.createDevice();
        try self.pipeline.createReader(self.path16.?);

        // Deselect all streams, then enable just the ones we configure.
        _ = self.pipeline.reader.?.SetStreamSelection(mf.MF_SOURCE_READER_ALL_STREAMS, com.FALSE);

        const has_video = try self.configureVideoStream();
        // Match AVF: fail only if there is neither audio nor video.
        if (!has_video and self.audio_stream_index < 0) return error.NoStreams;

        self.configureAudioStream();
        self.readDuration();
    }

    fn closeImpl(self: *MfBackend) void {
        // Release the COM object graph (readers before device), then MF then COM
        // — mirrors the C++ Impl::teardown order.
        self.pipeline.teardown();
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
    }

    fn seekImpl(self: *MfBackend, pts_seconds: f64) bool {
        if (self.pipeline.reader == null) return false;
        const target = @max(pts_seconds, 0.0);

        // Tear down any dedicated audio-only reader and re-home audio on the
        // shared reader.
        const audio_reader_torn = self.pipeline.audio_reader != null;
        if (audio_reader_torn) self.pipeline.resetAudioReader();
        // Catch the shared reader up to a pending selectAudioTrack(), and/or
        // re-home audio after a dedicated reselect reader. Safe here because
        // SetCurrentPosition below restarts the media source, which is what
        // makes a newly (re)selected stream actually deliver samples.
        if (audio_reader_torn or self.applied_audio_track != self.selected_audio_track) {
            _ = self.switchAudioTrack(self.selected_audio_track);
        }

        var pos = com.initPropVariantFromInt64(colorimetry.secondsToTicks(target));
        const hr = self.pipeline.reader.?.SetCurrentPosition(&mf.GUID_NULL, &pos);
        _ = com.PropVariantClear(&pos);
        return com.SUCCEEDED(hr);
    }

    fn selectAudioTrackImpl(self: *MfBackend, index: i32) void {
        if (self.audio_tracks.items.len == 0) return;
        // Selection takes effect on the next seek()/open(); applyTrackSelection
        // updates channel/rate metadata immediately so a caller inspecting them
        // pre-playback sees the selected track's format.
        _ = self.applyTrackSelection(index);
    }

    fn reselectAudioTrackImpl(self: *MfBackend, index: i32, pts_seconds: f64) bool {
        if (self.audio_tracks.items.len == 0) return false;
        const clamped = self.applyTrackSelection(index);
        const target = @max(pts_seconds, 0.0);
        const mf_index = self.audio_stream_indices.items[@intCast(clamped)];

        // Dedicated audio-only reader for the new track, primed at target, while
        // the shared reader keeps decoding video from its current position. The
        // pipeline builds it into a local and swaps only on success, so a
        // failure here leaves any existing dedicated reader intact.
        if (!self.pipeline.buildAudioReader(self.path16.?, mf_index, colorimetry.secondsToTicks(target))) return false;

        // Stop the shared reader from queueing the old track's audio.
        if (self.audio_stream_index >= 0) {
            _ = self.pipeline.reader.?.SetStreamSelection(@intCast(self.audio_stream_index), com.FALSE);
        }
        self.audio_stream_index = mf_index;
        self.applied_audio_track = clamped;
        return true;
    }

    fn nextVideoFrameImpl(self: *MfBackend) ?core.VideoFrame {
        if (self.pipeline.reader == null or self.video_stream_index < 0) return null;
        const vidx: com.DWORD = @intCast(self.video_stream_index);

        while (true) {
            var stream_flags: com.DWORD = 0;
            var timestamp: mf.LONGLONG = 0;
            var sample: ?*mf.IMFSample = null;
            const hr = self.pipeline.reader.?.ReadSample(vidx, 0, null, &stream_flags, &timestamp, &sample);
            if (com.FAILED(hr)) return null;
            if ((stream_flags & mf.MF_SOURCE_READERF_ENDOFSTREAM) != 0) return null; // clean EOS
            // No sample this call (stream tick / native-type change): loop.
            // Known limitation preserved from the C++: a mid-stream native type
            // change does not re-probe colorimetry.
            const s = sample orelse continue;
            defer com.release(s);

            var media_buffer: ?*mf.IMFMediaBuffer = null;
            if (com.FAILED(s.GetBufferByIndex(0, &media_buffer)) or media_buffer == null) return null;
            const mb = media_buffer.?;
            defer com.release(mb);

            const dxgi_buffer = com.queryInterface(mf.IMFDXGIBuffer, mb) orelse {
                // Not a D3D11-backed sample — the DXGI device manager wasn't honored.
                return null;
            };
            defer com.release(dxgi_buffer);

            // GetResource returns a +1 reference we adopt into native_handle.
            var raw: ?*anyopaque = null;
            if (com.FAILED(dxgi_buffer.GetResource(&d3d11.ID3D11Texture2D.IID, &raw)) or raw == null) return null;
            const tex: *d3d11.ID3D11Texture2D = @ptrCast(@alignCast(raw.?));

            // The decoder packs frames as slices of one texture array; the
            // subresource index tells the importer which slice this frame is.
            var subresource: com.UINT = 0;
            _ = dxgi_buffer.GetSubresourceIndex(&subresource);

            return .{
                .pts_seconds = colorimetry.ticksToSeconds(timestamp),
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
            com.release(tex);
        }
    }

    fn nextAudioChunkImpl(self: *MfBackend) ?core.AudioChunk {
        if (self.pipeline.reader == null) return null;
        // When a dedicated audio-only reader is active (from reselect), read
        // from it at its OWN stored stream index; otherwise read the shared
        // reader at the shared audio stream index.
        var active: *mf.IMFSourceReader = undefined;
        var aidx: com.DWORD = undefined;
        if (self.pipeline.audio_reader) |ar| {
            active = ar;
            aidx = @intCast(self.pipeline.audio_reader_stream_index);
        } else {
            if (self.audio_stream_index < 0) return null;
            active = self.pipeline.reader.?;
            aidx = @intCast(self.audio_stream_index);
        }

        while (true) {
            var stream_flags: com.DWORD = 0;
            var timestamp: mf.LONGLONG = 0;
            var sample: ?*mf.IMFSample = null;
            const hr = active.ReadSample(aidx, 0, null, &stream_flags, &timestamp, &sample);
            if (com.FAILED(hr)) return null;
            if ((stream_flags & mf.MF_SOURCE_READERF_ENDOFSTREAM) != 0) return null; // clean EOS
            const s = sample orelse continue;
            defer com.release(s);

            // Flatten into one contiguous block and lock it.
            var media_buffer: ?*mf.IMFMediaBuffer = null;
            if (com.FAILED(s.ConvertToContiguousBuffer(&media_buffer)) or media_buffer == null) return null;
            const mb = media_buffer.?;
            defer com.release(mb);

            var data: ?[*]u8 = null;
            var cur_len: com.DWORD = 0;
            if (com.FAILED(mb.Lock(&data, null, &cur_len)) or data == null) return null;

            const channels: i32 = if (self.audio_channels > 0) self.audio_channels else 1;
            const float_count: usize = cur_len / @sizeOf(f32);

            // Copy into scratch so the borrowed pointer outlives the locked
            // buffer (unlocked before we return).
            self.audio_scratch.resize(self.allocator, float_count) catch {
                _ = mb.Unlock();
                return null;
            };
            const src: [*]const f32 = @ptrCast(@alignCast(data.?));
            @memcpy(self.audio_scratch.items[0..float_count], src[0..float_count]);
            _ = mb.Unlock();

            const frame_count: i32 = @intCast(float_count / @as(usize, @intCast(channels)));

            return .{
                .pts_seconds = colorimetry.ticksToSeconds(timestamp),
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
