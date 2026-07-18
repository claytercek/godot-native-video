//! retire_ring.zig — port of src/core/retire_ring.h.
//!
//! RetireRing(N) — bounded surface-lifetime guard (the memory-safety core).
//!
//! Problem: when we import a decoder surface (CVPixelBuffer / IOSurface) into
//! the GPU and run a present pass that samples it, the GPU may still be
//! reading that surface for some number of frames after we issued the work.
//! If the Backend recycles the surface immediately, the GPU reads freed
//! memory — a use-after-free that corrupts the frame or crashes.
//!
//! We deliberately do NOT use per-platform GPU fences. Instead we hold each
//! source surface's release closure for exactly N *rendered* frames: a
//! bounded ring keyed on Godot's frame latency. After a surface has survived
//! N calls to advance(), the GPU is guaranteed to be done with it and we run
//! its release closure exactly once.
//!
//! Design rules:
//!  - Pure logic. No Godot, RenderingDevice, Metal, or CoreVideo types. The
//!    retained payload is an opaque ctx+fn release closure (std::function<void()>
//!    equivalent), so this component is fully unit-testable headlessly.
//!  - Holds a surface for EXACTLY N frames and releases it EXACTLY once.
//!  - Fixed capacity N slots: a surface parked this frame is released on the
//!    N-th advance() that follows (when the ring head cycles back to its
//!    slot), so there is no heap allocation on the present path.
//!
//! Usage (once per rendered frame, on the render thread):
//!   ring.advance();              // ages everything; releases the oldest slot
//!   ring.retain(frame.release);  // park this frame's surface for N frames
//!
//! Non-copyable: it owns release closures whose duplication would release a
//! surface twice. Callers should hold this by pointer.

const std = @import("std");

/// C++ std::function<void()> release closure → ctx + fn pointer. An empty
/// value (func == null) is the "no closure" state (C++'s nullptr
/// std::function), accepted and ignored by retain().
pub const ReleaseFn = struct {
    ctx: ?*anyopaque = null,
    func: ?*const fn (?*anyopaque) void = null,

    pub fn call(self: ReleaseFn) void {
        if (self.func) |f| f(self.ctx);
    }
};

pub fn RetireRing(comptime N: usize) type {
    comptime {
        if (N < 1) @compileError("Retire latency must be at least 1 frame");
    }

    return struct {
        const Self = @This();
        // N slots: parking one surface per advance() keeps the ring full,
        // and the slot reused N advances later is exactly the surface that
        // has now survived its N frames of GPU latency.
        const capacity: usize = N;

        slots: [capacity]ReleaseFn = [_]ReleaseFn{.{}} ** capacity,
        head: usize = 0,

        pub fn init() Self {
            return .{};
        }

        pub fn deinit(self: *Self) void {
            self.drain();
        }

        /// Park a surface's release closure for N frames. Call once per
        /// presented frame, AFTER advance(). An empty ReleaseFn{} is accepted
        /// and ignored (e.g. a CPU/test frame with no native surface to
        /// retire).
        pub fn retain(self: *Self, release: ReleaseFn) void {
            // The current write slot is `head`. advance() has already aged
            // out whatever previously occupied it, so it is guaranteed empty
            // here.
            self.slots[self.head] = release;
        }

        /// Age the ring by one rendered frame. The slot that has now survived
        /// N frames (the one we are about to reuse for this frame's
        /// retain()) is released exactly once. Call once per rendered frame,
        /// BEFORE retain().
        pub fn advance(self: *Self) void {
            self.head = (self.head + 1) % capacity;
            // `head` now points at the slot filled N frames ago. Release it
            // before it is overwritten so the surface is freed exactly once
            // and only after the GPU has had N frames to finish reading it.
            self.releaseSlot(self.head);
        }

        /// Release every still-parked surface immediately (teardown / stop),
        /// in FIFO (oldest-first) order so drain preserves the same release
        /// ordering as steady-state aging. After this the ring holds
        /// nothing. Idempotent.
        pub fn drain(self: *Self) void {
            // The oldest surface sits in the slot advance() would next reuse,
            // i.e. (head + 1). Walk forward from there so we release oldest
            // -> newest.
            var k: usize = 0;
            while (k < capacity) : (k += 1) {
                const i = (self.head + 1 + k) % capacity;
                self.releaseSlot(i);
            }
        }

        /// Number of surfaces currently parked (for tests / instrumentation).
        pub fn liveCount(self: *const Self) usize {
            var n: usize = 0;
            for (self.slots) |slot| {
                if (slot.func != null) n += 1;
            }
            return n;
        }

        pub fn latencyFrames() usize {
            return N;
        }

        fn releaseSlot(self: *Self, i: usize) void {
            const slot = self.slots[i];
            if (slot.func != null) {
                self.slots[i] = .{}; // clear before invoking so re-entrancy is safe
                slot.call();
            }
        }
    };
}

test "a surface is held for exactly N frames then released once" {
    const N = 3;
    var ring = RetireRing(N).init();

    var releases: i32 = 0;
    const Ctx = struct {
        fn bump(p: ?*anyopaque) void {
            const r: *i32 = @ptrCast(@alignCast(p.?));
            r.* += 1;
        }
    };

    // Frame 0: park a surface.
    ring.advance();
    ring.retain(.{ .ctx = &releases, .func = Ctx.bump });
    try std.testing.expectEqual(@as(usize, 1), ring.liveCount());

    // It must survive the next N-1 advances...
    var f: usize = 1;
    while (f < N) : (f += 1) {
        ring.advance();
        ring.retain(.{}); // no new surface this frame
        try std.testing.expectEqual(@as(i32, 0), releases); // still alive
    }

    // ...and be released on the N-th advance after it was parked.
    ring.advance();
    try std.testing.expectEqual(@as(i32, 1), releases);
    try std.testing.expectEqual(@as(usize, 0), ring.liveCount());

    // And never released again.
    var i: i32 = 0;
    while (i < 10) : (i += 1) {
        ring.advance();
        ring.retain(.{});
    }
    try std.testing.expectEqual(@as(i32, 1), releases);
}

test "each frame's surface is released exactly once, in order" {
    const N = 2;
    var ring = RetireRing(N).init();

    var released_order = std.ArrayList(i32).empty;
    defer released_order.deinit(std.testing.allocator);

    const Ctx = struct {
        list: *std.ArrayList(i32),
        value: i32,

        fn release(p: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(p.?));
            self.list.append(std.testing.allocator, self.value) catch unreachable;
        }
    };

    // Park a distinct surface every frame for many frames.
    const kFrames = 20;
    var ctxs: [kFrames]Ctx = undefined;
    var i: i32 = 0;
    while (i < kFrames) : (i += 1) {
        ctxs[@intCast(i)] = .{ .list = &released_order, .value = i };
        ring.advance();
        ring.retain(.{ .ctx = &ctxs[@intCast(i)], .func = Ctx.release });
    }

    // Drain the tail so every parked surface gets released.
    ring.drain();

    // Every surface released exactly once...
    try std.testing.expectEqual(@as(usize, kFrames), released_order.items.len);
    // ...and in FIFO order.
    i = 0;
    while (i < kFrames) : (i += 1) {
        try std.testing.expectEqual(i, released_order.items[@intCast(i)]);
    }
}

test "drain releases all parked surfaces and is idempotent" {
    var ring = RetireRing(4).init();
    var releases: i32 = 0;

    const Ctx = struct {
        fn bump(p: ?*anyopaque) void {
            const r: *i32 = @ptrCast(@alignCast(p.?));
            r.* += 1;
        }
    };

    var i: i32 = 0;
    while (i < 3) : (i += 1) {
        ring.advance();
        ring.retain(.{ .ctx = &releases, .func = Ctx.bump });
    }
    try std.testing.expectEqual(@as(i32, 0), releases);

    ring.drain();
    try std.testing.expectEqual(@as(i32, 3), releases);

    // Second drain must not double-release.
    ring.drain();
    try std.testing.expectEqual(@as(i32, 3), releases);
}

test "destructor releases outstanding surfaces (no leak)" {
    // C++ captures a shared_ptr in the closure and checks its refcount drops
    // when the ring is destroyed. Zig has no shared_ptr; we pin the same
    // externally-observable behaviour instead: deinit() (the C++ destructor
    // equivalent) invokes the still-parked closure exactly once, so any
    // resource it owns is released without the ring holding on to it.
    var released = false;
    const Ctx = struct {
        fn markReleased(p: ?*anyopaque) void {
            const flag: *bool = @ptrCast(@alignCast(p.?));
            flag.* = true;
        }
    };
    {
        var ring = RetireRing(3).init();
        ring.advance();
        ring.retain(.{ .ctx = &released, .func = Ctx.markReleased });
        try std.testing.expect(!released);
        ring.deinit();
    }
    try std.testing.expect(released);
}

test "latency_frames reports the configured N" {
    try std.testing.expectEqual(@as(usize, 1), RetireRing(1).latencyFrames());
    try std.testing.expectEqual(@as(usize, 5), RetireRing(5).latencyFrames());
}
