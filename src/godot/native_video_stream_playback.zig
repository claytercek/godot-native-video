//! Adapt core.PlaybackController to Godot's VideoStreamPlayback through type
//! conversion, mixAudio(), and PresentPipeline. Playback state machines remain
//! in the Godot-independent controller.
//!
//! _update() takes controller.tick()'s frame by value and passes it to
//! PresentPipeline, which releases it on failure or through the GPU retire ring.
//!
//! Virtual integer parameters/returns use natural widths (i32 for indices,
//! channels, and mix rate): gdzig's vtable ptrcall marshals full 8-byte engine
//! slots regardless of Zig width. Floats use Godot's f64 width. output_mode
//! accessors are addProperty methods dispatched through Variant, whose integers
//! require i64.

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

// Use build.zig's named module to share PlaybackController's type identity;
// Zig's module-root boundary prevents path imports into ../core.
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
    class.addMethod("process_presentation", .auto);
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
// Weak SceneTree ObjectID. The pump stays connected until paused previews
// and GPU retirements both drain.
presentation_tree_id: ?object_id.ObjectId = null,
preview: preview_policy.Pending(backend_mod.VideoFrame) = .{},
presentation_processing: bool = false,

// Owned MixSink scratch array, grown as needed and reused across ticks.
// The adapter copies the controller's plain floats into it for Godot.
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
    self.disconnectPresentationPump();
    // Unregister before freeing backend state. shutdown() waits for in-flight
    // decode work and releases buffered surfaces; no worker can use it after.
    self.controller.shutdown();
    self.present.shutdown();
    self.controller.deinit();
    self.mix_buffer.deinit();
    self.base.destroy();
    allocator.destroy(self);
}

// MixSink adapter: copy the controller's floats into the reusable
// PackedFloat32Array and submit them through VideoStreamPlayback.mixAudio().
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

/// Monotonic wall clock for scrub velocity/debounce, independent of media time.
fn nowMs() WallClockMs {
    const ns: i128 = core.sys_clock.nanoTimestamp();
    const ms: f64 = @as(f64, @floatFromInt(ns)) / std.time.ns_per_ms;
    return WallClockMs.init(ms);
}

/// Drain and log queued warnings; the controller has no logging dependency.
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

/// Open a fresh backend for a res://, user://, or absolute OS path.
/// globalizePath leaves absolute paths unchanged. On success, the caller owns
/// the open backend and must deinit() it; construction/open failures return errors.
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

/// Report load failure through push_error with the resolved OS path and Zig
/// error name, making it visible in the editor's Output/errors panel.
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

    // Sample output latency once. The controller subtracts it from media time
    // to track audio reaching the speaker rather than audio entering the buffer.
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

/// Requested mode, preserved even if its build fails. get_color_info()'s
/// output_mode key reports the built mode when resources exist.
pub fn getOutputMode(self: *NativeVideoStreamPlayback) i64 {
    return @backingInt(self.present.outputMode());
}

/// Apply a typed mode forwarded by NativeVideoStream, bypassing Variant conversion.
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
        self.connectPresentationPump();
    }
}

/// Main-thread presentation pump. While VideoStreamPlayer pauses _update,
/// SceneTree.process_frame drives seeks and retirement across pause/stop/resume.
/// The controller owns the latest request; Engine.getFramesDrawn alone ages GPU
/// resources.
pub fn processPresentation(self: *NativeVideoStreamPlayback) void {
    // ObjectID callables are weak; synchronous Texture2DRD.changed handlers
    // may replace the stream or free the player during present(). Retain self
    // through gdzig's RefCounted Variant adapter, and deinit it after all other
    // defers and accesses to self.
    var keep_alive = Variant.init(*VideoStreamPlayback, self.base);
    defer keep_alive.deinit();
    if (self.presentation_processing) return;
    self.presentation_processing = true;
    defer self.finishPresentation();

    self.present.advanceRenderEpoch();
    if (self.preview.token == 0) return;
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
    self.disconnectIdlePresentationPump();
}

fn finishPresentation(self: *NativeVideoStreamPlayback) void {
    self.presentation_processing = false;
    self.disconnectIdlePresentationPump();
}

fn disconnectIdlePresentationPump(self: *NativeVideoStreamPlayback) void {
    // Cancellation from a synchronous changed handler may happen before the
    // dispatch payload is retained. Reconcile only once the whole call exits.
    if (!self.presentation_processing and self.preview.token == 0 and !self.present.hasRetirements()) self.disconnectPresentationPump();
}

fn connectPresentationPump(self: *NativeVideoStreamPlayback) void {
    if (self.presentation_tree_id != null) return;
    const main_loop = Engine.getMainLoop() orelse return;
    const tree = SceneTree.downcast(main_loop) orelse return;
    var callback = self.presentationCallback();
    defer callback.deinit();
    tree.connect(SceneTree.ProcessFrame, callback) catch {
        log.err("Could not schedule presentation pump.", .{});
        return;
    };
    self.presentation_tree_id = object_id.fromRaw(tree.getInstanceId());
}

fn disconnectPresentationPump(self: *NativeVideoStreamPlayback) void {
    const id = self.presentation_tree_id orelse return;
    self.presentation_tree_id = null;
    const object = godot.general.instanceFromId(object_id.toEngineInt(id)) orelse return;
    const tree = SceneTree.downcast(object) orelse return;
    var callback = self.presentationCallback();
    defer callback.deinit();
    tree.disconnect(SceneTree.ProcessFrame, callback);
}

fn presentationCallback(self: *NativeVideoStreamPlayback) Callable {
    // Do not use gdzig's fromClosure here: it destructs a cached static
    // StringName. This name is borrowed and stays alive for the process.
    return Callable.initObjectMethod(
        godot.class.Object.upcast(self.base),
        .fromComptimeLatin1("process_presentation"),
    );
}

pub fn _setAudioTrack(self: *NativeVideoStreamPlayback, idx: i32) void {
    self.controller.requestAudioTrack(idx);
    self.flushWarnings();
}

pub fn _getTexture(self: *NativeVideoStreamPlayback) ?*Texture2d {
    // Godot samples this RGBA Texture2DRD, never the decoder surface. The
    // pipeline owns current_texture; this virtual return needs a separate +1
    // for the engine to adopt. Without it, get_video_texture() remains readable
    // but RenderingServer CPU readback (Image.get_image()) returns null
    // partway through playback.
    const tex = self.present.getTexture();
    _ = tex.reference();
    return .upcast(tex);
}

pub fn _update(self: *NativeVideoStreamPlayback, delta: f64) void {
    // Also use the retained/token-checked path if an engine/client explicitly
    // updates paused playback; never lose a delayed preview to normal present.
    if (self.controller.paused) {
        self.processPresentation();
        return;
    }
    // Normal publication has the same reentrancy/lifetime contract as the
    // SceneTree callback, including preparation-time texture.changed signals.
    var keep_alive = Variant.init(*VideoStreamPlayback, self.base);
    defer keep_alive.deinit();
    if (self.presentation_processing) return;
    self.presentation_processing = true;
    defer self.finishPresentation();
    self.present.advanceRenderEpoch();
    const sink = self.mixSinkAdapter();
    const frame = self.controller.tick(delta, nowMs(), sink);
    self.flushWarnings();
    if (frame) |f| {
        // Connect BEFORE publication: a synchronous changed handler can stop,
        // resume, or replace the stream. Retirement must outlive that preview.
        self.connectPresentationPump();
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
    // Canonical mix sample rate: the first audio-bearing track's rate.
    return self.controller.canonical_sample_rate;
}

// --- Colorimetry ---

/// Return parsed/negotiated colorimetry after successful load(); untagged clips
/// use BT.709 video-range defaults. output_mode (0 or 1) reports the built mode,
/// which can lag the property until present() or remain SDR after an HDR build
/// failure until the request changes. With no resources built (before present,
/// headless, or after build failure), it reports the requested mode.
pub fn getColorInfo(self: *NativeVideoStreamPlayback) Dictionary {
    const color: Colorimetry = self.controller.color;
    var info = Dictionary.init();
    setDict(&info, "matrix", @backingInt(color.matrix));
    setDict(&info, "primaries", @backingInt(color.primaries));
    setDict(&info, "transfer", @backingInt(color.transfer));
    setDict(&info, "range", @backingInt(color.range));
    setDict(&info, "bit_depth", color.bit_depth);
    // Expose the built mode, including SDR fallback. Before any build, use the
    // request rather than an arbitrary SDR default.
    const built = self.present.builtOutputMode() orelse self.present.outputMode();
    setDict(&info, "output_mode", @backingInt(built));
    return info;
}

/// Successful CPU-copy imports this playback session, including Windows
/// sessions that fall back from D3D12. Always zero on Metal.
pub fn getCpuCopyCount(self: *NativeVideoStreamPlayback) i64 {
    return @intCast(self.present.cpuCopyCount());
}
