//! GStreamer PCM positioning and input rejection through Backend.
//! The PCM check is a test, bounded by `--test-timeout`. Rejections run as
//! `main` instead: a blocked open needs `alarm()` to kill the process, and
//! the missing-decoder case needs a process with its own decoder ranks.
const std = @import("std");
const gst = @import("gst");
const core = @import("core");
const Backend = core.backend.Backend;

const testing = std.testing;
const sample_rate = 48_000;

fn require(ok: bool, reason: []const u8) !void {
    if (!ok) {
        std.debug.print("LINUX_DECODE_FAIL {s}\n", .{reason});
        return error.RegressionFailed;
    }
}

fn sampleTime(frame: usize) f64 {
    return @as(f64, @floatFromInt(frame)) / sample_rate;
}

fn checkAudioPosition(backend: Backend, target_frame: usize, expected_hz: f64) !void {
    const window_frames = 512;
    const target = sampleTime(target_frame);
    var count: usize = 0;
    var dot: f64 = 0;
    var energy: f64 = 0;
    var reference_energy: f64 = 0;
    while (count < window_frames) {
        const chunk = backend.nextAudioChunk() orelse return error.PositionedAudioMissing;
        try require(chunk.channel_count == 2 and chunk.sample_rate == sample_rate and chunk.frame_count > 0, "positioned audio geometry mismatch");
        try require(chunk.samples.len == @as(usize, @intCast(chunk.frame_count)) * 2, "positioned audio is not interleaved stereo");
        const expected_pts = target + sampleTime(count);
        std.debug.print("LINUX_DECODE_AUDIO_POSITION pts={d:.9} expected={d:.9}\n", .{ chunk.pts_seconds, expected_pts });
        // Packet timestamp rounding can clip one extra sample at the target.
        try require(@abs(chunk.pts_seconds - expected_pts) <= 1.5 / @as(f64, sample_rate), "audio seek/reselect replayed keyframe audio instead of target sample");
        const chunk_frames: usize = @intCast(chunk.frame_count);
        const take = @min(chunk_frames, window_frames - count);
        for (0..take) |i| {
            const value: f64 = chunk.samples[i * 2];
            try require(std.math.isFinite(value), "positioned PCM is nonfinite");
            const t = target + sampleTime(count + i);
            const reference = @sin(2.0 * std.math.pi * expected_hz * t);
            dot += value * reference;
            energy += value * value;
            reference_energy += reference * reference;
        }
        count += chunk_frames;
    }
    const correlation = dot / @sqrt(energy * reference_energy);
    std.debug.print("LINUX_DECODE_AUDIO_POSITION sample={d} frequency={d:.0} correlation={d:.6}\n", .{ target_frame, expected_hz, correlation });
    try require(std.math.isFinite(correlation) and correlation > 0.95, "audio was retimestamped without trimming to the target waveform");

    if (target_frame == 0) try checkFullPcm(backend, count, expected_hz);
}

fn checkFullPcm(backend: Backend, consumed_frames: usize, expected_hz: f64) !void {
    const expected_frames = 3 * sample_rate;
    // AAC priming and tail padding can shift the decoded total by up to two packets.
    const padding = 2 * 1024;
    var frames = consumed_frames;
    while (backend.nextAudioChunk()) |chunk| {
        frames += @intCast(chunk.frame_count);
        try require(frames <= expected_frames + padding, "audio replay exceeded the padded PCM frame count");
    }
    std.debug.print("LINUX_DECODE_AUDIO_TOTAL frequency={d:.0} frames={d}\n", .{ expected_hz, frames });
    try require(frames >= expected_frames - padding and frames <= expected_frames + padding, "audio replay did not produce the full PCM frame count");
}

fn reselectAndCheck(backend: Backend, track: i32, target_frame: usize, expected_hz: f64) !void {
    if (!backend.reselectAudioTrack(track, sampleTime(target_frame))) {
        std.debug.print("LINUX_DECODE_FAIL audio reselect failed track={d} sample={d}\n", .{ track, target_frame });
        return error.RegressionFailed;
    }
    try checkAudioPosition(backend, target_frame, expected_hz);
}

fn seekAndCheck(backend: Backend, target_frame: usize, expected_hz: f64) !void {
    if (!backend.seek(sampleTime(target_frame))) {
        std.debug.print("LINUX_DECODE_FAIL shared seek failed sample={d} frequency={d:.0}\n", .{ target_frame, expected_hz });
        return error.RegressionFailed;
    }
    try checkAudioPosition(backend, target_frame, expected_hz);
}

fn drainVideo(backend: Backend) !void {
    const first = backend.nextVideoFrame() orelse return error.NoDecodedVideo;
    first.release();
    while (backend.nextVideoFrame()) |frame| frame.release();
}

fn expectVideoEos(backend: Backend, reason: []const u8) !void {
    if (backend.nextVideoFrame()) |frame| {
        defer frame.release();
        return require(false, reason);
    }
}

test "GStreamer regression: PCM starts at the target sample and audio reselection preserves video EOS" {
    const backend = try gst.create(testing.allocator);
    defer backend.deinit();
    try require(backend.open(@import("fixtures").multitrack), "multi-track fixture failed to open");
    try require(backend.audioTrackCount() == 2, "multi-track fixture lost an audio stream");

    try drainVideo(backend);
    try reselectAndCheck(backend, 0, 0, 440);
    try expectVideoEos(backend, "first-track reselect disturbed video EOS");
    try reselectAndCheck(backend, 1, 0, 880);
    try expectVideoEos(backend, "second-track reselect disturbed video EOS");

    // Seek from drained readers before checking nonzero positions on both tracks.
    try require(backend.seek(0), "rewind with the second track selected failed");
    try drainVideo(backend);
    try checkAudioPosition(backend, 0, 880);
    try reselectAndCheck(backend, 0, 72_151, 440);
    try reselectAndCheck(backend, 1, 24_353, 880);
    try seekAndCheck(backend, 72_151, 880);

    // The AAC packet edge and its following sample exercise clipping with preroll clamped to zero.
    for ([_]usize{ 1024, 1025 }) |target_frame| {
        try reselectAndCheck(backend, 0, target_frame, 440);
    }
    try closeBounded(backend);
}

fn closeBounded(backend: Backend) !void {
    const started = core.sys_clock.nanoTimestamp();
    backend.close();
    const elapsed = core.sys_clock.nanoTimestamp() - started;
    try require(elapsed < 2 * std.time.ns_per_s, "close exceeded two-second budget");
    std.debug.print("LINUX_DECODE_CLOSE milliseconds={d}\n", .{@divTrunc(elapsed, std.time.ns_per_ms)});
}

fn rejectInput(allocator: std.mem.Allocator, path: []const u8, missing_decoder: bool) !void {
    const backend = try gst.create(allocator);
    defer backend.deinit();
    const opened = backend.open(path);
    if (missing_decoder and opened) {
        if (backend.nextVideoFrame()) |frame| {
            frame.release();
            try require(false, "excluded decoder still produced a frame");
        }
    } else {
        try require(!opened, "unsupported media unexpectedly opened");
    }
    try closeBounded(backend);
}

extern "c" fn mkdtemp([*:0]u8) ?[*:0]u8;
extern "c" fn mkfifo([*:0]const u8, std.c.mode_t) c_int;
extern "c" fn alarm(c_uint) c_uint;

fn runRejection(allocator: std.mem.Allocator, name: []const u8, path: []const u8, seconds: c_uint, missing_decoder: bool) !void {
    std.debug.print("LINUX_DECODE_START case={s} timeout={d}s path={s}\n", .{ name, seconds, path });
    _ = alarm(seconds);
    defer _ = alarm(0);
    try rejectInput(allocator, path, missing_decoder);
    std.debug.print("LINUX_DECODE_PASS case={s}\n", .{name});
}

fn testRejections(allocator: std.mem.Allocator, io: std.Io, invalid_file: []const u8, temp_root: []const u8) !void {
    try runRejection(allocator, "invalid", invalid_file, 30, false);

    const dir = try std.fs.path.joinZ(allocator, &.{ temp_root, "gnv-linux-decode.XXXXXX" });
    defer allocator.free(dir);
    if (mkdtemp(dir.ptr) == null) {
        std.debug.print("LINUX_DECODE_FAIL mkdtemp {s}: {t}\n", .{ dir, std.c.errno(-1) });
        return error.TempDirCreationFailed;
    }
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch |err| {
        std.debug.print("LINUX_DECODE_NOTE cleanup {s}: {t}\n", .{ dir, err });
    };

    const missing = try std.fs.path.join(allocator, &.{ dir, "does-not-exist.mp4" });
    defer allocator.free(missing);
    try runRejection(allocator, "missing", missing, 30, false);
    try runRejection(allocator, "directory", dir, 14, false);

    const fifo = try std.fs.path.joinZ(allocator, &.{ dir, "blocked-media.fifo" });
    defer allocator.free(fifo);
    const errno = std.c.errno(mkfifo(fifo.ptr, 0o600));
    if (errno != .SUCCESS) {
        std.debug.print("LINUX_DECODE_FAIL mkfifo {s}: {t}\n", .{ fifo, errno });
        return error.FifoCreationFailed;
    }
    try runRejection(allocator, "fifo", fifo, 14, false);
}

pub fn main(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer if (gpa.deinit() == .leak) @panic("owned backend allocation leaked");
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len == 3 and std.mem.eql(u8, args[1], "--test-rejections")) {
        try testRejections(gpa.allocator(), init.io, args[2], init.environ_map.get("TMPDIR") orelse "/tmp");
        std.debug.print("LINUX_DECODE_PASS mode=--test-rejections\n", .{});
    } else if (args.len == 3 and std.mem.eql(u8, args[1], "missing-decoder")) {
        try runRejection(gpa.allocator(), "missing-decoder", args[2], 30, true);
        std.debug.print("LINUX_DECODE_PASS mode=missing-decoder\n", .{});
    } else {
        return require(false, "expected --test-rejections <invalid fixture> or missing-decoder <valid fixture>");
    }
}
