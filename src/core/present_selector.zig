//! present_selector.zig — port of src/core/present_selector.h.
//!
//! present_selector — Godot-free drop-late / hold-early present policy.
//!
//! Linear-playback A/V sync needs a deterministic rule for "which decoded
//! frame should be on screen right now?" given the master clock. This is
//! the heart of staying in sync, so it lives here in the Engine Core,
//! isolated from Godot and unit-tested headlessly.
//!
//! The Binding owns a FrameQueue<VideoFrame> of decode-ahead frames sorted
//! by PTS (the backend pumps them in PTS order). Each render tick it asks
//! the selector what to do with the queue head, given:
//!   - the master clock time `now` (audio-master or monotonic fallback), and
//!   - the nominal frame interval (1 / fps), used to decide what "late" means.
//!
//! Policy: drop-late / hold-early.
//!   * Hold — the head frame's PTS is in the future (PTS > now). It is not
//!            due yet; keep showing the current frame and wait.
//!   * Show — the head frame is due (PTS <= now) AND it is the newest frame
//!            that is still due (the next frame, if any, is in the future).
//!            Present it.
//!   * Drop — the head frame is due, but a *newer* frame is ALSO already due
//!            (next.PTS <= now). The head is stale; drop it so we catch up
//!            to real time instead of replaying a backlog in slow motion.
//!
//! "Late by more than one frame" is implicit: if only the head is due and
//! the next frame is still in the future, we Show the head even if it is
//! slightly behind `now` (a frame is on screen for ~one interval, so being
//! up to one interval behind the clock is normal and must NOT be dropped —
//! dropping it would blank the display). We only Drop when a strictly
//! better (newer, due) frame exists to replace it. This guarantees we never
//! drop the only frame we could show, and never fall permanently behind:
//! any backlog is collapsed in a single tick by repeated Drop decisions
//! until exactly one due frame remains.

const std = @import("std");

pub const PresentAction = enum {
    hold, // Head not due yet — keep the current frame, present nothing new.
    drop, // Head is stale (a newer due frame exists) — discard the head, re-evaluate.
    show, // Head is the correct frame for `now` — present it.
};

/// Decide what to do with the queue head.
///
///   head_pts       : PTS (seconds) of the frame at the front of the queue, if any.
///   next_pts       : PTS of the frame immediately behind it, if any (for lookahead).
///   now            : master-clock media time in seconds.
///   frame_interval : nominal seconds-per-frame (1/fps). Used only as the
///                    tolerance epsilon for "due"; pass <= 0 to use a tiny eps.
///
/// Returns .hold when the queue is empty or the head is in the future.
pub fn selectPresentAction(
    head_pts: ?f64,
    next_pts: ?f64,
    now: f64,
    frame_interval: f64,
) PresentAction {
    const head = head_pts orelse {
        // Nothing decoded yet — hold whatever is currently on screen.
        return .hold;
    };

    // A small tolerance so a frame whose PTS lands a hair after `now`
    // (rounding, sample-granular clock) is still treated as due rather than
    // held a tick.
    const eps = if (frame_interval > 0.0) frame_interval * 0.5 else 1e-6;

    if (head > now + eps) {
        // Head is genuinely in the future: hold-early.
        return .hold;
    }

    // Head is due. If a newer frame is ALSO already due, the head is stale —
    // drop it to catch up (drop-late). Otherwise the head is the freshest
    // due frame: show it.
    if (next_pts) |next| {
        if (next <= now + eps) {
            return .drop;
        }
    }
    return .show;
}

// fps -> seconds per frame for the tests below (30 fps clip).
const test_fps: f64 = 30.0;
const test_interval: f64 = 1.0 / test_fps;

test "empty queue holds" {
    try std.testing.expectEqual(PresentAction.hold, selectPresentAction(null, null, 1.0, test_interval));
}

test "head in the future holds (hold-early)" {
    // now = 0.50, head at 0.60 (well beyond half-interval tolerance) -> hold.
    try std.testing.expectEqual(PresentAction.hold, selectPresentAction(0.60, null, 0.50, test_interval));
}

test "single due frame shows" {
    // head exactly at now, no successor -> show.
    try std.testing.expectEqual(PresentAction.show, selectPresentAction(0.50, null, 0.50, test_interval));
}

test "slightly-late single frame still shows (never blank the display)" {
    // head is ~0.6 of a frame behind now but is the only due frame -> show, not drop.
    const now = 0.50;
    const head = now - 0.6 * test_interval;
    try std.testing.expectEqual(PresentAction.show, selectPresentAction(head, null, now, test_interval));
}

test "stale head with a newer due frame drops (drop-late)" {
    // now = 1.00, head at 0.90 (stale) and next at 0.96 also due -> drop the head.
    try std.testing.expectEqual(PresentAction.drop, selectPresentAction(0.90, 0.96, 1.00, test_interval));
}

test "due head with a future successor shows the head" {
    // now = 1.00, head at 0.99 is due; next at 1.20 is in the future -> show head.
    try std.testing.expectEqual(PresentAction.show, selectPresentAction(0.99, 1.20, 1.00, test_interval));
}

test "within half-interval tolerance counts as due" {
    // head a hair after now (within the half-interval eps) -> treated as due.
    const now = 0.50;
    const head = now + 0.4 * test_interval; // inside eps = 0.5*interval
    try std.testing.expectEqual(PresentAction.show, selectPresentAction(head, null, now, test_interval));
}

test "repeated drops collapse a backlog to one frame in a single tick" {
    // Simulate a queue [0.80, 0.85, 0.90, 0.95] with now = 1.00.
    // The selector should Drop until only the newest due frame (0.95) remains,
    // which then Shows. We model the queue head/next walk here.
    const pts = [_]f64{ 0.80, 0.85, 0.90, 0.95 };
    const now = 1.00;
    var i: usize = 0;
    var drops: i32 = 0;
    while (true) {
        const head: ?f64 = if (i < 4) pts[i] else null;
        const next: ?f64 = if (i + 1 < 4) pts[i + 1] else null;
        const a = selectPresentAction(head, next, now, test_interval);
        if (a == .drop) {
            drops += 1;
            i += 1;
            continue;
        }
        // Should land on Show for the last (newest due) frame.
        try std.testing.expectEqual(PresentAction.show, a);
        try std.testing.expectEqual(3, i); // pts[3] == 0.95 is the survivor
        break;
    }
    try std.testing.expectEqual(3, drops);
}
