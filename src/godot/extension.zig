//! GDExtension entry point. Registers the playback, stream, and loader classes,
//! then manages the ResourceFormatLoader singleton at the SCENE level.
//!
//! gdzig calls register() at load, registry.enter/exit per initialization level,
//! and unregister() at teardown. `.auto` classes commit at SCENE. Registry's
//! addCallbacks enter hook runs after those commits, so the loader class exists
//! before its singleton is created; the exit hook removes it.
//!
//! gdzig's generated root re-exports std_options, installing godot_log.logFn for
//! the extension binary. register()/unregister() enable Godot logging only while
//! gdzig's interface is live. Outside that window, including standalone binaries
//! that never register, logging uses stderr alone.

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

// Keep .info logs in every build mode, independent of std.log's defaults.
pub const std_options: std.Options = .{
    .logFn = godot_log.logFn,
    .log_level = .info,
};

// All playbacks share a bounded process-wide decode pool, created under a
// mutex on first use. It is never torn down; workers live until process exit.
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
    // gdzig's interface is live at register() (entrypoint.zig). Enable Godot
    // logging before any registration work can log.
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

    // Disable Godot logging before entrypoint.zig tears down the interface.
    godot_log.setAvailable(false);
}

// Loader singleton lifecycle. enter/exit act only at SCENE, though called at
// every level. Registry stores this value in its arena and passes callbacks a
// stable pointer to that copy.
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
