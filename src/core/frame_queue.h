#pragma once

#include <array>
#include <atomic>
#include <cstddef>
#include <optional>
#include <stdexcept>

namespace core {

// -----------------------------------------------------------------------
// FrameQueue<T, Capacity>
//
// A bounded, lock-free Single-Producer / Single-Consumer (SPSC) ring queue.
//
// Guarantees:
//  - Exactly one thread calls push(); exactly one calls pop().
//  - push() never blocks — it returns false when the queue is full, so
//    the producer can apply its own back-pressure strategy.
//  - pop() returns std::nullopt when the queue is empty.
//  - Capacity must be a power of two and > 0.
//
// Memory model: the head_ and tail_ indices are ordered with
// memory_order_acquire / memory_order_release so that the item written by
// the producer is visible to the consumer without a mutex.
// -----------------------------------------------------------------------
template <typename T, size_t Capacity>
class FrameQueue {
	static_assert(Capacity >= 2, "Capacity must be at least 2");
	static_assert((Capacity & (Capacity - 1)) == 0, "Capacity must be a power of two");

public:
	FrameQueue() :
			head_(0), tail_(0) {}

	// Not copyable or movable — atomics and the storage array make it awkward
	// and there is no legitimate use case for copying a live queue.
	FrameQueue(const FrameQueue &) = delete;
	FrameQueue &operator=(const FrameQueue &) = delete;

	// Push an item onto the queue (producer side).
	// Returns true on success, false if the queue is full.
	bool push(T item) {
		const size_t tail = tail_.load(std::memory_order_relaxed);
		const size_t next = (tail + 1) & mask_;

		if (next == head_.load(std::memory_order_acquire)) {
			// Queue is full.
			return false;
		}

		storage_[tail] = std::move(item);
		tail_.store(next, std::memory_order_release);
		return true;
	}

	// Pop an item from the queue (consumer side).
	// Returns std::nullopt if the queue is empty.
	std::optional<T> pop() {
		const size_t head = head_.load(std::memory_order_relaxed);

		if (head == tail_.load(std::memory_order_acquire)) {
			// Queue is empty.
			return std::nullopt;
		}

		T item = std::move(storage_[head]);
		head_.store((head + 1) & mask_, std::memory_order_release);
		return item;
	}

	// Returns true if the queue contains no items.
	// Only reliable when called from the consumer thread.
	bool empty() const {
		return head_.load(std::memory_order_acquire) == tail_.load(std::memory_order_acquire);
	}

	// Returns true when push() would fail (the queue holds Capacity-1 items).
	// Only reliable when called from the producer thread.
	bool full() const {
		const size_t tail = tail_.load(std::memory_order_relaxed);
		const size_t next = (tail + 1) & mask_;
		return next == head_.load(std::memory_order_acquire);
	}

	// Approximate item count. Not exact under concurrent access.
	size_t size_approx() const {
		const size_t tail = tail_.load(std::memory_order_acquire);
		const size_t head = head_.load(std::memory_order_acquire);
		return (tail - head + Capacity) & mask_;
	}

	// The maximum number of items the queue can hold.
	static constexpr size_t capacity() { return Capacity - 1; }

private:
	static constexpr size_t mask_ = Capacity - 1;

	// Pad the two hot counters into separate cache lines to avoid false sharing
	// between producer and consumer threads.
	alignas(64) std::atomic<size_t> head_;
	alignas(64) std::atomic<size_t> tail_;

	// Storage sized Capacity; the ring uses Capacity-1 usable slots to
	// distinguish full from empty without a separate counter.
	std::array<T, Capacity> storage_;
};

} // namespace core
