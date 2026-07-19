//! native_video_stream.zig — the VideoStream resource for native clips.
//!
//! Port of src/common/native_video_stream.h/.cpp. A stock VideoStreamPlayer
//! holds a VideoStream and calls _instantiatePlayback() to get a
//! VideoStreamPlayback. This resource carries the clip's file path (set by the
//! ResourceFormatLoader) and instantiates a NativeVideoStreamPlayback bound to
//! it. It also exposes a lazy, cached audio-track probe (getAudioTracks()) so
//! GDScript can query per-track metadata before playback.

const NativeVideoStream = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const godot = @import("godot");
const Registry = godot.extension.Registry;
const VideoStream = godot.class.VideoStream;
const VideoStreamPlayback = godot.class.VideoStreamPlayback;
const String = godot.builtin.String;
const Array = godot.builtin.Array;
const Dictionary = godot.builtin.Dictionary;
const Variant = godot.builtin.Variant;

const avf = @import("avf");

const NativeVideoStreamPlayback = @import("native_video_stream_playback.zig");

pub fn register(r: *Registry) void {
    const class = r.createClass(NativeVideoStream, r.allocator, .auto);
    // On macOS (and iOS) Metal-accelerated VideoToolbox produces 10-bit
    // biplanar surfaces we import zero-copy: always supported here. Registered
    // as an instance method (gdzig has no static-method seam); GDScript calls
    // it on an instance. C++ bound it as a static method — a minor deviation.
    class.addMethod("hdr_decode_supported", .auto);
    class.addMethod("get_audio_tracks", .auto);
    // output_mode (SDR,HDR) enum property, backed by set/get methods.
    class.addProperty("output_mode", .{
        .hint = .property_hint_enum,
        .hint_string = String.fromLatin1("SDR,HDR"),
    });
}

pub fn unregister(r: *Registry) void {
    r.removeClass(NativeVideoStream);
}

allocator: Allocator,
base: *VideoStream,

output_mode_: i64 = 0, // matches NativeVideoStreamPlayback OutputMode

// Instance ids of playbacks instantiated from this stream. ObjectIDs, not
// refs, on purpose: the stream must never extend a playback's lifetime.
// Dead ids are pruned whenever the list is walked.
playback_ids: std.ArrayList(u64) = .empty,

// True once getAudioTracks() has probed the clip, whether or not the probe
// succeeded. Distinguishes "not probed yet" from "probed and found no audio
// tracks" so a failed probe or an audio-less clip doesn't re-open the file.
audio_tracks_probed: bool = false,
cached_audio_tracks: Array = undefined,
has_cached_tracks: bool = false,

pub fn create(allocator: *Allocator) !*NativeVideoStream {
    const self = try allocator.create(NativeVideoStream);
    self.* = .{
        .allocator = allocator.*,
        .base = .init(),
    };
    self.base.setInstance(NativeVideoStream, self);
    return self;
}

pub fn destroy(self: *NativeVideoStream, allocator: *Allocator) void {
    self.playback_ids.deinit(self.allocator);
    if (self.has_cached_tracks) self.cached_audio_tracks.deinit();
    self.base.destroy();
    allocator.destroy(self);
}

/// True when the platform supports 10-bit/HDR hardware decode output through
/// the zero-copy Metal import path. Always true on macOS.
pub fn hdrDecodeSupported(self: *NativeVideoStream) bool {
    _ = self;
    return true;
}

// -----------------------------------------------------------------------
// Live-playback resolution.
//
// Resolve playback_ids to the playbacks still alive, pruning dead ids. Mirrors
// C++ live_playbacks() using gdzig's instanceFromId + typed downcast.
// -----------------------------------------------------------------------
fn pruneDeadPlaybacks(self: *NativeVideoStream) void {
    var write: usize = 0;
    for (self.playback_ids.items) |id| {
        if (resolvePlayback(id) != null) {
            self.playback_ids.items[write] = id;
            write += 1;
        }
    }
    self.playback_ids.shrinkRetainingCapacity(write);
}

fn resolvePlayback(id: u64) ?*NativeVideoStreamPlayback {
    const obj = godot.general.instanceFromId(@intCast(id)) orelse return null;
    // Object -> engine VideoStreamPlayback (opaque cast) -> our bound instance.
    // godot.class.downcast rejects user-struct targets, so we go through the
    // engine class's asInstance() (the same seam Variant.as uses).
    const vsp = godot.class.VideoStreamPlayback.downcast(obj) orelse return null;
    return vsp.asInstance(NativeVideoStreamPlayback);
}

pub fn setOutputMode(self: *NativeVideoStream, mode: i64) void {
    if (mode < 0 or mode > 1) return;
    self.output_mode_ = mode;
    // Forward to every still-alive playback instantiated from this stream.
    self.pruneDeadPlaybacks();
    for (self.playback_ids.items) |id| {
        if (resolvePlayback(id)) |playback| {
            playback.setOutputMode(self.output_mode_);
        }
    }
}

pub fn getOutputMode(self: *NativeVideoStream) i64 {
    return self.output_mode_;
}

/// Lazy, cached probe of audio track metadata. Probes exactly once; the result
/// (including an empty Array for a failed probe or a legitimately audio-less
/// clip) is cached for every subsequent call. Returns an Array of Dictionaries;
/// array position is the track index for VideoStreamPlayer.audio_track.
pub fn getAudioTracks(self: *NativeVideoStream) Array {
    if (self.audio_tracks_probed) {
        return self.cached_audio_tracks;
    }
    self.audio_tracks_probed = true;

    // Lazy probe: open the clip briefly to read audio track metadata, then
    // close the backend. The result (including empty, on failure) is cached.
    var tracks = Array.init();

    var backend = avf.create(self.allocator) catch {
        self.cached_audio_tracks = tracks;
        self.has_cached_tracks = true;
        return tracks;
    };
    defer backend.deinit();

    var file = self.base.getFile();
    defer file.deinit();
    var os_path = godot.class.ProjectSettings.globalizePath(file);
    defer os_path.deinit();
    var buf: [4096]u8 = undefined;
    const utf8 = os_path.toUtf8Buf(buf[0..]);

    if (!backend.open(utf8)) {
        self.cached_audio_tracks = tracks; // empty on failure
        self.has_cached_tracks = true;
        return tracks;
    }

    const count = backend.audioTrackCount();
    _ = tracks.resize(@intCast(count));
    var i: i32 = 0;
    while (i < count) : (i += 1) {
        const dinfo = backend.audioTrackInfo(i);
        var dict = Dictionary.init();
        setDictString(&dict, "language", dinfo.language);
        setDictString(&dict, "name", dinfo.name);
        setDictInt(&dict, "channels", dinfo.channels);
        setDictInt(&dict, "sample_rate", dinfo.sample_rate);
        setDictBool(&dict, "default", dinfo.is_default);
        tracks.set(@intCast(i), Variant.init(Dictionary, dict));
    }

    backend.close();
    self.cached_audio_tracks = tracks;
    self.has_cached_tracks = true;
    return tracks;
}

/// Called by NativeVideoStreamPlayback? No — the engine calls this virtual on
/// the stream to obtain a playback. Mirrors C++ _instantiate_playback().
pub fn _instantiatePlayback(self: *NativeVideoStream) ?*VideoStreamPlayback {
    const playback = NativeVideoStreamPlayback.create(&self.allocator) catch return null;
    playback.setOutputMode(self.output_mode_);

    // Prune dead ids, then record the new playback's id so setOutputMode() can
    // reach it later. The list stays bounded across many instantiations.
    self.pruneDeadPlaybacks();
    self.playback_ids.append(self.allocator, playback.base.getInstanceId()) catch {};

    // VideoStream.getFile() holds the path the ResourceFormatLoader recorded.
    var file = self.base.getFile();
    defer file.deinit();
    // Return an (empty) playback even on load failure so the player degrades
    // gracefully instead of crashing; _getTexture() yields a null texture.
    _ = playback.load(file);
    return playback.base;
}

fn setDictInt(dict: *Dictionary, comptime key: [:0]const u8, value: i32) void {
    var k = String.fromLatin1(key);
    defer k.deinit();
    _ = dict.set(Variant.init(String, k), Variant.init(i64, @intCast(value)));
}

fn setDictBool(dict: *Dictionary, comptime key: [:0]const u8, value: bool) void {
    var k = String.fromLatin1(key);
    defer k.deinit();
    _ = dict.set(Variant.init(String, k), Variant.init(bool, value));
}

fn setDictString(dict: *Dictionary, comptime key: [:0]const u8, value: []const u8) void {
    var k = String.fromLatin1(key);
    defer k.deinit();
    var v = String.fromUtf8(value) catch String.fromLatin1(value);
    defer v.deinit();
    _ = dict.set(Variant.init(String, k), Variant.init(String, v));
}
