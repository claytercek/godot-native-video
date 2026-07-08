#pragma once

// -----------------------------------------------------------------------
// wall_clock.h — a typed monotonic wall-clock timestamp (milliseconds).
//
// PlaybackController and Scrubber consume wall-clock time to measure scrub
// velocity and debounce settle. A bare `double` carries no contract that two
// values came from the same clock, so the "monotonic wall-clock milliseconds"
// contract was previously enforced only by comments. WallClockMs makes it a
// type: construction from a raw double is explicit (a caller must opt in),
// and there is no implicit conversion back to double, so a value can never
// silently masquerade as an ordinary number. Callers extract the raw value
// via `ms` when handing it to the Scrubber (whose own API stays `double`).
// -----------------------------------------------------------------------

namespace core {

struct WallClockMs {
	double ms = 0.0;

	// Explicit so a bare `double` is never silently treated as wall time.
	explicit WallClockMs(double milliseconds) : ms(milliseconds) {}

	WallClockMs() = default;
};

} // namespace core