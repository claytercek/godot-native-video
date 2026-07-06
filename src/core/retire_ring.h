#pragma once

#include <array>
#include <cstddef>
#include <functional>
#include <utility>

namespace core {

// -----------------------------------------------------------------------
// RetireRing<N> — bounded surface-lifetime guard (the memory-safety core).
//
// Problem: when we import a decoder surface (CVPixelBuffer / IOSurface) into
// the GPU and run a present pass that samples it, the GPU may still be
// reading that surface for some number of frames after we issued the work.
// If the Backend recycles the surface immediately, the GPU reads freed
// memory — a use-after-free that corrupts the frame or crashes.
//
// We deliberately do NOT use per-platform GPU fences. Instead we hold each
// source surface's release closure for exactly N *rendered* frames: a
// bounded ring keyed on Godot's frame latency. After a surface has survived
// N calls to advance(), the GPU is guaranteed to be done with it and we run
// its release closure exactly once.
//
// Design rules:
//  - Pure C++ logic. No Godot, RenderingDevice, Metal, or CoreVideo types.
//    The retained payload is an opaque std::function<void()> release closure,
//    so this component is fully unit-testable headlessly under ASan.
//  - Holds a surface for EXACTLY N frames and releases it EXACTLY once.
//  - Fixed capacity N slots: a surface parked this frame is released on the
//    N-th advance() that follows (when the ring head cycles back to its slot),
//    so there is no heap allocation on the present path.
//
// Usage (once per rendered frame, on the render thread):
//   ring.advance();              // ages everything; releases the oldest slot
//   ring.retain(frame.release);  // park this frame's surface for N frames
// -----------------------------------------------------------------------
template <size_t N>
class RetireRing {
	static_assert(N >= 1, "Retire latency must be at least 1 frame");

public:
	using ReleaseFn = std::function<void()>;

	RetireRing() = default;

	// Non-copyable: it owns release closures whose duplication would release a
	// surface twice. Movable so it can live inside a present pipeline object.
	RetireRing(const RetireRing &) = delete;
	RetireRing &operator=(const RetireRing &) = delete;
	RetireRing(RetireRing &&) = default;
	RetireRing &operator=(RetireRing &&) = default;

	~RetireRing() { drain(); }

	// Park a surface's release closure for N frames. Call once per presented
	// frame, AFTER advance(). A null closure is accepted and ignored (e.g. a
	// CPU/test frame with no native surface to retire).
	void retain(ReleaseFn release) {
		// The current write slot is `head_`. advance() has already aged out
		// whatever previously occupied it, so it is guaranteed empty here.
		slots_[head_] = std::move(release);
	}

	// Age the ring by one rendered frame. The slot that has now survived N
	// frames (the one we are about to reuse for this frame's retain()) is
	// released exactly once. Call once per rendered frame, BEFORE retain().
	void advance() {
		head_ = (head_ + 1) % kCapacity;
		// `head_` now points at the slot filled N frames ago. Release it before
		// it is overwritten so the surface is freed exactly once and only after
		// the GPU has had N frames to finish reading it.
		release_slot(head_);
	}

	// Release every still-parked surface immediately (teardown / stop), in FIFO
	// (oldest-first) order so drain preserves the same release ordering as
	// steady-state aging. After this the ring holds nothing. Idempotent.
	void drain() {
		// The oldest surface sits in the slot advance() would next reuse, i.e.
		// (head_ + 1). Walk forward from there so we release oldest -> newest.
		for (size_t k = 0; k < kCapacity; ++k) {
			const size_t i = (head_ + 1 + k) % kCapacity;
			release_slot(i);
		}
	}

	// Number of surfaces currently parked (for tests / instrumentation).
	size_t live_count() const {
		size_t n = 0;
		for (const auto &slot : slots_) {
			if (slot) {
				++n;
			}
		}
		return n;
	}

	static constexpr size_t latency_frames() { return N; }

private:
	// N slots: parking one surface per advance() keeps the ring full, and the
	// slot reused N advances later is exactly the surface that has now survived
	// its N frames of GPU latency.
	static constexpr size_t kCapacity = N;

	void release_slot(size_t i) {
		if (slots_[i]) {
			ReleaseFn fn = std::move(slots_[i]);
			slots_[i] = nullptr; // clear before invoking so re-entrancy is safe
			fn();
		}
	}

	std::array<ReleaseFn, kCapacity> slots_{};
	size_t head_ = 0;
};

} // namespace core
