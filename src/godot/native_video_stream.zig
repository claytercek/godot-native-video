//! VideoStream resource for native clips. Stores the path set by the
//! ResourceFormatLoader and creates NativeVideoStreamPlayback instances for
//! VideoStreamPlayer. getAudioTracks() lazily probes and caches track metadata
//! for GDScript queries before playback.

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
    // Reports 10-bit decode/import capability, not HDR display support or
    // availability of a decoder for a particular codec. Registered as an
    // instance method (gdzig has no static-method seam).
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

/// Cached track metadata. language/name borrow copies in owned_strings;
/// the backend's original AudioTrackInfo slices expire when the probe closes.
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

// Weak playback ObjectIDs: the stream must not extend playback lifetimes.
// Each walk prunes dead IDs.
playback_ids: std.ArrayList(ObjectId) = .empty,

// Cache plain Zig data. gdzig's ptrcall returns Arrays by bitwise move without
// retaining them, so returning a cached Array would let GDScript release a
// reference still owned here. getAudioTracks() builds a fresh Array per call.
audio_tracks: std.ArrayList(AudioTrack) = .empty,

// Owns all language/name copies borrowed by audio_tracks; freed in destroy().
owned_strings: std.ArrayList([]u8) = .empty,

// Set even on probe failure or no audio, preventing repeated file opens.
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
    // owned_strings holds every duplicated language/name string exactly once;
    // AudioTrack entries themselves borrow from it and own nothing.
    for (self.owned_strings.items) |s| self.allocator.free(s);
    self.owned_strings.deinit(self.allocator);
    self.audio_tracks.deinit(self.allocator);
    self.base.destroy();
    allocator.destroy(self);
}

/// True on targets with a 10-bit decode path and matching P010/x420 importer.
/// Linux uses CPU upload; installed GStreamer plugins determine codec support.
/// This does not report hardware decoding or HDR display availability.
pub fn hdrDecodeSupported(self: *NativeVideoStream) bool {
    _ = self;
    return switch (builtin.os.tag) {
        .macos, .ios, .windows, .linux => true,
        else => false,
    };
}

// Resolve and compact in one pass so every failed resolution prunes its ID.
fn pruneDeadPlaybacks(self: *NativeVideoStream) void {
    var write: usize = 0;
    for (self.playback_ids.items) |id| {
        if (resolvePlayback(id)) |_| {
            self.playback_ids.items[write] = id;
            write += 1;
        }
    }
    self.playback_ids.shrinkRetainingCapacity(write);
}

// ObjectDB removes the ID only after free_instance returns. An ID can still
// resolve between NativeVideoStreamPlayback.destroy's allocator.destroy(self)
// and Godot's completed ~Object(). This requires unref on a different thread
// from setOutputMode(); normal single-threaded script execution avoids it.
fn resolvePlayback(id: ObjectId) ?*NativeVideoStreamPlayback {
    const obj = godot.general.instanceFromId(object_id.toEngineInt(id)) orelse return null;
    // Downcast to the engine class, then use asInstance() for the bound struct;
    // godot.class.downcast rejects user-struct targets.
    const vsp = godot.class.VideoStreamPlayback.downcast(obj) orelse return null;
    return vsp.asInstance(NativeVideoStreamPlayback);
}

pub fn setOutputMode(self: *NativeVideoStream, mode: i64) void {
    const om = OutputMode.fromInt(mode) orelse return;
    self.output_mode = om;
    // Forward to live playbacks and prune every failed resolution in this pass.
    var write: usize = 0;
    for (self.playback_ids.items) |id| {
        if (resolvePlayback(id)) |playback| {
            self.playback_ids.items[write] = id;
            write += 1;
            playback.applyOutputMode(om);
        }
    }
    self.playback_ids.shrinkRetainingCapacity(write);
}

pub fn getOutputMode(self: *NativeVideoStream) i64 {
    return @backingInt(self.output_mode);
}

/// Probe at most once, including failed opens and clips without audio.
/// Return a fresh Array of Dictionaries for the caller to own through ptrcall.
/// Array positions match VideoStreamPlayer.audio_track indices; an empty probe
/// result returns an empty Array.
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
    // Reserve both strings per track so appending cannot fail after duplication.
    self.owned_strings.ensureTotalCapacity(self.allocator, count * 2) catch return;
    for (0..count) |i| {
        const dinfo = backend.audioTrackInfo(@intCast(i));
        // Copy backend strings before close() frees them. On OOM, keep tracks
        // already cached; owned_strings retains every completed duplication.
        const language = self.allocator.dupe(u8, dinfo.language) catch return;
        self.owned_strings.appendAssumeCapacity(language);
        const name = self.allocator.dupe(u8, dinfo.name) catch return;
        self.owned_strings.appendAssumeCapacity(name);
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

/// Engine virtual that creates a playback for this stream.
pub fn _instantiatePlayback(self: *NativeVideoStream) ?*VideoStreamPlayback {
    const playback = NativeVideoStreamPlayback.create(&self.allocator) catch return null;
    playback.applyOutputMode(self.output_mode);

    // Prune dead ids, then record the new playback's id so setOutputMode() can
    // reach it later. The list stays bounded across many instantiations.
    self.pruneDeadPlaybacks();
    self.playback_ids.append(self.allocator, object_id.fromRaw(playback.base.getInstanceId())) catch {
        // Playback still runs, but will not receive future output-mode updates.
        log.warn("failed to record playback id; it will not receive output_mode updates", .{});
    };

    // VideoStream.getFile() holds the path the ResourceFormatLoader recorded.
    var file = self.base.getFile();
    defer file.deinit();
    // Return an empty playback on load failure; _getTexture() yields null.
    _ = playback.load(file);
    return playback.base;
}
