//! OS synchronization and timing wrappers for Zig 0.16's std.Io primitives.
//! Keep an infallible API without passing Io through each call site.
//!
//! Workers use std.Thread.spawn and need no event loop or cancellation, so
//! std.Io.Threaded.global_single_threaded supplies the backing Io. It disables
//! async task spawning only; its OS futex operations still synchronize workers.

const std = @import("std");

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

/// Drop-in replacement for the removed std.Thread.Mutex.
pub const Mutex = struct {
    inner: std.Io.Mutex = .init,

    pub fn lock(m: *Mutex) void {
        m.inner.lockUncancelable(io());
    }

    pub fn unlock(m: *Mutex) void {
        m.inner.unlock(io());
    }
};

/// Drop-in replacement for the removed std.Thread.Condition.
pub const Condition = struct {
    inner: std.Io.Condition = .init,

    pub fn wait(cv: *Condition, mu: *Mutex) void {
        cv.inner.waitUncancelable(io(), &mu.inner);
    }

    pub fn signal(cv: *Condition) void {
        cv.inner.signal(io());
    }

    pub fn broadcast(cv: *Condition) void {
        cv.inner.broadcast(io());
    }
};

/// Replacement for the removed std.Thread.sleep.
pub fn sleep(ns: u64) void {
    const duration: std.Io.Clock.Duration = .{ .raw = .fromNanoseconds(@intCast(ns)), .clock = .awake };
    duration.sleep(io()) catch {};
}

/// Replacement for the removed std.time.nanoTimestamp (monotonic clock).
pub fn nanoTimestamp() i128 {
    return std.Io.Clock.awake.now(io()).nanoseconds;
}

/// Replacement for the removed std.time.milliTimestamp (monotonic clock).
pub fn milliTimestamp() i64 {
    return std.Io.Clock.awake.now(io()).toMilliseconds();
}
