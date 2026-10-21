//! The generated H.264/HEVC fixtures start at PTS zero at exactly 30fps.
const std = @import("std");

pub fn matches(index: usize, pts: f64) bool {
    const expected = @as(f64, @floatFromInt(index)) / 30.0;
    // Nanosecond transport rounding is allowed; one frame is not.
    return std.math.isFinite(pts) and @abs(pts - expected) <= 0.000001;
}

test "complete fixture PTS sequence" {
    for (0..90) |index| {
        try std.testing.expect(matches(index, @as(f64, @floatFromInt(index)) / 30.0));
    }
    try std.testing.expect(matches(1, 0.033333333));
}

test "missing zero replaced by duplicate second frame cannot preserve count" {
    // The old first<=40ms, nonstrict monotonicity, count and tail checks all
    // accepted [1/30, 1/30, 2/30, ..., 89/30]. The indexed oracle must not.
    try std.testing.expect(!matches(0, 1.0 / 30.0));
    try std.testing.expect(!matches(31, 30.0 / 30.0));
    try std.testing.expect(!matches(89, 88.0 / 30.0));
    try std.testing.expect(!matches(0, std.math.nan(f64)));
}
