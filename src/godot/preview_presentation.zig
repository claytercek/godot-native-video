//! Godot-independent ownership policy for an asynchronously imported preview.
//! A submission token identifies pixels, not PTS (two seeks may share a PTS).
const std = @import("std");

pub const Result = enum { pending, presented, failed };
pub const timeout_ms: f64 = 5000;

/// Classify a surface import's non-success tag without depending on Godot's
/// plane/RID types. Recoverable device pressure follows the same bounded
/// wall-time retry policy as a delayed importer, never drops the sole preview.
pub fn importFailure(tag: anytype) Result {
    return switch (tag) {
        .not_ready, .transient_failure => .pending,
        .bad_frame, .capability_unavailable => .failed,
        else => unreachable, // success carries planes, not a failure policy
    };
}

/// The presenter consumes Attempt.frame only on .presented. On .pending or
/// .failed it borrows the frame; finish() either retains it or releases it.
/// Taking the attempt out of this state before presenting makes cancellation
/// from a synchronous texture-changed handler safe and generation-aware.
pub fn Pending(comptime Frame: type) type {
    return struct {
        const Self = @This();
        pub const Attempt = struct { frame: Frame, token: u64 };
        token: u64 = 0,
        started_ms: f64 = 0,
        frame: ?Frame = null,

        pub fn begin(self: *Self, token: u64, now_ms: f64) void {
            std.debug.assert(token != 0);
            self.cancel();
            self.token = token;
            self.started_ms = now_ms;
        }

        pub fn cancel(self: *Self) void {
            const old = self.frame;
            self.frame = null;
            self.token = 0;
            if (old) |frame| frame.release();
        }

        pub fn setFrame(self: *Self, frame: Frame) void {
            std.debug.assert(self.token != 0 and self.frame == null);
            self.frame = frame;
        }

        pub fn take(self: *Self) ?Attempt {
            const frame = self.frame orelse return null;
            self.frame = null;
            return .{ .frame = frame, .token = self.token };
        }

        pub fn finish(self: *Self, attempt: Attempt, result: Result) void {
            if (result == .presented) return; // transferred to presenter's retire ring
            if (result == .pending and self.token == attempt.token and self.frame == null) {
                self.frame = attempt.frame;
                return;
            }
            attempt.frame.release();
            if (self.token == attempt.token) self.cancel();
        }

        pub fn expired(self: *const Self, now_ms: f64) bool {
            return self.token != 0 and now_ms - self.started_ms >= timeout_ms;
        }
    };
}

/// A stale ready result is no better than not_ready. The caller discards its
/// planes before dispatch; only matching pixels can complete the submission.
pub fn matches(expected: u64, actual: u64) bool {
    return expected != 0 and expected == actual;
}

const FakeFrame = struct {
    releases: *usize,
    pub fn release(self: FakeFrame) void {
        self.releases.* += 1;
    }
};

test "cold importer retries retain one source until matching output" {
    var releases: usize = 0;
    var pending: Pending(FakeFrame) = .{};
    pending.begin(1, 0);
    pending.setFrame(.{ .releases = &releases });
    // Fake delayed importer: two empty slots, then this submission is ready.
    for ([_]?u64{ null, null, 1 }) |ready| {
        const attempt = pending.take().?;
        const result: Result = if (ready) |token| (if (matches(attempt.token, token)) .presented else .pending) else .pending;
        pending.finish(attempt, result);
        try std.testing.expectEqual(@as(usize, 0), releases);
        if (result == .presented) attempt.frame.release(); // fake GPU retirement
    }
    pending.cancel();
    try std.testing.expectEqual(@as(usize, 1), releases);
}

test "warm ring with same PTS but different submission must not complete" {
    var releases: usize = 0;
    var pending: Pending(FakeFrame) = .{};
    pending.begin(30, 0);
    pending.setFrame(.{ .releases = &releases });
    for ([_]u64{ 28, 29, 30 }) |ready| {
        const attempt = pending.take().?;
        const result: Result = if (matches(attempt.token, ready)) .presented else .pending;
        pending.finish(attempt, result);
        if (ready != 30) try std.testing.expect(pending.frame != null);
        if (result == .presented) attempt.frame.release();
    }
    try std.testing.expect(pending.frame == null);
    try std.testing.expectEqual(@as(usize, 1), releases);
}

test "repeated seeks cancel retained old frame and reject in-flight retry" {
    var old_releases: usize = 0;
    var new_releases: usize = 0;
    var pending: Pending(FakeFrame) = .{};
    pending.begin(1, 0);
    pending.setFrame(.{ .releases = &old_releases });
    const old = pending.take().?;
    pending.begin(2, 1); // synchronous seek supersedes the in-flight attempt
    pending.setFrame(.{ .releases = &new_releases });
    pending.finish(old, .pending);
    try std.testing.expectEqual(@as(usize, 1), old_releases);
    try std.testing.expectEqual(@as(u64, 2), pending.token);
    try std.testing.expectEqual(@as(usize, 0), new_releases);
    pending.begin(3, 2); // supersede while owned, not in flight
    try std.testing.expectEqual(@as(usize, 1), new_releases);
    pending.cancel();
}

test "terminal failure releases once and does not authorize endless retries" {
    var releases: usize = 0;
    var pending: Pending(FakeFrame) = .{};
    pending.begin(1, 0);
    pending.setFrame(.{ .releases = &releases });
    pending.finish(pending.take().?, .failed);
    try std.testing.expectEqual(@as(u64, 0), pending.token);
    try std.testing.expect(pending.take() == null);
    pending.cancel();
    try std.testing.expectEqual(@as(usize, 1), releases);
}

test "cancel during publish leaves consumed frame with presenter only" {
    var releases: usize = 0;
    var pending: Pending(FakeFrame) = .{};
    pending.begin(1, 0);
    pending.setFrame(.{ .releases = &releases });
    const attempt = pending.take().?;
    pending.cancel(); // synchronous changed handler resumes/stops/unloads/frees
    pending.finish(attempt, .presented);
    try std.testing.expectEqual(@as(usize, 0), releases);
    attempt.frame.release();
    pending.cancel();
    try std.testing.expectEqual(@as(usize, 1), releases);
}

test "successful old publish cannot complete a reentrant newer request" {
    var old_releases: usize = 0;
    var new_releases: usize = 0;
    var pending: Pending(FakeFrame) = .{};
    pending.begin(1, 0);
    pending.setFrame(.{ .releases = &old_releases });
    const old = pending.take().?;
    pending.begin(2, 1); // changed handler seeks again during publication
    pending.setFrame(.{ .releases = &new_releases });
    pending.finish(old, .presented);
    try std.testing.expectEqual(@as(u64, 2), pending.token);
    try std.testing.expect(pending.frame != null);
    try std.testing.expectEqual(@as(usize, 0), old_releases);
    old.frame.release(); // old GPU retirement is independent of new request
    pending.cancel();
    try std.testing.expectEqual(@as(usize, 1), old_releases);
    try std.testing.expectEqual(@as(usize, 1), new_releases);
}

test "resume stop reload and destruction cancel owned previews exactly once" {
    for (0..4) |_| {
        var releases: usize = 0;
        var pending: Pending(FakeFrame) = .{};
        pending.begin(1, 0);
        try std.testing.expect(pending.take() == null); // decoder queue not ready
        pending.setFrame(.{ .releases = &releases });
        pending.finish(pending.take().?, .pending);
        pending.cancel();
        pending.cancel();
        try std.testing.expect(pending.take() == null);
        try std.testing.expectEqual(@as(usize, 1), releases);
    }
}

test "persistent not_ready has a wall-time deadline not a retry count" {
    var releases: usize = 0;
    var pending: Pending(FakeFrame) = .{};
    pending.begin(1, 100);
    pending.setFrame(.{ .releases = &releases });
    for (0..100) |_| pending.finish(pending.take().?, .pending);
    try std.testing.expect(!pending.expired(100));
    try std.testing.expect(pending.expired(100 + timeout_ms));
    pending.cancel();
    try std.testing.expectEqual(@as(usize, 1), releases);
}

const FakeImportTag = enum { success, not_ready, transient_failure, bad_frame, capability_unavailable };

test "transient import failures retain the sole preview until success" {
    var releases: usize = 0;
    var pending: Pending(FakeFrame) = .{};
    pending.begin(7, 100);
    pending.setFrame(.{ .releases = &releases });
    for ([_]FakeImportTag{ .transient_failure, .not_ready, .transient_failure }) |tag| {
        pending.finish(pending.take().?, importFailure(tag));
        try std.testing.expect(pending.frame != null);
        try std.testing.expectEqual(@as(u64, 7), pending.token);
        try std.testing.expectEqual(@as(f64, 100), pending.started_ms);
        try std.testing.expectEqual(@as(usize, 0), releases);
    }
    const success = pending.take().?;
    pending.finish(success, .presented);
    pending.cancel(); // preview->resume; GPU alone owns the consumed source
    try std.testing.expectEqual(@as(usize, 0), releases);
    success.frame.release();
    try std.testing.expectEqual(@as(usize, 1), releases);
}

test "persistent transient failure expires without resetting the deadline" {
    var releases: usize = 0;
    var pending: Pending(FakeFrame) = .{};
    pending.begin(7, 100);
    pending.setFrame(.{ .releases = &releases });
    for (0..100) |_| pending.finish(pending.take().?, importFailure(FakeImportTag.transient_failure));
    try std.testing.expect(!pending.expired(100 + timeout_ms - 1));
    try std.testing.expect(pending.expired(100 + timeout_ms));
    pending.cancel();
    pending.cancel();
    try std.testing.expectEqual(@as(usize, 1), releases);
}

test "permanent import failure after transient retries cancels once" {
    for ([_]FakeImportTag{ .bad_frame, .capability_unavailable }) |terminal| {
        var releases: usize = 0;
        var pending: Pending(FakeFrame) = .{};
        pending.begin(7, 100);
        pending.setFrame(.{ .releases = &releases });
        pending.finish(pending.take().?, importFailure(FakeImportTag.transient_failure));
        pending.finish(pending.take().?, importFailure(terminal));
        try std.testing.expectEqual(@as(u64, 0), pending.token);
        try std.testing.expect(pending.take() == null);
        pending.cancel();
        try std.testing.expectEqual(@as(usize, 1), releases);
    }
}
