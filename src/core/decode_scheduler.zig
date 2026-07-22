//! The bounded shared decode-worker pool (Engine Core).
//!
//! PROBLEM: a scene may hold many VideoStreamPlayers. Spawning one decode
//! thread per video does not scale. Conversely, decoding inline on the
//! main/render thread blocks presentation. The DecodeScheduler is a single
//! bounded pool of worker threads, SHARED across all active streams, that
//! pulls frames from each stream's Backend and fills that stream's FrameQueue
//! ahead of the present step.
//!
//! THREADING CONTRACT (the load-bearing invariant of this slice):
//!   * The pool has a fixed, bounded number of worker threads — NOT one per
//!     stream. Worker count is independent of stream count.
//!   * Each registered stream is decoded SERIALLY: at most ONE worker touches a
//!     given stream's Backend/FrameQueue at any instant. This is enforced by a
//!     per-stream "busy" flag — a stream is only ever handed to one worker, and
//!     is not re-enqueued for decode until that worker finishes its slice. So:
//!       - The FrameQueue's SPSC contract holds: exactly one producer (whichever
//!         worker currently owns the stream) and one consumer (the main thread
//!         calling drain/present). Producers never overlap in time.
//!       - Per-stream frame ORDER is deterministic — frames enter the queue in
//!         backend-decode order, which is monotonic PTS for linear playback.
//!   * The Backend is touched ONLY by the worker that currently owns the stream.
//!     register()/unregister()/the main thread never call into the Backend
//!     concurrently with a worker (unregister blocks until the in-flight slice,
//!     if any, completes — no use-after-free when a stream is destroyed
//!     mid-decode).
//!   * Workers touch NO Godot / RenderingDevice APIs. The present + GPU pass
//!     stays on the main/render thread, which drains the FrameQueue.
//!
//! SURFACE LIFETIME (acceptance criterion): the decode pool must be sized
//! `pool_depth + frame_latency` so that every surface that can be in flight
//! simultaneously — queued for present, being converted/presented, and still
//! held by the RetireRing for `frame_latency` rendered frames — has a distinct
//! backing surface and is never recycled while still in use. See
//! requiredPoolDepth().
//!
//! FORCE-SYNC DEBUG MODE (acceptance criterion): when force_synchronous is set
//! (debug builds only — gated OFF in release) the scheduler runs NO worker
//! threads. Decode happens synchronously on the calling (main) thread inside
//! pumpStream(), so a decode->convert->present lifetime bug reproduces
//! deterministically with no worker handoff and no deferred timing.
//!
//! SCRUB SEAM: requestSeek() lets the binding ask a stream to flush + reseek
//! before resuming decode-ahead; a scrubbing slice uses it to request a
//! keyframe-only decode without changing the threading model.
//!
//! OWNERSHIP NOTE: `StreamHandle = *DecodeStream`, with the DecodeStream
//! owned solely by the scheduler: register allocates it, unregister (and the
//! scheduler's deinit for leftovers) frees it. No reference counting is
//! needed because unregister orders itself against every worker before it
//! returns — the stream is marked dead, any in-flight busy claim is waited
//! out, and it is removed from the ready list — so the handle is simply
//! invalid after unregister, which is exactly how every caller uses it.

const std = @import("std");
const builtin = @import("builtin");

const backend_mod = @import("backend.zig");
const frame_queue = @import("frame_queue.zig");
const sys_clock = @import("sys_clock.zig");

pub const Backend = backend_mod.Backend;
pub const VideoFrame = backend_mod.VideoFrame;

// Debug gate. The force-synchronous-conversion mode is compiled in only for
// debug / test builds and forced false in release, so release binaries cannot
// accidentally run the synchronous path.
pub const force_sync_available: bool = switch (builtin.mode) {
    .Debug, .ReleaseSafe => true,
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
// requiredPoolDepth — surface-lifetime sizing helper.
//
// The decoder must own enough distinct surfaces that every surface which can be
// alive at once has its own backing store. At any instant a stream may hold:
//   * up to `queue_usable_depth` decoded frames waiting in the FrameQueue,
//   * 1 frame popped and being converted/presented this tick,
//   * up to `frame_latency` frames parked in the RetireRing from prior ticks.
// Sizing the decode pool to their sum guarantees the Backend never recycles a
// surface that is still queued, in-flight, or retained. Returns that sum.
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

    // A pending seek target requested via requestSeek(); applied by the owning
    // path before the next decode slice. Guarded by mu.
    seek_pending: bool = false,
    seek_target: f64 = 0.0,

    // True once the Backend reports EOS. Cleared on seek. Guarded by mu.
    eos: bool = false,

    // Set when unregisterStream begins teardown so a worker that wakes up does
    // not start a new slice. Write-once (never cleared), so it is an atomic
    // flag rather than a mu-guarded field: the hot decode-ahead loop reads it
    // lock-free (acquire) instead of taking mu per frame. The teardown store is
    // release; the mutex already orders every other (mu-held) read, so those
    // use monotonic loads.
    dead: std.atomic.Value(bool) = .init(false),
};

pub const StreamHandle = *DecodeStream;

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
            // in-flight slice for THIS stream finishes (busy drops) — guarantees
            // no worker is touching the Backend/queue when we tear it down.
            stream.dead.store(true, .release);
            stream.wants_more = false;
            // In synchronous mode there are no workers, so busy can never be set
            // by anyone but the calling thread; the wait below returns
            // immediately.
            while (stream.busy) self.cv.wait(&self.mu);

            // Drop it from the registry and the ready queue.
            removeHandle(&self.registered, stream);
            removeHandle(&self.ready, stream);
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

    // Run `func(ctx, backend)` with exclusive access to the stream's Backend,
    // serialized against the worker pool (claims the same per-stream "busy"
    // guard a decode slice uses, so no worker touches the Backend concurrently).
    // The binding uses this to pump AUDIO from the main thread without violating
    // the single-toucher contract. `func` must not call back into the scheduler
    // for this same stream. No-op if the stream is dead.
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
        {
            self.mu.lock();
            stream.busy = false;
            self.mu.unlock();
        }
        self.cv.broadcast(); // release waiters and let a worker resume decode-ahead
        self.notify(stream);
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

    // Ask the scheduler to flush the stream's queue and reseek the Backend to
    // `pts_seconds` before resuming decode-ahead. Blocks until any in-flight
    // slice completes so the reseek does not race a worker. (The scrub seam.)
    pub fn requestSeek(self: *DecodeScheduler, stream: StreamHandle, pts_seconds: f64) void {
        {
            self.mu.lock();
            // Wait out any in-flight slice, then CLAIM the per-stream guard
            // ourselves so no worker can start producing into the queue while we
            // flush it. Without this claim a stream already sitting in ready
            // (busy == false) could be picked up by a worker the instant we drop
            // the lock; that worker would seek + push new frames concurrently
            // with the flush below, corrupting the queue.
            while (stream.busy) self.cv.wait(&self.mu);
            stream.seek_pending = true;
            stream.seek_target = @max(pts_seconds, 0.0);
            stream.eos = false;
            if (stream.dead.load(.monotonic)) {
                self.mu.unlock();
                return; // torn down concurrently; nothing to flush/resume.
            }
            self.claimLocked(stream); // exclude workers for the duration of the flush
            stream.wants_more = true;
            self.mu.unlock();
        }
        // Flush queued frames on the consumer side (single-consumer: the caller).
        // We hold busy, so no worker is producing concurrently.
        while (stream.queue.pop()) |f| f.release();
        {
            self.mu.lock();
            stream.busy = false;
            self.mu.unlock();
        }
        self.cv.broadcast(); // release any unregister/withBackend waiters
        self.notify(stream);
    }

    // Resolve a seek to the exact target synchronously on the calling thread.
    // Claims the same per-stream "busy" guard a decode slice uses, then, as
    // the sole owner of the Backend and queue: flushes buffered frames, seeks
    // the Backend to (the keyframe at/before) `target_seconds`, and decodes
    // forward releasing every frame whose PTS is more than `eps_seconds`
    // before the target. The first surviving frame is pushed into the queue,
    // so afterwards the queue head is at/after target - eps. Stops at EOS
    // when the clip ends before the target. Intended for the settle/resume
    // scrub path, which values precision over latency and is not per-frame
    // hot. No-op if the stream is dead.
    pub fn seekExact(self: *DecodeScheduler, stream: StreamHandle, target_seconds: f64, eps_seconds: f64) void {
        const target = @max(target_seconds, 0.0);
        {
            self.mu.lock();
            while (stream.busy) self.cv.wait(&self.mu);
            if (stream.dead.load(.monotonic) or stream.backend == null) {
                self.mu.unlock();
                return;
            }
            // We seek right here, so any older pending seek is superseded.
            stream.seek_pending = false;
            stream.eos = false;
            self.claimLocked(stream); // exclude workers while we own the stream
            stream.wants_more = true;
            self.mu.unlock();
        }
        // Busy held: we are the sole producer for the queue and the sole
        // toucher of the Backend until we drop it.
        while (stream.queue.pop()) |f| f.release();
        const backend_ptr = &stream.backend.?;
        _ = backend_ptr.seek(target);
        // Safety valve: bound the synchronous decode-forward loop so a
        // misbehaving backend whose PTS never advances past `target` and never
        // signals EOS cannot spin the calling (main) thread forever. Large
        // enough that real GOP-bounded scrub-settle never trips it.
        const max_scrub_decode_frames = 4096;
        var scrub_decoded: usize = 0;
        while (backend_ptr.nextVideoFrame()) |f| {
            if (f.pts_seconds + eps_seconds >= target) {
                // The frame at/just before the target: keep it for present.
                const pushed = stream.queue.push(f);
                std.debug.assert(pushed); // queue was flushed above
                break;
            }
            f.release();
            scrub_decoded += 1;
            if (scrub_decoded >= max_scrub_decode_frames) break; // non-advancing backend; bail without eos
        } else {
            self.mu.lock();
            stream.eos = true; // clip ended before the target — clamp.
            self.mu.unlock();
        }
        {
            self.mu.lock();
            stream.busy = false;
            self.mu.unlock();
        }
        self.cv.broadcast(); // release unregister/withBackend waiters
        self.notify(stream); // resume decode-ahead behind the surviving frame
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

    // Claim the per-stream busy guard from a NON-worker thread (requestSeek /
    // withBackend). Requires mu held and busy == false. Also dequeues the stream
    // from ready so no worker can claim it concurrently; a queued work demand is
    // folded back into wants_more.
    fn claimLocked(self: *DecodeScheduler, stream: StreamHandle) void {
        if (stream.queued) {
            removeHandle(&self.ready, stream);
            stream.queued = false;
            stream.wants_more = true;
        }
        stream.busy = true;
    }

    // Mark a stream as needing decode-ahead and wake a worker (async mode) or
    // pump it inline (sync mode). Idempotent: a stream already queued or busy is
    // not enqueued twice — this is what guarantees per-stream serial decode.
    fn notify(self: *DecodeScheduler, stream: StreamHandle) void {
        if (self.synchronous) {
            // Synchronous mode: pump inline on the caller's thread. Claim busy so
            // the contract (single producer per stream) is honoured even though
            // there is no worker — requestSeek/unregister still wait on busy
            // correctly.
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
            const stream = self.ready.orderedRemove(0);
            stream.queued = false;
            if (stream.dead.load(.monotonic)) continue;
            stream.busy = true;
            return stream;
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
            // Wake unregister/requestSeek waiters (busy just dropped) and, if we
            // requeued, a worker to pick the stream up.
            self.cv.broadcast();
        }
    }

    // Decode one slice for `stream`: pull frames from its Backend into its queue
    // until the queue is full or EOS. The caller must hold the stream's "busy"
    // claim, so we are the sole producer for its FrameQueue and the sole toucher
    // of its Backend.
    fn pumpStream(self: *DecodeScheduler, stream: StreamHandle) void {
        const backend_ptr = if (stream.backend) |*b| b else return;

        // Apply any pending seek before decoding (the scrub seam).
        var do_seek = false;
        var seek_target: f64 = 0.0;
        {
            self.mu.lock();
            if (stream.seek_pending) {
                do_seek = true;
                seek_target = stream.seek_target;
                stream.seek_pending = false;
            }
            self.mu.unlock();
        }
        if (do_seek) {
            _ = backend_ptr.seek(seek_target);
            self.mu.lock();
            stream.eos = false;
            self.mu.unlock();
        }

        // Decode-ahead: fill the queue until full or EOS. We re-check dead each
        // iteration so a concurrent unregister cuts the slice short promptly.
        while (!stream.queue.full()) {
            // Lock-free hot-path read of the write-once dead flag (acquire pairs
            // with the release store in unregisterStream). No mu per frame.
            if (stream.dead.load(.acquire)) return;
            const f = backend_ptr.nextVideoFrame();
            if (f == null) {
                self.mu.lock();
                stream.eos = true;
                self.mu.unlock();
                return;
            }
            if (!stream.queue.push(f.?)) {
                // Lost a race against capacity (should not happen with one
                // producer); release the frame to stay leak-safe and stop.
                f.?.release();
                return;
            }
        }
    }
};

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
