#include "vendor/doctest.h"

#include "../../src/core/present_selector.h"

#include <optional>

using core::PresentAction;
using core::select_present_action;

// fps -> seconds per frame for the tests below (30 fps clip).
static constexpr double kFps = 30.0;
static constexpr double kInterval = 1.0 / kFps;

TEST_CASE("empty queue holds") {
	CHECK(select_present_action(std::nullopt, std::nullopt, 1.0, kInterval) == PresentAction::Hold);
}

TEST_CASE("head in the future holds (hold-early)") {
	// now = 0.50, head at 0.60 (well beyond half-interval tolerance) -> hold.
	CHECK(select_present_action(0.60, std::nullopt, 0.50, kInterval) == PresentAction::Hold);
}

TEST_CASE("single due frame shows") {
	// head exactly at now, no successor -> show.
	CHECK(select_present_action(0.50, std::nullopt, 0.50, kInterval) == PresentAction::Show);
}

TEST_CASE("slightly-late single frame still shows (never blank the display)") {
	// head is ~0.6 of a frame behind now but is the only due frame -> show, not drop.
	const double now = 0.50;
	const double head = now - 0.6 * kInterval;
	CHECK(select_present_action(head, std::nullopt, now, kInterval) == PresentAction::Show);
}

TEST_CASE("stale head with a newer due frame drops (drop-late)") {
	// now = 1.00, head at 0.90 (stale) and next at 0.96 also due -> drop the head.
	CHECK(select_present_action(0.90, 0.96, 1.00, kInterval) == PresentAction::Drop);
}

TEST_CASE("due head with a future successor shows the head") {
	// now = 1.00, head at 0.99 is due; next at 1.20 is in the future -> show head.
	CHECK(select_present_action(0.99, 1.20, 1.00, kInterval) == PresentAction::Show);
}

TEST_CASE("within half-interval tolerance counts as due") {
	// head a hair after now (within the half-interval eps) -> treated as due.
	const double now = 0.50;
	const double head = now + 0.4 * kInterval; // inside eps = 0.5*interval
	CHECK(select_present_action(head, std::nullopt, now, kInterval) == PresentAction::Show);
}

TEST_CASE("repeated drops collapse a backlog to one frame in a single tick") {
	// Simulate a queue [0.80, 0.85, 0.90, 0.95] with now = 1.00.
	// The selector should Drop until only the newest due frame (0.95) remains,
	// which then Shows. We model the queue head/next walk here.
	double pts[] = { 0.80, 0.85, 0.90, 0.95 };
	const double now = 1.00;
	int i = 0;
	int drops = 0;
	for (;;) {
		std::optional<double> head = i < 4 ? std::optional<double>(pts[i]) : std::nullopt;
		std::optional<double> next = (i + 1) < 4 ? std::optional<double>(pts[i + 1]) : std::nullopt;
		PresentAction a = select_present_action(head, next, now, kInterval);
		if (a == PresentAction::Drop) {
			++drops;
			++i; // discard head, advance
			continue;
		}
		// Should land on Show for the last (newest due) frame.
		CHECK(a == PresentAction::Show);
		CHECK(i == 3); // pts[3] == 0.95 is the survivor
		break;
	}
	CHECK(drops == 3);
}
