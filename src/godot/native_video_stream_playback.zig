//! native_video_stream_playback.zig — the Binding's VideoStreamPlayback.
//!
//! Adapts the Godot-independent Engine Core (core.PlaybackController) to
//! Godot's VideoStreamPlayback so a stock VideoStreamPlayer can play a
//! native clip.
//! Holds no playback logic of its own — every state machine lives in the
//! Godot-free PlaybackController. This class is exactly the translation layer:
//! Godot type conversion, a MixSink implementation wrapping mixAudio(), and
//! present-pipeline plumbing (the zero-copy GPU present + _getTexture()).
//!
//! _update() calls controller.tick(), which returns the frame to present (if
//! any) BY VALUE; this class performs the GPU present via PresentPipeline and
//! owns the frame's release() from there via the retire ring.
//!
//! Virtual method int params/returns use their natural width (i32 for
//! index/channels/mix-rate): gdzig's vtable ptrcall marshalling reads/writes
//! the full 8-byte engine slot regardless of the declared Zig width. Floats
//! stay f64 — that IS the natural Godot width. The output_mode property
//! accessors below are NOT virtuals — they're addProperty-registered methods
//! dispatched through Variant, which only supports i64 for integers — so
//! they stay i64.

const NativeVideoStreamPlayback = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const godot = @import("godot");
const Registry = godot.extension.Registry;
const VideoStreamPlayback = godot.class.VideoStreamPlayback;
const Texture2d = godot.class.Texture2d;
const AudioServer = godot.class.AudioServer;
const Engine = godot.class.Engine;
const SceneTree = godot.class.SceneTree;
const Callable = godot.builtin.Callable;
const ProjectSettings = godot.class.ProjectSettings;
const String = godot.builtin.String;
const Dictionary = godot.builtin.Dictionary;
const PackedFloat32Array = godot.builtin.PackedFloat32Array;
const Variant = godot.builtin.Variant;

// Each backend exposes `create(allocator) !Backend`. build.zig wires only
// the target's named import; unsupported platforms fail explicitly.
const platform_backend = switch (builtin.os.tag) {
    .windows => @import("mf"),
    .linux => @import("gst"),
    .macos, .ios => @import("avf"),
    else => @compileError("Native Video supports macOS, iOS, Windows, and Linux only"),
};

// Core types come through the "core" named module (build.zig-wired) so they
// match the PlaybackController's module instance. A module's root restricts
// @import, so path imports into ../core are not an option.
const core = @import("core");
const backend_mod = core.backend;
const Backend = backend_mod.Backend;
const Colorimetry = backend_mod.Colorimetry;
const pc_mod = core.playback_controller;
const PlaybackController = pc_mod.PlaybackController;
const MixSink = pc_mod.MixSink;
const WallClockMs = core.wall_clock.WallClockMs;

const present_pipeline = @import("present_pipeline.zig");
const PresentPipeline = present_pipeline.PresentPipeline;
const OutputMode = present_pipeline.OutputMode;
const extension = @import("extension.zig");
const setDict = @import("godot_dict.zig").setDict;
const object_id = @import("object_id.zig");
const preview_policy = @import("preview_presentation.zig");

const log = std.log.scoped(.native_video);

pub fn register(r: *Registry) void {
    const class = r.createClass(NativeVideoStreamPlayback, r.allocator, .auto);
    class.addMethod("get_color_info", .auto);
    class.addMethod("get_cpu_copy_count", .auto);
    class.addMethod("process_paused_preview", .auto);
    // output_mode (SDR,HDR) enum property, backed by set/get methods.
    class.addProperty("output_mode", .{
        .hint = .property_hint_enum,
        .hint_string = String.fromLatin1("SDR,HDR"),
    });
}

pub fn unregister(r: *Registry) void {
    r.removeClass(NativeVideoStreamPlayback);
}

allocator: Allocator,
base: *VideoStreamPlayback,
controller: PlaybackController,
present: PresentPipeline,
// A weak SceneTree ObjectID, never a raw callback pointer or owning reference.
// Connected only until the latest paused seek/settle has been presented.
preview_tree_id: ?object_id.ObjectId = null,
preview: preview_policy.Pending(backend_mod.VideoFrame) = .{},
preview_processing: bool = false,

// GodotMixSink scratch buffer, resized as needed, never per-tick — the seam
// costs nothing beyond the copy from the controller's plain-float scratch into
// Godot's array type. Owned here so the MixSink adapter can reach it.
mix_buffer: PackedFloat32Array,

pub fn create(allocator: *Allocator) !*NativeVideoStreamPlayback {
    const self = try allocator.create(NativeVideoStreamPlayback);
    self.* = .{
        .allocator = allocator.*,
        .base = .init(),
        .controller = .init(),
        .present = .init(allocator.*),
        .mix_buffer = .init(),
    };
    self.base.setInstance(NativeVideoStreamPlayback, self);
    return self;
}

pub fn destroy(self: *NativeVideoStreamPlayback, allocator: *Allocator) void {
    self.cancelPreviewWork();
    // Unregister from the shared pool first: this blocks until any in-flight
    // decode slice for our stream completes and releases every buffered
    // surface, so no worker can touch our Backend after this returns.
    self.controller.shutdown();
    self.present.shutdown();
    self.controller.deinit();
    self.mix_buffer.deinit();
    self.base.destroy();
    allocator.destroy(self);
}

// -----------------------------------------------------------------------
// GodotMixSink — the Binding's MixSink implementation.
//
// The one Godot API call the Engine Core's audio drive reaches through: wraps
// VideoStreamPlayback.mixAudio(). Copies the controller's plain-float scratch
// into the owned PackedFloat32Array (resized as needed) and pushes it.
// -----------------------------------------------------------------------
fn mixSinkAdapter(self: *NativeVideoStreamPlayback) MixSink {
    return .{ .ptr = self, .vtable = &mix_sink_vtable };
}

const mix_sink_vtable: MixSink.VTable = .{ .mix = mixSinkMix };

fn mixSinkMix(ptr: *anyopaque, interleaved: []const f32, channel_count: i32) i32 {
    const self: *NativeVideoStreamPlayback = @ptrCast(@alignCast(ptr));
    const frame_count: i32 = @intCast(interleaved.len / @as(usize, @intCast(channel_count)));
    const total: i64 = @intCast(interleaved.len);
    if (@as(i64, @intCast(self.mix_buffer.size())) < total) {
        _ = self.mix_buffer.resize(total);
    }
    if (interleaved.len > 0) {
        // index() is PackedFloat32Array's non-const operator[]; Godot detaches
        // the array's CoW storage before handing back the pointer, same as
        // resize() above, so this is the array's own unique buffer.
        const dst: [*]f32 = @ptrCast(self.mix_buffer.index(0));
        @memcpy(dst[0..interleaved.len], interleaved);
    }
    return self.base.mixAudio(frame_count, .{ .buffer = self.mix_buffer, .offset = 0 });
}

/// Monotonic wall clock for the Scrubber's velocity/debounce timing
/// (independent of media time, which jumps around during a scrub). Never jumps.
fn nowMs() WallClockMs {
    const ns: i128 = core.sys_clock.nanoTimestamp();
    const ms: f64 = @as(f64, @floatFromInt(ns)) / std.time.ns_per_ms;
    return WallClockMs.init(ms);
}

/// Drains warnings the controller queued since the last call and logs them.
/// The controller has no logging dependency of its own; this is the Godot-side
/// half of that seam.
fn flushWarnings(self: *NativeVideoStreamPlayback) void {
    var warnings = self.controller.takeWarnings();
    defer {
        for (warnings.items) |w| self.allocator.free(w);
        warnings.deinit(self.allocator);
    }
    for (warnings.items) |message| {
        log.err("{s}", .{message});
    }
}

/// Resolve a Godot res:// / user:// path to an absolute OS path and open it
/// on a fresh backend. globalizePath leaves absolute OS paths untouched.
/// Returns an error if the backend can't be constructed or open() fails; on
/// success the caller owns the (already open) backend and must deinit() it.
pub fn openBackendForPath(allocator: Allocator, path: String) !Backend {
    var backend = try platform_backend.create(allocator);

    var os_path = ProjectSettings.globalizePath(path);
    defer os_path.deinit();
    var buf: [4096]u8 = undefined;
    const utf8 = os_path.toUtf8Buf(buf[0..]);

    if (!backend.open(utf8)) {
        backend.deinit();
        return error.OpenFailed;
    }
    return backend;
}

/// Reports a load() failure to Godot's own error reporting (push_error —
/// visible in the editor's Output/errors panel, not just stderr), with the
/// resolved OS path and the Zig error name. Open/load failures used to be
/// swallowed silently, which made real bugs invisible.
fn reportLoadFailure(path: String, err: anyerror) void {
    var os_path = ProjectSettings.globalizePath(path);
    defer os_path.deinit();
    var buf: [4096]u8 = undefined;
    const utf8 = os_path.toUtf8Buf(buf[0..]);

    var msg_buf: [4096 + 128]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "native_video: failed to load '{s}': {s}", .{ utf8, @errorName(err) }) catch utf8;

    var msg_str = String.fromUtf8(msg) catch String.fromLatin1(msg);
    defer msg_str.deinit();
    var v = Variant.init(String, msg_str);
    defer v.deinit();
    godot.general.pushError(v, .{});
}

/// Open the media file. Returns true on success. Called by NativeVideoStream.
pub fn load(self: *NativeVideoStreamPlayback, path: String) bool {
    self.cancelPreviewWork();
    var backend = openBackendForPath(self.allocator, path) catch |e| {
        self.flushWarnings();
        reportLoadFailure(path, e);
        return false;
    };

    // Audio-master latency compensation shifts reported media time back so it
    // reflects what the speaker is emitting now, not what was just pushed into
    // the audio buffer. Resolved once here and handed to the controller.
    const latency: f64 = AudioServer.getOutputLatency();

    self.controller.load(self.allocator, extension.sharedScheduler(), backend, latency) catch |e| {
        backend.deinit();
        self.flushWarnings();
        reportLoadFailure(path, e);
        return false;
    };
    self.flushWarnings();
    return true;
}

// --- Output mode ---

pub fn setOutputMode(self: *NativeVideoStreamPlayback, mode: i64) void {
    const om = OutputMode.fromInt(mode) orelse return;
    self.applyOutputMode(om);
}

/// The REQUESTED output mode — the pipeline never rewrites it, so the
/// inspector round-trips what was set even if that mode failed to build. What
/// is actually built is reported by get_color_info()'s "output_mode" key.
pub fn getOutputMode(self: *NativeVideoStreamPlayback) i64 {
    return @backingInt(self.present.outputMode());
}

/// Applies an already-resolved OutputMode, bypassing the Variant boundary
/// conversion above. Used when the owning NativeVideoStream forwards its own
/// (already-converted) output mode to a live playback.
pub fn applyOutputMode(self: *NativeVideoStreamPlayback, mode: OutputMode) void {
    self.present.setOutputMode(mode);
}

// --- VideoStreamPlayback overrides ---

pub fn _play(self: *NativeVideoStreamPlayback) void {
    self.cancelPreviewWork();
    self.controller.play(nowMs());
    self.flushWarnings();
}

pub fn _stop(self: *NativeVideoStreamPlayback) void {
    self.cancelPreviewWork();
    self.controller.stop();
    self.flushWarnings();
}

pub fn _isPlaying(self: *NativeVideoStreamPlayback) bool {
    return self.controller.playing;
}

pub fn _setPaused(self: *NativeVideoStreamPlayback, paused: bool) void {
    self.controller.setPaused(paused);
    if (!paused) self.cancelPreviewWork();
}

pub fn _isPaused(self: *NativeVideoStreamPlayback) bool {
    return self.controller.paused;
}

pub fn _getLength(self: *NativeVideoStreamPlayback) f64 {
    return self.controller.length;
}

pub fn _getPlaybackPosition(self: *NativeVideoStreamPlayback) f64 {
    return self.controller.position;
}

pub fn _seek(self: *NativeVideoStreamPlayback, time: f64) void {
    self.cancelPreviewWork();
    self.controller.seek(time, nowMs());
    self.flushWarnings();
    if (self.controller.needsPausedPreview()) {
        self.preview.begin(self.present.nextSubmission(), nowMs().ms);
        self.connectPausedPreview();
    }
}

/// VideoStreamPlayer stops _update while paused. Drive only outstanding seek
/// previews from the SceneTree's normal main-thread frame signal instead.
/// This callback carries no old target/frame; the controller owns the latest
/// request and the scheduler serializes seek/flush against in-flight decode.
pub fn processPausedPreview(self: *NativeVideoStreamPlayback) void {
    // An ObjectID-bound callable is weak. Texture2DRD.changed is synchronous:
    // its handlers may replace the stream/free the player during present().
    // This owned Variant uses gdzig's RefCounted ownership adapter; its final
    // deinit MUST happen after every other defer and every access to self.
    var keep_alive = Variant.init(*VideoStreamPlayback, self.base);
    defer keep_alive.deinit();
    if (self.preview_processing) return;
    self.preview_processing = true;
    defer self.preview_processing = false;

    const now = nowMs();
    if (self.preview.expired(now.ms)) {
        self.controller.cancelPausedPreview();
        self.cancelPreviewWork();
        log.err("Paused seek preview timed out waiting for presentation.", .{});
        return;
    }
    if (self.controller.pollPausedPreview(now)) |frame| {
        // An exact settle can supersede a keyframe still waiting in a delayed
        // importer. Same PTS is not identity: allocate a fresh submission token.
        self.preview.begin(self.present.nextSubmission(), now.ms);
        self.preview.setFrame(frame);
    }
    if (self.preview.take()) |attempt| {
        // Ownership is temporarily local, not in self.preview. Reentrant
        // cancellation cannot release a frame already consumed by the GPU.
        const result = self.present.presentPreview(attempt.frame, attempt.token);
        const still_current = self.preview.token == attempt.token;
        self.preview.finish(attempt, result);
        if (result == .failed and still_current) {
            self.controller.cancelPausedPreview();
            log.err("Paused seek preview presentation failed.", .{});
        }
    }
    self.flushWarnings();
    if (self.preview.frame == null and !self.controller.needsPausedPreview()) self.cancelPreviewWork();
}

fn cancelPreviewWork(self: *NativeVideoStreamPlayback) void {
    self.preview.cancel();
    self.disconnectPausedPreview();
}

fn connectPausedPreview(self: *NativeVideoStreamPlayback) void {
    if (self.preview_tree_id != null) return;
    const main_loop = Engine.getMainLoop() orelse return;
    const tree = SceneTree.downcast(main_loop) orelse return;
    var callback = self.pausedPreviewCallback();
    defer callback.deinit();
    tree.connect(SceneTree.ProcessFrame, callback) catch {
        log.err("Could not schedule paused seek preview.", .{});
        return;
    };
    self.preview_tree_id = object_id.fromRaw(tree.getInstanceId());
}

fn disconnectPausedPreview(self: *NativeVideoStreamPlayback) void {
    const id = self.preview_tree_id orelse return;
    self.preview_tree_id = null;
    const object = godot.general.instanceFromId(object_id.toEngineInt(id)) orelse return;
    const tree = SceneTree.downcast(object) orelse return;
    var callback = self.pausedPreviewCallback();
    defer callback.deinit();
    tree.disconnect(SceneTree.ProcessFrame, callback);
}

fn pausedPreviewCallback(self: *NativeVideoStreamPlayback) Callable {
    // Do not use gdzig's fromClosure here: it destructs a cached static
    // StringName. This name is borrowed and stays alive for the process.
    return Callable.initObjectMethod(
        godot.class.Object.upcast(self.base),
        .fromComptimeLatin1("process_paused_preview"),
    );
}

pub fn _setAudioTrack(self: *NativeVideoStreamPlayback, idx: i32) void {
    self.controller.requestAudioTrack(idx);
    self.flushWarnings();
}

pub fn _getTexture(self: *NativeVideoStreamPlayback) ?*Texture2d {
    // The engine-owned RGBA Texture2DRD. Godot samples ONLY this — never the
    // decoder surface. The present pipeline (current_texture) holds its own
    // owning reference for the pipeline's lifetime; this virtual return needs
    // a SEPARATE +1 for the engine to adopt — confirmed empirically, since
    // omitting it leaves the displayed texture readable via get_video_texture()
    // but breaks RenderingServer's CPU image readback (Image.get_image()
    // returns null) partway through playback.
    const tex = self.present.getTexture();
    _ = tex.reference();
    return .upcast(tex);
}

pub fn _update(self: *NativeVideoStreamPlayback, delta: f64) void {
    // Also use the retained/token-checked path if an engine/client explicitly
    // updates paused playback; never lose a delayed preview to normal present.
    if (self.controller.paused) {
        self.processPausedPreview();
        return;
    }
    const sink = self.mixSinkAdapter();
    const frame = self.controller.tick(delta, nowMs(), sink);
    self.flushWarnings();
    if (frame) |f| {
        _ = self.present.present(f);
    }
}

pub fn _getChannels(self: *NativeVideoStreamPlayback) i32 {
    // Canonical Mix Format channel count (maximum across all audio tracks,
    // computed at load). Godot sizes its mix buffer from this and queries it
    // once at play start, so it is stable for the playback's lifetime.
    return self.controller.canonical_channels;
}

pub fn _getMixRate(self: *NativeVideoStreamPlayback) i32 {
    // Canonical Mix Format sample rate: the FIRST audio-bearing track's rate.
    return self.controller.canonical_sample_rate;
}

// --- Colorimetry ---

/// Returns a Dictionary with the parsed/negotiated colorimetry. Callable after
/// load() succeeds. Untagged clips return BT.709 video-range defaults. Always
/// includes an "output_mode" key (0 or 1) reporting the mode the present
/// pipeline actually built. Once something is built it lags the `output_mode`
/// property until the next present(), and stays behind it until the request
/// changes again if the requested mode failed to build and fell back to SDR.
/// While nothing is built at all — before the first present(), in headless
/// mode, or after a failed build — it reports the request instead.
pub fn getColorInfo(self: *NativeVideoStreamPlayback) Dictionary {
    const color: Colorimetry = self.controller.color;
    var info = Dictionary.init();
    setDict(&info, "matrix", @backingInt(color.matrix));
    setDict(&info, "primaries", @backingInt(color.primaries));
    setDict(&info, "transfer", @backingInt(color.transfer));
    setDict(&info, "range", @backingInt(color.range));
    setDict(&info, "bit_depth", color.bit_depth);
    // Report the mode actually built, not the requested one, so callers can
    // distinguish an SDR clip in an HDR viewport vs a native HDR clip — and
    // see when an HDR request fell back to SDR. With nothing built there is no
    // built mode to report, so fall back to the request rather than inventing
    // an SDR default — that default was the regression this key had.
    const built = self.present.builtOutputMode() orelse self.present.outputMode();
    setDict(&info, "output_mode", @backingInt(built));
    return info;
}

/// Frames imported through the Windows CPU-copy path so far this playback
/// session — the one sanctioned exception to the zero-copy contract, counted
/// honestly whether this session ran CPU-copy from the start or degraded
/// into it mid-flight from a failed D3D12 zero-copy attempt. Always 0 on
/// macOS (Metal is always zero-copy).
pub fn getCpuCopyCount(self: *NativeVideoStreamPlayback) i64 {
    return @intCast(self.present.cpuCopyCount());
}
