//! A typed monotonic wall-clock timestamp (milliseconds).
//!
//! PlaybackController and Scrubber consume wall-clock time to measure scrub
//! velocity and debounce settle. A bare `f64` carries no contract that two
//! values came from the same clock; WallClockMs makes the "monotonic
//! wall-clock milliseconds" contract a type. Construction from a raw f64 is
//! explicit (a caller must opt in), and there is no implicit conversion
//! back, so a value can never silently masquerade as an ordinary number.

const std = @import("std");

pub const WallClockMs = struct {
    ms: f64 = 0.0,

    pub fn init(milliseconds: f64) WallClockMs {
        return .{ .ms = milliseconds };
    }
};

test "WallClockMs default is zero" {
    const w: WallClockMs = .{};
    try std.testing.expectEqual(0.0, w.ms);
}

test "WallClockMs init carries the raw value" {
    const w = WallClockMs.init(123.5);
    try std.testing.expectEqual(123.5, w.ms);
}
