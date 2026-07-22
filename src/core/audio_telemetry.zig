//! AudioTelemetry — numeric instrumentation for the audio delivery path
//! (decoded chunks -> AudioRing -> Godot's mix sink).
//!
//! Exists to replace guessing with numbers when audio sounds wrong: is the
//! ring underrunning (silence padding), is the shared decoder starving the
//! ring of chunks, or is media time itself running fast? All four surface
//! here as plain counters, updated with integer/float adds only -- no
//! allocation, so this is safe to update on the per-tick mix path.
//!
//! Godot-free (no Godot types): PlaybackController owns one instance and
//! feeds it from fillAudioClosure() (decode side) and driveAudio() (mix
//! side). Reporting is pull-driven by the caller at existing per-tick and
//! stop/EOS/shutdown points -- no timer, no background thread. std.log.info
//! already reaches the Godot editor Output panel via the Binding's logFn
//! (verbose-gated: visible when Godot itself is run with `--verbose`, same
//! as `print_verbose()`; still on stderr unconditionally), so logging
//! straight from core is safe.
//!
//! Reset every load() so a reopened clip starts a fresh window.

const std = @import("std");
const wall_clock_mod = @import("wall_clock.zig");

const WallClockMs = wall_clock_mod.WallClockMs;

const log = std.log.scoped(.audio_telemetry);

pub const AudioTelemetry = struct {
    // --- Mix side (driveAudio, once per tick) ---
    mix_calls: u64 = 0,
    frames_offered: u64 = 0, // frames handed to the sink across all mix calls (ring content or silence)
    frames_served: u64 = 0, // of those, real ring-sourced frames the sink accepted
    silence_frames: u64 = 0, // of those, underrun-padding frames the sink accepted
    underrun_events: u64 = 0, // transitions INTO a starved (ring-empty) tick, not per-frame
    was_starved: bool = false, // previous mix call's ring state, for edge detection
    consecutive_silence: u64 = 0, // running silent-frame streak, reset on a fed tick
    max_silence_run: u64 = 0,
    ring_min: usize = std.math.maxInt(usize),
    ring_max: usize = 0,

    // --- Decode side (fillAudioClosure, per chunk consumed) ---
    chunks_in: u64 = 0,
    decoded_frames_in: u64 = 0,

    // --- Real-rate check ---
    first_mix_wall_ms: ?f64 = null,
    first_mix_media_s: f64 = 0.0,

    // --- Reporting cadence ---
    next_report_media_s: f64 = report_interval_media_s,
    reported_final: bool = false,

    const report_interval_media_s: f64 = 5.0;

    /// Fresh window: called from PlaybackController.load().
    pub fn reset(self: *AudioTelemetry) void {
        self.* = .{};
    }

    /// One decoded chunk pulled from the backend (fillAudioClosure, after the
    /// EOS check). Counts every real chunk, including zero-length ones; only
    /// adds to decoded_frames_in when frame_count is positive.
    pub fn recordChunk(self: *AudioTelemetry, frame_count: i32) void {
        self.chunks_in += 1;
        if (frame_count > 0) self.decoded_frames_in += @intCast(frame_count);
    }

    /// One driveAudio() call. `available_before` is the ring's availableFrames()
    /// sampled BEFORE the read (the watermark sample); `requested` is the frame
    /// count offered to the sink; `accepted` is what the sink returned.
    pub fn recordMix(
        self: *AudioTelemetry,
        now: WallClockMs,
        media_time: f64,
        available_before: usize,
        requested: i32,
        accepted: i32,
    ) void {
        self.mix_calls += 1;
        if (self.first_mix_wall_ms == null) {
            self.first_mix_wall_ms = now.ms;
            self.first_mix_media_s = media_time;
        }
        self.ring_min = @min(self.ring_min, available_before);
        self.ring_max = @max(self.ring_max, available_before);
        self.frames_offered += @intCast(@max(requested, 0));

        const accepted_frames: u64 = @intCast(@max(accepted, 0));
        const starved = available_before == 0;
        if (starved) {
            self.silence_frames += accepted_frames;
            self.consecutive_silence += accepted_frames;
            self.max_silence_run = @max(self.max_silence_run, self.consecutive_silence);
            if (!self.was_starved) self.underrun_events += 1;
        } else {
            self.frames_served += accepted_frames;
            self.consecutive_silence = 0;
        }
        self.was_starved = starved;
    }

    /// Periodic report: fires once every ~5s of media time. No-op until the
    /// first mix has happened (nothing to report) or the interval hasn't
    /// elapsed. Called from tick() every tick; cheap when it's a no-op.
    pub fn maybeReportPeriodic(self: *AudioTelemetry, now: WallClockMs, media_time: f64) void {
        if (self.mix_calls == 0) return;
        if (media_time < self.next_report_media_s) return;
        self.logSummary("audio-telemetry", now, media_time);
        self.next_report_media_s += report_interval_media_s;
    }

    /// Final summary: stop() / EOS / shutdown(). Fires at most once per
    /// load() -- later callers (e.g. shutdown() after stop() already
    /// reported) are a no-op.
    pub fn reportFinal(self: *AudioTelemetry, now: WallClockMs, media_time: f64) void {
        if (self.reported_final or self.mix_calls == 0) return;
        self.reported_final = true;
        self.logSummary("audio-telemetry final", now, media_time);
    }

    fn logSummary(self: *AudioTelemetry, tag: []const u8, now: WallClockMs, media_time: f64) void {
        const wall_elapsed_s: f64 = if (self.first_mix_wall_ms) |t0| (now.ms - t0) / 1000.0 else 0.0;
        const media_elapsed_s = media_time - self.first_mix_media_s;
        const ring_min_report: usize = if (self.ring_min == std.math.maxInt(usize)) 0 else self.ring_min;
        const mixed_frames = self.frames_served + self.silence_frames;
        log.info(
            "{s}: {d} mixes, offered {d} fr, mixed {d} fr (silence {d} fr / {d} underruns, max run {d} fr), in {d} fr / {d} chunks, ring {d}..{d}, media {d:.2}s wall {d:.2}s",
            .{
                tag,
                self.mix_calls,
                self.frames_offered,
                mixed_frames,
                self.silence_frames,
                self.underrun_events,
                self.max_silence_run,
                self.decoded_frames_in,
                self.chunks_in,
                ring_min_report,
                self.ring_max,
                media_elapsed_s,
                wall_elapsed_s,
            },
        );
    }
};

test "AudioTelemetry: a fully-fed mix counts as served, not silence" {
    var t: AudioTelemetry = .{};
    t.recordMix(WallClockMs.init(0.0), 0.0, 1024, 1024, 1024);
    try std.testing.expectEqual(1, t.mix_calls);
    try std.testing.expectEqual(1024, t.frames_served);
    try std.testing.expectEqual(0, t.silence_frames);
    try std.testing.expectEqual(0, t.underrun_events);
    try std.testing.expectEqual(0, t.max_silence_run);
}

test "AudioTelemetry: a starved mix counts as silence and fires one underrun event" {
    var t: AudioTelemetry = .{};
    t.recordMix(WallClockMs.init(0.0), 0.0, 0, 256, 256);
    try std.testing.expectEqual(0, t.frames_served);
    try std.testing.expectEqual(256, t.silence_frames);
    try std.testing.expectEqual(1, t.underrun_events);
    try std.testing.expectEqual(256, t.max_silence_run);
}

test "AudioTelemetry: consecutive starved mixes are one event, not one per call" {
    var t: AudioTelemetry = .{};
    t.recordMix(WallClockMs.init(0.0), 0.0, 0, 256, 256);
    t.recordMix(WallClockMs.init(5.0), 0.05, 0, 256, 256);
    t.recordMix(WallClockMs.init(10.0), 0.1, 0, 256, 256);
    try std.testing.expectEqual(1, t.underrun_events); // one transition, not three
    try std.testing.expectEqual(768, t.silence_frames);
    try std.testing.expectEqual(768, t.max_silence_run); // one unbroken run
}

test "AudioTelemetry: a fed tick resets the consecutive-silence run" {
    var t: AudioTelemetry = .{};
    t.recordMix(WallClockMs.init(0.0), 0.0, 0, 256, 256); // starved: run = 256
    t.recordMix(WallClockMs.init(5.0), 0.05, 1024, 1024, 1024); // fed: run resets
    t.recordMix(WallClockMs.init(10.0), 0.1, 0, 256, 256); // starved again: new event
    try std.testing.expectEqual(2, t.underrun_events);
    try std.testing.expectEqual(256, t.max_silence_run); // never exceeded a single run of 256
    try std.testing.expectEqual(1024, t.frames_served);
    try std.testing.expectEqual(512, t.silence_frames);
}

test "AudioTelemetry: ring watermark tracks min/max availableFrames across mixes" {
    var t: AudioTelemetry = .{};
    t.recordMix(WallClockMs.init(0.0), 0.0, 500, 500, 500);
    t.recordMix(WallClockMs.init(5.0), 0.05, 0, 256, 256);
    t.recordMix(WallClockMs.init(10.0), 0.1, 2000, 2000, 2000);
    try std.testing.expectEqual(0, t.ring_min);
    try std.testing.expectEqual(2000, t.ring_max);
}

test "AudioTelemetry: back-pressure (accepted < requested) is not double-counted as silence" {
    var t: AudioTelemetry = .{};
    // Fed tick, but the sink only accepts half -- the shortfall is dropped
    // entirely (see driveAudio's comment), not attributed to silence.
    t.recordMix(WallClockMs.init(0.0), 0.0, 1000, 1000, 400);
    try std.testing.expectEqual(400, t.frames_served);
    try std.testing.expectEqual(0, t.silence_frames);
    try std.testing.expectEqual(1000, t.frames_offered);
}

test "AudioTelemetry: reportFinal and maybeReportPeriodic are no-ops before any mix" {
    var t: AudioTelemetry = .{};
    // Should not crash or set reported_final with no data yet.
    t.reportFinal(WallClockMs.init(0.0), 0.0);
    try std.testing.expect(!t.reported_final);
    t.maybeReportPeriodic(WallClockMs.init(0.0), 10.0);
    try std.testing.expectEqual(AudioTelemetry.report_interval_media_s, t.next_report_media_s);
}

test "AudioTelemetry: reportFinal fires once; later calls are no-ops" {
    var t: AudioTelemetry = .{};
    t.recordMix(WallClockMs.init(0.0), 0.0, 100, 100, 100);
    t.reportFinal(WallClockMs.init(1000.0), 1.0);
    try std.testing.expect(t.reported_final);
    // A second call (e.g. shutdown() after stop() already reported) must not
    // panic and must leave state alone; nothing to assert on log output, but
    // reported_final stays true and counters are untouched.
    t.reportFinal(WallClockMs.init(2000.0), 2.0);
    try std.testing.expect(t.reported_final);
}

test "AudioTelemetry: recordChunk counts chunks and only adds positive frame counts" {
    var t: AudioTelemetry = .{};
    t.recordChunk(4096);
    t.recordChunk(0); // zero-length chunk still counts as consumed
    t.recordChunk(2048);
    try std.testing.expectEqual(3, t.chunks_in);
    try std.testing.expectEqual(6144, t.decoded_frames_in);
}

test "AudioTelemetry: reset clears everything back to a fresh window" {
    var t: AudioTelemetry = .{};
    t.recordChunk(100);
    t.recordMix(WallClockMs.init(0.0), 0.0, 0, 256, 256);
    t.reportFinal(WallClockMs.init(10.0), 1.0);
    t.reset();
    try std.testing.expectEqual(0, t.chunks_in);
    try std.testing.expectEqual(0, t.mix_calls);
    try std.testing.expect(!t.reported_final);
    try std.testing.expectEqual(AudioTelemetry.report_interval_media_s, t.next_report_media_s);
    try std.testing.expect(t.first_mix_wall_ms == null);
}
