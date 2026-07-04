#pragma once

#include <cstddef>
#include <optional>

namespace core {

// -----------------------------------------------------------------------
// present_selector — Godot-free drop-late / hold-early present policy.
//
// Linear-playback A/V sync needs a deterministic rule for "which decoded
// frame should be on screen right now?" given the master clock. This is the
// heart of staying in sync, so it lives here in the Engine Core, isolated
// from Godot and unit-tested headlessly.
//
// The Binding owns a FrameQueue<VideoFrame> of decode-ahead frames sorted by
// PTS (the backend pumps them in PTS order). Each render tick it asks the
// selector what to do with the queue head, given:
//   - the master clock time `now` (audio-master or monotonic fallback), and
//   - the nominal frame interval (1 / fps), used to decide what "late" means.
//
// Policy: drop-late / hold-early.
//   * HOLD  — the head frame's PTS is in the future (PTS > now). It is not
//             due yet; keep showing the current frame and wait. Return Hold.
//   * SHOW  — the head frame is due (PTS <= now) AND it is the newest frame
//             that is still due (the next frame, if any, is in the future).
//             Present it.
//   * DROP  — the head frame is due, but a *newer* frame is ALSO already due
//             (next.PTS <= now). The head is stale; drop it so we catch up to
//             real time instead of replaying a backlog in slow motion.
//
// "Late by more than one frame" is implicit: if only the head is due and the
// next frame is still in the future, we Show the head even if it is slightly
// behind `now` (a frame is on screen for ~one interval, so being up to one
// interval behind the clock is normal and must NOT be dropped — dropping it
// would blank the display). We only Drop when a strictly better (newer, due)
// frame exists to replace it. This guarantees we never drop the only frame we
// could show, and never fall permanently behind: any backlog is collapsed in
// a single tick by repeated Drop decisions until exactly one due frame remains.
// -----------------------------------------------------------------------

enum class PresentAction {
	Hold, // Head not due yet — keep the current frame, present nothing new.
	Drop, // Head is stale (a newer due frame exists) — discard the head, re-evaluate.
	Show, // Head is the correct frame for `now` — present it.
};

// Decide what to do with the queue head.
//
//   head_pts  : PTS (seconds) of the frame at the front of the queue, if any.
//   next_pts  : PTS of the frame immediately behind it, if any (for lookahead).
//   now       : master-clock media time in seconds.
//   frame_interval : nominal seconds-per-frame (1/fps). Used only as the
//                    tolerance epsilon for "due"; pass <= 0 to use a tiny eps.
//
// Returns Hold when the queue is empty or the head is in the future.
inline PresentAction select_present_action(std::optional<double> head_pts,
		std::optional<double> next_pts,
		double now,
		double frame_interval) {
	if (!head_pts.has_value()) {
		// Nothing decoded yet — hold whatever is currently on screen.
		return PresentAction::Hold;
	}

	// A small tolerance so a frame whose PTS lands a hair after `now` (rounding,
	// sample-granular clock) is still treated as due rather than held a tick.
	const double eps = frame_interval > 0.0 ? frame_interval * 0.5 : 1e-6;

	if (*head_pts > now + eps) {
		// Head is genuinely in the future: hold-early.
		return PresentAction::Hold;
	}

	// Head is due. If a newer frame is ALSO already due, the head is stale —
	// drop it to catch up (drop-late). Otherwise the head is the freshest due
	// frame: show it.
	if (next_pts.has_value() && *next_pts <= now + eps) {
		return PresentAction::Drop;
	}
	return PresentAction::Show;
}

} // namespace core
