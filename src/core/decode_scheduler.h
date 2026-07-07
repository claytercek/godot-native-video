#pragma once

// -----------------------------------------------------------------------
// decode_scheduler.h — the bounded shared decode-worker pool (Engine Core).
//
// PROBLEM: a scene may hold many
// VideoStreamPlayers. Spawning one decode thread per video does not scale.
// Conversely, decoding inline on the main/render thread (the linear-playback
// slice's boundary) blocks presentation. The DecodeScheduler is a single bounded pool
// of worker threads, SHARED across all active streams, that pulls frames from
// each stream's core::Backend and fills that stream's FrameQueue ahead of the
// present step.
//
// THREADING CONTRACT (the load-bearing invariant of this slice):
//   * The pool has a fixed, bounded number of worker threads — NOT one per
//     stream. Worker count is independent of stream count.
//   * Each registered stream is decoded SERIALLY: at most ONE worker touches a
//     given stream's Backend/FrameQueue at any instant. This is enforced by a
//     per-stream "busy" flag — a stream is only ever handed to one worker, and
//     is not re-enqueued for decode until that worker finishes its slice. So:
//       - The FrameQueue's SPSC contract holds: exactly one producer (whichever
//         worker currently owns the stream) and one consumer (the main thread
//         calling drain/present). Producers never overlap in time.
//       - Per-stream frame ORDER is deterministic — frames enter the queue in
//         backend-decode order, which is monotonic PTS for linear playback.
//   * The Backend is touched ONLY by the worker that currently owns the stream.
//     register()/unregister()/the main thread never call into the Backend
//     concurrently with a worker (unregister blocks until the in-flight slice,
//     if any, completes — no use-after-free when a stream is destroyed
//     mid-decode).
//   * Workers touch NO Godot / RenderingDevice APIs (D9). The present + GPU pass
//     stays on the main/render thread, which drains the FrameQueue.
//
// SURFACE LIFETIME (acceptance criterion): the decode pool must be sized
// `pool_depth + frame_latency` so that every surface that can be in flight
// simultaneously — queued for present, being converted/presented, and still
// held by the RetireRing for `frame_latency` rendered frames — has a distinct
// backing surface and is never recycled while still in use. pool_depth here is
// the stream's FrameQueue usable capacity; frame_latency is RetireRing<N>'s N.
// See required_pool_depth().
//
// FORCE-SYNC DEBUG MODE (acceptance criterion): when force_synchronous is set
// (debug builds only — gated OFF in release, see NATIVE_VIDEO_DEBUG below) the
// scheduler runs NO worker threads. Decode happens synchronously on the calling
// (main) thread inside pump_stream(), so a decode->convert->present lifetime bug
// reproduces deterministically with no worker handoff and no deferred timing.
//
// SCRUB SEAM: request_seek() lets the binding ask a stream to
// flush + reseek before resuming decode-ahead; a future scrubbing slice can use
// it to request a keyframe-only decode without changing the threading model.
// -----------------------------------------------------------------------

#include <atomic>
#include <condition_variable>
#include <cstddef>
#include <deque>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <thread>
#include <vector>

#include "backend.h"
#include "frame_queue.h"

// Debug gate. The force-synchronous-conversion mode and other lifetime-debug
// affordances are compiled in only when NATIVE_VIDEO_DEBUG is defined. The
// build defines it for template_debug / the headless test targets and leaves it
// undefined for template_release, so release binaries cannot accidentally run
// the synchronous path. (We also keep the *field* present in release so the ABI
// is identical; it is simply forced false and never read on a hot path.)
#if defined(NATIVE_VIDEO_DEBUG) || defined(DEBUG_ENABLED) || !defined(NDEBUG)
#define NATIVE_VIDEO_FORCE_SYNC_AVAILABLE 1
#else
#define NATIVE_VIDEO_FORCE_SYNC_AVAILABLE 0
#endif

namespace core {

// The per-stream decode-ahead ring capacity (usable slots). FrameQueue uses
// Capacity-1 usable slots, so the template Capacity is kDecodeAheadCapacity and
// the usable depth is kDecodeAheadCapacity - 1.
inline constexpr size_t kDecodeAheadCapacity = 8;

// The default bound on worker threads. Kept small: decode is hardware-assisted
// and per-stream serial, so a handful of workers fairly services many streams.
inline constexpr size_t kDefaultWorkerCount = 3;

// A stream's decode-ahead frame queue type. One producer (the owning worker),
// one consumer (the main thread). See FrameQueue's SPSC contract.
using DecodeAheadQueue = FrameQueue<VideoFrame, kDecodeAheadCapacity>;

// -----------------------------------------------------------------------
// required_pool_depth — surface-lifetime sizing helper.
//
// The decoder must own enough distinct surfaces that every surface which can be
// alive at once has its own backing store. At any instant a stream may hold:
//   * up to `queue_usable_depth` decoded frames waiting in the FrameQueue,
//   * 1 frame popped and being converted/presented this tick,
//   * up to `frame_latency` frames parked in the RetireRing from prior ticks.
// Sizing the decode pool to their sum guarantees the Backend never recycles a
// surface that is still queued, in-flight, or retained. Returns that sum.
inline constexpr size_t required_pool_depth(size_t queue_usable_depth, size_t frame_latency) {
	return queue_usable_depth + 1 + frame_latency;
}

// -----------------------------------------------------------------------
// DecodeStream — per-stream decode state owned by the scheduler.
//
// Holds the Backend, the decode-ahead FrameQueue, and the scheduling flags that
// enforce per-stream serial decode. All mutable scheduling state is guarded by
// the scheduler's mutex; the FrameQueue itself is lock-free SPSC. The binding
// holds a StreamHandle (shared_ptr) and treats it as opaque.
// -----------------------------------------------------------------------
class DecodeStream {
public:
	explicit DecodeStream(std::unique_ptr<Backend> backend) :
			backend_(std::move(backend)) {}

	DecodeStream(const DecodeStream &) = delete;
	DecodeStream &operator=(const DecodeStream &) = delete;

private:
	friend class DecodeScheduler;

	std::unique_ptr<Backend> backend_;
	DecodeAheadQueue queue_;

	// Scheduling flags (guarded by DecodeScheduler::mu_):
	//   queued_ — the stream sits in the ready_ work queue waiting for a worker.
	//   busy_   — a worker currently owns this stream (its decode slice is in
	//             flight). At most one worker is ever busy on a given stream, which
	//             is what preserves the FrameQueue's single-producer contract.
	//   wants_more_ — the consumer popped a frame (or registration happened) so the
	//             stream should be (re)enqueued after the current slice.
	bool queued_ = false;
	bool busy_ = false;
	bool wants_more_ = false;

	// A pending seek target requested via request_seek(); applied by the owning
	// path before the next decode slice. Guarded by mu_.
	bool seek_pending_ = false;
	double seek_target_ = 0.0;

	// True once the Backend reports EOS. Cleared on seek. Guarded by mu_ for the
	// at_end() read; written by the owning worker.
	bool eos_ = false;

	// Set when unregister_stream begins teardown so a worker that wakes up does
	// not start a new slice. Guarded by mu_.
	bool dead_ = false;
};

using StreamHandle = std::shared_ptr<DecodeStream>;

// -----------------------------------------------------------------------
// DecodeScheduler — the shared pool. One instance is shared by all streams
// (the binding uses a process-wide singleton via instance()).
// -----------------------------------------------------------------------
class DecodeScheduler {
public:
	// `worker_count` is clamped to >= 1. `force_synchronous` (debug builds only)
	// disables the worker threads entirely; decode then runs on the caller's
	// thread inside pump_stream(). In release builds force_synchronous is ignored
	// and always treated as false.
	explicit DecodeScheduler(size_t worker_count = kDefaultWorkerCount,
			bool force_synchronous = false);
	~DecodeScheduler();

	DecodeScheduler(const DecodeScheduler &) = delete;
	DecodeScheduler &operator=(const DecodeScheduler &) = delete;

	// Process-wide shared pool used by the Godot binding so that N
	// VideoStreamPlayers share one bounded set of worker threads.
	static DecodeScheduler &instance();

	// Register a stream. The scheduler takes ownership of the Backend and decodes
	// ahead into the returned stream's queue. The stream begins idle; call
	// notify() (or it is auto-notified on registration) to start decode-ahead.
	StreamHandle register_stream(std::unique_ptr<Backend> backend);

	// Unregister a stream. Blocks until any in-flight decode slice for this stream
	// completes, then releases every frame still buffered (running each frame's
	// release closure) and drops the Backend. After return the StreamHandle's
	// queue is empty and the Backend is gone — no worker will touch it again.
	void unregister_stream(const StreamHandle &stream);

	// Pop the next decoded frame for the consumer (main thread). Returns nullopt
	// when the decode-ahead queue is momentarily empty. The caller owns the
	// returned frame and must eventually run its release() (typically via the
	// present pipeline's RetireRing). After popping, the stream is re-notified so
	// a worker tops the queue back up.
	std::optional<VideoFrame> next_frame(const StreamHandle &stream);

	// Run `fn` with exclusive access to the stream's Backend, serialized against
	// the worker pool (claims the same per-stream "busy" guard a decode slice
	// uses, so no worker touches the Backend concurrently). The binding uses this
	// to pump AUDIO from the main thread without violating the single-toucher
	// contract — video is decode-ahead on a worker, audio is pulled here under the
	// same mutual exclusion. `fn` must not call back into the scheduler for this
	// same stream (it already holds the claim). No-op if the stream is dead.
	void with_backend(const StreamHandle &stream, const std::function<void(Backend &)> &fn);

	// Peek the PTS of the head / second decode-ahead frame WITHOUT removing it
	// (consumer/main-thread only — same single-consumer contract as next_frame).
	// Returns nullopt when fewer than one / two frames are buffered. The present
	// step uses these to run the drop-late/hold-early selector non-destructively.
	std::optional<double> peek_head_pts(const StreamHandle &stream) const;
	std::optional<double> peek_next_pts(const StreamHandle &stream) const;

	// Ask the scheduler to flush the stream's queue and reseek the Backend to
	// `pts_seconds` before resuming decode-ahead. Blocks until any in-flight slice
	// completes so the reseek does not race a worker. (The scrub seam.)
	void request_seek(const StreamHandle &stream, double pts_seconds);

	// True end-of-stream: the Backend reported EOS and the queue is drained.
	bool at_end(const StreamHandle &stream) const;

	// --- Introspection (tests / instrumentation) ---
	size_t worker_count() const { return workers_.size(); }
	bool is_synchronous() const { return synchronous_; }

private:
	friend class DecodeStream;

	// Mark a stream as needing decode-ahead and wake a worker (async mode) or
	// pump it inline (sync mode). Idempotent: a stream already queued or busy is
	// not enqueued twice — this is what guarantees per-stream serial decode.
	void notify(const StreamHandle &stream);

	// Claim the per-stream busy guard from a NON-worker thread (request_seek /
	// with_backend). Requires mu_ held and busy_ == false. Also dequeues the
	// stream from ready_ so no worker can claim it concurrently; a queued work
	// demand is folded back into wants_more_.
	void claim_locked(const StreamHandle &stream);

	// Decode one slice for `stream`: pull frames from its Backend into its queue
	// until the queue is full or EOS. Runs on a worker thread (async) or the
	// caller (sync). The caller must hold the stream's "busy" claim.
	void pump_stream(const StreamHandle &stream);

	// Worker thread main loop: wait for a ready stream, claim it, pump it, release
	// the claim, and (if it still wants more) re-enqueue it for fairness.
	void worker_main();

	// Pull the next ready stream off the work queue, marking it busy. Returns null
	// when the pool is shutting down and the queue is empty.
	StreamHandle take_ready_stream();

	std::vector<std::thread> workers_;

	// Work queue of streams that need decode-ahead. Guarded by mu_; workers wait
	// on cv_. A stream is in the queue at most once (enforced via its queued_ flag).
	mutable std::mutex mu_;
	std::condition_variable cv_;
	std::deque<StreamHandle> ready_;
	bool shutting_down_ = false;

	// Keep handles alive for all registered streams so unregister can be ordered
	// against in-flight work without the binding's handle being the last ref.
	std::vector<StreamHandle> registered_;

	bool synchronous_ = false;
};

} // namespace core
