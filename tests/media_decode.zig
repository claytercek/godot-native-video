const std = @import("std");
const builtin = @import("builtin");
const decoder = @import("decoder");
const core = @import("core");
const VideoFrame = core.backend.VideoFrame;
const Backend = core.backend.Backend;
const testing = std.testing;

const fixtures = @import("fixtures");
const pcm_rate = 48_000;
const gstreamer = builtin.os.tag == .linux;

const VideoChecks = struct {
    fps: ?f64 = null,
    pts_tolerance: ?f64 = null,
    size: ?[2]i32 = null,
    format: ?core.backend.PixelFormat = null,
    transfer: ?core.backend.TransferFunction = null,
};

const h264: VideoChecks = .{
    .fps = 30,
    .size = .{ 320, 240 },
    .format = if (gstreamer) .nv12 else null,
};

fn openFixture(path: []const u8) !Backend {
    const backend = try decoder.create(testing.allocator);
    errdefer backend.deinit();
    try open(backend, path);
    return backend;
}

fn open(backend: Backend, path: []const u8) !void {
    if (!backend.open(path)) {
        std.debug.print("could not open media fixture: {s}\n", .{path});
        return error.OpenFixtureFailed;
    }
}

fn expectVideoFrames(backend: Backend, count: usize, checks: VideoChecks) !void {
    for (0..count) |index| {
        const frame = backend.nextVideoFrame() orelse {
            std.debug.print("video stopped after {d} of {d} frames\n", .{ index, count });
            return error.ShortVideo;
        };
        defer frame.release();
        try expectVideoFrame(frame, index, checks);
    }
    for (0..2) |_| {
        if (backend.nextVideoFrame()) |extra| {
            extra.release();
            return error.ExtraVideoFrame;
        }
    }
}

fn expectVideoFrame(frame: VideoFrame, index: usize, checks: VideoChecks) !void {
    try testing.expect(frame.native_handle != null);
    try testing.expect(std.math.isFinite(frame.pts_seconds));
    if (checks.fps) |fps| try expectFrameTime(frame, index, fps, checks.pts_tolerance);
    if (checks.size) |size| try testing.expectEqual(size, [2]i32{ frame.width, frame.height });
    if (checks.format) |format| {
        try testing.expectEqual(format, frame.pixel_format);
        try testing.expectEqual(@as(i32, if (format == .x420) 10 else 8), frame.color.bit_depth);
    }
    if (checks.transfer) |transfer| try testing.expectEqual(transfer, frame.color.transfer);
}

fn expectFrameTime(frame: VideoFrame, index: usize, fps: f64, tolerance: ?f64) !void {
    // Allow timestamp rounding, but not enough to mistake an adjacent frame for this one.
    const seconds = @as(f64, @floatFromInt(index)) / fps;
    try testing.expectApproxEqAbs(seconds, frame.pts_seconds, tolerance orelse 0.25 / fps);
}

fn expectTrackFormat(backend: Backend, index: i32, channels: i32) !void {
    const track = backend.audioTrackInfo(index);
    try testing.expectEqual(channels, track.channels);
    try testing.expectEqual(@as(i32, pcm_rate), track.sample_rate);
}

fn expectPcmFormat(backend: Backend, channels: i32) !void {
    try testing.expectEqual(channels, backend.audioChannelCount());
    try testing.expectEqual(@as(i32, pcm_rate), backend.audioSampleRate());
}

fn pcmFrames(chunk: core.backend.AudioChunk, channels: i32) !usize {
    try testing.expectEqual(channels, chunk.channel_count);
    try testing.expectEqual(@as(i32, pcm_rate), chunk.sample_rate);
    try testing.expect(chunk.frame_count > 0);
    const frames: usize = @intCast(chunk.frame_count);
    try testing.expectEqual(frames * @as(usize, @intCast(channels)), chunk.samples.len);
    return frames;
}

fn expectPcm(backend: Backend, comptime channels: usize, tone_hz: ?f64) !void {
    try expectPcmFormat(backend, channels);

    // A quarter-second window distinguishes the tones without depending on AAC
    // packet size, priming, or the exact phase after a seek.
    const window = pcm_rate / 4;
    var frames: usize = 0;
    var energy: [channels]f64 = @splat(0);
    var previous: f32 = 0;
    var crossings: usize = 0;
    while (frames < window) {
        const chunk = backend.nextAudioChunk() orelse return error.ShortAudio;
        const chunk_frames = try pcmFrames(chunk, channels);
        const take = @min(chunk_frames, window - frames);
        for (0..take) |i| {
            const samples = chunk.samples[i * channels ..][0..channels];
            for (samples, &energy) |sample, *sum| {
                try testing.expect(std.math.isFinite(sample));
                sum.* += @as(f64, sample) * sample;
            }
            if (tone_hz != null) {
                if (previous <= 0 and samples[0] > 0) crossings += 1;
                previous = samples[0];
            }
        }
        frames += take;
    }
    for (energy) |sum| try testing.expect(@sqrt(sum / window) > 0.005);
    if (tone_hz) |expected| {
        const hz = @as(f64, @floatFromInt(crossings)) * 4;
        try testing.expectApproxEqAbs(expected, hz, 40);
    }
}

fn expectStereoEos(backend: Backend) !void {
    try expectPcmFormat(backend, 2);
    const expected_frames = 3 * pcm_rate;
    // Allow up to two AAC or 20 ms Opus packets of priming or tail padding.
    const padding = 2 * 1024;
    var frames: usize = 0;
    var energy: [2]f64 = @splat(0);
    var previous_pts: f64 = -std.math.inf(f64);
    while (backend.nextAudioChunk()) |chunk| {
        frames += try pcmFrames(chunk, 2);
        try testing.expect(frames <= expected_frames + padding);
        try testing.expect(std.math.isFinite(chunk.pts_seconds));
        try testing.expect(chunk.pts_seconds + 0.0001 >= previous_pts);
        previous_pts = chunk.pts_seconds;
        for (0.., chunk.samples) |i, sample| {
            try testing.expect(std.math.isFinite(sample));
            energy[i % 2] += @as(f64, sample) * sample;
        }
    }
    try testing.expectApproxEqAbs(@as(f64, expected_frames), @as(f64, @floatFromInt(frames)), padding);
    try testing.expect(backend.nextAudioChunk() == null);
    for (energy) |sum| {
        const rms = @sqrt(sum / @as(f64, @floatFromInt(frames)));
        try testing.expect(rms > 0.01 and rms < 0.5);
    }
}

fn expectSilent(backend: Backend) !void {
    try testing.expectEqual(@as(i32, 0), backend.audioTrackCount());
    try testing.expectEqual(@as(i32, 0), backend.audioChannelCount());
    try testing.expect(backend.nextAudioChunk() == null);
}

fn closeBounded(backend: Backend) !void {
    const started = core.sys_clock.nanoTimestamp();
    backend.close();
    try testing.expect(core.sys_clock.nanoTimestamp() - started < 2 * std.time.ns_per_s);
}

fn expectReplay(path: []const u8, count: usize, checks: VideoChecks, comptime with_audio: bool) !void {
    const backend = try openFixture(path);
    defer backend.deinit();

    const size = checks.size.?;
    try testing.expectEqual(size, [2]i32{ backend.videoWidth(), backend.videoHeight() });
    const duration = @as(f64, @floatFromInt(count)) / checks.fps.?;
    try testing.expectApproxEqAbs(duration, backend.durationSeconds(), if (gstreamer) 0.05 else 0.1);
    if (with_audio) {
        try testing.expectEqual(@as(i32, 1), backend.audioTrackCount());
        try expectTrackFormat(backend, 0, 2);
    }
    const expectAudio = if (with_audio) expectStereoEos else expectSilent;

    // Either stream can stall if the other stream's queue fills up. Seeking
    // before the first drain once deadlocked GStreamer's paired readers.
    try testing.expect(backend.seek(0));
    try expectVideoFrames(backend, count, checks);
    try expectAudio(backend);
    if (checks.format) |format| try testing.expectEqual(@as(i32, if (format == .x420) 10 else 8), backend.colorimetry().bit_depth);
    if (with_audio) {
        try testing.expect(backend.seek(1));
        const fps = checks.fps.?;
        const tolerance = checks.pts_tolerance orelse 0.25 / fps;
        {
            var frame = backend.nextVideoFrame() orelse return error.NoVideoAfterSeek;
            // These clips have a keyframe at 1 s. The MP4 demuxer can align to the
            // preceding AAC packet, exposing the tail of one video frame first.
            if (frame.pts_seconds < 1 - tolerance) {
                const early_pts = frame.pts_seconds;
                frame.release();
                try testing.expect(early_pts >= 1 - 1 / fps);
                frame = backend.nextVideoFrame() orelse return error.NoVideoAfterSeek;
            }
            defer frame.release();
            try expectVideoFrame(frame, @intFromFloat(fps), checks);
        }
        try expectPcm(backend, 2, 440);
    }
    try testing.expect(backend.seek(0));
    try expectAudio(backend);
    try expectVideoFrames(backend, count, checks);
    try closeBounded(backend);

    try open(backend, path);
    {
        const frame = backend.nextVideoFrame() orelse return error.ReopenProducedNoVideo;
        defer frame.release();
        try expectVideoFrame(frame, 0, checks);
    }
    try closeBounded(backend);
}

test "media: H.264 and stereo AAC reach EOS in either drain order and replay" {
    try expectReplay(fixtures.h264_aac, 90, h264, true);
}

test "media: silent H.264 reaches EOS and replays without PCM" {
    try expectReplay(fixtures.h264_silent, 90, h264, false);
}

test "media: multitrack MP4 exposes both audio tracks and decodes PCM" {
    const backend = try openFixture(fixtures.multitrack);
    defer backend.deinit();

    try testing.expectEqual(@as(i32, 2), backend.audioTrackCount());
    try expectTrackFormat(backend, 0, 2);
    try expectTrackFormat(backend, 1, 2);
    if (gstreamer) {
        const low = backend.audioTrackInfo(0);
        const high = backend.audioTrackInfo(1);
        try testing.expect(std.mem.eql(u8, low.language, "en") or std.mem.eql(u8, low.language, "eng"));
        try testing.expect(std.mem.eql(u8, high.language, "de") or std.mem.eql(u8, high.language, "deu"));
        // MP4 demuxers may omit handler labels and the default flag.
        if (low.name.len != 0) try testing.expectEqualStrings("low-tone", low.name);
        if (high.name.len != 0) try testing.expectEqualStrings("high-tone", high.name);
        try testing.expect(!low.is_default);
        try expectVideoFrames(backend, 90, h264);
        try expectPcm(backend, 2, 440);
        backend.selectAudioTrack(0);
        try testing.expect(backend.seek(0));
        try expectPcm(backend, 2, 440);
        try expectVideoFrames(backend, 90, h264);
        // GStreamer's nonzero track switches are exercised by test-gst-extended.
        return;
    }
    for ([_]f64{ 440, 880 }, 0..) |hz, index| {
        backend.selectAudioTrack(@intCast(index));
        try testing.expect(backend.seek(1.0));
        try expectPcm(backend, 2, hz);
    }
}

// Windows HEVC requires an MFT that is not installed by default.
test "media: HEVC Main10 preserves 10-bit PQ video through EOS and replay" {
    switch (builtin.os.tag) {
        .macos, .linux => {},
        else => return error.SkipZigTest,
    }
    try expectReplay(fixtures.hevc_pq, 30, .{
        .fps = 30,
        .size = .{ 320, 240 },
        .format = .x420,
        .transfer = .pq,
    }, false);
}

const codec_8: VideoChecks = .{ .fps = 30, .size = .{ 320, 240 }, .format = .nv12 };
const codec_10: VideoChecks = .{ .fps = 2, .pts_tolerance = 0.001, .size = .{ 320, 240 }, .format = .x420 };

test "media: VP9 Profile 0 with AAC and silent Profile 2 in MP4" {
    if (!fixtures.expect_vp9) return error.SkipZigTest;
    try expectReplay(fixtures.vp9_8_mp4, 90, codec_8, true);
    try expectReplay(fixtures.vp9_10_mp4, 2, codec_10, false);
}

test "media: AV1 Main with AAC and silent 10-bit Main in MP4" {
    if (!fixtures.expect_av1) return error.SkipZigTest;
    try expectReplay(fixtures.av1_8_mp4, 90, codec_8, true);
    try expectReplay(fixtures.av1_10_mp4, 2, codec_10, false);
}

test "media: VP9 Profile 0 with Opus and silent Profile 2 in WebM" {
    if (!gstreamer) return error.SkipZigTest;
    try expectReplay(fixtures.vp9_8_webm, 90, codec_8, true);
    try expectReplay(fixtures.vp9_10_webm, 2, codec_10, false);
}

test "media: AV1 Main with Opus and silent 10-bit Main in WebM" {
    if (!gstreamer) return error.SkipZigTest;
    try expectReplay(fixtures.av1_8_webm, 90, codec_8, true);
    try expectReplay(fixtures.av1_10_webm, 2, codec_10, false);
}

test "media: Matroska preserves track titles and the second-track default on GStreamer" {
    if (!gstreamer) return error.SkipZigTest;
    const backend = try openFixture(fixtures.multitrack_mkv);
    defer backend.deinit();

    try testing.expectEqual(@as(i32, 2), backend.audioTrackCount());
    const low = backend.audioTrackInfo(0);
    const high = backend.audioTrackInfo(1);
    try testing.expectEqualStrings("low-tone", low.name);
    try testing.expectEqualStrings("high-tone", high.name);
    try testing.expect(!low.is_default);
    try testing.expect(high.is_default);
    try expectVideoFrames(backend, 90, h264);
    try expectPcm(backend, 2, null);
    try closeBounded(backend);
}

test "media stress: B-frames arrive in presentation order through EOS" {
    const backend = try openFixture(fixtures.bframes);
    defer backend.deinit();

    try expectVideoFrames(backend, 72, .{ .fps = 24 });
}

test "media stress: 5.1 AAC exposes one six-channel track with signal in every channel" {
    const backend = try openFixture(fixtures.surround);
    defer backend.deinit();

    try testing.expectEqual(@as(i32, 1), backend.audioTrackCount());
    try expectTrackFormat(backend, 0, 6);
    try expectVideoFrames(backend, 90, .{});
    try expectPcm(backend, 6, null);
}

test "media stress: a preceding MOV timecode track does not hide stereo audio" {
    const backend = try openFixture(fixtures.timecode);
    defer backend.deinit();

    try testing.expectEqual(@as(i32, 1), backend.audioTrackCount());
    try expectTrackFormat(backend, 0, 2);
    try expectPcm(backend, 2, null);
    try expectVideoFrames(backend, 72, .{});
}

test "media stress: MOV with timecode, 5.1 AAC, and B-frames decodes after seek" {
    const backend = try openFixture(fixtures.combined);
    defer backend.deinit();

    try testing.expectEqual(@as(i32, 1), backend.audioTrackCount());
    try expectTrackFormat(backend, 0, 6);
    backend.selectAudioTrack(0);
    try testing.expect(backend.seek(0));
    try expectVideoFrames(backend, 72, .{ .fps = 24 });
    try expectPcm(backend, 6, null);
}

test "media stress: the 240-frame marker timeline stays ordered and rewinds after EOS" {
    const backend = try openFixture(fixtures.marker);
    defer backend.deinit();

    // Backend exposes opaque surfaces, so this checks PTS order, not marker pixels.
    try expectVideoFrames(backend, 240, .{ .fps = 24 });
    try testing.expect(backend.seek(0));
    const first = backend.nextVideoFrame() orelse return error.NoVideoAfterSeek;
    defer first.release();
    try expectFrameTime(first, 0, 24, null);
}

test "media stress: non-macroblock-aligned video exposes 854x480 display dimensions" {
    const backend = try openFixture(fixtures.nonmod16);
    defer backend.deinit();

    try testing.expectEqual(@as(i32, 854), backend.videoWidth());
    try testing.expectEqual(@as(i32, 480), backend.videoHeight());
    const frame = backend.nextVideoFrame() orelse return error.ShortVideo;
    defer frame.release();
    try testing.expectEqual(@as(i32, 854), frame.width);
    try testing.expectEqual(@as(i32, 480), frame.height);
    if (frame.crop.width != 0) {
        try testing.expectEqual(@as(u32, 854), frame.crop.width);
        try testing.expectEqual(@as(u32, 480), frame.crop.height);
    }
}
