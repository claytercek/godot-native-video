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
const object_id = @import("object_id.zig");
const ObjectId = object_id.ObjectId;

const log = std.log.scoped(.native_video_stream);

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

/// One probed audio track, in plain Zig. Owns its `language`/`name`: the
/// backend's AudioTrackInfo slices borrow shim-owned storage that is freed
/// when the probe closes the backend, so they are duplicated into the
/// stream's allocator here and freed in destroy().
const AudioTrack = struct {
    language: []const u8,
    name: []const u8,
    channels: i32,
    sample_rate: i32,
    is_default: bool,
};

allocator: Allocator,
base: *VideoStream,

output_mode: OutputMode = .sdr,

// Instance ids of playbacks instantiated from this stream. ObjectIDs, not
// refs, on purpose: the stream must never extend a playback's lifetime.
// Dead ids are pruned whenever the list is walked.
playback_ids: std.ArrayList(ObjectId) = .empty,

// The cached audio-track probe, held as plain Zig data rather than as a Godot
// Array. A bound method returning an Array leaves through gdzig's ptrcall
// path as a bitwise struct move with no refcount bump, so a typed GDScript
// call would have the engine adopt -- and later release -- a reference this
// struct still owns. getAudioTracks() therefore builds a fresh Array from
// this table on every call and never hands out a cached one.
audio_tracks: std.ArrayList(AudioTrack) = .empty,

// Set once getAudioTracks() has probed the clip, whether or not the probe
// succeeded. Distinguishes "not probed yet" from "probed and found no audio
// tracks" so a failed probe or an audio-less clip doesn't re-open the file.
audio_tracks_probed: bool = false,

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
    // The cache owns its duplicated strings; nothing else points at them.
    for (self.audio_tracks.items) |track| {
        self.allocator.free(track.language);
        self.allocator.free(track.name);
    }
    self.audio_tracks.deinit(self.allocator);
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
    self.walkLivePlaybacks({}, null);
}

// resolvePlayback can, in principle, resolve an id whose object is already
// freed: Godot only drops an id from ObjectDB after the extension's
// free_instance callback returns, so the window between allocator.destroy(self)
// in NativeVideoStreamPlayback.destroy and Godot finishing ~Object() still
// resolves. Only reachable if the unref lands on a different thread than the
// setOutputMode() caller, which normal single-threaded script execution never does.
fn resolvePlayback(id: ObjectId) ?*NativeVideoStreamPlayback {
    const obj = godot.general.instanceFromId(object_id.toEngineInt(id)) orelse return null;
    // Object -> engine VideoStreamPlayback (opaque cast) -> our bound instance.
    // godot.class.downcast rejects user-struct targets, so we go through the
    // engine class's asInstance() (the same seam Variant.as uses).
    const vsp = godot.class.VideoStreamPlayback.downcast(obj) orelse return null;
    return vsp.asInstance(NativeVideoStreamPlayback);
}

// Single pass over playback_ids: compacts out dead ids as it goes, and, when
// `action` is non-null, invokes it on every playback still resolvable. Doing
// both in one walk avoids resolving each live id twice (once to prune, once
// to act) and keeps the "dead" and "skipped" cases identical -- there is no
// separate post-prune pass where a resolution failure could go unpruned.
fn walkLivePlaybacks(self: *NativeVideoStream, context: anytype, comptime action: ?fn (@TypeOf(context), *NativeVideoStreamPlayback) void) void {
    var write: usize = 0;
    for (self.playback_ids.items) |id| {
        if (resolvePlayback(id)) |playback| {
            self.playback_ids.items[write] = id;
            write += 1;
            if (action) |apply| apply(context, playback);
        }
    }
    self.playback_ids.shrinkRetainingCapacity(write);
}

pub fn setOutputMode(self: *NativeVideoStream, mode: i64) void {
    const om = OutputMode.fromInt(mode) orelse return;
    self.output_mode = om;
    // Forward to every still-alive playback instantiated from this stream,
    // pruning dead ids in the same pass.
    self.walkLivePlaybacks(om, struct {
        fn apply(output_mode: OutputMode, playback: *NativeVideoStreamPlayback) void {
            playback.applyOutputMode(output_mode);
        }
    }.apply);
}

pub fn getOutputMode(self: *NativeVideoStream) i64 {
    return @intFromEnum(self.output_mode);
}

/// Lazy, cached probe of audio track metadata. The clip is opened at most once
/// (a failed probe or a legitimately audio-less clip still counts as probed, so
/// the file is never re-opened). Returns a freshly built Array of Dictionaries
/// -- empty if the probe failed -- where array position is the track index for
/// VideoStreamPlayer.audio_track. The Array is built per call, never cached and
/// handed out, because the caller takes ownership of it on the ptrcall path.
pub fn getAudioTracks(self: *NativeVideoStream) Array {
    self.probeAudioTracksOnce();

    var tracks = Array.init();
    _ = tracks.resize(@intCast(self.audio_tracks.items.len));
    for (self.audio_tracks.items, 0..) |track, i| {
        // `dict` and the Variant boxing it are both temporaries: `tracks.set`
        // copies the Variant in, so the Array holds the only surviving
        // reference and both locals are released before the next iteration.
        var dict = Dictionary.init();
        defer dict.deinit();
        setDict(&dict, "language", track.language);
        setDict(&dict, "name", track.name);
        setDict(&dict, "channels", track.channels);
        setDict(&dict, "sample_rate", track.sample_rate);
        setDict(&dict, "default", track.is_default);
        const dv = Variant.init(Dictionary, dict);
        defer dv.deinit();
        tracks.set(@intCast(i), dv);
    }
    return tracks;
}

/// Open the clip briefly, copy out its audio-track metadata, close it again.
/// Runs at most once per stream; the cached table owns everything it holds.
fn probeAudioTracksOnce(self: *NativeVideoStream) void {
    if (self.audio_tracks_probed) return;
    // Mark probed up front so a failed open doesn't retry on every call.
    self.audio_tracks_probed = true;

    var file = self.base.getFile();
    defer file.deinit();
    var backend = NativeVideoStreamPlayback.openBackendForPath(self.allocator, file) catch return;
    defer backend.deinit();

    const count: usize = @intCast(@max(backend.audioTrackCount(), 0));
    self.audio_tracks.ensureTotalCapacity(self.allocator, count) catch return;
    for (0..count) |i| {
        const dinfo = backend.audioTrackInfo(@intCast(i));
        // dinfo.language/.name borrow storage the backend frees on close()
        // below, so the cache takes its own copies. On OOM we keep the tracks
        // recorded so far rather than failing the whole probe.
        const language = self.allocator.dupe(u8, dinfo.language) catch return;
        const name = self.allocator.dupe(u8, dinfo.name) catch {
            self.allocator.free(language);
            return;
        };
        self.audio_tracks.appendAssumeCapacity(.{
            .language = language,
            .name = name,
            .channels = dinfo.channels,
            .sample_rate = dinfo.sample_rate,
            .is_default = dinfo.is_default,
        });
    }

    backend.close();
}

/// Called by NativeVideoStreamPlayback? No — the engine calls this virtual on
/// the stream to obtain a playback.
pub fn _instantiatePlayback(self: *NativeVideoStream) ?*VideoStreamPlayback {
    const playback = NativeVideoStreamPlayback.create(&self.allocator) catch return null;
    playback.applyOutputMode(self.output_mode);

    // Prune dead ids, then record the new playback's id so setOutputMode() can
    // reach it later. The list stays bounded across many instantiations.
    self.pruneDeadPlaybacks();
    self.playback_ids.append(self.allocator, object_id.fromRaw(playback.base.getInstanceId())) catch {
        // Degrade, don't fail: the playback still runs, but future
        // setOutputMode() calls won't reach it until it's re-instantiated.
        log.warn("failed to record playback id; it will not receive output_mode updates", .{});
    };

    // VideoStream.getFile() holds the path the ResourceFormatLoader recorded.
    var file = self.base.getFile();
    defer file.deinit();
    // Return an (empty) playback even on load failure so the player degrades
    // gracefully instead of crashing; _getTexture() yields a null texture.
    _ = playback.load(file);
    return playback.base;
}
