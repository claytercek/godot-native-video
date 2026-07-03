// -----------------------------------------------------------------------
// decode_scheduler.cpp — see decode_scheduler.h for the threading contract.
// -----------------------------------------------------------------------

#include "decode_scheduler.h"

#include <algorithm>
#include <utility>

namespace core {

DecodeScheduler::DecodeScheduler(size_t worker_count, bool force_synchronous) {
#if PLATFORM_MEDIA_FORCE_SYNC_AVAILABLE
	synchronous_ = force_synchronous;
#else
	// Release builds: the synchronous lifetime-debug path is compiled out, so the
	// requested flag is ignored and decode always runs on the worker pool.
	(void)force_synchronous;
	synchronous_ = false;
#endif

	if (synchronous_) {
		// No worker threads in synchronous mode; pump runs on the caller's thread.
		return;
	}

	const size_t n = std::max<size_t>(1, worker_count);
	workers_.reserve(n);
	for (size_t i = 0; i < n; ++i) {
		workers_.emplace_back([this] { worker_main(); });
	}
}

DecodeScheduler::~DecodeScheduler() {
	{
		std::lock_guard<std::mutex> lk(mu_);
		shutting_down_ = true;
	}
	cv_.notify_all();
	for (std::thread &t : workers_) {
		if (t.joinable()) {
			t.join();
		}
	}
	// Release any frames still buffered in streams that outlived their binding
	// (defensive — well-behaved callers unregister first).
	std::vector<StreamHandle> leftover;
	{
		std::lock_guard<std::mutex> lk(mu_);
		leftover.swap(registered_);
	}
	for (const StreamHandle &s : leftover) {
		while (auto f = s->queue_.pop()) {
			if (f->release) {
				f->release();
			}
		}
		if (s->backend_) {
			s->backend_->close();
		}
	}
}

DecodeScheduler &DecodeScheduler::instance() {
	// Process-wide shared pool. Constructed on first use, torn down at exit; the
	// destructor joins workers and frees any leftover frames.
	static DecodeScheduler s;
	return s;
}

StreamHandle DecodeScheduler::register_stream(std::unique_ptr<Backend> backend) {
	auto stream = std::make_shared<DecodeStream>(std::move(backend));
	{
		std::lock_guard<std::mutex> lk(mu_);
		registered_.push_back(stream);
		stream->wants_more_ = true;
	}
	// Kick off decode-ahead immediately so the queue starts filling.
	notify(stream);
	return stream;
}

void DecodeScheduler::unregister_stream(const StreamHandle &stream) {
	if (!stream) {
		return;
	}
	{
		std::unique_lock<std::mutex> lk(mu_);
		// Mark dead so no worker starts a new slice, and wait until any in-flight
		// slice for THIS stream finishes (busy_ drops) — guarantees no worker is
		// touching the Backend/queue when we tear it down (no use-after-free).
		stream->dead_ = true;
		stream->wants_more_ = false;
		// In synchronous mode there are no workers, so busy_ can never be set by
		// anyone but the calling thread; the wait below returns immediately.
		cv_.wait(lk, [&stream] { return !stream->busy_; });

		// Drop it from the registry and the ready queue.
		auto reg_it = std::find(registered_.begin(), registered_.end(), stream);
		if (reg_it != registered_.end()) {
			registered_.erase(reg_it);
		}
		auto rdy_it = std::find(ready_.begin(), ready_.end(), stream);
		if (rdy_it != ready_.end()) {
			ready_.erase(rdy_it);
		}
		stream->queued_ = false;
	}

	// Safe to touch the Backend/queue now: dead_ is set and busy_ is clear, so no
	// worker will ever pump this stream again. Release everything buffered.
	while (auto f = stream->queue_.pop()) {
		if (f->release) {
			f->release();
		}
	}
	if (stream->backend_) {
		stream->backend_->close();
		stream->backend_.reset();
	}
}

std::optional<VideoFrame> DecodeScheduler::next_frame(const StreamHandle &stream) {
	if (!stream) {
		return std::nullopt;
	}
	std::optional<VideoFrame> f = stream->queue_.pop();
	if (f.has_value()) {
		// Popping freed a slot; ask the pool to top the queue back up.
		{
			std::lock_guard<std::mutex> lk(mu_);
			if (!stream->dead_) {
				stream->wants_more_ = true;
			}
		}
		notify(stream);
	}
	return f;
}

void DecodeScheduler::with_backend(const StreamHandle &stream,
		const std::function<void(Backend &)> &fn) {
	if (!stream || !fn) {
		return;
	}
	{
		std::unique_lock<std::mutex> lk(mu_);
		// Claim the per-stream guard so no worker pumps this Backend while we use
		// it. Wait out any in-flight slice first.
		cv_.wait(lk, [&stream] { return !stream->busy_; });
		if (stream->dead_ || !stream->backend_) {
			return;
		}
		claim_locked(stream);
	}
	// We exclusively own the Backend here (busy_ held, no worker can claim it).
	fn(*stream->backend_);
	{
		std::lock_guard<std::mutex> lk(mu_);
		stream->busy_ = false;
	}
	cv_.notify_all(); // release waiters and let a worker resume decode-ahead
	notify(stream);
}

void DecodeScheduler::request_seek(const StreamHandle &stream, double pts_seconds) {
	if (!stream) {
		return;
	}
	{
		std::unique_lock<std::mutex> lk(mu_);
		// Wait out any in-flight slice, then CLAIM the per-stream guard ourselves so
		// no worker can start producing into the queue while we flush it. Without
		// this claim a stream already sitting in ready_ (busy_ == false) could be
		// picked up by a worker the instant we drop the lock; that worker would seek
		// + push new frames concurrently with the flush below, corrupting the queue
		// (post-seek frames partially flushed, pre/post-seek frames intermixed).
		cv_.wait(lk, [&stream] { return !stream->busy_; });
		stream->seek_pending_ = true;
		stream->seek_target_ = pts_seconds < 0.0 ? 0.0 : pts_seconds;
		stream->eos_ = false;
		if (stream->dead_) {
			return; // torn down concurrently; nothing to flush/resume.
		}
		claim_locked(stream); // exclude workers for the duration of the flush
		stream->wants_more_ = true;
	}
	// Flush queued frames on the consumer side (single-consumer: the caller). We
	// hold busy_, so no worker is producing concurrently.
	while (auto f = stream->queue_.pop()) {
		if (f->release) {
			f->release();
		}
	}
	{
		std::lock_guard<std::mutex> lk(mu_);
		stream->busy_ = false;
	}
	cv_.notify_all(); // release any unregister/with_backend waiters
	notify(stream);
}

std::optional<double> DecodeScheduler::peek_head_pts(const StreamHandle &stream) const {
	if (!stream) {
		return std::nullopt;
	}
	// peek() is consumer-thread-only and does not touch producer state, matching
	// the FrameQueue SPSC contract; no scheduler lock needed.
	const VideoFrame *head = stream->queue_.peek();
	return head ? std::optional<double>(head->pts_seconds) : std::nullopt;
}

std::optional<double> DecodeScheduler::peek_next_pts(const StreamHandle &stream) const {
	if (!stream) {
		return std::nullopt;
	}
	const VideoFrame *next = stream->queue_.peek_next();
	return next ? std::optional<double>(next->pts_seconds) : std::nullopt;
}

bool DecodeScheduler::at_end(const StreamHandle &stream) const {
	if (!stream) {
		return true;
	}
	std::lock_guard<std::mutex> lk(mu_);
	return stream->eos_ && stream->queue_.empty();
}

void DecodeScheduler::claim_locked(const StreamHandle &stream) {
	// Precondition: mu_ held and stream->busy_ == false. Claims the per-stream
	// producer guard AND removes the stream from the ready_ work queue, so a
	// worker in take_ready_stream can never pop it and stomp the claim (the
	// invariant is: a stream sitting in ready_ is never busy). If the stream was
	// queued, its pending work demand is folded back into wants_more_ so the
	// releaser's notify() re-enqueues it afterwards.
	if (stream->queued_) {
		auto it = std::find(ready_.begin(), ready_.end(), stream);
		if (it != ready_.end()) {
			ready_.erase(it);
		}
		stream->queued_ = false;
		stream->wants_more_ = true;
	}
	stream->busy_ = true;
}

void DecodeScheduler::notify(const StreamHandle &stream) {
	if (!stream) {
		return;
	}

	if (synchronous_) {
		// Synchronous mode: pump inline on the caller's thread. Claim busy_ so the
		// contract (single producer per stream) is honoured even though there is no
		// worker — request_seek/unregister still wait on busy_ correctly.
		{
			std::lock_guard<std::mutex> lk(mu_);
			if (stream->dead_ || stream->busy_ || !stream->wants_more_) {
				return;
			}
			stream->busy_ = true;
			stream->wants_more_ = false;
		}
		pump_stream(stream);
		{
			std::lock_guard<std::mutex> lk(mu_);
			stream->busy_ = false;
		}
		cv_.notify_all();
		return;
	}

	bool wake = false;
	{
		std::lock_guard<std::mutex> lk(mu_);
		// Enqueue only if the stream wants more work and is neither already queued
		// nor currently being decoded. This single guard is what guarantees a stream
		// is never handed to two workers at once -> per-stream serial decode.
		if (stream->dead_ || stream->queued_ || stream->busy_ || !stream->wants_more_) {
			return;
		}
		stream->queued_ = true;
		ready_.push_back(stream);
		wake = true;
	}
	if (wake) {
		cv_.notify_one();
	}
}

StreamHandle DecodeScheduler::take_ready_stream() {
	std::unique_lock<std::mutex> lk(mu_);
	cv_.wait(lk, [this] { return shutting_down_ || !ready_.empty(); });
	if (shutting_down_ && ready_.empty()) {
		return nullptr;
	}
	StreamHandle stream = ready_.front();
	ready_.pop_front();
	stream->queued_ = false;
	if (stream->dead_) {
		// Was torn down between enqueue and now; skip it.
		return nullptr;
	}
	stream->busy_ = true;
	return stream;
}

void DecodeScheduler::worker_main() {
	for (;;) {
		StreamHandle stream = take_ready_stream();
		if (!stream) {
			// Either shutdown, or a stream that died before we claimed it. Loop to
			// re-check the shutdown condition.
			std::lock_guard<std::mutex> lk(mu_);
			if (shutting_down_ && ready_.empty()) {
				return;
			}
			continue;
		}

		pump_stream(stream);

		bool requeue = false;
		{
			std::lock_guard<std::mutex> lk(mu_);
			stream->busy_ = false;
			// If the consumer asked for more while we were decoding (or the queue is
			// not yet full and the stream is alive), re-enqueue for another slice so
			// streams are fairly serviced round-robin without one starving others.
			if (!stream->dead_ && stream->wants_more_ && !stream->queued_) {
				stream->queued_ = true;
				stream->wants_more_ = false;
				ready_.push_back(stream);
				requeue = true;
			}
		}
		// Wake unregister/request_seek waiters (busy_ just dropped) and, if we
		// requeued, a worker to pick the stream up.
		cv_.notify_all();
		(void)requeue;
	}
}

void DecodeScheduler::pump_stream(const StreamHandle &stream) {
	// Precondition: the caller holds this stream's busy_ claim, so we are the sole
	// producer for its FrameQueue and the sole toucher of its Backend.
	Backend *backend = stream->backend_.get();
	if (!backend) {
		return;
	}

	// Apply any pending seek before decoding (scrub seam for o3h).
	bool do_seek = false;
	double seek_target = 0.0;
	{
		std::lock_guard<std::mutex> lk(mu_);
		if (stream->seek_pending_) {
			do_seek = true;
			seek_target = stream->seek_target_;
			stream->seek_pending_ = false;
		}
	}
	if (do_seek) {
		backend->seek(seek_target);
		std::lock_guard<std::mutex> lk(mu_);
		stream->eos_ = false;
	}

	// Decode-ahead: fill the queue until full or EOS. We re-check dead_ each
	// iteration so a concurrent unregister cuts the slice short promptly.
	while (!stream->queue_.full()) {
		{
			std::lock_guard<std::mutex> lk(mu_);
			if (stream->dead_) {
				return;
			}
		}
		std::optional<VideoFrame> f = backend->next_video_frame();
		if (!f.has_value()) {
			std::lock_guard<std::mutex> lk(mu_);
			stream->eos_ = true;
			return;
		}
		if (!stream->queue_.push(std::move(*f))) {
			// Lost a race against capacity (should not happen with one producer);
			// release the frame to stay leak-safe and stop the slice.
			if (f->release) {
				f->release();
			}
			return;
		}
	}
}

} // namespace core
