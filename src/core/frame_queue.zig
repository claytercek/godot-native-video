//! FrameQueue(T, Capacity) — a bounded, lock-free Single-Producer /
//! Single-Consumer (SPSC) ring queue.
//!
//! Guarantees:
//!  - Exactly one thread calls push(); exactly one calls pop().
//!  - push() never blocks — it returns false when the queue is full, so
//!    the producer can apply its own back-pressure strategy.
//!  - pop() returns null when the queue is empty.
//!  - cap must be a power of two and > 0.
//!
//! Memory model: the head and tail indices are ordered with
//! .acquire / .release so that the item written by the producer is visible
//! to the consumer without a mutex.

const std = @import("std");

/// Not copyable — atomics and the storage array make it awkward and there is
/// no legitimate use case for copying a live queue. Callers should hold this
/// by pointer and never `var q2 = q;`.
pub fn FrameQueue(comptime T: type, comptime cap: usize) type {
    comptime {
        if (cap < 2) @compileError("Capacity must be at least 2");
        if (!std.math.isPowerOfTwo(cap)) @compileError("Capacity must be a power of two");
    }

    return struct {
        const Self = @This();
        const mask: usize = cap - 1;

        // Pad the two hot counters into separate cache lines to avoid false
        // sharing between producer and consumer threads (128 bytes on
        // aarch64 big cores, 64 on most x86_64).
        head: std.atomic.Value(usize) align(std.atomic.cache_line) = std.atomic.Value(usize).init(0),
        tail: std.atomic.Value(usize) align(std.atomic.cache_line) = std.atomic.Value(usize).init(0),

        // Storage sized cap; the ring uses cap-1 usable slots to distinguish
        // full from empty without a separate counter.
        storage: [cap]T = undefined,

        /// Ring-advance: the slot index one step past `idx`, wrapping via
        /// mask. Shared by push()/full()/peekNext() so the wrap arithmetic
        /// lives in exactly one place.
        fn nextIndex(idx: usize) usize {
            return (idx + 1) & mask;
        }

        pub const init: Self = .{};

        /// Push an item onto the queue (producer side).
        /// Returns true on success, false if the queue is full.
        pub fn push(self: *Self, item: T) bool {
            const tail = self.tail.load(.monotonic);
            const next = nextIndex(tail);

            if (next == self.head.load(.acquire)) {
                // Queue is full — rare in practice: the sole producer checks
                // full() before each push, so this is only a race window.
                @branchHint(.unlikely);
                return false;
            }

            self.storage[tail] = item;
            self.tail.store(next, .release);
            return true;
        }

        /// Peek the front item without removing it (consumer side).
        /// Returns null if the queue is empty. The pointer is valid until the
        /// next pop()/push() that touches this slot — read what you need, then
        /// pop(). Only safe to call from the single consumer thread.
        pub fn peek(self: *Self) ?*T {
            const head = self.head.load(.monotonic);
            if (head == self.tail.load(.acquire)) {
                return null; // empty
            }
            return &self.storage[head];
        }

        /// Peek the item one slot behind the front (the would-be "next" after
        /// a pop), without removing anything. Returns null if fewer than two
        /// items exist. Consumer-thread only.
        pub fn peekNext(self: *Self) ?*T {
            const head = self.head.load(.monotonic);
            const tail = self.tail.load(.acquire);
            if (head == tail) {
                return null; // empty
            }
            const second = nextIndex(head);
            if (second == tail) {
                return null; // exactly one item
            }
            return &self.storage[second];
        }

        /// Pop an item from the queue (consumer side).
        /// Returns null if the queue is empty.
        pub fn pop(self: *Self) ?T {
            const head = self.head.load(.monotonic);

            if (head == self.tail.load(.acquire)) {
                // Queue is empty.
                return null;
            }

            const item = self.storage[head];
            self.head.store((head + 1) & mask, .release);
            return item;
        }

        /// Returns true if the queue contains no items.
        /// Only reliable when called from the consumer thread.
        pub fn empty(self: *const Self) bool {
            return self.head.load(.acquire) == self.tail.load(.acquire);
        }

        /// Returns true when push() would fail (the queue holds cap-1 items).
        /// Only reliable when called from the producer thread.
        pub fn full(self: *const Self) bool {
            const tail = self.tail.load(.monotonic);
            return nextIndex(tail) == self.head.load(.acquire);
        }
    };
}

// -----------------------------------------------------------------------
// Basic single-threaded behaviour
// -----------------------------------------------------------------------

test "FrameQueue starts empty" {
    var q: FrameQueue(i32, 4) = .init;
    try std.testing.expect(q.empty());
    try std.testing.expect(!q.full());
}

test "FrameQueue push and pop round-trips values" {
    var q: FrameQueue(i32, 4) = .init;
    try std.testing.expect(q.push(42));
    const v = q.pop();
    try std.testing.expect(v != null);
    try std.testing.expectEqual(42, v.?);
    try std.testing.expect(q.empty());
}

test "FrameQueue preserves FIFO order" {
    var q: FrameQueue(i32, 8) = .init;
    var i: i32 = 0;
    while (i < 7) : (i += 1) {
        try std.testing.expect(q.push(i));
    }
    i = 0;
    while (i < 7) : (i += 1) {
        const v = q.pop();
        try std.testing.expect(v != null);
        try std.testing.expectEqual(i, v.?);
    }
}

test "FrameQueue pop on empty returns null" {
    var q: FrameQueue(i32, 4) = .init;
    const v = q.pop();
    try std.testing.expect(v == null);
}

test "FrameQueue peek is non-destructive and sees the front" {
    var q: FrameQueue(i32, 8) = .init;
    try std.testing.expect(q.peek() == null); // empty
    try std.testing.expect(q.peekNext() == null); // empty
    try std.testing.expect(q.push(10));
    try std.testing.expect(q.peek() != null);
    try std.testing.expectEqual(10, q.peek().?.*);
    try std.testing.expect(q.peekNext() == null); // only one item
    try std.testing.expect(q.push(20));
    try std.testing.expectEqual(10, q.peek().?.*);
    try std.testing.expect(q.peekNext() != null);
    try std.testing.expectEqual(20, q.peekNext().?.*);
    const v = q.pop();
    try std.testing.expect(v != null);
    try std.testing.expectEqual(10, v.?);
    try std.testing.expectEqual(20, q.peek().?.*);
    try std.testing.expect(q.peekNext() == null);
}

test "FrameQueue push returns false when full" {
    var q: FrameQueue(i32, 4) = .init; // capacity == 3 usable slots
    try std.testing.expect(q.push(1));
    try std.testing.expect(q.push(2));
    try std.testing.expect(q.push(3));
    // Fourth push must fail — queue is full
    try std.testing.expect(!q.push(4));
    try std.testing.expect(q.full());
}

test "FrameQueue is not full after a pop makes space" {
    var q: FrameQueue(i32, 4) = .init;
    _ = q.push(1);
    _ = q.push(2);
    _ = q.push(3);
    try std.testing.expect(q.full());

    const v = q.pop();
    try std.testing.expect(v != null);
    try std.testing.expect(!q.full());
    try std.testing.expect(q.push(99));
}

test "FrameQueue wraps around ring correctly" {
    // Fill, drain, fill again to exercise wrap-around
    var q: FrameQueue(i32, 4) = .init; // 3 usable slots
    var round: i32 = 0;
    while (round < 3) : (round += 1) {
        var i: i32 = 0;
        while (i < 3) : (i += 1) {
            try std.testing.expect(q.push(i + round * 10));
        }
        i = 0;
        while (i < 3) : (i += 1) {
            const v = q.pop();
            try std.testing.expect(v != null);
            try std.testing.expectEqual(i + round * 10, v.?);
        }
    }
}

test "FrameQueue works with move-only type" {
    // Zig has no move-only type, so this exercises the "owns a heap
    // allocation transferred through the queue" property with an allocated
    // pointer instead.
    var q: FrameQueue(?*i32, 4) = .init;
    const p = try std.testing.allocator.create(i32);
    p.* = 7;
    _ = q.push(p);
    const v = q.pop();
    try std.testing.expect(v != null);
    try std.testing.expectEqual(7, v.?.?.*);
    std.testing.allocator.destroy(v.?.?);
}

// -----------------------------------------------------------------------
// Concurrent SPSC stress test
// -----------------------------------------------------------------------

test "FrameQueue SPSC concurrent push/pop" {
    const kItems: i32 = 100_000;
    var q: FrameQueue(i32, 64) = .init;

    var consumed = std.atomic.Value(i32).init(0);
    var sum_produced = std.atomic.Value(i64).init(0);
    var sum_consumed = std.atomic.Value(i64).init(0);

    const Ctx = struct {
        q: *FrameQueue(i32, 64),
        consumed: *std.atomic.Value(i32),
        sum_produced: *std.atomic.Value(i64),
        sum_consumed: *std.atomic.Value(i64),

        fn producer(ctx: @This()) void {
            var i: i32 = 0;
            while (i < kItems) : (i += 1) {
                while (!ctx.q.push(i)) {
                    // Back-pressure: busy-spin until space is available
                    std.Thread.yield() catch {};
                }
                _ = ctx.sum_produced.fetchAdd(i, .monotonic);
            }
        }

        fn consumer(ctx: @This()) void {
            while (ctx.consumed.load(.monotonic) < kItems) {
                if (ctx.q.pop()) |v| {
                    _ = ctx.sum_consumed.fetchAdd(v, .monotonic);
                    _ = ctx.consumed.fetchAdd(1, .monotonic);
                } else {
                    std.Thread.yield() catch {};
                }
            }
        }
    };

    const ctx: Ctx = .{
        .q = &q,
        .consumed = &consumed,
        .sum_produced = &sum_produced,
        .sum_consumed = &sum_consumed,
    };

    const producer_thread = try std.Thread.spawn(.{}, Ctx.producer, .{ctx});
    const consumer_thread = try std.Thread.spawn(.{}, Ctx.consumer, .{ctx});

    producer_thread.join();
    consumer_thread.join();

    try std.testing.expectEqual(kItems, consumed.load(.monotonic));
    try std.testing.expectEqual(sum_produced.load(.monotonic), sum_consumed.load(.monotonic));
}
