//! Integration checks through Backend, not GStreamer internals or test doubles.
//! Run via `zig build linux-decode-regression -- av|silent|hevc10|vp9ten|multi|defaults|reject|missing-decoder <path>`.
//! The runner applies an external timeout as protection against a blocked native call.
const std = @import("std");
const gst = @import("gst");
const core = @import("core");
const Backend = core.backend.Backend;

fn require(ok: bool, reason: []const u8) !void {
    if (!ok) {
        std.debug.print("LINUX_DECODE_FAIL {s}\n", .{reason});
        return error.RegressionFailed;
    }
}

fn drainVideo(backend: Backend, ten_bit: bool, expected: usize, duration: f64) !void {
    var count: usize = 0;
    var previous: f64 = -1;
    while (backend.nextVideoFrame()) |frame| {
        defer frame.release();
        try require(std.math.isFinite(frame.pts_seconds), "nonfinite video PTS");
        try require(frame.pts_seconds + 0.0001 >= previous, "video PTS regressed within one generation");
        try require(frame.width == 320 and frame.height == 240, "unexpected decoded frame dimensions");
        try require(frame.native_handle != null, "video frame has no retained payload");
        try require(frame.pixel_format == @as(core.backend.PixelFormat, if (ten_bit) .x420 else .nv12), "wrong decoded pixel format/precision");
        if (ten_bit) {
            try require(frame.color.bit_depth == 10 and frame.color.transfer == .pq, "Main10/PQ metadata was lost");
        }
        if (count == 0) {
            std.debug.print("LINUX_DECODE_FIRST pts={d:.6}\n", .{frame.pts_seconds});
            try require(frame.pts_seconds >= -0.001 and frame.pts_seconds <= 0.04, "seek(0) lost first video frame");
        }
        previous = frame.pts_seconds;
        count += 1;
        try require(count <= expected, "duplicate/extra decoded video frames");
    }
    try require(count == expected, "video EOS arrived before expected frame count");
    try require(@abs(previous - (duration - 1.0 / 30.0)) <= 0.04, "video tail PTS missing at EOS");
    try require(backend.nextVideoFrame() == null, "video EOS was not stable");
    std.debug.print("LINUX_DECODE_VIDEO frames={d} last_pts={d:.6} format={s}\n", .{ count, previous, if (ten_bit) "p010" else "nv12" });
}

fn drainAudio(backend: Backend, with_audio: bool) !void {
    var frames: usize = 0;
    var chunks: usize = 0;
    var energy: f64 = 0;
    var previous: f64 = -1;
    while (backend.nextAudioChunk()) |chunk| {
        try require(with_audio, "silent source produced PCM");
        try require(chunk.channel_count == 2 and chunk.sample_rate == 48000, "PCM channel/rate metadata differs from fixture");
        try require(chunk.frame_count > 0, "empty PCM chunk can spin the audio fill loop");
        try require(chunk.samples.len == @as(usize, @intCast(chunk.frame_count)) * 2, "PCM is not frame-interleaved stereo");
        try require(std.math.isFinite(chunk.pts_seconds) and chunk.pts_seconds + 0.0001 >= previous, "invalid/regressing audio PTS");
        previous = chunk.pts_seconds;
        for (chunk.samples) |sample| {
            try require(std.math.isFinite(sample), "nonfinite PCM sample");
            const value: f64 = sample;
            energy += value * value;
        }
        frames += @intCast(chunk.frame_count);
        chunks += 1;
        try require(frames <= 144000 + 2048, "unexpected PCM duplication or unbounded drain");
    }
    try require(backend.nextAudioChunk() == null, "audio EOS was not stable");
    if (with_audio) {
        // Three seconds at 48kHz; tolerate at most two AAC packets of priming/tail.
        try require(frames >= 144000 - 2048 and frames <= 144000 + 2048, "PCM tail lost or duplicated beyond AAC padding tolerance");
        const rms = @sqrt(energy / @as(f64, @floatFromInt(frames * 2)));
        try require(rms > 0.01 and rms < 0.5, "fixture PCM energy is silent or implausible");
        std.debug.print("LINUX_DECODE_PCM chunks={d} frames={d} rms={d:.6}\n", .{ chunks, frames, rms });
    } else {
        try require(frames == 0, "silent source has audio samples");
        std.debug.print("LINUX_DECODE_PCM silent\n", .{});
    }
}

fn trackTone(backend: Backend, expected_hz: f64) !void {
    var frames: usize = 0;
    var crossings: usize = 0;
    var previous: f32 = 0;
    var energy: f64 = 0;
    while (backend.nextAudioChunk()) |chunk| {
        try require(chunk.channel_count == 2 and chunk.sample_rate == 48000 and chunk.frame_count > 0, "multi-track PCM geometry differs from fixture");
        try require(chunk.samples.len == @as(usize, @intCast(chunk.frame_count)) * 2, "multi-track PCM is not interleaved stereo");
        var i: usize = 0;
        while (i < chunk.samples.len) : (i += 2) {
            const value = chunk.samples[i];
            try require(std.math.isFinite(value), "multi-track PCM is nonfinite");
            if (previous <= 0 and value > 0) crossings += 1;
            previous = value;
            energy += @as(f64, value) * @as(f64, value);
            frames += 1;
        }
        try require(frames <= 146048, "multi-track audio drain exceeded fixture duration");
    }
    try require(frames >= 141952, "multi-track audio tail was truncated");
    const hz = @as(f64, @floatFromInt(crossings)) * 48000.0 / @as(f64, @floatFromInt(frames));
    const rms = @sqrt(energy / @as(f64, @floatFromInt(frames)));
    std.debug.print("LINUX_DECODE_TRACK frequency={d:.2} expected={d:.0} frames={d} rms={d:.6}\n", .{ hz, expected_hz, frames, rms });
    try require(@abs(hz - expected_hz) < 40 and rms > 0.01, "track selection returned the wrong tone or silence");
}

fn checkAudioPosition(backend: Backend, target_frame: usize, expected_hz: f64) !void {
    const target = @as(f64, @floatFromInt(target_frame)) / 48000.0;
    var count: usize = 0;
    var dot: f64 = 0;
    var energy: f64 = 0;
    var reference_energy: f64 = 0;
    while (count < 512) {
        const chunk = backend.nextAudioChunk() orelse return error.PositionedAudioMissing;
        try require(chunk.channel_count == 2 and chunk.sample_rate == 48000 and chunk.frame_count > 0, "positioned audio geometry mismatch");
        try require(chunk.samples.len == @as(usize, @intCast(chunk.frame_count)) * 2, "positioned audio is not interleaved stereo");
        const expected_pts = target + @as(f64, @floatFromInt(count)) / 48000.0;
        std.debug.print("LINUX_DECODE_AUDIO_POSITION pts={d:.9} expected={d:.9}\n", .{ chunk.pts_seconds, expected_pts });
        try require(@abs(chunk.pts_seconds - expected_pts) <= 1.5 / 48000.0, "audio seek/reselect replayed keyframe audio instead of target sample");
        const take = @min(@as(usize, @intCast(chunk.frame_count)), 512 - count);
        for (0..take) |i| {
            const value: f64 = chunk.samples[i * 2];
            try require(std.math.isFinite(value), "positioned PCM is nonfinite");
            const t = target + @as(f64, @floatFromInt(count + i)) / 48000.0;
            const reference = @sin(2.0 * std.math.pi * expected_hz * t);
            dot += value * reference;
            energy += value * value;
            reference_energy += reference * reference;
        }
        count += take;
    }
    const correlation = dot / @sqrt(energy * reference_energy);
    std.debug.print("LINUX_DECODE_AUDIO_POSITION correlation={d:.6}\n", .{correlation});
    try require(std.math.isFinite(correlation) and correlation > 0.95, "audio was retimestamped without trimming to the target waveform");
}

fn vp9Ten(backend: Backend, path: []const u8) !void {
    try require(backend.open(path), "VP9 Profile 2 fixture failed to open");
    try require(backend.audioTrackCount() == 0, "silent VP9 fixture unexpectedly has audio");
    var frames: usize = 0;
    while (backend.nextVideoFrame()) |frame| {
        defer frame.release();
        try require(frame.pixel_format == .x420 and frame.color.bit_depth == 10, "VP9 10-bit content was reduced to NV12/8-bit");
        try require(frame.width == 320 and frame.height == 240, "VP9 dimensions changed");
        const expected_pts = @as(f64, @floatFromInt(frames)) * 0.5;
        try require(@abs(frame.pts_seconds - expected_pts) < 0.001, "unexpected VP9 fixture PTS");
        frames += 1;
        try require(frames <= 2, "VP9 duplicated frames");
    }
    try require(frames == 2, "VP9 ended before both frames");
    try require(backend.colorimetry().bit_depth == 10, "VP9 negotiated asset precision was not updated");
    try closeBounded(backend);
}

fn defaultMetadata(backend: Backend, path: []const u8) !void {
    try require(backend.open(path), "Matroska metadata fixture failed to open");
    try require(backend.audioTrackCount() == 2, "Matroska lost an audio track");
    const low = backend.audioTrackInfo(0);
    const high = backend.audioTrackInfo(1);
    try require(!low.is_default and high.is_default, "known second-track container default was not preserved");
    try require(std.mem.eql(u8, low.name, "low-tone") and std.mem.eql(u8, high.name, "high-tone"), "Matroska track titles missing");
    std.debug.print("LINUX_DECODE_DEFAULTS first={} second={} titles={s}/{s}\n", .{ low.is_default, high.is_default, low.name, high.name });
    try closeBounded(backend);
}

fn multiTrack(backend: Backend, path: []const u8) !void {
    try require(backend.open(path), "multi-track fixture failed to open");
    try require(backend.audioTrackCount() == 2, "multi-track metadata lost an audio stream");
    const low = backend.audioTrackInfo(0);
    const high = backend.audioTrackInfo(1);
    std.debug.print("LINUX_DECODE_TRACK_METADATA 0={s}/{s} 1={s}/{s}\n", .{ low.language, low.name, high.language, high.name });
    try require(std.mem.eql(u8, low.language, "en") or std.mem.eql(u8, low.language, "eng"), "first-track language missing");
    try require(std.mem.eql(u8, high.language, "de") or std.mem.eql(u8, high.language, "deu"), "second-track language missing");
    // Names are optional in Backend; FFmpeg's MP4 handler labels are not
    // exposed as GST_TAG_TITLE by every demuxer. Validate supplied names only.
    try require((low.name.len == 0 or std.mem.eql(u8, low.name, "low-tone")) and
        (high.name.len == 0 or std.mem.eql(u8, high.name, "high-tone")), "track titles contradict fixture labels");
    if (low.name.len == 0 or high.name.len == 0) std.debug.print("LINUX_DECODE_NOTE optional track titles unavailable\n", .{});
    // Backend has no tri-state default field: both false may mean unknown,
    // but inventing track zero as default contradicts this container.
    try require(!low.is_default, "first track was fabricated as container default");
    if (!high.is_default) std.debug.print("LINUX_DECODE_NOTE container default unknown\n", .{});
    try drainVideo(backend, false, 90, 3);
    try require(backend.reselectAudioTrack(0, 0), "first-track reselect failed");
    try trackTone(backend, 440);
    try require(backend.nextVideoFrame() == null, "audio reselect disturbed video EOS");
    try require(backend.reselectAudioTrack(1, 0), "second-track reselect failed");
    try trackTone(backend, 880);
    try require(backend.nextVideoFrame() == null, "second-track reselect rewound video");
    try require(backend.seek(0), "seek with second track selected failed");
    try drainVideo(backend, false, 90, 3);
    try trackTone(backend, 880);
    try require(backend.reselectAudioTrack(0, 72151.0 / 48000.0), "nonzero first-track reselect failed");
    try checkAudioPosition(backend, 72151, 440);
    try require(backend.reselectAudioTrack(1, 24353.0 / 48000.0), "nonzero second-track reselect failed");
    try checkAudioPosition(backend, 24353, 880);
    try require(backend.seek(72151.0 / 48000.0), "nonzero shared seek failed");
    try checkAudioPosition(backend, 72151, 880);
    backend.selectAudioTrack(0);
    try require(backend.seek(0), "select-first-track plus seek failed");
    try trackTone(backend, 440);
    try drainVideo(backend, false, 90, 3);
    try closeBounded(backend);
}

fn closeBounded(backend: Backend) !void {
    const started = core.sys_clock.nanoTimestamp();
    backend.close();
    const elapsed = core.sys_clock.nanoTimestamp() - started;
    try require(elapsed < 2 * std.time.ns_per_s, "close exceeded two-second budget");
    std.debug.print("LINUX_DECODE_CLOSE milliseconds={d}\n", .{@divTrunc(elapsed, std.time.ns_per_ms)});
}

pub fn main(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer if (gpa.deinit() == .leak) @panic("owned backend allocation leaked");
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) return error.ExpectedModeAndFixturePath;
    const mode = args[1];
    const path = args[2];
    const reject = std.mem.eql(u8, mode, "reject");
    const missing_decoder = std.mem.eql(u8, mode, "missing-decoder");
    const defaults = std.mem.eql(u8, mode, "defaults");
    const vp9 = std.mem.eql(u8, mode, "vp9ten");
    const multi = std.mem.eql(u8, mode, "multi");
    const with_audio = std.mem.eql(u8, mode, "av");
    const ten_bit = std.mem.eql(u8, mode, "hevc10");
    try require(reject or missing_decoder or defaults or vp9 or multi or with_audio or ten_bit or std.mem.eql(u8, mode, "silent"), "unknown test mode");
    const backend = try gst.create(gpa.allocator());
    defer backend.deinit();
    if (defaults) {
        try defaultMetadata(backend, path);
        std.debug.print("LINUX_DECODE_PASS mode=defaults\n", .{});
        return;
    }
    if (vp9) {
        try vp9Ten(backend, path);
        std.debug.print("LINUX_DECODE_PASS mode=vp9ten\n", .{});
        return;
    }
    if (multi) {
        try multiTrack(backend, path);
        std.debug.print("LINUX_DECODE_PASS mode=multi\n", .{});
        return;
    }
    if (reject or missing_decoder) {
        const opened = backend.open(path);
        if (missing_decoder and opened) {
            if (backend.nextVideoFrame()) |frame| {
                frame.release();
                try require(false, "excluded decoder still produced a frame");
            }
        } else {
            try require(!opened, "invalid/missing media unexpectedly opened");
        }
        try closeBounded(backend);
        std.debug.print("LINUX_DECODE_PASS mode={s}\n", .{mode});
        return;
    }
    try require(backend.open(path), "fixture failed to open");
    const duration: f64 = if (ten_bit) 1 else 3;
    const expected: usize = if (ten_bit) 30 else 90;
    try require(@abs(backend.durationSeconds() - duration) <= 0.05, "fixture duration differs from container");
    try require(backend.videoWidth() == 320 and backend.videoHeight() == 240, "wrong asset dimensions");
    try require(backend.audioTrackCount() == (if (with_audio) @as(i32, 1) else 0), "wrong audio-track count");
    if (with_audio) {
        const track = backend.audioTrackInfo(0);
        try require(track.channels == 2 and track.sample_rate == 48000, "wrong selected track metadata");
    }
    // This order intentionally catches a bounded paired-appsink demux deadlock.
    try require(backend.seek(0), "initial seek failed");
    try drainVideo(backend, ten_bit, expected, duration);
    try drainAudio(backend, with_audio);
    // Seek after both EOS latches, drain in the opposite order, then replay.
    try require(backend.seek(0), "seek after EOS failed");
    try drainAudio(backend, with_audio);
    try drainVideo(backend, ten_bit, expected, duration);
    try require(backend.seek(0), "second replay seek failed");
    try drainVideo(backend, ten_bit, expected, duration);
    try drainAudio(backend, with_audio);
    try closeBounded(backend);
    // Close an active reader too, not only an already-drained pipeline.
    try require(backend.open(path), "reopen after close failed");
    const frame = backend.nextVideoFrame() orelse return error.ReopenProducedNoVideo;
    frame.release();
    try closeBounded(backend);
    std.debug.print("LINUX_DECODE_PASS mode={s}\n", .{mode});
}
