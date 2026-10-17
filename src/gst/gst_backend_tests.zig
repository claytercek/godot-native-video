const std = @import("std");
const gst = @import("gst_backend.zig");
const t = std.testing;

fn fixture() ![]const u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const path = "project/synthetic.mp4";
    std.Io.Dir.cwd().access(io, path, .{}) catch return error.SkipZigTest;
    return path;
}

test "closed backend is inert and close is idempotent" {
    const b = try gst.create(t.allocator);
    defer b.deinit();
    try t.expectEqual(@as(i32, 0), b.videoWidth());
    try t.expectEqual(@as(i32, 0), b.audioTrackCount());
    try t.expect(b.nextVideoFrame() == null);
    try t.expect(b.nextAudioChunk() == null);
    try t.expect(!b.seek(0));
    try t.expect(!b.reselectAudioTrack(0, 0));
    b.close();
    b.close();
}

test "serialized all video before audio, EOS, reset and retained frame" {
    const path = try fixture();
    const b = try gst.create(t.allocator);
    var alive = true;
    defer if (alive) b.deinit();
    try t.expect(b.open(path));
    try t.expect(b.durationSeconds() > 0);
    try t.expect(b.videoWidth() > 0);
    try t.expect(b.videoHeight() > 0);
    const first = b.nextVideoFrame() orelse return error.NoVideo;
    defer first.release();
    const view = gst.frameView(first.native_handle.?);
    const hash = std.hash.Wyhash.hash(0, view.planes[0]);
    var frames: usize = 1;
    var previous = first.pts_seconds;
    while (b.nextVideoFrame()) |f| {
        defer f.release();
        try t.expect(std.math.isFinite(f.pts_seconds));
        try t.expect(f.pts_seconds >= previous);
        previous = f.pts_seconds;
        try t.expectEqual(@as(u32, 0), f.crop.width);
        const fv = gst.frameView(f.native_handle.?);
        try t.expect(fv.strides[0] > 0 and fv.strides[1] > 0);
        frames += 1;
    }
    try t.expect(frames > 1);
    try t.expect(b.nextVideoFrame() == null);
    var chunks: usize = 0;
    var energy: f64 = 0;
    while (b.nextAudioChunk()) |a| {
        try t.expect(a.frame_count > 0 and a.channel_count > 0 and a.sample_rate > 0);
        try t.expectEqual(@as(usize, @intCast(a.frame_count * a.channel_count)), a.samples.len);
        for (a.samples) |sample| {
            try t.expect(std.math.isFinite(sample));
            energy += @as(f64, sample) * sample;
        }
        chunks += 1;
    }
    if (b.audioTrackCount() > 0) {
        try t.expect(chunks > 0);
        try t.expect(energy > 0);
    }
    try t.expect(b.nextAudioChunk() == null);
    try t.expectEqual(@as(i32, 0), b.audioTrackInfo(-1).channels);
    try t.expectEqual(@as(i32, 0), b.audioTrackInfo(999).channels);
    b.selectAudioTrack(999);
    try t.expect(b.seek(0));
    // Reverse the drain order on replay.
    while (b.nextAudioChunk()) |_| {}
    const replay = b.nextVideoFrame() orelse return error.NoReplay;
    replay.release();
    if (b.audioTrackCount() > 0) {
        try t.expect(b.reselectAudioTrack(0, 0));
        try t.expect(b.nextAudioChunk() != null);
    }
    try t.expect(!b.seek(std.math.nan(f64)));
    b.close();
    try t.expect(b.open(path));
    b.deinit();
    alive = false;
    try t.expectEqual(hash, std.hash.Wyhash.hash(0, gst.frameView(first.native_handle.?).planes[0]));
}
