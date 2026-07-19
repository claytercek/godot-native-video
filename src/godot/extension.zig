//! extension.zig — GDExtension entry point for the native video module.
//!
//! Port of src/register_types.cpp. Registers the three Binding classes and, at
//! the SCENE initialization level, adds a NativeVideoResourceFormatLoader
//! singleton to the ResourceLoader (removed at teardown) so a stock
//! VideoStreamPlayer can load + play a native clip.
//!
//! Init-level handling: gdzig's entrypoint calls register() once at load, then
//! registry.enter(level)/exit(level) per initialization level, and
//! unregister() at final teardown. Classes registered with `.auto` commit at
//! the SCENE level by default (matching the C++
//! MODULE_INITIALIZATION_LEVEL_SCENE gate). The loader singleton has no class
//! seam of its own for per-level setup, so we hook the SCENE enter/exit via the
//! Registry's addCallbacks mechanism — the enter callback runs AFTER all
//! classes for that level have committed (see Registry.enter), so the loader
//! class is already registered and instantiable when we create the singleton.

const std = @import("std");
const Allocator = std.mem.Allocator;

const godot = @import("godot");
const Registry = godot.extension.Registry;
const InitializationLevel = godot.extension.InitializationLevel;
const ResourceLoader = godot.class.ResourceLoader;

const NativeVideoStream = @import("native_video_stream.zig");
const NativeVideoStreamPlayback = @import("native_video_stream_playback.zig");
const NativeVideoResourceFormatLoader = @import("native_video_resource_format_loader.zig");

pub fn register(r: *Registry) void {
    // Register playback before stream (C++ registers the playback class first
    // so the stream's _instantiate_playback return type resolves).
    r.addModule(NativeVideoStreamPlayback);
    r.addModule(NativeVideoStream);
    r.addModule(NativeVideoResourceFormatLoader);

    // Loader singleton lifecycle, gated to the SCENE level (mirrors
    // register_types.cpp's MODULE_INITIALIZATION_LEVEL_SCENE add/remove).
    r.addCallbacks(LoaderLifecycle, .{ .allocator = r.allocator }, .{});
}

pub fn unregister(r: *Registry) void {
    r.removeModule(NativeVideoResourceFormatLoader);
    r.removeModule(NativeVideoStream);
    r.removeModule(NativeVideoStreamPlayback);
}

// -----------------------------------------------------------------------
// LoaderLifecycle — the ResourceFormatLoader singleton's per-level hook.
//
// enter/exit fire for every initialization level; we act only at SCENE,
// exactly like register_types.cpp. Stored by value in the Registry arena; the
// enter/exit callbacks receive a stable pointer to that copy.
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
