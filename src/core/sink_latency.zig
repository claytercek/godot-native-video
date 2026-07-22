//! SinkLatencyEstimator — measures how far the audio mix sink runs AHEAD of
//! real-time playout, so the present selector can be shifted back onto what the
//! listener actually hears.
//!
//! WHY: Godot's VideoStreamPlayback.mix_audio() feeds an engine-side audio
//! resampler ring whose size comes from `buffering_msec` (default 500 ms,
//! user-configurable 10..1000 ms) rounded UP to a power of two by
//! AudioRBResampler::setup — ~0.68 s (32768 frames) at 48 kHz. At playback
//! start the sink GULPS enough frames to prime that ring, then accepts at
//! real-time rate. Because the master clock (AudioMasterClock) advances by
//! every frame the sink ACCEPTS, media time races ~gulp seconds ahead of what
//! is audible and stays there. Video, paced against media time, then LEADS
//! audio by that constant depth (the classic "audio lags video" symptom).
//!
//! The depth is not a knowable constant — buffering_msec is configurable and
//! power-of-two rounded — so it is MEASURED: accepted-frames-as-seconds minus
//! real wall time since the first accept converges to the buffered depth once
//! the gulp is done and the sink is draining 1x. The estimate is FROZEN after a
//! short warmup so per-tick wall-clock jitter cannot wobble video pacing, and
//! RESET (re-measured) after a seek/flush or an underrun, when the sink's ring
//! drains and re-primes.
//!
//! Scope: this measures ONLY the accept-side ring depth (the gulp). Downstream
//! AudioServer output latency is a DISJOINT delay already handled by the
//! clock's own latency_seconds; the two are kept separate so neither is
//! double-counted. A silent clip (sample_rate == 0) never feeds the estimator,
//! so its compensation stays exactly zero.

const std = @import("std");
const wall_clock_mod = @import("wall_clock.zig");

const WallClockMs = wall_clock_mod.WallClockMs;

pub const SinkLatencyEstimator = struct {
    // Immutable across a measurement window; preserved by reset().
    sample_rate: i32 = 0,
    warmup_seconds: f64 = default_warmup_seconds,

    // Running measurement state; cleared by reset().
    accepted_frames: u64 = 0,
    first_wall_ms: ?f64 = null,
    estimate_seconds: f64 = 0.0,
    frozen: bool = false,

    /// Freeze the estimate this long (wall seconds) after the first real mix.
    /// The gulp completes well under a second; a couple of seconds guarantees
    /// the measurement has plateaued before we lock it in against jitter.
    pub const default_warmup_seconds: f64 = 2.0;

    pub fn init(sample_rate: i32) SinkLatencyEstimator {
        return .{ .sample_rate = sample_rate };
    }

    /// Begin a fresh measurement window: called at load(), after a seek/flush,
    /// and on an underrun — every point where the sink's ring drains and must
    /// re-prime. Preserves sample_rate/warmup; clears the running estimate so
    /// compensation() ramps back up from the new gulp.
    pub fn reset(self: *SinkLatencyEstimator) void {
        self.accepted_frames = 0;
        self.first_wall_ms = null;
        self.estimate_seconds = 0.0;
        self.frozen = false;
    }

    /// Report a mix that accepted `accepted` REAL (non-silence) frames at wall
    /// time `now`. Silence / zero-accept ticks must NOT be reported: they carry
    /// no real audio and would understate the depth. A no-op once frozen and on
    /// a silent clip (sample_rate == 0).
    pub fn onRealMix(self: *SinkLatencyEstimator, now: WallClockMs, accepted: i32) void {
        if (self.frozen or accepted <= 0 or self.sample_rate <= 0) return;

        if (self.first_wall_ms == null) self.first_wall_ms = now.ms;
        self.accepted_frames += @intCast(accepted);

        const wall_elapsed_s = (now.ms - self.first_wall_ms.?) / 1000.0;
        const accepted_s = @as(f64, @floatFromInt(self.accepted_frames)) /
            @as(f64, @floatFromInt(self.sample_rate));
        // Frames accepted beyond real-time playout ARE the buffered depth. Never
        // negative: a sink that briefly drains faster than it fills cannot mean
        // "negative latency".
        self.estimate_seconds = @max(accepted_s - wall_elapsed_s, 0.0);

        if (wall_elapsed_s >= self.warmup_seconds) self.frozen = true;
    }

    /// Seconds to subtract from master media time to get audible media time.
    pub fn compensation(self: *const SinkLatencyEstimator) f64 {
        return self.estimate_seconds;
    }

    pub fn isFrozen(self: *const SinkLatencyEstimator) bool {
        return self.frozen;
    }
};

// -----------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------

// The synthetic "gulp then steady 1x" accept pattern used across the tests:
// rate 1000 Hz, 0.1 s ticks (100 frames = real-time), a 500-frame (0.5 s) ring
// that primes over the first four ticks (accepting 200/tick while filling) then
// settles to real-time (100/tick). Modeled straight from the drain+fill of a
// mix sink: each tick drains 100 (real-time) and accepts up to the ring's free
// space, offered 200 at a time.
const gulp_rate: i32 = 1000;
const gulp_tick_s: f64 = 0.1;
// accepted-frames-per-tick: four priming ticks, then steady real-time.
const gulp_accepts = [_]i32{ 200, 200, 200, 200, 100, 100, 100, 100, 100, 100, 100, 100 };
const gulp_expected_depth: f64 = 0.5; // 500 frames / 1000 Hz

fn wallAt(tick: usize) WallClockMs {
    return WallClockMs.init(@as(f64, @floatFromInt(tick)) * gulp_tick_s * 1000.0);
}

test "SinkLatencyEstimator converges to the buffered gulp depth" {
    // Warmup high enough that it never freezes; assert the running estimate
    // reaches the ring depth.
    var e = SinkLatencyEstimator{ .sample_rate = gulp_rate, .warmup_seconds = 1000.0 };
    for (gulp_accepts, 0..) |acc, i| {
        e.onRealMix(wallAt(i), acc);
    }
    try std.testing.expectApproxEqAbs(gulp_expected_depth, e.compensation(), 1e-9);
    try std.testing.expect(!e.isFrozen());
}

test "SinkLatencyEstimator freezes after warmup and ignores later jitter" {
    // Warmup 0.35 s: freezes on the first mix whose wall_elapsed >= 0.35 s
    // (tick 4, wall 0.4 s), by which point the estimate has plateaued at 0.5.
    var e = SinkLatencyEstimator{ .sample_rate = gulp_rate, .warmup_seconds = 0.35 };
    var i: usize = 0;
    while (i < 6) : (i += 1) e.onRealMix(wallAt(i), gulp_accepts[i]);
    try std.testing.expect(e.isFrozen());
    try std.testing.expectApproxEqAbs(gulp_expected_depth, e.compensation(), 1e-9);

    // A wild post-freeze accept (e.g. a stutter) must not move the frozen value.
    e.onRealMix(wallAt(6), 100000);
    try std.testing.expectApproxEqAbs(gulp_expected_depth, e.compensation(), 1e-9);
}

test "SinkLatencyEstimator reset re-measures a fresh gulp (seek/flush/underrun)" {
    var e = SinkLatencyEstimator{ .sample_rate = gulp_rate, .warmup_seconds = 0.35 };
    var i: usize = 0;
    while (i < 6) : (i += 1) e.onRealMix(wallAt(i), gulp_accepts[i]);
    try std.testing.expect(e.isFrozen());

    // Seek/flush: the sink re-primes, so the old frozen estimate is discarded.
    e.reset();
    try std.testing.expectApproxEqAbs(0.0, e.compensation(), 1e-9);
    try std.testing.expect(!e.isFrozen());
    // sample_rate survives the reset.
    try std.testing.expectEqual(gulp_rate, e.sample_rate);

    // A fresh, smaller gulp (300-frame ring) re-measures from scratch.
    const accepts2 = [_]i32{ 200, 200, 100, 100, 100, 100 };
    for (accepts2, 0..) |acc, k| e.onRealMix(wallAt(k), acc);
    try std.testing.expectApproxEqAbs(0.3, e.compensation(), 1e-9);
}

test "SinkLatencyEstimator ignores silence / zero-accept ticks" {
    var e = SinkLatencyEstimator{ .sample_rate = gulp_rate, .warmup_seconds = 1000.0 };
    // Zero-accept ticks (underrun silence) must not start the window or move it.
    e.onRealMix(wallAt(0), 0);
    e.onRealMix(wallAt(1), 0);
    try std.testing.expect(e.first_wall_ms == null);
    try std.testing.expectApproxEqAbs(0.0, e.compensation(), 1e-9);

    // The window opens on the first REAL accept, anchored at that wall time.
    e.onRealMix(wallAt(2), 200);
    try std.testing.expectEqual(wallAt(2).ms, e.first_wall_ms.?);
    try std.testing.expectApproxEqAbs(0.2, e.compensation(), 1e-9);
}

test "SinkLatencyEstimator never reports negative compensation" {
    // A sink accepting BELOW real-time (accepted < wall) must clamp to zero, not
    // report a negative "latency".
    var e = SinkLatencyEstimator{ .sample_rate = gulp_rate, .warmup_seconds = 1000.0 };
    e.onRealMix(wallAt(0), 50); // 50 frames but 0 wall elapsed -> 0.05
    e.onRealMix(wallAt(1), 50); // 100 frames / 1000 = 0.1s vs 0.1s wall -> 0
    e.onRealMix(wallAt(2), 50); // 150/1000 = 0.15 vs 0.2 wall -> clamp 0
    try std.testing.expectApproxEqAbs(0.0, e.compensation(), 1e-9);
}

test "SinkLatencyEstimator on a silent clip (sample_rate 0) stays at zero" {
    var e = SinkLatencyEstimator.init(0);
    e.onRealMix(wallAt(0), 4096);
    e.onRealMix(wallAt(1), 4096);
    try std.testing.expectApproxEqAbs(0.0, e.compensation(), 1e-9);
    try std.testing.expect(!e.isFrozen());
}
