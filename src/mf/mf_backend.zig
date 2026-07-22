//! mf_backend.zig — Media Foundation Decoder-mode Backend (Windows).
//!
//! The Windows analog of avf::AvfBackend. Drives an IMFSourceReader bound to an
//! IMFDXGIDeviceManager as a pure hardware decoder: video decodes straight into
//! D3D11 textures (DXGI_FORMAT_NV12 for 8-bit sources, DXGI_FORMAT_P010 for
//! 10-bit HEVC Main10), audio into interleaved float32 PCM. Every decoded frame
//! is snapshotted out of the decoder's recycled sample pool into a frame-owned
//! ID3D11Texture2D handed out as the native surface, whose single +1 reference
//! is released via VideoFrame.release. No Godot / RenderingDevice symbols appear
//! here — this is a decode pump only.
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
//!  - Video frames: the pooled decoder slice is copied into a fresh, frame-owned
//!    single-slice ID3D11Texture2D adopted into native_handle; the release hook
//!    Releases that copy exactly once. The pooled sample/texture is released as
//!    soon as the copy is enqueued, so the decoder is free to recycle it — the
//!    frame's content is immutable no matter what the pool does behind it.
//!  - Audio samples: copied into backend-owned scratch, valid until the next
//!    nextAudioChunk()/close() — the AudioChunk slice borrows it.
//!  - AudioTrackInfo strings: normalized/duplicated into backend-owned storage
//!    at open, freed at close; slices stay valid until close().
//!
//! COM/MF lifecycle is per-open(), but the COM apartment is NOT the caller's.
//! Godot's D3D12 renderer runs the engine main thread — our open()/close()
//! caller — in an STA, where CoInitializeEx(MTA) fails (RPC_E_CHANGED_MODE) and
//! MFCreateSourceReaderFromURL then fails intermittently. So the backend owns a
//! ComExecutor: a dedicated thread it puts in the MTA and marshals the whole
//! COM open (MFStartup + device/reader creation + stream configuration) and the
//! whole COM teardown (object release + MFShutdown) onto. CoInitializeEx and its
//! paired CoUninitialize stay on that one thread; the thread lives from open()
//! to close(), anchoring the process MTA for the reader's decode-time lifetime.
//! The scheduler still pumps ReadSample off-thread on its workers — a sync
//! source reader has no single-thread affinity, and the anchored MTA keeps the
//! reader a true free-threaded object. open()/close() still return synchronously
//! to their caller: the caller blocks on the executor job.

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
const ComExecutor = @import("com_executor.zig").ComExecutor;

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

    // Display-aperture crop within the decoder's (possibly macroblock-aligned)
    // backing texture, read at open time alongside width/height -- see
    // configureVideoStream's aperture read and CropRect's doc comment.
    crop: core.CropRect = .{},

    // The dedicated MTA thread every COM object of this backend is created and
    // torn down on. Started in open(), stopped in close(). See the module doc.
    executor: ComExecutor = .{},
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
            self.readDisplayAperture(current.?);
        }
        return true;
    }

    // Read the display/clean aperture off the video stream's CURRENT media
    // type: MF_MT_MINIMUM_DISPLAY_APERTURE first (what H.264/HEVC decoders
    // actually populate for non-mod-16 content), MF_MT_GEOMETRIC_APERTURE as
    // a fallback, and -- when neither attribute is present -- the full
    // negotiated frame (self.width/self.height, already read from
    // MF_MT_FRAME_SIZE), which is the correct crop for a decoder that never
    // pads its backing texture. A negative aperture offset is defensively
    // clamped to 0 (never observed in practice; MF decoders report whole-
    // frame, non-negative apertures).
    fn readDisplayAperture(self: *MfBackend, t: *mf.IMFMediaType) void {
        const attrs = t.asAttributes();
        const area = attrs.getVideoArea(&mf.MF_MT_MINIMUM_DISPLAY_APERTURE) orelse
            attrs.getVideoArea(&mf.MF_MT_GEOMETRIC_APERTURE) orelse {
                self.crop = .{
                    .x = 0,
                    .y = 0,
                    .width = @intCast(self.width),
                    .height = @intCast(self.height),
                };
                return;
            };
        self.crop = .{
            .x = if (area.offset_x > 0) @intCast(area.offset_x) else 0,
            .y = if (area.offset_y > 0) @intCast(area.offset_y) else 0,
            .width = if (area.width > 0) @intCast(area.width) else @intCast(self.width),
            .height = if (area.height > 0) @intCast(area.height) else @intCast(self.height),
        };
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
            if (self.trackIndexForStream(self.audio_stream_index)) |ti| {
                logAudioNegotiation(ti, self.audio_tracks.items[@intCast(ti)], fmt);
            }
        } else {
            self.audio_stream_index = -1;
        }
    }

    // Map an MF source-reader stream index back to its position in
    // audio_tracks (built in container order by reorderAudioTracksByContainerOrder).
    // Used only for divergence logging, where the declared native-descriptor
    // values live.
    fn trackIndexForStream(self: *MfBackend, mf_stream_index: i32) ?i32 {
        for (self.audio_stream_indices.items, 0..) |idx, i| {
            if (idx == mf_stream_index) return @intCast(i);
        }
        return null;
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
        logAudioNegotiation(track_index, self.audio_tracks.items[@intCast(track_index)], fmt);
        self.applied_audio_track = track_index;
        return true;
    }

    // ---- lifecycle ----

    // A COM open dispatched onto the executor thread. Carries the source path in
    // and the outcome out (`err == null` means success).
    const OpenJob = struct {
        self: *MfBackend,
        url_or_path: []const u8,
        err: ?anyerror = null,

        fn thunk(p: *anyopaque) void {
            const job: *OpenJob = @ptrCast(@alignCast(p));
            job.self.openInner(job.url_or_path) catch |e| {
                job.err = e;
            };
        }
    };

    fn openImpl(self: *MfBackend, url_or_path: []const u8) bool {
        // The sole reset-to-closed point before opening (also tears down any
        // prior executor so open() always starts a fresh apartment thread).
        self.closeImpl();

        // Godot's D3D12 renderer runs this (main) thread in an STA, where the MF
        // source reader can't be created reliably. Run the whole COM open on our
        // own MTA thread and block until it finishes, so open() stays
        // synchronous and its failures still surface to the caller.
        self.executor.start() catch |e| {
            log.err("open failed: {s}", .{@errorName(e)});
            return false;
        };
        var job: OpenJob = .{ .self = self, .url_or_path = url_or_path };
        self.executor.run(OpenJob.thunk, &job);
        if (job.err) |e| {
            // log.err, not log.debug: this must survive the default ReleaseFast
            // log-level filter, or open failures are invisible in release builds.
            log.err("open failed: {s}", .{@errorName(e)});
            self.closeImpl();
            return false;
        }
        return true;
    }

    // Runs on the executor's MTA thread (see openImpl). The COM apartment is
    // owned by that thread — CoInitializeEx is not called here — so this only
    // brings up the MF platform and builds the reader.
    fn openInner(self: *MfBackend, url_or_path: []const u8) !void {
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

    // Runs on the executor's MTA thread (see closeImpl): release the COM object
    // graph (readers before device, via pipeline.teardown), then shut down the
    // MF platform — mirrors the C++ Impl::teardown order. The apartment itself
    // (CoUninitialize) is retired by the executor when it stops.
    fn closeComThunk(p: *anyopaque) void {
        const self: *MfBackend = @ptrCast(@alignCast(p));
        self.pipeline.teardown();
        if (self.mf_started) {
            _ = mf.MFShutdown();
            self.mf_started = false;
        }
    }

    fn closeImpl(self: *MfBackend) void {
        // Tear the COM object graph + MF platform down on the SAME MTA thread
        // that built them, then stop that thread (its CoUninitialize pairs the
        // CoInitializeEx it made when it started). Every COM object this backend
        // owns — the shared reader/device built in openInner and the dedicated
        // audio reader built in buildAudioReader — is created only inside an
        // executor job, so there is nothing to release when the executor was
        // never started.
        if (self.executor.isRunning()) {
            self.executor.run(closeComThunk, self);
            self.executor.stop();
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

    // Building the dedicated audio reader dispatched onto the executor thread —
    // it calls MFCreateSourceReaderFromURL, which (like the shared reader in
    // openInner) must run in our MTA, not on the STA main thread reselect is
    // driven from. Carries the target stream/position in and the outcome out.
    const BuildAudioReaderJob = struct {
        self: *MfBackend,
        mf_index: i32,
        start_ticks: i64,
        ok: bool = false,

        fn thunk(p: *anyopaque) void {
            const job: *BuildAudioReaderJob = @ptrCast(@alignCast(p));
            job.ok = job.self.pipeline.buildAudioReader(job.self.path16.?, job.mf_index, job.start_ticks);
        }
    };

    fn reselectAudioTrackImpl(self: *MfBackend, index: i32, pts_seconds: f64) bool {
        if (self.audio_tracks.items.len == 0) return false;
        const clamped = self.applyTrackSelection(index);
        const target = @max(pts_seconds, 0.0);
        const mf_index = self.audio_stream_indices.items[@intCast(clamped)];

        // Dedicated audio-only reader for the new track, primed at target, while
        // the shared reader keeps decoding video from its current position. The
        // pipeline builds it into a local and swaps only on success, so a
        // failure here leaves any existing dedicated reader intact. Construction
        // is marshaled onto the executor (MFCreateSourceReaderFromURL must run in
        // our MTA); reselect itself is driven from the STA main thread.
        //
        // Teardown (resetAudioReader -> Release) is deliberately NOT marshaled.
        // The reader is created on a real MTA thread, so it is a free-threaded
        // MTA object with no thread affinity: Release needs no cross-apartment
        // marshaling from any thread already in the MTA. Its retire paths are all
        // in-MTA — buildAudioReader's own swap (executor) and the shared reader's
        // seek (decode workers, implicit MTA). The one STA path (a scrub-settle
        // seekExact on the main thread retiring a dedicated reader) is the same
        // pre-existing STA-touches-reader residual that already applies to every
        // audio/seek call the main thread makes, not something this construction
        // fix introduces; a bare refcount decrement is the cheapest, most
        // apartment-tolerant COM call, so marshaling only it would add a hot-path
        // executor round-trip for no correctness gain.
        var job: BuildAudioReaderJob = .{ .self = self, .mf_index = mf_index, .start_ticks = colorimetry.secondsToTicks(target) };
        self.executor.run(BuildAudioReaderJob.thunk, &job);
        if (!job.ok) return false;

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

            // GetResource yields a +1 reference to the decoder's POOLED output
            // texture — an array whose slices the decoder recycles the instant
            // this frame's IMFSample is released (below), independent of any ref
            // we hold on the array itself. In H.264 decode order (B-frames) that
            // recycle overwrites the slice with a temporally-earlier frame long
            // before the present pipeline samples it, so the pooled slice must
            // NOT travel downstream. Snapshot it into a frame-owned texture now,
            // while the sample still pins the slice, and let the pool recycle.
            var raw: ?*anyopaque = null;
            if (com.FAILED(dxgi_buffer.GetResource(&d3d11.ID3D11Texture2D.IID, &raw)) or raw == null) return null;
            const pooled: *d3d11.ID3D11Texture2D = @ptrCast(@alignCast(raw.?));
            defer com.release(pooled);

            // Which array slice of the pooled texture this frame decoded into —
            // the source subresource for the snapshot copy.
            var subresource: com.UINT = 0;
            _ = dxgi_buffer.GetSubresourceIndex(&subresource);

            const owned = self.snapshotFrame(pooled, subresource) orelse return null;

            return .{
                .pts_seconds = colorimetry.ticksToSeconds(timestamp),
                .native_handle = @ptrCast(owned),
                // The snapshot is a standalone single-slice texture, so the
                // importer samples slice 0 — the pooled array index is consumed
                // here, not carried forward.
                .plane_slice = 0,
                .width = self.width,
                .height = self.height,
                // 8-bit -> NV12; 10-bit HEVC Main10 -> P010 tagged x420, the
                // same logical tag the AVF backend uses for 10-bit surfaces.
                .pixel_format = if (self.color.bit_depth >= 10) .x420 else .nv12,
                .color = self.color,
                .crop = self.crop,
                .release_hook = .{ .ctx = @ptrCast(owned), .func = frameRelease },
            };
        }
    }

    // Copy one slice of the decoder's pooled texture into a freshly-created,
    // single-slice texture this frame owns outright, so the frame's pixel
    // content is immutable for its whole queue-to-present lifetime regardless of
    // how the decoder recycles the pool behind it. Runs on the decoder's OWN
    // device+context (D3D11 resources are per-device; the device is
    // multithread-protected, so this decode-worker copy is serialized against
    // the render thread's later import copy). The copy is enqueued while the
    // caller still holds the source IMFSample, so it captures this frame's
    // content before the slice can be reused. Returns a +1 texture the caller
    // adopts into native_handle (released by frameRelease), or null on failure.
    fn snapshotFrame(self: *MfBackend, pooled: *d3d11.ID3D11Texture2D, slice: com.UINT) ?*d3d11.ID3D11Texture2D {
        const device = self.pipeline.d3d_device orelse return null;
        const context = self.pipeline.d3d_context orelse return null;

        var desc: d3d11.D3D11_TEXTURE2D_DESC = undefined;
        pooled.GetDesc(&desc);
        // A private, single-slice copy: no array, no decoder/sharing flags. Bind
        // as a shader resource (the same NV12/P010 + SHADER_RESOURCE combo the
        // importers create their intermediates with, so it is known-good on this
        // device) so it is a valid copy source for either import path.
        desc.ArraySize = 1;
        desc.MipLevels = 1;
        desc.Usage = d3d11.D3D11_USAGE_DEFAULT;
        desc.BindFlags = d3d11.D3D11_BIND_SHADER_RESOURCE;
        desc.CPUAccessFlags = 0;
        desc.MiscFlags = 0;

        var out: ?*d3d11.ID3D11Texture2D = null;
        if (com.FAILED(device.CreateTexture2D(&desc, null, &out)) or out == null) return null;
        context.CopySubresourceRegion(out.?.asResource(), 0, 0, 0, 0, pooled.asResource(), slice, null);
        return out.?;
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

// Diagnostic: compare a just-negotiated PCM format against the track's
// declared (pre-negotiation, native-descriptor) values and log the result.
// CanonicalMixFormat (canonical_mix_format.zig) derives the AudioMasterClock
// / ring sizing / _getMixRate() rate from the declared values, NOT from what
// PCM negotiation actually delivers here, so a mismatch means audio can play
// at the wrong speed. Diagnostic only -- no behavior change.
fn logAudioNegotiation(track_index: i32, declared: core.AudioTrackInfo, fmt: pipe.PcmFormat) void {
    if (declared.sample_rate != fmt.rate or declared.channels != fmt.channels) {
        log.warn(
            "audio track {d}: negotiated PCM format diverges from declared -- declared {d} Hz/{d} ch, pcm {d} Hz/{d} ch",
            .{ track_index, declared.sample_rate, declared.channels, fmt.rate, fmt.channels },
        );
    }
    log.info(
        "audio negotiated: declared {d} Hz/{d} ch -> pcm {d} Hz/{d} ch",
        .{ declared.sample_rate, declared.channels, fmt.rate, fmt.channels },
    );
}

/// Construct a Media Foundation backend and return it as the core.Backend
/// ptr+vtable interface. The returned Backend owns its heap allocation; the COM
/// / MF / D3D11 pipeline is created lazily in open() and torn down in close().
/// Backend.deinit() closes and frees everything.
pub fn create(allocator: std.mem.Allocator) !core.Backend {
    const self = try allocator.create(MfBackend);
    self.* = .{ .allocator = allocator };
    return .{ .ptr = self, .vtable = &MfBackend.vtable };
}

// Hash the Y-plane bytes of an NV12/P010 decoder texture via a staging readback,
// so a queued frame's pixel content can be compared before and after further
// decoding. Returns null if the device/readback is unavailable.
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

    // Hash the Y plane row by row (RowPitch may exceed the tight row width).
    const base: [*]const u8 = @ptrCast(mapped.pData.?);
    const row_bytes: usize = if (desc.Format == win.dxgi.DXGI_FORMAT_P010) @as(usize, desc.Width) * 2 else desc.Width;
    var hasher = std.hash.Wyhash.init(0);
    var y: usize = 0;
    while (y < desc.Height) : (y += 1) {
        hasher.update(base[y * mapped.RowPitch ..][0..row_bytes]);
    }
    return hasher.final();
}

// A real-decode test skips -- never fails -- when its fixture asset is absent
// (the CI runners don't carry the generated media). Probe the file up front:
// backend.open() logs an error on failure, and a single logged error fails the
// whole `zig build test` step, so a missing-asset skip must return before ever
// reaching open().
fn skipUnlessFixture(path: []const u8) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.Dir.cwd().access(io, path, .{}) catch return error.SkipZigTest;
}

// Regression guard for the decode-order overwrite bug: a queued VideoFrame must
// keep its OWN immutable pixel content no matter how much the decoder recycles
// its sample pool afterward. On a B-frame clip (decode order != display order)
// the decoder reuses the pooled texture slice as soon as the sample is released,
// so before the snapshot fix the first frame's pixels turned into a
// later-decoded frame's the moment the pump ran ahead. We decode the first
// frame, fingerprint it, pump several more frames (past the pool depth) to force
// recycling, then re-fingerprint the first frame and require it unchanged.
//
// Needs a hardware MF/D3D11 decode path and the bframes.mp4 asset; skips (never
// fails) when either is absent, matching the win.zig device round-trip test.
test "queued video frame content survives later decoding (no pool recycle)" {
    const t = std.testing;
    // Resolved relative to the repo root, where `zig build test` runs the binary.
    try skipUnlessFixture("project/bframes.mp4");

    const backend = create(t.allocator) catch return error.SkipZigTest;
    defer backend.deinit();

    if (!backend.open("project/bframes.mp4")) return error.SkipZigTest;

    var frames: std.ArrayList(core.VideoFrame) = .empty;
    defer {
        for (frames.items) |f| f.release();
        frames.deinit(t.allocator);
    }

    const first = backend.nextVideoFrame() orelse return error.SkipZigTest;
    try frames.append(t.allocator, first);
    // The snapshot is a standalone single-slice texture -> slice 0.
    try t.expectEqual(@as(u32, 0), first.plane_slice);

    const first_tex: *d3d11.ID3D11Texture2D = @ptrCast(@alignCast(first.native_handle.?));
    const before = hashFrameTexture(first_tex) orelse return error.SkipZigTest;

    // Pump well past requiredPoolDepth so the decoder is forced to recycle the
    // slice the first frame originally decoded into.
    var pumped: usize = 0;
    while (pumped < 14) : (pumped += 1) {
        const f = backend.nextVideoFrame() orelse break;
        try frames.append(t.allocator, f);
    }
    // Meaningful only if we actually decoded ahead of the first frame.
    if (frames.items.len < 3) return error.SkipZigTest;

    const after = hashFrameTexture(first_tex) orelse return error.SkipZigTest;
    try t.expectEqual(before, after);
}

// Regression guard for the H.264 clean/display-aperture defect: MF's hardware
// decoder MFTs allocate their backing D3D11 texture macroblock-aligned (width
// rounded up to a multiple of 16), independent of the container's declared
// display size. A non-mod-16-width clip (854, not a multiple of 16) makes the
// two diverge -- the decoder's backing texture is 864 wide while the frame's
// declared/crop width stays 854 -- so a regression that lets the aligned
// texture leak through as the display size fails this assertion outright.
// Needs a hardware MF/D3D11 decode path and the generated non-mod-16 fixture
// (tools/gen_stress_media.sh); skips (never fails) when either is
// unavailable, matching the other real-decode tests in this file.
test "video frame crop tracks the display aperture, not the macroblock-aligned decoder texture" {
    const t = std.testing;
    try skipUnlessFixture("tests/fixtures/stress/nonmod16_854x480.mp4");

    const backend = create(t.allocator) catch return error.SkipZigTest;
    defer backend.deinit();

    if (!backend.open("tests/fixtures/stress/nonmod16_854x480.mp4")) return error.SkipZigTest;

    const frame = backend.nextVideoFrame() orelse return error.SkipZigTest;
    defer frame.release();

    const tex: *d3d11.ID3D11Texture2D = @ptrCast(@alignCast(frame.native_handle.?));
    var desc: d3d11.D3D11_TEXTURE2D_DESC = undefined;
    tex.GetDesc(&desc);

    // The decoder's backing texture is macroblock-aligned...
    try t.expectEqual(@as(com.UINT, 864), desc.Width);
    // ...but the frame's declared size and crop rect both report the true
    // display width, not the padded texture width.
    try t.expectEqual(@as(i32, 854), frame.width);
    try t.expectEqual(@as(u32, 854), frame.crop.width);
    try t.expectEqual(@as(u32, 0), frame.crop.x);
}
