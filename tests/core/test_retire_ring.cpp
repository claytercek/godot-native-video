#include "vendor/doctest.h"

#include "../../src/core/retire_ring.h"

#include <memory>
#include <vector>

using core::RetireRing;

// -----------------------------------------------------------------------
// RetireRing — surface-lifetime guard. These tests assert the external
// behaviour the present path depends on: a parked surface is released
// EXACTLY once and only after it has survived EXACTLY N rendered frames.
// Compile this target with -fsanitize=address to prove no use-after-free.
// -----------------------------------------------------------------------

TEST_CASE("a surface is held for exactly N frames then released once") {
	constexpr size_t N = 3;
	RetireRing<N> ring;

	int releases = 0;

	// Frame 0: park a surface.
	ring.advance();
	ring.retain([&releases]() { ++releases; });
	CHECK(ring.live_count() == 1);

	// It must survive the next N-1 advances...
	for (size_t f = 1; f < N; ++f) {
		ring.advance();
		ring.retain(nullptr); // no new surface this frame
		CHECK(releases == 0); // still alive
	}

	// ...and be released on the N-th advance after it was parked.
	ring.advance();
	CHECK(releases == 1);
	CHECK(ring.live_count() == 0);

	// And never released again.
	for (int f = 0; f < 10; ++f) {
		ring.advance();
		ring.retain(nullptr);
	}
	CHECK(releases == 1);
}

TEST_CASE("each frame's surface is released exactly once, in order") {
	constexpr size_t N = 2;
	RetireRing<N> ring;

	std::vector<int> released_order;

	// Park a distinct surface every frame for many frames.
	constexpr int kFrames = 20;
	for (int i = 0; i < kFrames; ++i) {
		ring.advance();
		ring.retain([&released_order, i]() { released_order.push_back(i); });
	}

	// Drain the tail so every parked surface gets released.
	ring.drain();

	// Every surface released exactly once...
	REQUIRE(released_order.size() == static_cast<size_t>(kFrames));
	// ...and in FIFO order.
	for (int i = 0; i < kFrames; ++i) {
		CHECK(released_order[static_cast<size_t>(i)] == i);
	}
}

TEST_CASE("drain releases all parked surfaces and is idempotent") {
	RetireRing<4> ring;
	int releases = 0;

	for (int i = 0; i < 3; ++i) {
		ring.advance();
		ring.retain([&releases]() { ++releases; });
	}
	CHECK(releases == 0);

	ring.drain();
	CHECK(releases == 3);

	// Second drain must not double-release.
	ring.drain();
	CHECK(releases == 3);
}

TEST_CASE("destructor releases outstanding surfaces (no leak)") {
	auto sentinel = std::make_shared<int>(0);
	{
		RetireRing<3> ring;
		std::weak_ptr<int> weak = sentinel;
		// Capture the shared_ptr in the release closure; if the ring leaks the
		// closure, the sentinel's refcount never drops.
		ring.advance();
		ring.retain([sentinel]() { /* holds a ref until released */ });
		CHECK(sentinel.use_count() == 2); // local + closure
	}
	// Ring destroyed -> closure destroyed -> only the local ref remains.
	CHECK(sentinel.use_count() == 1);
}

TEST_CASE("latency_frames reports the configured N") {
	CHECK(RetireRing<1>::latency_frames() == 1);
	CHECK(RetireRing<5>::latency_frames() == 5);
}
