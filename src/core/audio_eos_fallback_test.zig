//! audio_eos_fallback_test.zig — port of tests/core/test_audio_eos_fallback.cpp.
//!
//! Audio-EOS wall-clock fallback — no Godot, no GPU.
//!
//! A clip's audio track can legitimately end before its video track. The
//! audio-master clock only advances from real samples consumed (onAudioMixed());
//! once the backend stops producing real audio frames for good, nothing will
//! ever call onAudioMixed() again, so the clock would freeze permanently unless
//! something else advances it.
//!
//! This models the controller's unified clock rule:
//!
//!   var advanced_from_audio = false;
//!   if (has_audio) { fill_audio(); advanced_from_audio = drive_audio(); }
//!   if (!advanced_from_audio and audio_exhausted()) {
//!       clock.setTime(clock.mediaTime() + delta);
//!   }
//!
//! where audio_exhausted() == !has_audio or (audio_eos and ring empty): the
//! clock advances from real samples whenever any exist; only once no more can
//! ever come does the render delta take over. The !advanced_from_audio gate
//! keeps the tick that drains the last partial block from double-advancing
//! (real leftover + delta).

const std = @import("std");

const clock_mod = @import("clock.zig");
const present_selector = @import("present_selector.zig");

const AudioMasterClock = clock_mod.AudioMasterClock;
const MonotonicClock = clock_mod.MonotonicClock;
const PresentAction = present_selector.PresentAction;
const selectPresentAction = present_selector.selectPresentAction;

const kSampleRate: i32 = 48000;
const kFps: f64 = 30.0;
const kFrameInterval: f64 = 1.0 / kFps;
const kTickSeconds: f64 = 1.0 / 60.0; // render tick, independent of fps
const kTotalFrames: i32 = 300; // 10s @ 30fps
// Audio track only covers the first ~2.63s. Deliberately not a multiple of a
// tick's worth of samples, so one tick drains a partial final block of real
// audio — the exact seam a double-advance bug would show up on.
const kAudioEndSeconds: f64 = 2.63;

// A tiny FIFO of decode-ahead frame PTS values.
const Buf = struct {
    list: std.ArrayList(f64) = .empty,

    fn deinit(self: *Buf, a: std.mem.Allocator) void {
        self.list.deinit(a);
    }
    fn pushBack(self: *Buf, a: std.mem.Allocator, v: f64) void {
        self.list.append(a, v) catch @panic("oom");
    }
    fn popFront(self: *Buf) void {
        _ = self.list.orderedRemove(0);
    }
    fn head(self: *const Buf) ?f64 {
        return if (self.list.items.len == 0) null else self.list.items[0];
    }
    fn next(self: *const Buf) ?f64 {
        return if (self.list.items.len >= 2) self.list.items[1] else null;
    }
    fn empty(self: *const Buf) bool {
        return self.list.items.len == 0;
    }
};

// Deliver every video frame whose PTS has already passed into the decode-ahead
// buffer (no jitter — this test is about the clock, not drift).
fn fillReadyFrames(a: std.mem.Allocator, buf: *Buf, next_frame: *i32, now: f64) void {
    while (next_frame.* < kTotalFrames and @as(f64, @floatFromInt(next_frame.*)) * kFrameInterval <= now) {
        buf.pushBack(a, @as(f64, @floatFromInt(next_frame.*)) * kFrameInterval);
        next_frame.* += 1;
    }
}

fn runPresent(buf: *Buf, now: f64, held_pts: f64) f64 {
    var shown = held_pts;
    while (true) {
        const a = selectPresentAction(buf.head(), buf.next(), now, kFrameInterval);
        if (a == .drop) {
            buf.popFront();
            continue;
        }
        if (a == .show) {
            shown = buf.head().?;
            buf.popFront();
        }
        break;
    }
    return shown;
}

const SimResult = struct {
    shown_pts: f64 = -1.0,
    max_tick_advance: f64 = 0.0, // largest single-tick clock jump observed
};

// Runs the freeze scenario. `apply_fallback` toggles the fix under test.
fn simulate(a: std.mem.Allocator, apply_fallback: bool) SimResult {
    var result: SimResult = .{};
    var clock = AudioMasterClock.init(kSampleRate, 0.0);
    var buf: Buf = .{};
    defer buf.deinit(a);
    var next_frame: i32 = 0;
    const total_real_frames: i64 = @intFromFloat(kAudioEndSeconds * @as(f64, @floatFromInt(kSampleRate)));
    var real_frames_consumed: i64 = 0;
    var prev_now: f64 = 0.0;

    var tick: i32 = 0;
    while (tick < 1200) : (tick += 1) {
        const block: i64 = @intFromFloat(kTickSeconds * @as(f64, @floatFromInt(kSampleRate)));
        const remaining = total_real_frames - real_frames_consumed;
        const this_block = @min(block, @max(remaining, @as(i64, 0)));

        var advanced_from_audio = false;
        if (this_block > 0) {
            clock.onAudioMixed(@intCast(this_block));
            real_frames_consumed += this_block;
            advanced_from_audio = true;
        }
        // audio_exhausted(): the backend reported genuine EOS and the ring has
        // drained — in this sim the supply running dry stands in for both.
        const audio_exhausted = real_frames_consumed >= total_real_frames;
        if (apply_fallback and !advanced_from_audio and audio_exhausted) {
            clock.setTime(clock.mediaTime() + kTickSeconds);
        }

        const now = clock.mediaTime();
        result.max_tick_advance = @max(result.max_tick_advance, now - prev_now);
        prev_now = now;

        fillReadyFrames(a, &buf, &next_frame, now);
        result.shown_pts = runPresent(&buf, now, result.shown_pts);

        if (result.shown_pts >= @as(f64, @floatFromInt(kTotalFrames - 1)) * kFrameInterval) {
            break; // last frame presented — playback reached the end
        }
    }
    return result;
}

test "audio ending before video falls back to wall-clock so trailing video keeps playing" {
    const a = std.testing.allocator;
    const result = simulate(a, true);

    // Without the fallback, `now` would freeze at kAudioEndSeconds forever and
    // shown_pts would get stuck well short of the clip's last frame.
    try std.testing.expect(result.shown_pts >= @as(f64, @floatFromInt(kTotalFrames - 1)) * kFrameInterval);
    try std.testing.expect(result.shown_pts <= @as(f64, @floatFromInt(kTotalFrames)) * kFrameInterval);

    // The real-advance/fallback gate must be mutually exclusive: no tick should
    // ever advance the clock by more than one tick's worth.
    try std.testing.expect(result.max_tick_advance <= kTickSeconds * 1.0001);
}

test "without the fallback, audio ending early freezes video short of the clip end" {
    const a = std.testing.allocator;
    const result = simulate(a, false);

    // The clip never reaches its last frame: playback is stuck at the frame
    // nearest the audio cutoff.
    try std.testing.expect(result.shown_pts < @as(f64, @floatFromInt(kTotalFrames - 1)) * kFrameInterval);
    try std.testing.expect(result.shown_pts <= kAudioEndSeconds);
}

test "mid-stream underrun without audio EOS freezes the clock until audio resumes" {
    // Models a transient decode stall: real audio stops arriving for a stretch of
    // ticks, but the backend never reported EOS, so audio_exhausted() stays false
    // and the wall-clock fallback must NOT fire.
    const a = std.testing.allocator;
    var clock = AudioMasterClock.init(kSampleRate, 0.0);
    var buf: Buf = .{};
    defer buf.deinit(a);
    var next_frame: i32 = 0;
    var shown_pts: f64 = -1.0;
    var real_frames_consumed: i64 = 0;
    const block: i64 = @intFromFloat(kTickSeconds * @as(f64, @floatFromInt(kSampleRate)));

    const kGapStart: i32 = 120; // ticks [kGapStart, kGapEnd): no audio arrives
    const kGapEnd: i32 = 180;

    var time_at_gap_start: f64 = -1.0;
    var shown_at_gap_start: f64 = -1.0;

    var tick: i32 = 0;
    while (tick < 480) : (tick += 1) {
        const in_gap = tick >= kGapStart and tick < kGapEnd;

        var advanced_from_audio = false;
        if (!in_gap) { // audio flowing normally
            clock.onAudioMixed(@intCast(block));
            real_frames_consumed += block;
            advanced_from_audio = true;
        }
        // audio_exhausted() is false throughout: an empty ring alone must not
        // trigger the fallback.
        const audio_exhausted = false;
        if (!advanced_from_audio and audio_exhausted) {
            clock.setTime(clock.mediaTime() + kTickSeconds);
        }

        const now = clock.mediaTime();
        fillReadyFrames(a, &buf, &next_frame, now);
        shown_pts = runPresent(&buf, now, shown_pts);

        if (tick == kGapStart) {
            time_at_gap_start = now;
            shown_at_gap_start = shown_pts;
        }
        if (in_gap) {
            // Frozen: no advance of any kind during the underrun.
            try std.testing.expectApproxEqAbs(time_at_gap_start, now, 1e-9);
            try std.testing.expectApproxEqAbs(shown_at_gap_start, shown_pts, 1e-9);
        }
    }

    // A/V sync preserved across the gap: media time is exactly the real samples
    // consumed — the underrun neither advanced nor skewed the clock.
    try std.testing.expectApproxEqAbs(
        @as(f64, @floatFromInt(real_frames_consumed)) / @as(f64, @floatFromInt(kSampleRate)),
        clock.mediaTime(),
        1e-9,
    );
    // Video resumed after the gap and moved past where it froze.
    try std.testing.expect(shown_pts > shown_at_gap_start);
}

test "silent clip advances by exactly delta per tick under the unified rule" {
    // No audio track at all: audio_exhausted() is true from tick 0, so the same
    // fallback that handles the post-audio-EOS tail drives the whole clip. The
    // master here is the MonotonicClock, where setTime(mediaTime() + delta) is
    // equivalent to advance(delta).
    const a = std.testing.allocator;
    var clock = MonotonicClock.init(0.0);
    var buf: Buf = .{};
    defer buf.deinit(a);
    var next_frame: i32 = 0;
    var shown_pts: f64 = -1.0;

    var tick: i32 = 0;
    while (tick < 1200) : (tick += 1) {
        const before = clock.mediaTime();

        // The unified gate, folded: with no audio track, advanced_from_audio is
        // always false and audio_exhausted() is always true (!has_audio), so the
        // fallback fires every tick.
        clock.setTime(clock.mediaTime() + kTickSeconds);

        // Exactly one render delta per tick — the clip plays at the correct rate.
        try std.testing.expectApproxEqAbs(kTickSeconds, clock.mediaTime() - before, 1e-9);

        const now = clock.mediaTime();
        fillReadyFrames(a, &buf, &next_frame, now);
        shown_pts = runPresent(&buf, now, shown_pts);

        if (shown_pts >= @as(f64, @floatFromInt(kTotalFrames - 1)) * kFrameInterval) {
            break; // last frame presented — the silent clip played to the end
        }
    }

    try std.testing.expect(shown_pts >= @as(f64, @floatFromInt(kTotalFrames - 1)) * kFrameInterval);
}
