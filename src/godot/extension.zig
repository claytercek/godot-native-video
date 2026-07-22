//! extension.zig — GDExtension entry point for the native video module.
//!
//! Registers the three Binding classes and, at the SCENE initialization
//! level, adds a NativeVideoResourceFormatLoader singleton to the
//! ResourceLoader (removed at teardown) so a stock VideoStreamPlayer can
//! load + play a native clip.
//!
//! Init-level handling: gdzig's entrypoint calls register() once at load, then
//! registry.enter(level)/exit(level) per initialization level, and
//! unregister() at final teardown. Classes registered with `.auto` commit at
//! the SCENE level by default. The loader singleton has no class seam of its
//! own for per-level setup, so we hook the SCENE enter/exit via the
//! Registry's addCallbacks mechanism — the enter callback runs AFTER all
//! classes for that level have committed (see Registry.enter), so the loader
//! class is already registered and instantiable when we create the singleton.
//!
//! `std_options` here is the whole extension binary's actual log config:
//! gdzig's generated entrypoint root re-exports it verbatim (`pub const
//! std_options = if (@hasDecl(extension, "std_options")) extension.std_options
//! else .{}`), so declaring it in this module is enough to install
//! godot_log.logFn process-wide. register()/unregister() bracket the window
//! where gdzig's interface (and so Godot's push_error/print) is actually
//! live; godot_log falls back to stderr-only outside it and in standalone
//! binaries that never call register() at all.

const std = @import("std");
const Allocator = std.mem.Allocator;

const godot = @import("godot");
const Registry = godot.extension.Registry;
const InitializationLevel = godot.extension.InitializationLevel;
const ResourceLoader = godot.class.ResourceLoader;

const core = @import("core");
const DecodeScheduler = core.decode_scheduler.DecodeScheduler;

const NativeVideoStream = @import("native_video_stream.zig");
const NativeVideoStreamPlayback = @import("native_video_stream_playback.zig");
const NativeVideoResourceFormatLoader = @import("native_video_resource_format_loader.zig");
const godot_log = @import("godot_log.zig");

// Pinned explicitly rather than left at Zig's build-mode default: ReleaseFast
// already defaults to .info (only .debug is compiled out), but pinning it
// here makes that an explicit contract instead of an accident of std.log's
// per-mode default -- one that would silently reopen this exact bug if
// std.log's default for ReleaseFast ever changes upstream.
pub const std_options: std.Options = .{
    .logFn = godot_log.logFn,
    .log_level = .info,
};

// -----------------------------------------------------------------------
// Process-wide decode pool. Every playback instance registers with this one
// scheduler so N VideoStreamPlayers share a single bounded set of worker
// threads. Lazily created under a mutex on first use; intentionally never
// torn down — its worker threads live for the process lifetime and the OS
// reclaims them at exit.
// -----------------------------------------------------------------------
var g_scheduler: ?*DecodeScheduler = null;
var g_scheduler_mu: core.sys_clock.Mutex = .{};

pub fn sharedScheduler() *DecodeScheduler {
    g_scheduler_mu.lock();
    defer g_scheduler_mu.unlock();
    if (g_scheduler) |p| return p;
    const p = DecodeScheduler.init(
        std.heap.page_allocator,
        core.decode_scheduler.kDefaultWorkerCount,
        false,
    ) catch @panic("DecodeScheduler init failed");
    g_scheduler = p;
    return p;
}

pub fn register(r: *Registry) void {
    // gdzig's raw interface is already live by the time the generated
    // entrypoint calls register() (see entrypoint.zig), so push_error/print
    // are safe to call from here on -- flip the gate before anything below
    // has a chance to log.
    godot_log.setAvailable(true);

    // Playback must be registered before the stream so the stream's
    // _instantiatePlayback return type resolves.
    r.addModule(NativeVideoStreamPlayback);
    r.addModule(NativeVideoStream);
    r.addModule(NativeVideoResourceFormatLoader);

    // Loader singleton lifecycle, gated to the SCENE level.
    r.addCallbacks(LoaderLifecycle, .{ .allocator = r.allocator }, .{});
}

pub fn unregister(r: *Registry) void {
    r.removeModule(NativeVideoResourceFormatLoader);
    r.removeModule(NativeVideoStream);
    r.removeModule(NativeVideoStreamPlayback);

    // Last thing before the generated entrypoint tears down gdzig's
    // interface (see entrypoint.zig's exit()) -- nothing after this point
    // may reach for Godot's utility functions.
    godot_log.setAvailable(false);
}

// -----------------------------------------------------------------------
// LoaderLifecycle — the ResourceFormatLoader singleton's per-level hook.
//
// enter/exit fire for every initialization level; we act only at SCENE.
// Stored by value in the Registry arena; the enter/exit callbacks receive
// a stable pointer to that copy.
// -----------------------------------------------------------------------
const LoaderLifecycle = struct {
    allocator: Allocator,
    loader: ?*NativeVideoResourceFormatLoader = null,

    pub fn enter(self: *LoaderLifecycle, level: InitializationLevel) void {
        if (level != .scene) return;
        const loader = NativeVideoResourceFormatLoader.create(&self.allocator) catch return;
        self.loader = loader;
        ResourceLoader.addResourceFormatLoader(loader.base, .{});
    }

    pub fn exit(self: *LoaderLifecycle, level: InitializationLevel) void {
        if (level != .scene) return;
        if (self.loader) |loader| {
            ResourceLoader.removeResourceFormatLoader(loader.base);
            // Drop our create-time ref; the engine dropped its own on remove.
            // When the last ref goes, Godot calls our destroy() callback.
            if (loader.base.unreference()) loader.base.destroy();
            self.loader = null;
        }
    }
};
