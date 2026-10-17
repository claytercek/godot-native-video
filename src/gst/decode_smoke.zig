//! Standalone, Godot-free decode and frame-lifetime regression.
const std = @import("std");
const gst = @import("gst");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) return error.MissingPath;
    const b = try gst.create(init.gpa);
    var alive = true;
    defer if (alive) b.deinit();
    if (!b.open(args[1])) return error.OpenFailed;
    std.debug.print("open: {d}x{d}, {d:.3}s, {d} audio tracks\n", .{ b.videoWidth(), b.videoHeight(), b.durationSeconds(), b.audioTrackCount() });
    var retained: ?@import("core").backend.VideoFrame = null;
    defer if (retained) |f| f.release();
    var signature: u64 = 0;
    for (0..3) |pass| {
        if (pass != 0 and !b.seek(0)) return error.SeekFailed;
        var frames: usize = 0;
        var chunks: usize = 0;
        var samples: usize = 0;
        var previous: f64 = -1;
        while (b.nextVideoFrame()) |f| {
            if (!std.math.isFinite(f.pts_seconds) or f.pts_seconds < previous) {
                f.release();
                return error.InvalidVideoPTS;
            }
            previous = f.pts_seconds;
            const view = gst.frameView(f.native_handle.?);
            if (view.planes[0].len == 0 or view.planes[1].len == 0) {
                f.release();
                return error.EmptyPlane;
            }
            frames += 1;
            if (retained == null) {
                retained = f;
                signature = std.hash.Wyhash.hash(0, view.planes[0]);
            } else f.release();
        }
        if (b.nextVideoFrame() != null) return error.UnstableEOS;
        previous = -1;
        while (b.nextAudioChunk()) |a| {
            if (!std.math.isFinite(a.pts_seconds) or a.pts_seconds < previous) return error.InvalidAudioPTS;
            previous = a.pts_seconds;
            for (a.samples) |sample| if (!std.math.isFinite(sample)) return error.InvalidPCM;
            if (a.samples.len != @as(usize, @intCast(a.frame_count)) * @as(usize, @intCast(a.channel_count))) return error.InvalidPCMGeometry;
            chunks += 1;
            samples += @intCast(a.frame_count);
        }
        if (b.videoWidth() > 0 and frames == 0) return error.NoFrames;
        if (b.audioTrackCount() > 0 and chunks == 0) return error.NoAudio;
        std.debug.print("pass {d}: {d} frames, {d} PCM chunks / {d} sample frames\n", .{ pass, frames, chunks, samples });
    }
    for (0..@intCast(b.audioTrackCount())) |index| {
        const track = b.audioTrackInfo(@intCast(index));
        std.debug.print("track {d}: language='{s}' name='{s}' {d}Hz/{d}ch default={}\n", .{ index, track.language, track.name, track.sample_rate, track.channels, track.is_default });
        if (!b.reselectAudioTrack(@intCast(index), 0)) return error.TrackReselectFailed;
        const chunk = b.nextAudioChunk() orelse return error.TrackHasNoPCM;
        if (chunk.frame_count == 0) return error.EmptyTrack;
        // Reselecting audio must not reset an already drained video reader.
        if (b.nextVideoFrame()) |unexpected| {
            unexpected.release();
            return error.ReselectResetVideo;
        }
    }
    if (retained) |f| std.debug.print("retained format={t}, color={t}/{t}/{t}/{t}, depth={d}, pts={d:.6}\n", .{ f.pixel_format, f.color.matrix, f.color.primaries, f.color.transfer, f.color.range, f.color.bit_depth, f.pts_seconds });
    b.deinit();
    alive = false;
    if (retained) |f| {
        if (signature != std.hash.Wyhash.hash(0, gst.frameView(f.native_handle.?).planes[0])) return error.RetainedFrameChanged;
    }
    std.debug.print("DECODE_SMOKE_PASS\n", .{});
}
