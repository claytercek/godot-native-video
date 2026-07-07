#include "vendor/doctest.h"

#include "../../src/core/decode_scheduler.h"

#include <atomic>
#include <chrono>
#include <cstring>
#include <memory>
#include <thread>
#include <vector>

using core::AudioChunk;
using core::Backend;
using core::DecodeScheduler;
using core::PixelFormat;
using core::StreamHandle;
using core::VideoFrame;

// -----------------------------------------------------------------------
// FakeBackend — a deterministic, Godot-free decoder mock.
//
// Each backend belongs to one stream id. It produces `frame_count` frames with
// a known, monotonic frame index encoded in BOTH the width field (stream id)
// and the pts (frame index). The release closure increments a shared release
// counter and a per-surface "in flight" guard so a leak / double-release / use-
// after-recycle is detectable. A small optional sleep models decode latency so
// the pool's fairness and serialization are actually exercised under timing.
// -----------------------------------------------------------------------
class FakeBackend : public Backend {
public:
	FakeBackend(int stream_id, int frame_count, std::atomic<int> *live_surfaces,
			std::atomic<long> *total_released, int decode_micros = 0) :
			stream_id_(stream_id),
			frame_count_(frame_count),
			live_surfaces_(live_surfaces),
			total_released_(total_released),
			decode_micros_(decode_micros) {}

	bool open(const std::string &) override { return true; }
	void close() override {}
	double duration_seconds() const override { return frame_count_ / 30.0; }
	int video_width() const override { return stream_id_; }
	int video_height() const override { return 1; }
	int audio_channel_count() const override { return 0; }
	int audio_sample_rate() const override { return 0; }

	bool seek(double pts_seconds) override {
		// Reseek to the frame at or before pts (1/30s grid). Deterministic.
		next_index_ = static_cast<int>(pts_seconds * 30.0);
		if (next_index_ < 0) {
			next_index_ = 0;
		}
		return true;
	}

	std::optional<VideoFrame> next_video_frame() override {
		if (next_index_ >= frame_count_) {
			return std::nullopt; // EOS
		}
		if (decode_micros_ > 0) {
			std::this_thread::sleep_for(std::chrono::microseconds(decode_micros_));
		}
		const int idx = next_index_++;
		if (live_surfaces_) {
			live_surfaces_->fetch_add(1, std::memory_order_relaxed);
		}
		VideoFrame f;
		f.pts_seconds = idx / 30.0;
		f.width = stream_id_; // carry the stream id for cross-stream corruption checks
		f.height = idx; // carry the frame index for order checks
		f.pixel_format = PixelFormat::NV12;
		std::atomic<int> *live = live_surfaces_;
		std::atomic<long> *total = total_released_;
		// Each release runs exactly once; guard against double release via a flag.
		auto released = std::make_shared<std::atomic<bool>>(false);
		f.release = [live, total, released]() {
			bool was = released->exchange(true);
			REQUIRE_FALSE(was); // exactly-once release
			if (live) {
				live->fetch_sub(1, std::memory_order_relaxed);
			}
			if (total) {
				total->fetch_add(1, std::memory_order_relaxed);
			}
		};
		return f;
	}

	std::optional<core::AudioChunk> next_audio_chunk() override { return std::nullopt; }

private:
	int stream_id_;
	int frame_count_;
	int next_index_ = 0;
	std::atomic<int> *live_surfaces_;
	std::atomic<long> *total_released_;
	int decode_micros_;
};

// -----------------------------------------------------------------------
// required_pool_depth — the surface-lifetime sizing contract.
// -----------------------------------------------------------------------
TEST_CASE("required_pool_depth = queue depth + in-flight + frame latency") {
	// 7 usable queue slots + 1 being presented + 3 retire-ring frames = 11.
	CHECK(core::required_pool_depth(7, 3) == 11);
	CHECK(core::required_pool_depth(0, 1) == 2);
	CHECK(core::required_pool_depth(core::kDecodeAheadCapacity - 1, 3) ==
			(core::kDecodeAheadCapacity - 1) + 1 + 3);
}

TEST_CASE("worker count is bounded and independent of stream count") {
	DecodeScheduler sched(2);
	CHECK(sched.worker_count() == 2);

	std::atomic<int> live{ 0 };
	std::atomic<long> released{ 0 };
	// Register many more streams than workers; the pool must NOT grow.
	std::vector<StreamHandle> streams;
	for (int i = 0; i < 16; ++i) {
		streams.push_back(sched.register_stream(
				std::make_unique<FakeBackend>(i, 30, &live, &released)));
	}
	CHECK(sched.worker_count() == 2); // still 2 — not one-thread-per-stream

	for (auto &s : streams) {
		sched.unregister_stream(s);
	}
	CHECK(live.load() == 0); // no surface leaked
}

// -----------------------------------------------------------------------
// Multi-stream stress: many streams, few workers, per-stream order preserved,
// no cross-stream corruption, no leak. Repeated over many iterations.
// -----------------------------------------------------------------------
TEST_CASE("multi-stream stress: per-stream order preserved, no corruption") {
	constexpr int kStreams = 24;
	constexpr int kFramesPerStream = 120;
	constexpr int kWorkers = 3; // << kStreams, to prove sharing

	for (int iter = 0; iter < 5; ++iter) {
		std::atomic<int> live{ 0 };
		std::atomic<long> released{ 0 };

		DecodeScheduler sched(kWorkers);
		REQUIRE(sched.worker_count() == kWorkers);

		std::vector<StreamHandle> streams;
		streams.reserve(kStreams);
		for (int i = 0; i < kStreams; ++i) {
			// Stagger decode latency a little so workers interleave streams.
			const int micros = (i % 3) * 5;
			streams.push_back(sched.register_stream(std::make_unique<FakeBackend>(
					i, kFramesPerStream, &live, &released, micros)));
		}

		// Consume every frame of every stream on the main thread. Assert that each
		// stream's frames arrive strictly in index order and carry that stream's id.
		std::vector<int> next_expected(kStreams, 0);
		int total_consumed = 0;
		const int total_expected = kStreams * kFramesPerStream;

		// Bound the spin so a hang fails the test rather than wedging CI.
		const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(20);

		while (total_consumed < total_expected) {
			bool progressed = false;
			for (int i = 0; i < kStreams; ++i) {
				auto f = sched.next_frame(streams[i]);
				if (!f.has_value()) {
					continue;
				}
				progressed = true;
				// Cross-stream corruption check: the frame must belong to stream i.
				REQUIRE(f->width == i);
				// Per-stream order check: frame index must be exactly the next one.
				REQUIRE(f->height == next_expected[i]);
				CHECK(f->pts_seconds == doctest::Approx(next_expected[i] / 30.0));
				++next_expected[i];
				++total_consumed;
				// Mimic the present path: release the surface back to the pool.
				if (f->release) {
					f->release();
				}
			}
			if (!progressed) {
				std::this_thread::sleep_for(std::chrono::microseconds(50));
			}
			REQUIRE(std::chrono::steady_clock::now() < deadline);
		}

		// Every stream delivered exactly its frames, in order.
		for (int i = 0; i < kStreams; ++i) {
			CHECK(next_expected[i] == kFramesPerStream);
			CHECK(sched.at_end(streams[i]));
		}

		for (auto &s : streams) {
			sched.unregister_stream(s);
		}
		// No surface left alive; every produced surface released exactly once.
		CHECK(live.load() == 0);
		CHECK(released.load() == static_cast<long>(total_expected));
	}
}

// -----------------------------------------------------------------------
// Unregister mid-decode must not leak or use-after-free. We tear streams down
// while workers are actively decoding (no draining first).
// -----------------------------------------------------------------------
TEST_CASE("unregister mid-decode releases buffered surfaces, no leak") {
	std::atomic<int> live{ 0 };
	std::atomic<long> released{ 0 };

	DecodeScheduler sched(4);
	std::vector<StreamHandle> streams;
	for (int i = 0; i < 12; ++i) {
		streams.push_back(sched.register_stream(std::make_unique<FakeBackend>(
				i, 200, &live, &released, /*decode_micros=*/10)));
	}

	// Let workers get busy decoding ahead.
	std::this_thread::sleep_for(std::chrono::milliseconds(5));

	// Pop a few frames from some streams, then tear everything down mid-flight.
	for (int i = 0; i < 12; ++i) {
		for (int k = 0; k < 3; ++k) {
			if (auto f = sched.next_frame(streams[i])) {
				if (f->release) {
					f->release();
				}
			}
		}
	}

	for (auto &s : streams) {
		sched.unregister_stream(s);
	}
	CHECK(live.load() == 0); // every buffered + in-flight surface released
}

// -----------------------------------------------------------------------
// request_seek (the scrub seam): flushes the queue, reseeks the backend,
// and resumes decode-ahead from the new position in order.
// -----------------------------------------------------------------------
TEST_CASE("request_seek flushes and resumes decode-ahead at the target") {
	std::atomic<int> live{ 0 };
	std::atomic<long> released{ 0 };

	DecodeScheduler sched(2);
	auto s = sched.register_stream(std::make_unique<FakeBackend>(0, 300, &live, &released));

	// Drain a few frames from the start.
	for (int k = 0; k < 5; ++k) {
		auto f = sched.next_frame(s);
		// May be momentarily empty; spin briefly.
		while (!f.has_value()) {
			std::this_thread::sleep_for(std::chrono::microseconds(50));
			f = sched.next_frame(s);
		}
		if (f->release) {
			f->release();
		}
	}

	// Seek to frame 150 (5.0s @ 30fps).
	sched.request_seek(s, 5.0);

	// The next frame delivered must be frame 150 or later (keyframe grid), in
	// order from there. With FakeBackend's exact seek it is exactly 150.
	auto f = sched.next_frame(s);
	const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
	while (!f.has_value()) {
		std::this_thread::sleep_for(std::chrono::microseconds(50));
		f = sched.next_frame(s);
		REQUIRE(std::chrono::steady_clock::now() < deadline);
	}
	CHECK(f->height == 150);
	if (f->release) {
		f->release();
	}

	sched.unregister_stream(s);
	CHECK(live.load() == 0);
}

#if NATIVE_VIDEO_FORCE_SYNC_AVAILABLE
// -----------------------------------------------------------------------
// Force-synchronous mode (debug only): no worker threads; decode runs on the
// caller's thread so lifetime bugs reproduce deterministically. Same external
// behaviour — order preserved, exactly-once release.
// -----------------------------------------------------------------------
TEST_CASE("force-synchronous mode: no workers, deterministic in-order decode") {
	std::atomic<int> live{ 0 };
	std::atomic<long> released{ 0 };

	DecodeScheduler sched(4, /*force_synchronous=*/true);
	CHECK(sched.is_synchronous());
	CHECK(sched.worker_count() == 0); // no threads spawned

	constexpr int kStreams = 6;
	constexpr int kFrames = 50;
	std::vector<StreamHandle> streams;
	for (int i = 0; i < kStreams; ++i) {
		streams.push_back(sched.register_stream(
				std::make_unique<FakeBackend>(i, kFrames, &live, &released)));
	}

	std::vector<int> expected(kStreams, 0);
	int consumed = 0;
	const int total = kStreams * kFrames;
	while (consumed < total) {
		bool progressed = false;
		for (int i = 0; i < kStreams; ++i) {
			auto f = sched.next_frame(streams[i]);
			if (!f.has_value()) {
				continue;
			}
			progressed = true;
			CHECK(f->width == i);
			CHECK(f->height == expected[i]);
			++expected[i];
			++consumed;
			if (f->release) {
				f->release();
			}
		}
		// Synchronous: next_frame re-pumps inline, so progress is guaranteed.
		REQUIRE(progressed);
	}

	for (auto &s : streams) {
		sched.unregister_stream(s);
	}
	CHECK(live.load() == 0);
	CHECK(released.load() == static_cast<long>(total));
}
#endif

// -----------------------------------------------------------------------
// ReselectFakeBackend — a multi-track FakeBackend for testing reselect.
//
// Has two audio "tracks" (0 and 1) with different sample counts per-frame.
// reselect_audio_track() switches between them, and next_audio_chunk()
// produces frames whose frame_count identifies the active track. The audio
// scratch buffer is shared so the returned pointer is valid across calls.
// -----------------------------------------------------------------------
class ReselectFakeBackend : public FakeBackend {
public:
	ReselectFakeBackend(int stream_id, int frame_count,
			std::atomic<int> *live, std::atomic<long> *released,
			int decode_micros = 0) :
			FakeBackend(stream_id, frame_count, live, released, decode_micros),
			active_track_(0) {}

	int audio_track_count() const override { return 2; }

	core::AudioTrackInfo audio_track_info(int index) const override {
		core::AudioTrackInfo info;
		info.channels = 2;
		info.sample_rate = 48000;
		info.is_default = (index == 0);
		return info;
	}

	void select_audio_track(int index) override {
		if (index >= 0 && index < 2) {
			active_track_ = index;
		}
	}

	bool reselect_audio_track(int index, double /*pts_seconds*/) override {
		if (index < 0 || index >= 2) {
			return false;
		}
		active_track_ = index;
		reselect_count_++;
		return true;
	}

	std::optional<core::AudioChunk> next_audio_chunk() override {
		// Produce a frame whose frame_count encodes the active track (0 or 1) so
		// the caller can verify which track is flowing. Track 0 produces 512-frame
		// chunks; track 1 produces 256-frame chunks.
		const int frames_per_chunk = (active_track_ == 0) ? 512 : 256;
		const int channels = 2;
		const size_t n = static_cast<size_t>(frames_per_chunk * channels);
		if (audio_scratch_.size() < n) {
			audio_scratch_.resize(n);
		}
		std::memset(audio_scratch_.data(), 0, n * sizeof(float));
		// Tag the first sample with the active track so a test can assert.
		audio_scratch_[0] = static_cast<float>(active_track_);

		core::AudioChunk chunk;
		chunk.samples = audio_scratch_.data();
		chunk.frame_count = frames_per_chunk;
		chunk.channel_count = channels;
		chunk.sample_rate = 48000;
		return chunk;
	}

	int reselect_count() const { return reselect_count_; }
	int active_track() const { return active_track_; }

private:
	int active_track_ = 0;
	int reselect_count_ = 0;
	std::vector<float> audio_scratch_;
};

// -----------------------------------------------------------------------
// reselect_audio_track: verify that a reselect switches audio tracks and
// does NOT break the video decode pipeline (frames continue flowing).
// -----------------------------------------------------------------------
TEST_CASE("reselect_audio_track switches audio and preserves video flow") {
	std::atomic<int> live{ 0 };
	std::atomic<long> released{ 0 };

	DecodeScheduler sched(2);
	auto s = sched.register_stream(
			std::make_unique<ReselectFakeBackend>(0, 200, &live, &released));

	// Let video decode-ahead start filling the queue.
	std::this_thread::sleep_for(std::chrono::milliseconds(20));

	// Verify video frames flow (checking the present path works).
	auto vf = sched.next_frame(s);
	const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
	while (!vf.has_value()) {
		std::this_thread::sleep_for(std::chrono::microseconds(50));
		vf = sched.next_frame(s);
		REQUIRE(std::chrono::steady_clock::now() < deadline);
	}
	CHECK(vf->width == 0); // stream 0
	if (vf->release) {
		vf->release();
	}

	// Verify the initial audio track is 0.
	int initial_track = 0;
	sched.with_backend(s, [&](core::Backend &b) {
		auto ch = b.next_audio_chunk();
		REQUIRE(ch.has_value());
		CHECK(ch->frame_count == 512); // track 0 = 512 frames/chunk
		initial_track = static_cast<int>(ch->samples[0]);
	});
	CHECK(initial_track == 0);

	// Reselect to track 1.
	bool reselect_ok = false;
	sched.with_backend(s, [&](core::Backend &b) {
		reselect_ok = b.reselect_audio_track(1, 0.0);
	});
	CHECK(reselect_ok);

	// Verify video still flows post-reselect (the video decode pipeline was not
	// broken by the reselect).
	vf = sched.next_frame(s);
	while (!vf.has_value()) {
		std::this_thread::sleep_for(std::chrono::microseconds(50));
		vf = sched.next_frame(s);
		REQUIRE(std::chrono::steady_clock::now() < deadline);
	}
	CHECK(vf->width == 0); // still stream 0, not corrupted
	if (vf->release) {
		vf->release();
	}

	// Verify the active audio track is now 1.
	int switched_track = -1;
	sched.with_backend(s, [&](core::Backend &b) {
		auto ch = b.next_audio_chunk();
		REQUIRE(ch.has_value());
		CHECK(ch->frame_count == 256); // track 1 = 256 frames/chunk
		switched_track = static_cast<int>(ch->samples[0]);
	});
	CHECK(switched_track == 1);

	sched.unregister_stream(s);
	CHECK(live.load() == 0);
}

// -----------------------------------------------------------------------
// with_backend serialization: verify that reselect via with_backend is
// serialized against worker decode (the stream is busy_ during reselect).
// -----------------------------------------------------------------------
TEST_CASE("with_backend is serialized against worker decode during reselect") {
	std::atomic<int> live{ 0 };
	std::atomic<long> released{ 0 };

	DecodeScheduler sched(2);
	auto s = sched.register_stream(
			std::make_unique<ReselectFakeBackend>(0, 100, &live, &released));

	// Let the worker start decoding ahead.
	std::this_thread::sleep_for(std::chrono::milliseconds(10));

	// Call with_backend while the worker may be decoding. The test passes if
	// the reselect succeeds and video still flows afterwards (no deadlock).
	bool reselect_ok = false;
	sched.with_backend(s, [&](core::Backend &b) {
		reselect_ok = b.reselect_audio_track(1, 0.0);
	});
	CHECK(reselect_ok);

	// Consume a few video frames to verify the worker woke up after our
	// with_backend released the busy claim.
	const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
	int consumed = 0;
	while (consumed < 3) {
		auto vf = sched.next_frame(s);
		if (vf.has_value()) {
			if (vf->release) {
				vf->release();
			}
			++consumed;
		} else {
			std::this_thread::sleep_for(std::chrono::microseconds(50));
		}
		REQUIRE(std::chrono::steady_clock::now() < deadline);
	}
	CHECK(consumed == 3);

	sched.unregister_stream(s);
	CHECK(live.load() == 0);
}
