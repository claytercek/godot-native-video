//! scrubber.zig — Godot-free adaptive-scrubbing state machine (Engine Core).
//!
//! Godot drives seeking with nothing but repeated VideoStreamPlayback._seek(time)
//! calls. There is no "drag started / drag ended" signal: a rapid BURST of seeks
//! is a user dragging the playhead, and a GAP (or a playback resume) means they
//! settled. The Scrubber turns that bare stream of (target, wall-clock-now) seek
//! events into a decision about HOW to resolve each seek:
//!
//!   * keyframe (fast feedback) — during a fast drag burst we only want to decode
//!     + present the nearest keyframe at/just-before each target. Skipping the
//!     inter-frame decode-forward gives near-instant visual feedback while the
//!     user is still moving, even though the shown frame is approximate.
//!
//!   * exact (precise) — when the user is moving slowly, or has SETTLED (a
//!     debounced ~80-120ms gap with no new seek), or playback resumes, we resolve
//!     to the exact target PTS (seek the preceding keyframe, decode forward to the
//!     target). Correctness over latency once motion stops.
//!
//! THRESHOLDS (all tunable via ScrubConfig, covered by the unit test):
//!   * velocity_threshold — media-seconds of target movement per wall-second
//!     between two consecutive seeks. At/above this, and within the burst window,
//!     the seek is treated as part of a fast drag (Keyframe). Below it, Exact.
//!   * burst_window_ms — two seeks farther apart than this in wall time do not
//!     form a burst; the later one starts fresh and resolves Exact.
//!   * settle_debounce_ms — wall time with no new seek after which the scrub is
//!     considered settled; poll() then emits a single Exact resolve at the last
//!     target so the final on-screen frame is precise.
//!
//! TIME IS INJECTED (a WallClockMs monotonic millisecond timestamp, see
//! wall_clock.zig) so the state machine is deterministic and unit-testable
//! with no real clock — same pattern as present_selector.zig.
//!
//! NO Godot / RenderingDevice / Backend types here — pure policy. The binding
//! maps a Keyframe resolve to a tolerant keyframe seek (the existing
//! DecodeScheduler.requestSeek path) and an Exact resolve to a precise
//! seek-and-decode-forward to the target PTS.

const std = @import("std");

const WallClockMs = @import("wall_clock.zig").WallClockMs;

/// How a seek target should be resolved.
pub const ResolveMode = enum {
    keyframe, // Fast: present the nearest keyframe at/before the target.
    exact, // Precise: decode forward to the exact target PTS.
};

/// The decision the Scrubber returns for a seek (or a settle/resume event).
pub const ScrubResolve = struct {
    mode: ResolveMode = .exact,
    target_seconds: f64 = 0.0,
};

/// Tunable thresholds. Defaults sit in the middle of the issue's guidance
/// band and can be overridden by the binding / a project setting.
pub const ScrubConfig = struct {
    /// Wall ms of quiet after the last seek before the scrub is considered settled.
    settle_debounce_ms: f64 = 100.0,
    /// Two seeks more than this far apart (wall ms) do not form a drag burst.
    burst_window_ms: f64 = 120.0,
    /// Target movement (media seconds) per wall second at/above which a seek
    /// inside the burst window counts as a fast drag (Keyframe). Below this
    /// -> Exact.
    velocity_threshold: f64 = 2.0,
};

pub const Scrubber = struct {
    config: ScrubConfig = .{},

    have_prev: bool = false,
    prev_target: f64 = 0.0,
    prev_now_ms: f64 = 0.0,

    settle_pending: bool = false,

    pub fn init(config: ScrubConfig) Scrubber {
        return .{ .config = config };
    }

    /// Feed one _seek(target) event observed at wall time `now`. Returns how
    /// this seek should be resolved RIGHT NOW (Keyframe for a fast drag, Exact
    /// otherwise). Records the target/time so a later poll() can detect a
    /// settle.
    pub fn onSeek(self: *Scrubber, target_seconds: f64, now: WallClockMs) ScrubResolve {
        var out: ScrubResolve = .{ .target_seconds = target_seconds };

        if (self.have_prev) {
            const dt_ms = now.ms - self.prev_now_ms;
            // A burst requires the previous seek to be recent. A non-positive or
            // zero gap can't yield a meaningful velocity, so treat it
            // conservatively as a continuation of the current burst at
            // "infinite" speed.
            const within_burst = dt_ms <= self.config.burst_window_ms;
            var fast = false;
            if (within_burst) {
                if (dt_ms <= 0.0) {
                    // Same-instant seeks during a drag: treat as fast.
                    fast = true;
                } else {
                    const velocity = @abs(target_seconds - self.prev_target) / (dt_ms / 1000.0);
                    fast = velocity >= self.config.velocity_threshold;
                }
            }
            out.mode = if (fast) .keyframe else .exact;
        } else {
            // No prior seek to measure velocity against: a lone seek (timeline
            // click) resolves exactly.
            out.mode = .exact;
        }

        self.prev_target = target_seconds;
        self.prev_now_ms = now.ms;
        self.have_prev = true;
        // A keyframe scrub leaves an approximate frame on screen, so it still
        // owes a precise resolve once motion settles. An exact resolve is
        // already precise.
        self.settle_pending = out.mode == .keyframe;
        return out;
    }

    /// Called each tick (or on a timer) with the current wall time. If the
    /// scrub has settled — at least `settle_debounce_ms` since the last seek
    /// AND the last seek was an approximate keyframe scrub — returns a
    /// one-shot Exact resolve at the last target so the final frame is
    /// precise. Returns null otherwise. Fires at most once per settle;
    /// re-armed by the next keyframe scrub.
    pub fn poll(self: *Scrubber, now: WallClockMs) ?ScrubResolve {
        if (!self.settle_pending or !self.have_prev) {
            return null;
        }
        if (now.ms - self.prev_now_ms < self.config.settle_debounce_ms) {
            return null; // still within the debounce window
        }
        self.settle_pending = false;
        return .{ .mode = .exact, .target_seconds = self.prev_target };
    }

    /// Playback is resuming. Force an immediate Exact resolve at the last
    /// scrub target so play starts from the precise frame, and consume any
    /// pending settle.
    pub fn onResume(self: *Scrubber, now: WallClockMs) ScrubResolve {
        _ = now;
        self.settle_pending = false;
        const out: ScrubResolve = .{
            .mode = .exact,
            .target_seconds = if (self.have_prev) self.prev_target else 0.0,
        };
        return out;
    }
};

// -----------------------------------------------------------------------
// Pure state-machine tests. The cases that drive a real DecodeScheduler +
// Backend to prove these decisions map onto real seeks live in
// scrubber_integration_test.zig.
// -----------------------------------------------------------------------

// Wall-clock shorthand for the cases below.
fn at(ms: f64) WallClockMs {
    return .{ .ms = ms };
}

// Shared scrub thresholds used across the cases here and in the integration
// tests.
const makeConfig = @import("test_support.zig").makeScrubConfig;

test "first seek with no prior history resolves exactly (no burst yet)" {
    var s = Scrubber.init(makeConfig());
    // A lone seek (e.g. a click on the timeline) has no preceding velocity,
    // so it must resolve to the exact frame, not a keyframe.
    const r = s.onSeek(5.0, at(1000.0));
    try std.testing.expectEqual(ResolveMode.exact, r.mode);
    try std.testing.expectApproxEqAbs(5.0, r.target_seconds, 1e-9);
}

test "a fast burst of seeks resolves to nearest keyframe for low latency" {
    var s = Scrubber.init(makeConfig());
    // First seek primes the state (exact).
    _ = s.onSeek(1.0, at(0.0));
    // Subsequent seeks arrive quickly and move far: 1.0 -> 2.0 in 20ms is
    // 50 media-s/wall-s, well above threshold -> keyframe scrub.
    const r1 = s.onSeek(2.0, at(20.0));
    try std.testing.expectEqual(ResolveMode.keyframe, r1.mode);
    const r2 = s.onSeek(3.2, at(40.0));
    try std.testing.expectEqual(ResolveMode.keyframe, r2.mode);
    try std.testing.expectApproxEqAbs(3.2, r2.target_seconds, 1e-9);
}

test "a slow drag (below velocity threshold) resolves exactly" {
    var s = Scrubber.init(makeConfig());
    _ = s.onSeek(1.0, at(0.0));
    // Move only 0.05s over 100ms = 0.5 media-s/wall-s, below the 2.0 threshold.
    const r = s.onSeek(1.05, at(100.0));
    try std.testing.expectEqual(ResolveMode.exact, r.mode);
}

test "poll before the debounce elapses emits nothing" {
    var s = Scrubber.init(makeConfig());
    _ = s.onSeek(1.0, at(0.0));
    _ = s.onSeek(2.0, at(20.0)); // fast -> keyframe
    // Only 50ms since the last seek; debounce is 100ms -> not settled yet.
    try std.testing.expect(s.poll(at(70.0)) == null);
}

test "poll after the debounce emits an exact resolve to the last target (settle)" {
    var s = Scrubber.init(makeConfig());
    _ = s.onSeek(1.0, at(0.0));
    _ = s.onSeek(2.0, at(20.0)); // fast -> keyframe at 2.0
    _ = s.onSeek(3.0, at(40.0)); // fast -> keyframe at 3.0
    // 100ms+ since the last seek -> settled: emit an exact resolve to 3.0.
    const r = s.poll(at(141.0));
    try std.testing.expect(r != null);
    try std.testing.expectEqual(ResolveMode.exact, r.?.mode);
    try std.testing.expectApproxEqAbs(3.0, r.?.target_seconds, 1e-9);
}

test "settle fires exactly once until the next seek" {
    var s = Scrubber.init(makeConfig());
    _ = s.onSeek(1.0, at(0.0));
    _ = s.onSeek(2.0, at(20.0));
    try std.testing.expect(s.poll(at(141.0)) != null); // first poll past debounce settles
    try std.testing.expect(s.poll(at(200.0)) == null); // already settled -> no repeat
    // A new fast burst re-arms the settle.
    _ = s.onSeek(4.0, at(220.0));
    _ = s.onSeek(5.0, at(240.0));
    try std.testing.expect(s.poll(at(260.0)) == null); // within debounce again
    try std.testing.expect(s.poll(at(360.0)) != null); // settles once more
}

test "a settled (exact) seek does not need a follow-up poll resolve" {
    var s = Scrubber.init(makeConfig());
    // A lone exact seek already resolved exactly; polling past debounce
    // should not re-emit a redundant exact resolve for the same target.
    _ = s.onSeek(5.0, at(0.0));
    try std.testing.expect(s.poll(at(200.0)) == null);
}

test "playback resume forces an exact resolve at the last scrub target" {
    var s = Scrubber.init(makeConfig());
    _ = s.onSeek(1.0, at(0.0));
    _ = s.onSeek(2.0, at(20.0)); // keyframe scrub at 2.0
    const r = s.onResume(at(30.0));
    try std.testing.expectEqual(ResolveMode.exact, r.mode);
    try std.testing.expectApproxEqAbs(2.0, r.target_seconds, 1e-9);
    // After resume, the settle is consumed (resume already did the exact resolve).
    try std.testing.expect(s.poll(at(200.0)) == null);
}

test "config is tunable: a higher threshold treats the same drag as exact" {
    var c = makeConfig();
    c.velocity_threshold = 1000.0; // absurdly high -> nothing counts as a fast drag
    var s = Scrubber.init(c);
    _ = s.onSeek(1.0, at(0.0));
    const r = s.onSeek(2.0, at(20.0)); // 50 media-s/wall-s < 1000 -> exact
    try std.testing.expectEqual(ResolveMode.exact, r.mode);
}
