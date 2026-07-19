//! native_video_resource_format_loader.zig — loads a clip path into a
//! NativeVideoStream resource so VideoStreamPlayer can play it.
//!
//! Port of src/common/native_video_resource_format_loader.h/.cpp. Registered
//! with ResourceLoader for the video container extensions the OS decodes
//! (mp4/mov/m4v). It does NOT decode anything here — it just produces a
//! VideoStream pointing at the file; decoding happens lazily in the playback.

const NativeVideoResourceFormatLoader = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const godot = @import("godot");
const Registry = godot.extension.Registry;
const ResourceFormatLoader = godot.class.ResourceFormatLoader;
const String = godot.builtin.String;
const StringName = godot.builtin.StringName;
const PackedStringArray = godot.builtin.PackedStringArray;
const Variant = godot.builtin.Variant;

const NativeVideoStream = @import("native_video_stream.zig");

pub fn register(r: *Registry) void {
    r.addClass(NativeVideoResourceFormatLoader, r.allocator, .auto);
}

pub fn unregister(r: *Registry) void {
    r.removeClass(NativeVideoResourceFormatLoader);
}

allocator: Allocator,
base: *ResourceFormatLoader,

pub fn create(allocator: *Allocator) !*NativeVideoResourceFormatLoader {
    const self = try allocator.create(NativeVideoResourceFormatLoader);
    self.* = .{
        .allocator = allocator.*,
        .base = .init(),
    };
    self.base.setInstance(NativeVideoResourceFormatLoader, self);
    return self;
}

pub fn destroy(self: *NativeVideoResourceFormatLoader, allocator: *Allocator) void {
    self.base.destroy();
    allocator.destroy(self);
}

/// Containers AVFoundation decodes on macOS. v1 contract is 8-bit SDR
/// H.264/HEVC in MP4/MOV.
pub fn _getRecognizedExtensions(self: *NativeVideoResourceFormatLoader) PackedStringArray {
    _ = self;
    var exts = PackedStringArray.init();
    inline for (recognized_extensions) |ext| {
        var s = String.fromLatin1(ext);
        defer s.deinit();
        _ = exts.pushBack(s);
    }
    return exts;
}

pub fn _handlesType(self: *NativeVideoResourceFormatLoader, type_name: StringName) bool {
    _ = self;
    var s = String.fromStringName(type_name);
    defer s.deinit();
    var buf: [128]u8 = undefined;
    const t = s.toUtf8Buf(buf[0..]);
    return std.mem.eql(u8, t, "VideoStream") or std.mem.eql(u8, t, "NativeVideoStream");
}

pub fn _getResourceType(self: *NativeVideoResourceFormatLoader, path: String) String {
    _ = self;
    var ext_str = path.getExtension();
    defer ext_str.deinit();
    var lower = ext_str.toLower();
    defer lower.deinit();
    var buf: [16]u8 = undefined;
    const ext = lower.toUtf8Buf(buf[0..]);
    inline for (recognized_extensions) |known| {
        if (std.mem.eql(u8, ext, known)) {
            return String.fromLatin1("NativeVideoStream");
        }
    }
    return String.empty;
}

/// Record the path; the playback opens the backend lazily on instantiate.
pub fn _load(
    self: *NativeVideoResourceFormatLoader,
    path: String,
    original_path: String,
    use_sub_threads: bool,
    cache_mode: i32,
) Variant {
    _ = original_path;
    _ = use_sub_threads;
    _ = cache_mode;
    const stream = NativeVideoStream.create(&self.allocator) catch return Variant.nil;
    stream.base.setFile(path);
    return Variant.init(*NativeVideoStream, stream);
}

const recognized_extensions = [_][:0]const u8{ "mp4", "mov", "m4v" };
