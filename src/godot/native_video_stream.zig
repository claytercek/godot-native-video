//! native_video_stream.zig — the VideoStream resource for native clips.
//!
//! A stock VideoStreamPlayer holds a VideoStream and calls
//! _instantiatePlayback() to get a VideoStreamPlayback. This resource
//! carries the clip's file path (set by the ResourceFormatLoader) and
//! instantiates a NativeVideoStreamPlayback bound to it. It also exposes a
//! lazy, cached audio-track probe (getAudioTracks()) so GDScript can query
//! per-track metadata before playback.

const NativeVideoStream = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const godot = @import("godot");
const Registry = godot.extension.Registry;
const VideoStream = godot.class.VideoStream;
const VideoStreamPlayback = godot.class.VideoStreamPlayback;
const String = godot.builtin.String;
const Array = godot.builtin.Array;
const Dictionary = godot.builtin.Dictionary;
const Variant = godot.builtin.Variant;

const NativeVideoStreamPlayback = @import("native_video_stream_playback.zig");
const present_pipeline = @import("present_pipeline.zig");
const OutputMode = present_pipeline.OutputMode;
const setDict = @import("godot_dict.zig").setDict;

pub fn register(r: *Registry) void {
    const class = r.createClass(NativeVideoStream, r.allocator, .auto);
    // On macOS (and iOS) Metal-accelerated VideoToolbox produces 10-bit
    // biplanar surfaces we import zero-copy: always supported here. Registered
    // as an instance method (gdzig has no static-method seam); GDScript calls
    // it on an instance.
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

output_mode: OutputMode = .sdr,

// Instance ids of playbacks instantiated from this stream. ObjectIDs, not
// refs, on purpose: the stream must never extend a playback's lifetime.
// Dead ids are pruned whenever the list is walked.
playback_ids: std.ArrayList(u64) = .empty,

// The cached audio-track probe. null until getAudioTracks() has probed the
// clip, whether or not the probe succeeded; a non-null (possibly empty) Array
// afterwards. Distinguishes "not probed yet" from "probed and found no audio
// tracks" so a failed probe or an audio-less clip doesn't re-open the file.
cached_audio_tracks: ?Array = null,

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
    if (self.cached_audio_tracks) |*a| a.deinit();
    self.base.destroy();
    allocator.destroy(self);
}

/// True only on targets where this extension has both a 10-bit hardware decode
/// path and a matching P010/x420 surface importer.
pub fn hdrDecodeSupported(self: *NativeVideoStream) bool {
    _ = self;
    return switch (builtin.os.tag) {
        .macos, .ios, .windows => true,
        else => false,
    };
}

// -----------------------------------------------------------------------
// Live-playback resolution.
//
// Resolve playback_ids to the playbacks still alive, pruning dead ids, using
// gdzig's instanceFromId + typed downcast.
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
    const om = OutputMode.fromInt(mode) orelse return;
    self.output_mode = om;
    // Forward to every still-alive playback instantiated from this stream.
    self.pruneDeadPlaybacks();
    for (self.playback_ids.items) |id| {
        if (resolvePlayback(id)) |playback| {
            playback.applyOutputMode(self.output_mode);
        }
    }
}

pub fn getOutputMode(self: *NativeVideoStream) i64 {
    return @intFromEnum(self.output_mode);
}

/// Lazy, cached probe of audio track metadata. Probes exactly once; the result
/// (including an empty Array for a failed probe or a legitimately audio-less
/// clip) is cached for every subsequent call. Returns an Array of Dictionaries;
/// array position is the track index for VideoStreamPlayer.audio_track.
pub fn getAudioTracks(self: *NativeVideoStream) Array {
    if (self.cached_audio_tracks) |cached| {
        return cached;
    }

    // Lazy probe: open the clip briefly to read audio track metadata, then
    // close the backend. The result (including empty, on failure) is cached.
    var tracks = Array.init();

    var file = self.base.getFile();
    defer file.deinit();
    var backend = NativeVideoStreamPlayback.openBackendForPath(self.allocator, file) catch {
        self.cached_audio_tracks = tracks; // empty on failure
        return tracks;
    };
    defer backend.deinit();

    const count: usize = @intCast(@max(backend.audioTrackCount(), 0));
    _ = tracks.resize(@intCast(count));
    for (0..count) |i| {
        const dinfo = backend.audioTrackInfo(@intCast(i));
        var dict = Dictionary.init();
        setDict(&dict, "language", dinfo.language);
        setDict(&dict, "name", dinfo.name);
        setDict(&dict, "channels", dinfo.channels);
        setDict(&dict, "sample_rate", dinfo.sample_rate);
        setDict(&dict, "default", dinfo.is_default);
        tracks.set(@intCast(i), Variant.init(Dictionary, dict));
    }

    backend.close();
    self.cached_audio_tracks = tracks;
    return tracks;
}

/// Called by NativeVideoStreamPlayback? No — the engine calls this virtual on
/// the stream to obtain a playback.
pub fn _instantiatePlayback(self: *NativeVideoStream) ?*VideoStreamPlayback {
    const playback = NativeVideoStreamPlayback.create(&self.allocator) catch return null;
    playback.applyOutputMode(self.output_mode);

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
