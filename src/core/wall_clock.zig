//! Monotonic wall-clock milliseconds for scrub velocity and settle timing.
//! WallClockMs requires explicit conversion to/from f64 to distinguish these
//! timestamps from media time and other numeric values.

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
