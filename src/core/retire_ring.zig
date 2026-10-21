//! GPU lifetime retirement, paced by the engine's rendered-frame counter.
//!
//! Every submitted frame and replaced resource generation is held for N
//! rendered epochs. All payloads submitted in one epoch share a FIFO batch:
//! retries never age lifetimes, and multiple submissions never overwrite one
//! another. A skipped epoch gap can release old batches in bounded time.
//!
//! Retention allocates and transfers ownership before GPU dispatch; allocation
//! failure leaves every resource with the caller. Non-copyable. `drain` is an
//! immediate teardown operation, NOT a GPU fence or a latency wait.

const std = @import("std");

/// Output-slot pacing is by submitting epoch, not by elapsed time. Multiple
/// dispatches before one draw share a slot; the first dispatch after a pause
/// uses a different slot from the texture still sampled in the previous draw.
pub fn EpochSlots(comptime N: usize) type {
    if (N < 2) @compileError("Output requires at least 2 slots");
    return struct {
        epoch: ?u64 = null,
        index: usize = 0,

        pub fn select(self: *@This(), epoch: u64) usize {
            if (self.epoch != epoch) {
                self.index = (self.index + 1) % N;
                self.epoch = epoch;
            }
            return self.index;
        }
    };
}

/// Render-epoch retirement with any number of payloads per epoch. Repeated
/// imports/presents neither age resources nor overwrite a payload. Allocation and
/// ownership transfer happen atomically, BEFORE the caller submits GPU work.
///
/// `epoch` must be the canonical rendered-frame counter, not a process tick or
/// an import-attempt count. Call advance even when no new frame is presented.
/// Non-copyable; drain before destroying the allocator or rendering device.
pub fn RetireRing(comptime N: usize) type {
    if (N < 1) @compileError("Retire latency must be at least 1 frame");
    return struct {
        const Self = @This();
        const Node = struct {
            next: ?*Node = null,
            release: *const fn (*Node) void,
        };
        const Batch = struct { first: ?*Node = null, last: ?*Node = null };

        slots: [N]Batch = @splat(.{}),
        head: usize = 0,
        epoch: ?u64 = null,
        count: usize = 0,

        pub fn advance(self: *Self, epoch: u64) void {
            const previous = self.epoch orelse {
                self.epoch = epoch;
                return;
            };
            std.debug.assert(epoch >= previous);
            self.epoch = epoch;
            // After N epochs every old batch is safe; don't walk an unbounded
            // gap when a stopped player resumes or a window was hidden.
            const elapsed = @min(epoch - previous, N);
            for (0..@intCast(elapsed)) |_| {
                self.head = (self.head + 1) % N;
                self.releaseSlot(self.head);
            }
        }

        pub fn retain(self: *Self, allocator: std.mem.Allocator, value: anytype, comptime teardown: fn (*@TypeOf(value)) void) !void {
            std.debug.assert(self.epoch != null);
            const Box = struct {
                node: Node = .{ .release = release },
                allocator: std.mem.Allocator,
                value: @TypeOf(value),
                fn release(node: *Node) void {
                    // Nodes only come from allocator.create(Box), which
                    // guarantees the parent's potentially stronger alignment.
                    const box: *@This() = @alignCast(@fieldParentPtr("node", node));
                    teardown(&box.value);
                    box.allocator.destroy(box);
                }
            };
            const box = try allocator.create(Box);
            box.* = .{ .allocator = allocator, .value = value };
            const batch = &self.slots[self.head];
            if (batch.last) |last| last.next = &box.node else batch.first = &box.node;
            batch.last = &box.node;
            self.count += 1;
        }

        pub fn currentEpoch(self: *const Self) u64 {
            return self.epoch.?;
        }

        pub fn liveCount(self: *const Self) usize {
            return self.count;
        }

        pub fn drain(self: *Self) void {
            for (0..N) |k| self.releaseSlot((self.head + 1 + k) % N);
        }

        fn releaseSlot(self: *Self, index: usize) void {
            var next = self.slots[index].first;
            self.slots[index] = .{}; // detach the entire batch before teardown
            while (next) |node| {
                next = node.next;
                self.count -= 1;
                node.release(node);
            }
        }
    };
}

const EpochTestValue = struct {
    releases: *usize,
    fn release(value: *EpochTestValue) void {
        value.releases.* += 1;
    }
};

test "epoch batches retain every same-frame preview and resumed submission" {
    var releases: usize = 0;
    var ring: RetireRing(3) = .{};
    defer ring.drain();
    ring.advance(100);
    const preview_epoch = ring.currentEpoch();
    // Preview dispatch; synchronous changed resumes playback; _update then
    // dispatches another frame in the SAME rendered epoch, plus a rebuild.
    for (0..12) |_| {
        ring.advance(100);
        try ring.retain(std.testing.allocator, EpochTestValue{ .releases = &releases }, EpochTestValue.release);
        try std.testing.expectEqual(preview_epoch, ring.currentEpoch());
    }
    try std.testing.expectEqual(@as(usize, 12), ring.liveCount());
    // not_ready/transient retries in this same frame cannot age the batch.
    for (0..100) |_| ring.advance(100);
    try std.testing.expectEqual(@as(usize, 0), releases);
    ring.advance(101);
    try std.testing.expect(preview_epoch != ring.currentEpoch());
    ring.advance(102);
    try std.testing.expectEqual(@as(usize, 0), releases);
    // The pump still advances while paused/stopped, without new submissions.
    ring.advance(103);
    try std.testing.expectEqual(@as(usize, 12), releases);
    try std.testing.expectEqual(@as(usize, 0), ring.liveCount());
    ring.advance(104);
    ring.drain();
    try std.testing.expectEqual(@as(usize, 12), releases);
}

test "epoch retirement releases FIFO across frames and idle gaps" {
    var order = std.ArrayList(usize).empty;
    defer order.deinit(std.testing.allocator);
    const Value = struct {
        order: *std.ArrayList(usize),
        id: usize,
        fn release(value: *@This()) void {
            value.order.append(std.testing.allocator, value.id) catch unreachable;
        }
    };
    var ring: RetireRing(3) = .{};
    defer ring.drain();
    var id: usize = 0;
    for (0..3) |epoch| {
        ring.advance(epoch);
        for (0..2) |_| {
            try ring.retain(std.testing.allocator, Value{ .order = &order, .id = id }, Value.release);
            id += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), order.items.len);
    ring.advance(10000); // no retry-count aging, no unbounded gap loop
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2, 3, 4, 5 }, order.items);
    try ring.retain(std.testing.allocator, Value{ .order = &order, .id = 6 }, Value.release);
    ring.advance(10002);
    try std.testing.expectEqual(@as(usize, 6), order.items.len);
    ring.advance(10003);
    try std.testing.expectEqual(@as(usize, 7), order.items.len);
}

test "epoch retirement releases over-aligned payloads on advance and drain" {
    const Value = struct {
        releases: *[3]usize,
        id: usize align(64),

        fn release(value: *@This()) void {
            std.testing.expectEqual(@as(usize, 0), @intFromPtr(value) % @alignOf(@This())) catch unreachable;
            value.releases[value.id] += 1;
        }
    };
    // Force Box to require stronger alignment than its intrusive Node, even
    // on targets where ordinary pointer-sized payloads don't expose the bug.
    try std.testing.expect(@alignOf(Value) > @alignOf(RetireRing(2).Node));
    var releases: [3]usize = @splat(0);
    var ring: RetireRing(2) = .{};
    defer ring.drain();
    ring.advance(10);
    for (0..2) |id| {
        try ring.retain(std.testing.allocator, Value{ .releases = &releases, .id = id }, Value.release);
    }
    ring.advance(11);
    try std.testing.expectEqualSlices(usize, &.{ 0, 0, 0 }, &releases);
    ring.advance(12);
    try std.testing.expectEqualSlices(usize, &.{ 1, 1, 0 }, &releases);
    try std.testing.expectEqual(@as(usize, 0), ring.liveCount());

    try ring.retain(std.testing.allocator, Value{ .releases = &releases, .id = 2 }, Value.release);
    ring.drain();
    ring.drain();
    try std.testing.expectEqualSlices(usize, &.{ 1, 1, 1 }, &releases);
    try std.testing.expectEqual(@as(usize, 0), ring.liveCount());
}

test "epoch retention allocation failure leaves caller ownership intact" {
    var releases: usize = 0;
    var ring: RetireRing(3) = .{};
    ring.advance(0);
    var buffer: [0]u8 = .{};
    var failing = std.heap.FixedBufferAllocator.init(&buffer);
    try std.testing.expectError(error.OutOfMemory, ring.retain(failing.allocator(), EpochTestValue{ .releases = &releases }, EpochTestValue.release));
    ring.drain();
    try std.testing.expectEqual(@as(usize, 0), releases);
    try std.testing.expectEqual(@as(usize, 0), ring.liveCount());
    // The frame/import/generation was never transferred; caller cleans up.
    var value: EpochTestValue = .{ .releases = &releases };
    EpochTestValue.release(&value);
    try std.testing.expectEqual(@as(usize, 1), releases);
}

test "epoch drain releases complete batches once and permits reuse" {
    var releases: usize = 0;
    var ring: RetireRing(3) = .{};
    ring.advance(10);
    for (0..5) |_| try ring.retain(std.testing.allocator, EpochTestValue{ .releases = &releases }, EpochTestValue.release);
    ring.drain();
    ring.drain();
    try std.testing.expectEqual(@as(usize, 5), releases);
    try ring.retain(std.testing.allocator, EpochTestValue{ .releases = &releases }, EpochTestValue.release);
    ring.advance(12);
    try std.testing.expectEqual(@as(usize, 5), releases);
    ring.advance(13);
    try std.testing.expectEqual(@as(usize, 6), releases);
}

test "output slots do not lap in one epoch or overwrite displayed slot after pause" {
    var slots: EpochSlots(3) = .{};
    const first = slots.select(10);
    for (0..100) |_| try std.testing.expectEqual(first, slots.select(10));
    const second = slots.select(11);
    try std.testing.expect(first != second);
    const third = slots.select(12);
    try std.testing.expect(first != third and second != third);
    try std.testing.expectEqual(first, slots.select(13));
    // During a long pause the most recent output remains sampled every draw.
    // The number of elapsed epochs must not select that same displayed slot.
    const resumed = slots.select(10000);
    try std.testing.expect(resumed != first);
    for (0..100) |_| try std.testing.expectEqual(resumed, slots.select(10000));
}

test "replaced generations retire without a later successful frame" {
    var frame_releases: usize = 0;
    var generation_releases: usize = 0;
    const Generation = struct {
        frame_releases: *usize,
        generation_releases: *usize,
        fn release(value: *@This()) void {
            // Shader/output resources must outlive uniforms/imports/surfaces
            // from the generation's most recent use, not the next new frame.
            std.debug.assert(value.frame_releases.* == 1);
            value.generation_releases.* += 1;
        }
    };
    var ring: RetireRing(3) = .{};
    defer ring.drain();
    ring.advance(8);
    try ring.retain(std.testing.allocator, EpochTestValue{ .releases = &frame_releases }, EpochTestValue.release);
    ring.advance(9);
    // Two rebuilds, then replacement build/import never succeeds. Both old
    // generations still release, with no generation chain or future carrier.
    for (0..2) |_| try ring.retain(std.testing.allocator, Generation{
        .frame_releases = &frame_releases,
        .generation_releases = &generation_releases,
    }, Generation.release);
    ring.advance(11);
    try std.testing.expectEqual(@as(usize, 1), frame_releases);
    try std.testing.expectEqual(@as(usize, 0), generation_releases);
    ring.advance(12);
    try std.testing.expectEqual(@as(usize, 2), generation_releases);
    try std.testing.expectEqual(@as(usize, 0), ring.liveCount());
}
