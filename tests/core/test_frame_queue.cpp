#include "vendor/doctest.h"

#include "../../src/core/frame_queue.h"

#include <atomic>
#include <thread>
#include <vector>

using core::FrameQueue;

// -----------------------------------------------------------------------
// Basic single-threaded behaviour
// -----------------------------------------------------------------------

TEST_CASE("FrameQueue starts empty") {
	FrameQueue<int, 4> q;
	CHECK(q.empty());
	CHECK_FALSE(q.full());
	CHECK(q.size_approx() == 0);
}

TEST_CASE("FrameQueue capacity is Capacity-1") {
	// With Capacity=4 the usable slots are 3 (one sentinel for full/empty)
	CHECK(FrameQueue<int, 4>::capacity() == 3);
	CHECK(FrameQueue<int, 8>::capacity() == 7);
	CHECK(FrameQueue<int, 16>::capacity() == 15);
}

TEST_CASE("FrameQueue push and pop round-trips values") {
	FrameQueue<int, 4> q;
	REQUIRE(q.push(42));
	auto v = q.pop();
	REQUIRE(v.has_value());
	CHECK(*v == 42);
	CHECK(q.empty());
}

TEST_CASE("FrameQueue preserves FIFO order") {
	FrameQueue<int, 8> q;
	for (int i = 0; i < 7; ++i) {
		REQUIRE(q.push(i));
	}
	for (int i = 0; i < 7; ++i) {
		auto v = q.pop();
		REQUIRE(v.has_value());
		CHECK(*v == i);
	}
}

TEST_CASE("FrameQueue pop on empty returns nullopt") {
	FrameQueue<int, 4> q;
	auto v = q.pop();
	CHECK_FALSE(v.has_value());
}

TEST_CASE("FrameQueue push returns false when full") {
	FrameQueue<int, 4> q; // capacity == 3 usable slots
	CHECK(q.push(1));
	CHECK(q.push(2));
	CHECK(q.push(3));
	// Fourth push must fail — queue is full
	CHECK_FALSE(q.push(4));
	CHECK(q.full());
}

TEST_CASE("FrameQueue is not full after a pop makes space") {
	FrameQueue<int, 4> q;
	q.push(1);
	q.push(2);
	q.push(3);
	REQUIRE(q.full());

	auto v = q.pop();
	REQUIRE(v.has_value());
	CHECK_FALSE(q.full());
	CHECK(q.push(99));
}

TEST_CASE("FrameQueue size_approx tracks item count") {
	FrameQueue<int, 8> q;
	CHECK(q.size_approx() == 0);
	q.push(1);
	CHECK(q.size_approx() == 1);
	q.push(2);
	CHECK(q.size_approx() == 2);
	q.pop();
	CHECK(q.size_approx() == 1);
	q.pop();
	CHECK(q.size_approx() == 0);
}

TEST_CASE("FrameQueue wraps around ring correctly") {
	// Fill, drain, fill again to exercise wrap-around
	FrameQueue<int, 4> q; // 3 usable slots
	for (int round = 0; round < 3; ++round) {
		for (int i = 0; i < 3; ++i) {
			REQUIRE(q.push(i + round * 10));
		}
		for (int i = 0; i < 3; ++i) {
			auto v = q.pop();
			REQUIRE(v.has_value());
			CHECK(*v == i + round * 10);
		}
	}
}

TEST_CASE("FrameQueue works with move-only type") {
	FrameQueue<std::unique_ptr<int>, 4> q;
	q.push(std::make_unique<int>(7));
	auto v = q.pop();
	REQUIRE(v.has_value());
	CHECK(**v == 7);
}

// -----------------------------------------------------------------------
// Concurrent SPSC stress test
// -----------------------------------------------------------------------

TEST_CASE("FrameQueue SPSC concurrent push/pop") {
	constexpr int kItems = 100'000;
	FrameQueue<int, 64> q;

	std::atomic<int> consumed{ 0 };
	std::atomic<long long> sum_produced{ 0 };
	std::atomic<long long> sum_consumed{ 0 };

	std::thread producer([&] {
		for (int i = 0; i < kItems; ++i) {
			while (!q.push(i)) {
				// Back-pressure: busy-spin until space is available
				std::this_thread::yield();
			}
			sum_produced.fetch_add(i, std::memory_order_relaxed);
		}
	});

	std::thread consumer([&] {
		while (consumed.load(std::memory_order_relaxed) < kItems) {
			auto v = q.pop();
			if (v) {
				sum_consumed.fetch_add(*v, std::memory_order_relaxed);
				consumed.fetch_add(1, std::memory_order_relaxed);
			} else {
				std::this_thread::yield();
			}
		}
	});

	producer.join();
	consumer.join();

	CHECK(consumed.load() == kItems);
	CHECK(sum_produced.load() == sum_consumed.load());
}
