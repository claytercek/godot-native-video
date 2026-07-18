//! av_drift_test.zig — port of tests/core/test_av_drift.cpp.
//!
//! A/V drift simulation — the key correctness gate for this slice.
//!
//! Model (no Godot, no GPU, fully deterministic with a fixed RNG seed):
//!
//!   * The MASTER CLOCK is the AudioMasterClock. We "consume" audio in fixed
//!     mix blocks (like Godot's AudioServer pulling a buffer), each call
//!     advancing the clock by block_frames / sample_rate. This is exactly how
//!     the binding drives the clock from real audio consumption.
//!
//!   * A simulated DECODE THREAD delivers video frames into a decode-ahead
//!     buffer (a PTS-ordered queue, like the binding's FrameQueue). Frame N
//!     has the ideal PTS N*frame_interval, but it ARRIVES with INDUCED
//!     JITTER: a random, sometimes large delay relative to when it "should"
//!     have been decoded. A deliberate JITTER SPIKE stalls decode entirely
//!     for a span of ticks to test recovery (a decode hiccup).
//!
//!   * Each render tick we run the REAL present-selector (drop-late/hold-early)
//!     against the buffer head/next and the master clock, applying its
//!     decisions (Drop pops the head; Show presents the head; Hold keeps the
//!     current frame). We record the PTS of whatever frame is on screen.
//!
//! Assertions:
//!   (a) Steady state: once frames are flowing, the presented PTS stays within
//!       half a frame interval of the master clock (the standard "in sync"
//!       budget — a frame is correct for ~its own display interval).
//!   (b) Recovery: after the jitter spike drains, the player catches back up to
//!       within the steady-state budget within a bounded number of ticks (it
//!       does NOT drift permanently — drop-late collapses the backlog).
//!
//! This file lives as a sibling test (rather than inside clock.zig or
//! present_selector.zig) because it exercises both modules together, per
//! PORTING.md's "or a sibling <name>_test.zig" allowance.
//!
//! NOTE: the C++ test drives its jitter with a seeded std::mt19937 for
//! bit-exact reproducibility. Zig's std.Random.DefaultPrng is a different
//! algorithm, so the exact per-tick jitter sequence differs from the C++
//! run. The assertions below are statistical bounds (steady-state drift
//! budget, spike-recovery bound), not exact-value checks, so a different
//! (but still fixed-seed, deterministic) PRNG preserves the test's intent.

const std = @import("std");
const clock_mod = @import("clock.zig");
const present_selector = @import("present_selector.zig");

const kSampleRate: i32 = 48000;
const kFps: f64 = 30.0;
const kFrameInterval: f64 = 1.0 / kFps;

// Audio mix block size (frames per AudioServer pull). 512 @ 48k ~= 10.7 ms.
const kMixBlock: i32 = 512;
const kBlockSeconds: f64 = @as(f64, @floatFromInt(kMixBlock)) / @as(f64, @floatFromInt(kSampleRate));

// Consume ~one frame-interval of audio per render tick so the clock advances at
// real rate (2 blocks @ ~10.7 ms ~= 21.3 ms ~ slightly under one 30fps frame;
// close enough that the decoder must keep up).
const kBlocksPerTick: i32 = 2;

// Apply the selector to the decode buffer for the current clock time and return
// the PTS now on screen (or the held value if nothing new is due).
fn runPresent(buf: *std.ArrayList(f64), now: f64, held_pts: f64) f64 {
    var shown = held_pts;
    while (true) {
        const head: ?f64 = if (buf.items.len == 0) null else buf.items[0];
        const next: ?f64 = if (buf.items.len >= 2) buf.items[1] else null;

        const a = present_selector.selectPresentAction(head, next, now, kFrameInterval);
        if (a == .drop) {
            _ = buf.orderedRemove(0); // discard stale head, re-evaluate
            continue;
        }
        if (a == .show) {
            shown = buf.items[0];
            _ = buf.orderedRemove(0);
        }
        // Hold or Show both terminate the tick.
        break;
    }
    return shown;
}

test "A/V drift stays within budget under induced decode jitter" {
    const allocator = std.testing.allocator;

    // Master clock: audio-master, with a realistic output-latency comp.
    const latency = 0.020; // 20 ms, like AudioServer::get_output_latency()
    var clock = clock_mod.AudioMasterClock.init(kSampleRate, latency);
    clock.setPaused(false);

    var buf = std.ArrayList(f64){}; // decode-ahead PTS buffer (PTS-ordered)
    defer buf.deinit(allocator);

    var prng = std.Random.DefaultPrng.init(1234567);
    const rng = prng.random();
    // Jitter: each frame's arrival is perturbed +/- ~0.75 frame around its
    // nominal ready time. Arrivals stay monotonic (we max against the previous).
    const jitter_half_range: f64 = 0.75 * kFrameInterval;

    const kTicks: i32 = 1500;
    const kTotalFrames: i32 = 3000;

    // `wall` is real elapsed time; it advances by exactly the audio duration we
    // consume each tick, the same quantity that drives the master clock. The
    // decoder produces frames against `wall` (real time), the clock reads media
    // time off consumed audio — when in sync the two track each other.
    const kTickSeconds: f64 = @as(f64, @floatFromInt(kBlocksPerTick)) * kBlockSeconds;
    var wall: f64 = 0.0;

    // DECODE SCHEDULE: frame N is "intended" to be ready at N*interval of wall
    // time, but lands at a jittered offset. We give the decoder a real LEAD by
    // shifting the schedule earlier by a few frames so frames arrive before the
    // clock needs them (decode-ahead).
    const kDecodeLead: f64 = 4.0 * kFrameInterval;
    var next_frame: i32 = 0;
    var last_ready: f64 = -1.0; // monotonic arrival guard
    var shown_pts: f64 = -1.0; // nothing on screen yet

    // Hard decode stall (jitter spike): no frames arrive for this span of wall
    // time, then the decoder sprints to catch up afterwards.
    const kSpikeStart: i32 = 500;
    const kSpikeEnd: i32 = 540; // ~40 ticks of total stall
    const spike_begin_wall: f64 = @as(f64, @floatFromInt(kSpikeStart)) * kTickSeconds;
    const spike_end_wall: f64 = @as(f64, @floatFromInt(kSpikeEnd)) * kTickSeconds;

    var steady_drift = std.ArrayList(f64){};
    defer steady_drift.deinit(allocator);
    var peak_post_spike: f64 = 0.0;
    var during_spike_peak: f64 = 0.0;
    var ticks_to_recover: i32 = -1;

    var tick: i32 = 0;
    while (tick < kTicks) : (tick += 1) {
        // --- advance master clock from consumed audio, and wall time in lockstep ---
        var b: i32 = 0;
        while (b < kBlocksPerTick) : (b += 1) {
            clock.onAudioMixed(kMixBlock);
        }
        wall += kTickSeconds;
        const now = clock.mediaTime();

        // --- decode: deliver every frame whose jittered ready time has passed ---
        while (next_frame < kTotalFrames) {
            // Nominal ready time, shifted earlier by the decode lead, plus jitter.
            const jitter = (rng.float(f64) * 2.0 - 1.0) * jitter_half_range;
            var ready = @as(f64, @floatFromInt(next_frame)) * kFrameInterval - kDecodeLead + jitter;
            ready = @max(ready, last_ready); // arrivals are monotonic
            // During the stall window, nothing becomes ready; frames that were
            // scheduled inside it pile up and all land at spike_end_wall.
            if (ready >= spike_begin_wall and ready < spike_end_wall) {
                ready = spike_end_wall;
            }
            if (ready > wall) {
                break; // not ready yet this tick
            }
            try buf.append(allocator, @as(f64, @floatFromInt(next_frame)) * kFrameInterval);
            last_ready = ready;
            next_frame += 1;
        }

        // --- present (drop-late / hold-early) ---
        shown_pts = runPresent(&buf, now, shown_pts);

        // --- record drift ---
        if (shown_pts >= 0.0) {
            const drift = @abs(now - shown_pts);
            if (tick < kSpikeStart) {
                if (tick > 30) { // skip warm-up
                    try steady_drift.append(allocator, drift);
                }
            } else {
                // From the stall onward: the held frame goes stale as the buffer
                // drains, so drift grows during the spike; once frames flow again
                // drop-late collapses the backlog and drift returns to budget.
                // We measure recovery from kSpikeEnd (when frames resume).
                if (tick >= kSpikeEnd) {
                    peak_post_spike = @max(peak_post_spike, drift);
                    if (ticks_to_recover < 0 and drift <= 0.5 * kFrameInterval) {
                        ticks_to_recover = tick - kSpikeEnd;
                    }
                }
                during_spike_peak = @max(during_spike_peak, drift);
            }
        }
    }

    try std.testing.expect(steady_drift.items.len != 0);

    // (a) Steady-state budget: presented PTS within half a frame of the clock.
    var max_steady: f64 = 0.0;
    var sum: f64 = 0.0;
    for (steady_drift.items) |d| {
        max_steady = @max(max_steady, d);
        sum += d;
    }
    const mean_steady = sum / @as(f64, @floatFromInt(steady_drift.items.len));
    std.debug.print(
        "steady-state max drift = {d}s ({d} frames), mean = {d}s; budget = {d}s\n",
        .{ max_steady, max_steady / kFrameInterval, mean_steady, 0.5 * kFrameInterval },
    );
    try std.testing.expect(max_steady <= 0.5 * kFrameInterval);

    // (b) Recovery after the spike: catch back up, and quickly.
    std.debug.print(
        "during-spike peak drift = {d}s ({d} frames); recovered {d} ticks after spike; peak post-spike drift = {d}s ({d} frames)\n",
        .{ during_spike_peak, during_spike_peak / kFrameInterval, ticks_to_recover, peak_post_spike, peak_post_spike / kFrameInterval },
    );
    // The spike must actually induce out-of-budget drift, else recovery is vacuous.
    try std.testing.expect(during_spike_peak > 0.5 * kFrameInterval);
    try std.testing.expect(ticks_to_recover >= 0); // did recover
    try std.testing.expect(ticks_to_recover <= 60); // bounded recovery (~< 1 s of ticks)
}
