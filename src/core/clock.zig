//! clock.zig — port of src/core/clock.h.
//!
//! Clock — abstract media-time interface.
//!
//! The Engine Core owns the master playback clock. The audio subsystem
//! drives it when audio is present (audio-master mode); a monotonic delta
//! fallback is used when no audio track exists.
//!
//! All times are in seconds using f64 to represent PTS values accurately
//! for media up to several hours long.

const std = @import("std");

/// Generates the ptr+vtable forwarding shims for a type T that implements the
/// Clock interface as plain methods (mediaTime/advance/setTime/setPaused/
/// isPaused). MonotonicClock, AudioMasterClock, and ClockBridge each had an
/// identical copy of this boilerplate; this comptime helper collapses the
/// three into one.
fn vtableFor(comptime T: type) Clock.VTable {
    const Impl = struct {
        fn mediaTimeVt(ptr: *anyopaque) f64 {
            const self: *const T = @ptrCast(@alignCast(ptr));
            return self.mediaTime();
        }
        fn advanceVt(ptr: *anyopaque, delta_seconds: f64) void {
            const self: *T = @ptrCast(@alignCast(ptr));
            self.advance(delta_seconds);
        }
        fn setTimeVt(ptr: *anyopaque, time_seconds: f64) void {
            const self: *T = @ptrCast(@alignCast(ptr));
            self.setTime(time_seconds);
        }
        fn setPausedVt(ptr: *anyopaque, paused: bool) void {
            const self: *T = @ptrCast(@alignCast(ptr));
            self.setPaused(paused);
        }
        fn isPausedVt(ptr: *anyopaque) bool {
            const self: *const T = @ptrCast(@alignCast(ptr));
            return self.isPaused();
        }
    };
    return .{
        .media_time = Impl.mediaTimeVt,
        .advance = Impl.advanceVt,
        .set_time = Impl.setTimeVt,
        .set_paused = Impl.setPausedVt,
        .is_paused = Impl.isPausedVt,
    };
}

/// Pure-virtual C++ Clock → ptr + vtable (see backend.zig for the pattern).
/// MonotonicClock, AudioMasterClock, and ClockBridge each expose `asClock()`
/// to obtain this interface without owning-pointer indirection.
pub const Clock = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        media_time: *const fn (*anyopaque) f64,
        advance: *const fn (*anyopaque, delta_seconds: f64) void,
        set_time: *const fn (*anyopaque, time_seconds: f64) void,
        set_paused: *const fn (*anyopaque, paused: bool) void,
        is_paused: *const fn (*anyopaque) bool,
    };

    /// Return the current media presentation time in seconds. This is the
    /// time against which frame PTS values are compared.
    pub fn mediaTime(self: Clock) f64 {
        return self.vtable.media_time(self.ptr);
    }

    /// Advance the clock by `delta_seconds` (monotonic fallback path).
    /// Audio-master implementations may ignore this and advance solely from
    /// sample-count accounting.
    pub fn advance(self: Clock, delta_seconds: f64) void {
        self.vtable.advance(self.ptr, delta_seconds);
    }

    /// Seek the clock to an absolute media time (e.g. after a scrub).
    pub fn setTime(self: Clock, time_seconds: f64) void {
        self.vtable.set_time(self.ptr, time_seconds);
    }

    /// Pause / resume ticking. A paused clock returns a constant mediaTime().
    pub fn setPaused(self: Clock, paused: bool) void {
        self.vtable.set_paused(self.ptr, paused);
    }

    pub fn isPaused(self: Clock) bool {
        return self.vtable.is_paused(self.ptr);
    }
};

/// MonotonicClock — simple non-audio-master reference implementation.
///
/// Accumulates time from advance() calls; suitable for unit tests and for
/// silent streams.
pub const MonotonicClock = struct {
    time: f64 = 0.0,
    paused: bool = false,

    pub fn init(initial_time: f64) MonotonicClock {
        return .{ .time = initial_time, .paused = false };
    }

    pub fn mediaTime(self: *const MonotonicClock) f64 {
        return self.time;
    }

    pub fn advance(self: *MonotonicClock, delta_seconds: f64) void {
        if (!self.paused and delta_seconds > 0.0) {
            self.time += delta_seconds;
        }
    }

    pub fn setTime(self: *MonotonicClock, time_seconds: f64) void {
        self.time = time_seconds;
    }

    pub fn setPaused(self: *MonotonicClock, paused: bool) void {
        self.paused = paused;
    }

    pub fn isPaused(self: *const MonotonicClock) bool {
        return self.paused;
    }

    const vtable: Clock.VTable = vtableFor(MonotonicClock);

    pub fn asClock(self: *MonotonicClock) Clock {
        return .{ .ptr = self, .vtable = &vtable };
    }
};

/// AudioMasterClock — drives media time from audio sample consumption.
///
/// The mix callback reports `mixed_frames` PCM frames at `sample_rate`; the
/// clock converts them to seconds and accumulates. An initial latency
/// compensation offset accounts for the audio buffer depth so that media
/// time reflects what the listener hears, not what was queued.
pub const AudioMasterClock = struct {
    sample_rate: i32,
    latency_seconds: f64,
    accumulated_seconds: f64 = 0.0,
    paused: bool = false,

    /// `latency_seconds` is subtracted from the running time so that
    /// mediaTime() represents "what the speaker is emitting now" rather
    /// than "what was last pushed into the audio buffer."
    pub fn init(sample_rate: i32, latency_seconds: f64) AudioMasterClock {
        return .{
            .sample_rate = sample_rate,
            .latency_seconds = latency_seconds,
            .accumulated_seconds = 0.0,
            .paused = false,
        };
    }

    /// Called by the audio mix callback after mixing `frame_count` frames.
    pub fn onAudioMixed(self: *AudioMasterClock, frame_count: i32) void {
        if (!self.paused and self.sample_rate > 0) {
            self.accumulated_seconds += @as(f64, @floatFromInt(frame_count)) / @as(f64, @floatFromInt(self.sample_rate));
        }
    }

    pub fn mediaTime(self: *const AudioMasterClock) f64 {
        const t = self.accumulated_seconds - self.latency_seconds;
        return if (t < 0.0) 0.0 else t;
    }

    /// advance() is a no-op for the audio-master clock; time is governed
    /// entirely by onAudioMixed().
    pub fn advance(self: *AudioMasterClock, delta_seconds: f64) void {
        _ = self;
        _ = delta_seconds;
    }

    pub fn setTime(self: *AudioMasterClock, time_seconds: f64) void {
        // After a seek the audio subsystem resets; re-anchor here.
        self.accumulated_seconds = time_seconds + self.latency_seconds;
    }

    pub fn setPaused(self: *AudioMasterClock, paused: bool) void {
        self.paused = paused;
    }

    pub fn isPaused(self: *const AudioMasterClock) bool {
        return self.paused;
    }

    const vtable: Clock.VTable = vtableFor(AudioMasterClock);

    pub fn asClock(self: *AudioMasterClock) Clock {
        return .{ .ptr = self, .vtable = &vtable };
    }
};

/// ClockBridge — runtime-switchable master clock.
///
/// Wraps both an AudioMasterClock and a MonotonicClock, delegating to
/// whichever is currently the active master. Supports audio-to-monotonic
/// handoff and monotonic-to-audio re-anchor, both seeded from the current
/// position so the reported mediaTime() remains continuous across the
/// switch.
///
/// The audio side is optional: `audio` may be null for clips with no audio
/// track. A null audio clock means the bridge is permanently
/// monotonic-master (silent clips) — every audio-facing method becomes a
/// safe no-op instead of requiring callers to construct a dummy
/// AudioMasterClock.
pub const ClockBridge = struct {
    audio: ?AudioMasterClock,
    mono: MonotonicClock,
    audio_master: bool,
    paused: bool = false,

    /// `mono` is always present. `audio` may be null for a silent clip, in
    /// which case `audio_master` is forced to false regardless of the
    /// requested value — there is no audio clock to be master of.
    pub fn init(audio: ?AudioMasterClock, mono: MonotonicClock, audio_master: bool) ClockBridge {
        return .{
            .audio = audio,
            .mono = mono,
            .audio_master = if (audio != null) audio_master else false,
            .paused = false,
        };
    }

    // --- Clock interface ---

    pub fn mediaTime(self: *const ClockBridge) f64 {
        return if (self.audio_master) self.audio.?.mediaTime() else self.mono.mediaTime();
    }

    pub fn advance(self: *ClockBridge, delta_seconds: f64) void {
        if (!self.paused and delta_seconds > 0.0) {
            if (!self.audio_master) {
                self.mono.advance(delta_seconds);
            }
            // audio-master: advance() is ignored (same as AudioMasterClock).
        }
    }

    pub fn setTime(self: *ClockBridge, time_seconds: f64) void {
        if (self.audio) |*a| {
            a.setTime(time_seconds);
        }
        self.mono.setTime(time_seconds);
    }

    pub fn setPaused(self: *ClockBridge, paused: bool) void {
        self.paused = paused;
        if (self.audio) |*a| {
            a.setPaused(paused);
        }
        self.mono.setPaused(paused);
    }

    pub fn isPaused(self: *const ClockBridge) bool {
        return self.paused;
    }

    // --- Handoff API ---

    /// Hand mastership from audio to monotonic. Seeds the monotonic clock at
    /// the audio clock's current mediaTime() so the position is continuous.
    /// No-op if already monotonic-master.
    pub fn handoffToMonotonic(self: *ClockBridge) void {
        if (!self.audio_master) return;
        self.mono.setTime(self.audio.?.mediaTime());
        self.audio_master = false;
    }

    /// Re-anchor back to audio master. Sets the audio clock's accumulated
    /// time so that mediaTime() continues from the monotonic clock's
    /// current position without a backward jump (forward nudge within
    /// sub-frame tolerance). No-op if already audio-master, and no-op when
    /// there is no audio clock (silent clips are permanently
    /// monotonic-master).
    pub fn reanchorToAudio(self: *ClockBridge) void {
        if (self.audio_master or self.audio == null) return;
        self.audio.?.setTime(self.mono.mediaTime());
        self.audio_master = true;
    }

    /// True when the audio-master clock is the active source of mediaTime().
    pub fn isAudioMaster(self: *const ClockBridge) bool {
        return self.audio_master;
    }

    /// Report audio sample consumption. Delegates to AudioMasterClock when
    /// audio-master; no-op in monotonic mode (audio samples are not
    /// consumed during a gap, so the clock stays honest for re-anchor).
    /// Also a no-op when there is no audio clock — audio_master can never
    /// be true in that case, but the explicit guard keeps this method safe
    /// on its own terms.
    pub fn onAudioMixed(self: *ClockBridge, frame_count: i32) void {
        if (self.audio_master) {
            if (self.audio) |*a| {
                a.onAudioMixed(frame_count);
            }
        }
    }

    /// Read a field of the inner audio clock, or `default` for a silent clip
    /// (no audio track) — the "no audio -> silent clip" defaulting shared by
    /// sampleRate() and latencySeconds().
    fn audioFieldOr(self: *const ClockBridge, comptime field: []const u8, default: anytype) @TypeOf(default) {
        return if (self.audio) |a| @field(a, field) else default;
    }

    /// Accessors delegated to the inner audio clock. Return zero when there
    /// is no audio clock (silent clip).
    pub fn sampleRate(self: *const ClockBridge) i32 {
        return self.audioFieldOr("sample_rate", @as(i32, 0));
    }
    pub fn latencySeconds(self: *const ClockBridge) f64 {
        return self.audioFieldOr("latency_seconds", @as(f64, 0.0));
    }

    const vtable: Clock.VTable = vtableFor(ClockBridge);

    pub fn asClock(self: *ClockBridge) Clock {
        return .{ .ptr = self, .vtable = &vtable };
    }
};

// -----------------------------------------------------------------------
// MonotonicClock
// -----------------------------------------------------------------------

test "MonotonicClock starts at given initial time" {
    var c = MonotonicClock.init(0.0);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), c.mediaTime(), 1e-9);

    var c2 = MonotonicClock.init(1.5);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), c2.mediaTime(), 1e-9);
}

test "MonotonicClock advance accumulates time" {
    var c = MonotonicClock.init(0.0);
    c.advance(0.016); // ~60 fps frame
    try std.testing.expectApproxEqAbs(@as(f64, 0.016), c.mediaTime(), 1e-9);
    c.advance(0.016);
    try std.testing.expectApproxEqAbs(@as(f64, 0.032), c.mediaTime(), 1e-9);
}

test "MonotonicClock ignores negative or zero delta" {
    var c = MonotonicClock.init(1.0);
    c.advance(-0.5);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), c.mediaTime(), 1e-9);
    c.advance(0.0);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), c.mediaTime(), 1e-9);
}

test "MonotonicClock set_time repositions the clock" {
    var c = MonotonicClock.init(0.0);
    c.advance(2.5);
    c.setTime(10.0);
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), c.mediaTime(), 1e-9);
}

test "MonotonicClock paused does not advance" {
    var c = MonotonicClock.init(5.0);
    c.setPaused(true);
    try std.testing.expect(c.isPaused());
    c.advance(1.0);
    try std.testing.expectApproxEqAbs(@as(f64, 5.0), c.mediaTime(), 1e-9);
}

test "MonotonicClock resumes after unpause" {
    var c = MonotonicClock.init(0.0);
    c.setPaused(true);
    c.advance(1.0);
    c.setPaused(false);
    try std.testing.expect(!c.isPaused());
    c.advance(0.5);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), c.mediaTime(), 1e-9);
}

test "MonotonicClock many small advances accumulate without drift" {
    var c = MonotonicClock.init(0.0);
    const n = 10_000;
    const delta = 1.0 / 60.0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        c.advance(delta);
    }
    try std.testing.expectApproxEqAbs(@as(f64, n) * delta, c.mediaTime(), 1e-6);
}

// -----------------------------------------------------------------------
// AudioMasterClock
// -----------------------------------------------------------------------

test "AudioMasterClock starts at zero" {
    var c = AudioMasterClock.init(48000, 0.0);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), c.mediaTime(), 1e-9);
}

test "AudioMasterClock advances by sample count" {
    var c = AudioMasterClock.init(48000, 0.0);
    // 48000 frames / 48000 Hz = 1 second
    c.onAudioMixed(48000);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), c.mediaTime(), 1e-9);
}

test "AudioMasterClock accumulates multiple mix calls" {
    var c = AudioMasterClock.init(44100, 0.0);
    // 3 calls of 512 frames each
    c.onAudioMixed(512);
    c.onAudioMixed(512);
    c.onAudioMixed(512);
    const expected = 3.0 * 512.0 / 44100.0;
    try std.testing.expectApproxEqAbs(expected, c.mediaTime(), 1e-9);
}

test "AudioMasterClock latency compensation shifts time back" {
    const latency = 0.02; // 20 ms
    var c = AudioMasterClock.init(48000, latency);
    // Mix exactly the latency worth of audio; should still read 0 (clamped).
    c.onAudioMixed(@intFromFloat(latency * 48000));
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), c.mediaTime(), 1e-9);

    // Mix another second; reported time should be 1 second behind the
    // accumulated time.
    c.onAudioMixed(48000);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), c.mediaTime(), 1e-4);
}

test "AudioMasterClock clamps to zero when latency exceeds accumulated" {
    var c = AudioMasterClock.init(48000, 0.1);
    c.onAudioMixed(100); // tiny amount
    // 100/48000 ~ 2 ms < 100 ms latency => media time should be 0
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), c.mediaTime(), 1e-9);
}

test "AudioMasterClock set_time repositions (e.g. after seek)" {
    var c = AudioMasterClock.init(48000, 0.0);
    c.onAudioMixed(48000); // 1 s
    c.setTime(30.0);
    try std.testing.expectApproxEqAbs(@as(f64, 30.0), c.mediaTime(), 1e-9);
}

test "AudioMasterClock paused does not advance on mix" {
    var c = AudioMasterClock.init(48000, 0.0);
    c.setPaused(true);
    c.onAudioMixed(48000);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), c.mediaTime(), 1e-9);
}

test "AudioMasterClock advance() is a no-op" {
    var c = AudioMasterClock.init(48000, 0.0);
    c.advance(999.0); // should be ignored
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), c.mediaTime(), 1e-9);
}

test "AudioMasterClock sample_rate and latency accessors" {
    const c = AudioMasterClock.init(44100, 0.05);
    try std.testing.expectEqual(@as(i32, 44100), c.sample_rate);
    try std.testing.expectApproxEqAbs(@as(f64, 0.05), c.latency_seconds, 1e-9);
}

// -----------------------------------------------------------------------
// ClockBridge
// -----------------------------------------------------------------------

// Utility: create a bridge starting in audio-master mode.
fn makeAudioBridge(latency: f64) ClockBridge {
    return ClockBridge.init(
        AudioMasterClock.init(48000, latency),
        MonotonicClock.init(0.0),
        true,
    );
}

// Utility: create a bridge starting in monotonic-master mode.
fn makeMonoBridge(initial: f64) ClockBridge {
    return ClockBridge.init(
        AudioMasterClock.init(48000, 0.0),
        MonotonicClock.init(initial),
        false,
    );
}

// Utility: create a bridge with no audio clock at all.
fn makeNullAudioBridge(initial: f64, request_audio_master: bool) ClockBridge {
    return ClockBridge.init(
        null,
        MonotonicClock.init(initial),
        request_audio_master,
    );
}

test "ClockBridge starts as audio-master" {
    var b = makeAudioBridge(0.0);
    try std.testing.expect(b.isAudioMaster());
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), b.mediaTime(), 1e-9);
}

test "ClockBridge starts as monotonic-master" {
    var b = makeMonoBridge(5.0);
    try std.testing.expect(!b.isAudioMaster());
    try std.testing.expectApproxEqAbs(@as(f64, 5.0), b.mediaTime(), 1e-9);
}

test "ClockBridge audio-master: advance is no-op, on_audio_mixed advances" {
    var b = makeAudioBridge(0.0);
    b.advance(1.0);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), b.mediaTime(), 1e-9);
    b.onAudioMixed(48000); // 1 s
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), b.mediaTime(), 1e-9);
}

test "ClockBridge audio-master: on_audio_mixed accumulates" {
    var b = makeAudioBridge(0.0);
    b.onAudioMixed(48000);
    b.onAudioMixed(24000);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), b.mediaTime(), 1e-9);
}

test "ClockBridge handoff seeds monotonic at audio position" {
    var b = makeAudioBridge(0.0);
    b.onAudioMixed(48000); // 1 s
    b.handoffToMonotonic();
    try std.testing.expect(!b.isAudioMaster());
    // After handoff, the monotonic clock starts at the audio clock's position.
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), b.mediaTime(), 1e-9);
}

test "ClockBridge handoff is idempotent" {
    var b = makeAudioBridge(0.0);
    b.onAudioMixed(24000); // 0.5 s
    b.handoffToMonotonic();
    try std.testing.expect(!b.isAudioMaster());
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), b.mediaTime(), 1e-9);
    // Second handoff should be a no-op.
    b.handoffToMonotonic();
    try std.testing.expect(!b.isAudioMaster());
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), b.mediaTime(), 1e-9);
}

test "ClockBridge handoff then advance advances monotonic" {
    var b = makeAudioBridge(0.0);
    b.onAudioMixed(48000); // 1 s
    b.handoffToMonotonic();
    b.advance(0.5);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), b.mediaTime(), 1e-9);
}

test "ClockBridge re-anchor keeps position continuous" {
    var b = makeAudioBridge(0.0);
    b.onAudioMixed(48000); // 1 s
    b.handoffToMonotonic();
    b.advance(2.0); // 3 s total
    b.reanchorToAudio();
    try std.testing.expect(b.isAudioMaster());
    // Position should be 3.0 — no backward jump.
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), b.mediaTime(), 1e-9);
}

test "ClockBridge re-anchor is idempotent" {
    var b = makeAudioBridge(0.0);
    b.onAudioMixed(24000); // 0.5 s
    b.handoffToMonotonic();
    b.reanchorToAudio();
    try std.testing.expect(b.isAudioMaster());
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), b.mediaTime(), 1e-9);
    // Second re-anchor should be a no-op.
    b.reanchorToAudio();
    try std.testing.expect(b.isAudioMaster());
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), b.mediaTime(), 1e-9);
}

test "ClockBridge on_audio_mixed is no-op in monotonic mode" {
    var b = makeAudioBridge(0.0);
    b.onAudioMixed(24000); // 0.5 s
    b.handoffToMonotonic();
    // on_audio_mixed while in monotonic mode should be ignored.
    b.onAudioMixed(48000);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), b.mediaTime(), 1e-9);
}

test "ClockBridge re-anchor then on_audio_mixed advances audio" {
    var b = makeAudioBridge(0.0);
    b.onAudioMixed(48000); // 1 s
    b.handoffToMonotonic();
    b.advance(2.0); // 3 s
    b.reanchorToAudio();
    b.onAudioMixed(48000); // +1 s
    try std.testing.expectApproxEqAbs(@as(f64, 4.0), b.mediaTime(), 1e-9);
}

test "ClockBridge long gap via monotonic" {
    // Simulates an arbitrarily long silent gap: handoff, advance by a large
    // delta, re-anchor. Position must be continuous.
    var b = makeAudioBridge(0.0);
    b.onAudioMixed(48000); // 1 s
    b.handoffToMonotonic();
    b.advance(300.0); // 5 minute gap
    b.reanchorToAudio();
    try std.testing.expectApproxEqAbs(@as(f64, 301.0), b.mediaTime(), 1e-9);
    // Audio clock should now be master and can continue from 301 s.
    b.onAudioMixed(48000); // +1 s
    try std.testing.expectApproxEqAbs(@as(f64, 302.0), b.mediaTime(), 1e-9);
}

test "ClockBridge set_time synchronizes both clocks" {
    var b = makeAudioBridge(0.0);
    b.onAudioMixed(48000); // 1 s
    b.setTime(10.0);
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), b.mediaTime(), 1e-9);
    // Handoff after set_time: monotonic should be at 10.0 too.
    b.handoffToMonotonic();
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), b.mediaTime(), 1e-9);
}

test "ClockBridge set_paused pauses both clocks" {
    var b = makeAudioBridge(0.0);
    b.setPaused(true);
    try std.testing.expect(b.isPaused());
    // Neither audio nor monotonic should advance.
    b.onAudioMixed(48000);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), b.mediaTime(), 1e-9);
    // Handoff while paused, then advance — should stay put.
    b.handoffToMonotonic();
    b.advance(1.0);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), b.mediaTime(), 1e-9);
    // Unpause: monotonic should start advancing.
    b.setPaused(false);
    b.advance(0.5);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), b.mediaTime(), 1e-9);
}

test "ClockBridge latency compensation works through bridge" {
    const latency = 0.02; // 20 ms
    var b = makeAudioBridge(latency);
    try std.testing.expectApproxEqAbs(latency, b.latencySeconds(), 1e-9);
    // Mix exactly the latency worth of audio; should still read 0.
    b.onAudioMixed(@intFromFloat(latency * 48000));
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), b.mediaTime(), 1e-9);
    // Mix another second; reported time is 1 s behind accumulated.
    b.onAudioMixed(48000);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), b.mediaTime(), 1e-4);
    // Handoff seeds mono at the latency-compensated position.
    b.handoffToMonotonic();
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), b.mediaTime(), 1e-4);
}

test "ClockBridge round-trip: audio to mono to audio to mono" {
    var b = makeAudioBridge(0.0);
    // Phase 1: audio advances 1s.
    b.onAudioMixed(48000);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), b.mediaTime(), 1e-9);
    // Phase 2: handoff to mono, advance 2s.
    b.handoffToMonotonic();
    b.advance(2.0);
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), b.mediaTime(), 1e-9);
    // Phase 3: re-anchor to audio, advance 1s via audio.
    b.reanchorToAudio();
    b.onAudioMixed(48000);
    try std.testing.expectApproxEqAbs(@as(f64, 4.0), b.mediaTime(), 1e-9);
    // Phase 4: handoff back to mono, advance 0.5s.
    b.handoffToMonotonic();
    b.advance(0.5);
    try std.testing.expectApproxEqAbs(@as(f64, 4.5), b.mediaTime(), 1e-9);
}

test "ClockBridge sample_rate delegation" {
    var b = makeAudioBridge(0.0);
    try std.testing.expectEqual(@as(i32, 48000), b.sampleRate());
}

// -----------------------------------------------------------------------
// ClockBridge — null audio clock (silent clips)
// -----------------------------------------------------------------------

test "ClockBridge with null audio forces monotonic-master" {
    var b = makeNullAudioBridge(0.0, true);
    try std.testing.expect(!b.isAudioMaster());
}

test "ClockBridge with null audio: media_time advances via advance()" {
    var b = makeNullAudioBridge(0.0, true);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), b.mediaTime(), 1e-9);
    b.advance(1.0);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), b.mediaTime(), 1e-9);
    b.advance(0.5);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), b.mediaTime(), 1e-9);
}

test "ClockBridge with null audio: set_time and set_paused work" {
    var b = makeNullAudioBridge(0.0, true);
    b.setTime(10.0);
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), b.mediaTime(), 1e-9);

    b.setPaused(true);
    try std.testing.expect(b.isPaused());
    b.advance(5.0);
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), b.mediaTime(), 1e-9);

    b.setPaused(false);
    b.advance(1.0);
    try std.testing.expectApproxEqAbs(@as(f64, 11.0), b.mediaTime(), 1e-9);
}

test "ClockBridge with null audio: reanchor_to_audio is a safe no-op" {
    var b = makeNullAudioBridge(0.0, true);
    b.advance(2.0);
    b.reanchorToAudio();
    try std.testing.expect(!b.isAudioMaster());
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), b.mediaTime(), 1e-9);
}

test "ClockBridge with null audio: on_audio_mixed is a safe no-op" {
    var b = makeNullAudioBridge(0.0, true);
    b.advance(1.0);
    b.onAudioMixed(48000);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), b.mediaTime(), 1e-9);
}

test "ClockBridge with null audio: sample_rate and latency_seconds are zero" {
    var b = makeNullAudioBridge(0.0, true);
    try std.testing.expectEqual(@as(i32, 0), b.sampleRate());
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), b.latencySeconds(), 1e-9);
}
