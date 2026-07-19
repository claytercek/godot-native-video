//! sys_clock.zig — zig 0.16 replacements for the OS threading/timing
//! primitives std.Thread.Mutex/Condition/sleep and std.time.*Timestamp used
//! to expose directly. In 0.16 those moved under std.Io as Io.Mutex/
//! Io.Condition/Io.Clock, all requiring an `Io` instance to be threaded
//! through every call.
//!
//! This codebase spawns its own worker threads directly via std.Thread.spawn
//! and has no event loop or cancelation needs, so the std-provided
//! single-threaded Io singleton is a correct, zero-setup backing instance.
//! `Mutex`/`Condition` below wrap the new primitives behind the old
//! infallible, io-free call shape (lock/unlock/wait/signal/broadcast) so
//! call sites elsewhere are unchanged.
//!
//! global_single_threaded only disables Io's async task spawning; its futex
//! ops are real OS futexes, so Mutex/Condition here are fully correct across
//! std.Thread.spawn worker pools — that's why this io-free facade is sound.

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
