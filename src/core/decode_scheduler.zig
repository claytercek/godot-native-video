//! Bounded decode-worker pool shared by active streams.
//!
//! Workers fill each stream's FrameQueue ahead of presentation. Worker count
//! is independent of stream count. A per-stream busy claim serializes Backend
//! access and queue production, preserving SPSC ownership and backend decode
//! order (non-decreasing PTS during linear playback). Main-thread Backend
//! access uses the same claim. Workers never call Godot or RenderingDevice;
//! the main/render thread drains the queue and presents frames.
//!
//! The scheduler owns each DecodeStream from registration to unregister or
//! deinit. Unregister marks it dead, waits for its busy claim, removes queued
//! work, and frees it; the handle is then invalid. Claimants complete and
//! requeue under the same mutex before releasing busy, and never dereference
//! the handle once teardown can proceed.
//!
//! Decoder surfaces must cover queued frames, the frame being presented, and
//! frames retained for GPU latency. Each needs distinct backing storage until
//! release; requiredPoolDepth() computes the minimum.
//!
//! In debug builds, force_synchronous disables workers and runs decode inline
//! in pumpStream() to reproduce lifetime bugs without worker timing. Release
//! builds ignore it. requestSeek() invalidates old decode work without waiting
//! for it; workers apply the latest target before resuming decode-ahead.

const std = @import("std");
const builtin = @import("builtin");

const backend_mod = @import("backend.zig");
const frame_queue = @import("frame_queue.zig");
const sys_clock = @import("sys_clock.zig");

const log = std.log.scoped(.decode_scheduler);

pub const Backend = backend_mod.Backend;
pub const VideoFrame = backend_mod.VideoFrame;

// Debug gate. The force-synchronous-conversion mode is compiled in only for
// debug / test builds and forced false in release, so release binaries cannot
// accidentally run the synchronous path.
pub const force_sync_available: bool = switch (builtin.mode) {
    .debug, .safe => true,
    else => false,
};

// The per-stream decode-ahead ring capacity (usable slots). FrameQueue uses
// Capacity-1 usable slots, so the template Capacity is kDecodeAheadCapacity and
// the usable depth is kDecodeAheadCapacity - 1.
pub const kDecodeAheadCapacity: usize = 8;

// The default bound on worker threads. Kept small: decode is hardware-assisted
// and per-stream serial, so a handful of workers fairly services many streams.
pub const kDefaultWorkerCount: usize = 3;

// A stream's decode-ahead frame queue type. One producer (the owning worker),
// one consumer (the main thread). See FrameQueue's SPSC contract.
pub const DecodeAheadQueue = frame_queue.FrameQueue(VideoFrame, kDecodeAheadCapacity);

// -----------------------------------------------------------------------
// Minimum distinct decoder surfaces: `queue_usable_depth` queued frames,
// one frame being converted/presented, and `frame_latency` retired frames.
// Returns their sum so no surface is recycled while still in use.
pub fn requiredPoolDepth(queue_usable_depth: usize, frame_latency: usize) usize {
    return queue_usable_depth + 1 + frame_latency;
}

// -----------------------------------------------------------------------
// DecodeStream — per-stream decode state owned by the scheduler.
//
// Holds the Backend, the decode-ahead FrameQueue, and the scheduling flags that
// enforce per-stream serial decode. All mutable scheduling state is guarded by
// the scheduler's mutex; the FrameQueue itself is lock-free SPSC.
// -----------------------------------------------------------------------
pub const DecodeStream = struct {
    backend: ?Backend = null,
    queue: DecodeAheadQueue = .{},

    // Scheduling flags (guarded by DecodeScheduler.mu):
    //   queued — the stream sits in the ready work queue waiting for a worker.
    //   busy   — a worker currently owns this stream (its decode slice is in
    //            flight). At most one worker is ever busy on a given stream,
    //            which is what preserves the FrameQueue's single-producer
    //            contract.
    //   wants_more — the consumer popped a frame (or registration happened) so
    //            the stream should be (re)enqueued after the current slice.
    queued: bool = false,
    busy: bool = false,
    wants_more: bool = false,
    // Consumer-side seek flushes release frames outside mu without waiting for
    // busy. Teardown must also wait for these release hooks before dropping
    // the backend (some hooks carry backend-owned state).
    retire_claims: usize = 0,

    // A pending seek target requested via requestSeek(); applied by the owning
    // path before the next decode slice. Guarded by mu. Each request advances
    // the generation, invalidating an in-flight seek/frame/EOS. Publication and
    // requestSeek's consumer-side flush use the same mutex, so stale work can
    // never appear after that flush, even if decode was already in progress.
    seek_pending: bool = false,
    seek_target: f64 = 0.0,
    seek_generation: u64 = 0,
    // Remains true through Backend.seek() and the first new frame (or EOS),
    // not just until the worker takes the request. The controller holds its
    // clock/audio delivery during this asynchronous gap.
    seeking: bool = false,
    seek_failed: bool = false,

    // True once the Backend reports EOS. Cleared on seek. Guarded by mu.
    eos: bool = false,

    // Set when unregisterStream begins teardown so a worker that wakes up does
    // not start a new slice. Write-once (never cleared). Reads under mu use
    // monotonic ordering because the mutex already orders them.
    dead: std.atomic.Value(bool) = .init(false),

    // The selector requires non-decreasing PTS. Track the last enqueued PTS,
    // clearing it on seek/flush to allow backward seeks. Warn once per open
    // if the backend violates presentation order. Only the stream's serial
    // producer accesses these fields; no extra synchronization is needed.
    last_enqueued_pts: ?f64 = null,
    pts_regressed_warned: bool = false,
};

pub const StreamHandle = *DecodeStream;

pub const ExactSeekResult = enum {
    resolved,
    end_of_stream,
    backend_seek_failed,
    decode_budget_exhausted,
    stream_unavailable,
};

/// Asynchronous seek progress, read under one lock so a per-tick check cannot
/// straddle a state change.
pub const SeekState = struct {
    /// The seek has not delivered its first new frame (or EOS) yet.
    seeking: bool = false,
    /// The seek failed. Latched until the next seek so a stopped or paused
    /// controller can still observe it.
    failed: bool = false,
};

// -----------------------------------------------------------------------
// DecodeScheduler — the shared pool. One instance serves many streams; the
// caller owns its lifetime and injects it wherever decode is needed (the
// binding shares one process-wide pool across all playbacks).
// -----------------------------------------------------------------------
pub const DecodeScheduler = struct {
    allocator: std.mem.Allocator,

    workers: std.ArrayList(std.Thread) = .empty,

    // Work queue of streams that need decode-ahead. Guarded by mu; workers wait
    // on cv. A stream is in the queue at most once (enforced via its queued flag).
    mu: sys_clock.Mutex = .{},
    cv: sys_clock.Condition = .{},
    ready: std.ArrayList(StreamHandle) = .empty,
    ready_head: usize = 0,
    shutting_down: bool = false,

    // Keep handles for all registered streams so unregister can be ordered
    // against in-flight work and leftovers can be cleaned up at teardown.
    registered: std.ArrayList(StreamHandle) = .empty,

    synchronous: bool = false,

    // `worker_count` is clamped to >= 1. `force_synchronous` (debug builds only)
    // disables the worker threads entirely; decode then runs on the caller's
    // thread inside pumpStream(). In release builds force_synchronous is ignored
    // and always treated as false.
    //
    // Returns a heap-allocated scheduler (held by pointer): the worker threads
    // capture the scheduler pointer, so it must live at a stable address.
    pub fn init(
        allocator: std.mem.Allocator,
        worker_count: usize,
        force_synchronous: bool,
    ) !*DecodeScheduler {
        const self = try allocator.create(DecodeScheduler);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .synchronous = if (force_sync_available) force_synchronous else false,
        };

        if (self.synchronous) {
            // No worker threads in synchronous mode; pump runs on the caller's
            // thread.
            return self;
        }

        const n = @max(@as(usize, 1), worker_count);
        try self.workers.ensureTotalCapacityPrecise(allocator, n);
        errdefer {
            // Stop and join any workers already spawned before the failure.
            self.mu.lock();
            self.shutting_down = true;
            self.mu.unlock();
            self.cv.broadcast();
            for (self.workers.items) |t| t.join();
            self.workers.deinit(allocator);
        }
        for (0..n) |_| {
            const t = try std.Thread.spawn(.{}, workerMain, .{self});
            self.workers.appendAssumeCapacity(t);
        }
        return self;
    }

    pub fn deinit(self: *DecodeScheduler) void {
        {
            self.mu.lock();
            self.shutting_down = true;
            self.mu.unlock();
        }
        self.cv.broadcast();
        for (self.workers.items) |t| t.join();
        self.workers.deinit(self.allocator);

        // Release any frames still buffered in streams that outlived their
        // binding (defensive — well-behaved callers unregister first).
        var leftover: std.ArrayList(StreamHandle) = .empty;
        {
            self.mu.lock();
            leftover = self.registered;
            self.registered = .empty;
            self.mu.unlock();
        }
        for (leftover.items) |s| {
            self.releaseStreamResources(s);
            self.allocator.destroy(s);
        }
        leftover.deinit(self.allocator);
        self.ready.deinit(self.allocator);

        const allocator = self.allocator;
        allocator.destroy(self);
    }

    // Register a stream. The scheduler takes ownership of the Backend and decodes
    // ahead into the returned stream's queue. Auto-notified on registration to
    // start decode-ahead.
    pub fn registerStream(self: *DecodeScheduler, backend: Backend) !StreamHandle {
        errdefer {
            backend.close();
            backend.deinit();
        }
        const stream = try self.allocator.create(DecodeStream);
        stream.* = .{ .backend = backend };
        {
            self.mu.lock();
            self.registered.append(self.allocator, stream) catch |e| {
                self.mu.unlock();
                self.allocator.destroy(stream);
                return e;
            };
            stream.wants_more = true;
            self.mu.unlock();
        }
        // Kick off decode-ahead immediately so the queue starts filling.
        self.notify(stream);
        return stream;
    }

    // Unregister a stream. Blocks until any in-flight decode slice for this
    // stream completes, then releases every frame still buffered (running each
    // frame's release closure), drops the Backend, and frees the stream. After
    // return the handle is invalid — no worker will touch it again.
    pub fn unregisterStream(self: *DecodeScheduler, stream: StreamHandle) void {
        {
            self.mu.lock();
            // Mark dead so no worker starts a new slice, and wait until any
            // in-flight slice and seek-flush release hooks for THIS stream.
            // No worker or release hook may touch backend state after teardown.
            stream.dead.store(true, .release);
            stream.wants_more = false;
            // In synchronous mode there are no workers, so busy can never be set
            // by anyone but the calling thread; the wait below returns
            // immediately.
            while (stream.busy or stream.retire_claims != 0) self.cv.wait(&self.mu);

            // Drop it from the registry and the ready queue.
            removeHandle(&self.registered, stream);
            self.removeReadyLocked(stream);
            stream.queued = false;
            self.mu.unlock();
        }

        // Safe to touch the Backend/queue now: dead is set and busy is clear, so
        // no worker will ever pump this stream again. Release everything
        // buffered, then free the stream.
        self.releaseStreamResources(stream);
        self.allocator.destroy(stream);
    }

    // Pop the next decoded frame for the consumer (main thread). Returns null
    // when the decode-ahead queue is momentarily empty. The caller owns the
    // returned frame and must eventually run its release(). After popping, the
    // stream is re-notified so a worker tops the queue back up.
    pub fn nextFrame(self: *DecodeScheduler, stream: StreamHandle) ?VideoFrame {
        const f = stream.queue.pop();
        if (f != null) {
            // Popping freed a slot; ask the pool to top the queue back up.
            {
                self.mu.lock();
                if (!stream.dead.load(.monotonic)) stream.wants_more = true;
                self.mu.unlock();
            }
            self.notify(stream);
        }
        return f;
    }

    // Run `func(ctx, backend)` under the stream's busy claim, excluding workers.
    // Used for explicit serialized backend operations (e.g. track selection).
    // `func` must not call back into this stream. No-op if the stream is dead.
    pub fn withBackend(
        self: *DecodeScheduler,
        stream: StreamHandle,
        ctx: anytype,
        comptime func: fn (@TypeOf(ctx), *Backend) void,
    ) void {
        {
            self.mu.lock();
            // Claim the per-stream guard so no worker pumps this Backend while we
            // use it. Wait out any in-flight slice first.
            while (stream.busy) self.cv.wait(&self.mu);
            if (stream.dead.load(.monotonic) or stream.backend == null) {
                self.mu.unlock();
                return;
            }
            self.claimLocked(stream);
            self.mu.unlock();
        }
        // We exclusively own the Backend here (busy held, no worker can claim it).
        func(ctx, &stream.backend.?);
        self.finishClaim(stream);
    }

    // Nonblocking counterpart for per-tick audio delivery. A busy video decoder
    // must not turn the first update after an async rewind into a blocking wait.
    // False means no callback ran; buffered audio can still be delivered.
    pub fn tryWithBackend(
        self: *DecodeScheduler,
        stream: StreamHandle,
        ctx: anytype,
        comptime func: fn (@TypeOf(ctx), *Backend) void,
    ) bool {
        self.mu.lock();
        if (stream.busy or stream.seeking or stream.seek_failed or stream.dead.load(.monotonic) or stream.backend == null) {
            self.mu.unlock();
            return false;
        }
        self.claimLocked(stream);
        self.mu.unlock();
        func(ctx, &stream.backend.?);
        self.finishClaim(stream);
        return true;
    }

    // Peek the PTS of the head / second decode-ahead frame WITHOUT removing it
    // (consumer/main-thread only). Returns null when fewer than one / two frames
    // are buffered.
    pub fn peekHeadPts(self: *DecodeScheduler, stream: StreamHandle) ?f64 {
        _ = self;
        // peek() is consumer-thread-only and does not touch producer state,
        // matching the FrameQueue SPSC contract; no scheduler lock needed.
        if (stream.queue.peek()) |head| return head.pts_seconds;
        return null;
    }

    pub fn peekNextPts(self: *DecodeScheduler, stream: StreamHandle) ?f64 {
        _ = self;
        if (stream.queue.peekNext()) |next| return next.pts_seconds;
        return null;
    }

    // Consumer-thread-only: invalidate old frames and queue the latest seek.
    // Never wait for Backend.seek()/decode or a busy claim. The active worker
    // discards any superseded result and yields to the new request. Only the
    // consumer pops; workers serialize publication against this bounded flush.
    // Debug force-synchronous mode deliberately still decodes inline.
    pub fn requestSeek(self: *DecodeScheduler, stream: StreamHandle, pts_seconds: f64) void {
        var retired: [DecodeAheadQueue.usable_capacity]VideoFrame = undefined;
        var retired_count: usize = 0;
        self.mu.lock();
        if (stream.dead.load(.monotonic)) {
            self.mu.unlock();
            return;
        }
        stream.seek_generation +%= 1;
        stream.seek_pending = true;
        stream.seek_target = @max(pts_seconds, 0.0);
        stream.seeking = true;
        stream.seek_failed = false;
        stream.eos = false;
        stream.wants_more = true;
        while (stream.queue.pop()) |f| {
            // Bounded by the ring's usable depth; never let a full queue
            // overrun the drain buffer.
            std.debug.assert(retired_count < retired.len);
            retired[retired_count] = f;
            retired_count += 1;
        }
        if (retired_count != 0) stream.retire_claims += 1;
        const wake = if (self.synchronous) false else self.enqueueLocked(stream);
        self.mu.unlock();
        if (wake) self.cv.signal();

        // Release hooks may touch platform resources; never run them with the
        // pool mutex held. A retire claim keeps their backend state alive.
        for (retired[0..retired_count]) |f| f.release();
        if (retired_count != 0) {
            self.mu.lock();
            stream.retire_claims -= 1;
            self.mu.unlock();
            self.cv.broadcast();
        }
        if (self.synchronous) self.notify(stream);
    }

    /// One lock for both seek flags, so the per-tick gate cannot read `seeking`
    /// from one generation and `failed` from the next.
    pub fn seekState(self: *DecodeScheduler, stream: StreamHandle) SeekState {
        self.mu.lock();
        defer self.mu.unlock();
        return .{ .seeking = stream.seeking, .failed = stream.seek_failed };
    }

    // Resolve a seek synchronously under the stream's busy claim. Flush the
    // queue, seek to the keyframe at/before `target_seconds`, and decode forward,
    // releasing frames before target - eps_seconds. Queue the first survivor,
    // or stop at EOS. Used for scrub settle/resume, outside the per-frame path.
    // The outcome tells callers whether it is safe to re-anchor playback.
    pub fn seekExact(self: *DecodeScheduler, stream: StreamHandle, target_seconds: f64, eps_seconds: f64) ExactSeekResult {
        const target = @max(target_seconds, 0.0);
        {
            self.mu.lock();
            while (stream.busy) self.cv.wait(&self.mu);
            if (stream.dead.load(.monotonic) or stream.backend == null) {
                self.mu.unlock();
                return .stream_unavailable;
            }
            // We seek right here, so any older pending seek is superseded.
            stream.seek_generation +%= 1;
            stream.seek_pending = false;
            stream.seeking = false;
            stream.seek_failed = false;
            stream.eos = false;
            self.claimLocked(stream); // exclude workers while we own the stream
            stream.wants_more = true;
            self.mu.unlock();
        }
        // Busy held: we are the sole producer for the queue and the sole
        // toucher of the Backend until we drop it.
        while (stream.queue.pop()) |f| f.release();
        const backend_ptr = &stream.backend.?;
        if (!backend_ptr.seek(target)) {
            self.mu.lock();
            stream.wants_more = false;
            self.mu.unlock();
            self.finishClaim(stream);
            return .backend_seek_failed;
        }
        // PTS jumps across the seek — reset the monotonicity baseline so the
        // surviving frame re-establishes it (rather than tripping the guard).
        stream.last_enqueued_pts = null;
        // Safety valve: bound the synchronous decode-forward loop so a
        // misbehaving backend whose PTS never advances past `target` and never
        // signals EOS cannot spin the calling (main) thread forever. Large
        // enough that real GOP-bounded scrub-settle never trips it.
        const max_scrub_decode_frames = 4096;
        var scrub_decoded: usize = 0;
        var result: ExactSeekResult = .decode_budget_exhausted;
        while (backend_ptr.nextVideoFrame()) |f| {
            if (f.pts_seconds + eps_seconds >= target) {
                // The frame at/just before the target: keep it for present. It
                // re-establishes the monotonicity baseline for the decode-ahead
                // slices that follow.
                checkEnqueueMonotonic(stream, f.pts_seconds);
                const pushed = stream.queue.push(f);
                std.debug.assert(pushed); // queue was flushed above
                result = .resolved;
                break;
            }
            f.release();
            scrub_decoded += 1;
            if (scrub_decoded >= max_scrub_decode_frames) break; // non-advancing backend; bail without eos
        } else {
            self.mu.lock();
            stream.eos = true; // clip ended before the target — clamp.
            self.mu.unlock();
            result = .end_of_stream;
        }
        if (result != .resolved) {
            self.mu.lock();
            stream.wants_more = false;
            self.mu.unlock();
        }
        self.finishClaim(stream);
        return result;
    }

    // True end-of-stream: the Backend reported EOS and the queue is drained.
    pub fn atEnd(self: *DecodeScheduler, stream: StreamHandle) bool {
        self.mu.lock();
        defer self.mu.unlock();
        return stream.eos and stream.queue.empty();
    }

    // --- Introspection (tests / instrumentation) ---
    pub fn workerCount(self: *const DecodeScheduler) usize {
        return self.workers.items.len;
    }
    pub fn isSynchronous(self: *const DecodeScheduler) bool {
        return self.synchronous;
    }

    // ------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------

    fn releaseStreamResources(self: *DecodeScheduler, stream: StreamHandle) void {
        _ = self;
        while (stream.queue.pop()) |f| f.release();
        if (stream.backend) |b| {
            b.close();
            b.deinit();
            stream.backend = null;
        }
    }

    // Claim the per-stream busy guard from a NON-worker thread (seekExact /
    // withBackend). Requires mu held and busy == false. Also dequeues the stream
    // from ready so no worker can claim it concurrently; a queued work demand is
    // folded back into wants_more.
    fn claimLocked(self: *DecodeScheduler, stream: StreamHandle) void {
        if (stream.queued) {
            self.removeReadyLocked(stream);
            stream.queued = false;
            stream.wants_more = true;
        }
        stream.busy = true;
    }

    // End an exclusive lease atomically with any requeue. Once busy becomes
    // false an unregister waiter may destroy the stream, so this function is
    // deliberately the claimant's final stream access.
    fn finishClaim(self: *DecodeScheduler, stream: StreamHandle) void {
        if (self.synchronous) {
            // Satisfy pending work while the same lease is still held. This
            // avoids recursively notifying after releasing it.
            self.mu.lock();
            const pump_more = !stream.dead.load(.monotonic) and stream.wants_more;
            stream.wants_more = false;
            self.mu.unlock();
            if (pump_more) self.pumpStream(stream);
        }

        self.mu.lock();
        stream.busy = false;
        const wake = if (self.synchronous) false else self.enqueueLocked(stream);
        self.mu.unlock();
        self.cv.broadcast();
        if (wake) self.cv.signal();
    }

    // Mark a stream as needing decode-ahead and wake a worker (async mode) or
    // pump it inline (sync mode). Idempotent: a stream already queued or busy is
    // not enqueued twice — this is what guarantees per-stream serial decode.
    fn notify(self: *DecodeScheduler, stream: StreamHandle) void {
        if (self.synchronous) {
            // Synchronous mode: pump inline on the caller's thread. Claim busy so
            // the contract (single producer per stream) is honoured even though
            // there is no worker. Exclusive leases/teardown still honor busy.
            {
                self.mu.lock();
                if (stream.dead.load(.monotonic) or stream.busy or !stream.wants_more) {
                    self.mu.unlock();
                    return;
                }
                stream.busy = true;
                stream.wants_more = false;
                self.mu.unlock();
            }
            self.pumpStream(stream);
            {
                self.mu.lock();
                stream.busy = false;
                self.mu.unlock();
            }
            self.cv.broadcast();
            return;
        }

        var wake = false;
        {
            self.mu.lock();
            wake = self.enqueueLocked(stream);
            self.mu.unlock();
        }
        if (wake) self.cv.signal();
    }

    // Enqueue `stream` for a decode slice if it is eligible: alive, wanting
    // more work, and neither already queued nor claimed. The single
    // queued/busy guard is what guarantees a stream is never handed to two
    // workers at once -> per-stream serial decode. Consumes the wants_more
    // demand when it enqueues. Returns true if the stream was enqueued (the
    // caller wakes a worker outside the lock). Requires mu held.
    fn enqueueLocked(self: *DecodeScheduler, stream: StreamHandle) bool {
        if (stream.dead.load(.monotonic) or stream.queued or stream.busy or !stream.wants_more) return false;
        stream.wants_more = false;
        stream.queued = true;
        self.ready.append(self.allocator, stream) catch @panic("DecodeScheduler OOM");
        return true;
    }

    // Pull the next ready stream off the work queue, marking it busy. Dead
    // streams (torn down between enqueue and now) are skipped internally, so
    // null means exactly one thing: the pool is shutting down and the queue
    // is empty.
    fn takeReadyStream(self: *DecodeScheduler) ?StreamHandle {
        self.mu.lock();
        defer self.mu.unlock();
        while (true) {
            while (!self.shutting_down and self.ready.items.len == 0) self.cv.wait(&self.mu);
            if (self.shutting_down and self.ready.items.len == 0) return null;
            const stream = self.ready.items[self.ready_head];
            self.ready_head += 1;
            if (self.ready_head == self.ready.items.len) {
                self.ready.clearRetainingCapacity();
                self.ready_head = 0;
            }
            stream.queued = false;
            if (stream.dead.load(.monotonic)) continue;
            stream.busy = true;
            return stream;
        }
    }

    // Claim/teardown removal is cold. The worker's hot FIFO dequeue advances a
    // cursor, making it amortized O(1) instead of shifting every ready stream.
    fn removeReadyLocked(self: *DecodeScheduler, stream: StreamHandle) void {
        var idx = self.ready_head;
        while (idx < self.ready.items.len) : (idx += 1) {
            if (self.ready.items[idx] == stream) {
                _ = self.ready.orderedRemove(idx);
                if (self.ready_head == self.ready.items.len) {
                    self.ready.clearRetainingCapacity();
                    self.ready_head = 0;
                }
                return;
            }
        }
    }

    fn workerMain(self: *DecodeScheduler) void {
        while (true) {
            const stream = self.takeReadyStream() orelse return;

            self.pumpStream(stream);

            {
                self.mu.lock();
                stream.busy = false;
                // If the consumer asked for more while we were decoding,
                // re-enqueue for another slice so streams are fairly serviced
                // round-robin without one starving others.
                _ = self.enqueueLocked(stream);
                self.mu.unlock();
            }
            // Wake exclusive-lease/teardown waiters (busy just dropped) and,
            // if we requeued, a worker to pick the stream up.
            self.cv.broadcast();
        }
    }

    // Decode one slice for `stream`: pull frames from its Backend into its queue
    // until the queue is full or EOS. The caller must hold the stream's "busy"
    // claim, so we are the sole producer for its FrameQueue and the sole toucher
    // of its Backend.
    fn pumpStream(self: *DecodeScheduler, stream: StreamHandle) void {
        const backend_ptr = if (stream.backend) |*b| b else return;

        // Snapshot the request under mu, but never hold mu over backend work.
        // A newer request may arrive during either seek or decode.
        self.mu.lock();
        const generation = stream.seek_generation;
        const do_seek = stream.seek_pending;
        const seek_target = stream.seek_target;
        stream.seek_pending = false;
        self.mu.unlock();
        if (do_seek) {
            const ok = backend_ptr.seek(seek_target);
            self.mu.lock();
            if (stream.dead.load(.monotonic) or generation != stream.seek_generation) {
                self.mu.unlock();
                return;
            }
            stream.last_enqueued_pts = null;
            if (!ok) {
                // Do not publish frames from the old backend position on a
                // failed async seek. Exact nonzero seeks report richer outcomes
                // through seekExact(); this path terminates delivery instead.
                stream.seeking = false;
                stream.seek_failed = true;
                stream.eos = true;
                stream.wants_more = false;
                self.mu.unlock();
                log.warn("async seek to {d:.3}s failed", .{seek_target});
                return;
            }
            self.mu.unlock();
        }

        if (do_seek) {
            // requestSeek's flush runs under this same mutex, so a requested seek
            // always starts from an empty queue. A full queue here would skip the
            // loop below and leave `seeking` latched forever -- a permanent
            // freeze, not a hitch. A full queue on a plain refill slice is fine
            // (the loop just does nothing), so only the seek case is checked.
            std.debug.assert(!stream.queue.full());
        }

        // A short publication lock orders each result against requestSeek's
        // generation change + flush. Decoding and release hooks stay outside
        // the mutex; an obsolete slice stops after at most its in-flight call.
        while (!stream.queue.full()) {
            self.mu.lock();
            const obsolete = stream.dead.load(.monotonic) or generation != stream.seek_generation;
            self.mu.unlock();
            if (obsolete) return;
            const f = backend_ptr.nextVideoFrame();
            self.mu.lock();
            if (stream.dead.load(.monotonic) or generation != stream.seek_generation) {
                self.mu.unlock();
                if (f) |frame| frame.release();
                return;
            }
            if (f == null) {
                stream.eos = true;
                stream.seeking = false;
                self.mu.unlock();
                return;
            }
            checkEnqueueMonotonic(stream, f.?.pts_seconds);
            const pushed = stream.queue.push(f.?);
            stream.seeking = false;
            self.mu.unlock();
            if (!pushed) {
                f.?.release();
                return;
            }
        }
    }
};

// Warn once when enqueued PTS regresses outside a seek, then update the baseline.
// The selector requires presentation order; decode-order B-frames could make
// the picture step backward. This diagnostic neither reorders nor drops frames.
// Requires the stream's sole-producer busy claim. Public for contract tests.
pub fn checkEnqueueMonotonic(stream: StreamHandle, pts: f64) void {
    if (stream.last_enqueued_pts) |prev| {
        if (pts < prev and !stream.pts_regressed_warned) {
            stream.pts_regressed_warned = true;
            log.warn(
                "video PTS regressed at the decode-queue boundary: {d:.4}s after {d:.4}s with no seek -- frames are not in presentation order; playback will stutter",
                .{ pts, prev },
            );
        }
    }
    stream.last_enqueued_pts = pts;
}

fn removeHandle(list: *std.ArrayList(StreamHandle), stream: StreamHandle) void {
    for (list.items, 0..) |s, idx| {
        if (s == stream) {
            _ = list.orderedRemove(idx);
            return;
        }
    }
}

test {
    _ = @import("decode_scheduler_test.zig");
}
