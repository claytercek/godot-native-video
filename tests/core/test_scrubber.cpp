#include "vendor/doctest.h"

#include "../../src/core/decode_scheduler.h"
#include "../../src/core/scrubber.h"

#include <atomic>
#include <chrono>
#include <cmath>
#include <memory>
#include <optional>
#include <thread>
#include <vector>

using core::Backend;
using core::DecodeScheduler;
using core::PixelFormat;
using core::ResolveMode;
using core::ScrubConfig;
using core::Scrubber;
using core::ScrubResolve;
using core::StreamHandle;
using core::VideoFrame;

// Default-ish config used across the cases: a seek is "fast" (a drag burst) when
// successive _seek calls arrive within the burst window AND move the target by at
// least the velocity threshold; the scrub is "settled" once `settle_debounce_ms`
// elapse with no new seek.
static ScrubConfig make_config() {
	ScrubConfig c;
	c.settle_debounce_ms = 100.0; // ~80-120ms band per the issue
	c.burst_window_ms = 120.0; // two seeks within this gap can form a burst
	c.velocity_threshold = 2.0; // media-seconds per wall-second to count as a fast drag
	return c;
}

TEST_CASE("first seek with no prior history resolves exactly (no burst yet)") {
	Scrubber s(make_config());
	// A lone seek (e.g. a click on the timeline) has no preceding velocity, so it
	// must resolve to the exact frame, not a keyframe.
	ScrubResolve r = s.on_seek(5.0, /*now_ms=*/1000.0);
	CHECK(r.mode == ResolveMode::Exact);
	CHECK(r.target_seconds == doctest::Approx(5.0));
}

TEST_CASE("a fast burst of seeks resolves to nearest keyframe for low latency") {
	Scrubber s(make_config());
	// First seek primes the state (exact).
	s.on_seek(1.0, 0.0);
	// Subsequent seeks arrive quickly and move far: 1.0 -> 2.0 in 20ms is
	// 50 media-s/wall-s, well above threshold -> keyframe scrub.
	ScrubResolve r1 = s.on_seek(2.0, 20.0);
	CHECK(r1.mode == ResolveMode::Keyframe);
	ScrubResolve r2 = s.on_seek(3.2, 40.0);
	CHECK(r2.mode == ResolveMode::Keyframe);
	CHECK(r2.target_seconds == doctest::Approx(3.2));
}

TEST_CASE("a slow drag (below velocity threshold) resolves exactly") {
	Scrubber s(make_config());
	s.on_seek(1.0, 0.0);
	// Move only 0.05s over 100ms = 0.5 media-s/wall-s, below the 2.0 threshold.
	ScrubResolve r = s.on_seek(1.05, 100.0);
	CHECK(r.mode == ResolveMode::Exact);
}

TEST_CASE("poll before the debounce elapses emits nothing") {
	Scrubber s(make_config());
	s.on_seek(1.0, 0.0);
	s.on_seek(2.0, 20.0); // fast -> keyframe
	// Only 50ms since the last seek; debounce is 100ms -> not settled yet.
	CHECK_FALSE(s.poll(70.0).has_value());
}

TEST_CASE("poll after the debounce emits an exact resolve to the last target (settle)") {
	Scrubber s(make_config());
	s.on_seek(1.0, 0.0);
	s.on_seek(2.0, 20.0); // fast -> keyframe at 2.0
	s.on_seek(3.0, 40.0); // fast -> keyframe at 3.0
	// 100ms+ since the last seek -> settled: emit an exact resolve to 3.0.
	std::optional<ScrubResolve> r = s.poll(141.0);
	REQUIRE(r.has_value());
	CHECK(r->mode == ResolveMode::Exact);
	CHECK(r->target_seconds == doctest::Approx(3.0));
}

TEST_CASE("settle fires exactly once until the next seek") {
	Scrubber s(make_config());
	s.on_seek(1.0, 0.0);
	s.on_seek(2.0, 20.0);
	REQUIRE(s.poll(141.0).has_value()); // first poll past debounce settles
	CHECK_FALSE(s.poll(200.0).has_value()); // already settled -> no repeat
	// A new fast burst re-arms the settle.
	s.on_seek(4.0, 220.0);
	s.on_seek(5.0, 240.0);
	CHECK_FALSE(s.poll(260.0).has_value()); // within debounce again
	CHECK(s.poll(360.0).has_value()); // settles once more
}

TEST_CASE("a settled (exact) seek does not need a follow-up poll resolve") {
	Scrubber s(make_config());
	// A lone exact seek already resolved exactly; polling past debounce should not
	// re-emit a redundant exact resolve for the same target.
	s.on_seek(5.0, 0.0);
	CHECK_FALSE(s.poll(200.0).has_value());
}

TEST_CASE("playback resume forces an exact resolve at the last scrub target") {
	Scrubber s(make_config());
	s.on_seek(1.0, 0.0);
	s.on_seek(2.0, 20.0); // keyframe scrub at 2.0
	ScrubResolve r = s.on_resume(30.0);
	CHECK(r.mode == ResolveMode::Exact);
	CHECK(r.target_seconds == doctest::Approx(2.0));
	// After resume, the settle is consumed (resume already did the exact resolve).
	CHECK_FALSE(s.poll(200.0).has_value());
}

TEST_CASE("config is tunable: a higher threshold treats the same drag as exact") {
	ScrubConfig c = make_config();
	c.velocity_threshold = 1000.0; // absurdly high -> nothing counts as a fast drag
	Scrubber s(c);
	s.on_seek(1.0, 0.0);
	ScrubResolve r = s.on_seek(2.0, 20.0); // 50 media-s/wall-s < 1000 -> exact
	CHECK(r.mode == ResolveMode::Exact);
}

// -----------------------------------------------------------------------
// Integration with the decode scheduler — proves the Scrubber's decisions, when
// mapped onto real seeks, give (a) low keyframe-scrub latency during a drag and
// (b) the EXACT target frame once the scrub settles. This is the acceptance
// harness for o3h: the exact-frame-on-settle marker assertion + the scrub-latency
// perf metric, both runnable headlessly in CI via ./bin/core_tests.
// -----------------------------------------------------------------------

namespace {

// Keyframe grid: a keyframe every kGopFrames frames. A Keyframe resolve snaps to
// the keyframe at/before the target (cheap, low latency); an Exact resolve seeks
// that keyframe then decodes FORWARD to the target frame (more frames decoded =
// higher latency, but lands on the precise frame).
constexpr int kFps = 30;
constexpr int kGopFrames = 30; // 1s GOP
constexpr int kTotalFrames = 1200; // 40s clip

int frame_of_pts(double pts) { return static_cast<int>(std::lround(pts * kFps)); }
int keyframe_at_or_before(int frame) { return (frame / kGopFrames) * kGopFrames; }

// A backend whose seek() snaps to the preceding keyframe. Each decoded frame
// carries its frame index in `height` so a test can assert which frame a resolve
// lands on and measure the consumer-side cost of reaching it.
class KeyframeBackend : public Backend {
public:
	explicit KeyframeBackend(std::atomic<int> *live = nullptr) :
			live_(live) {}

	bool open(const std::string &) override { return true; }
	void close() override {}
	double duration_seconds() const override { return kTotalFrames / double(kFps); }
	int video_width() const override { return 0; }
	int video_height() const override { return 1; }
	int audio_channel_count() const override { return 0; }
	int audio_sample_rate() const override { return 0; }

	bool seek(double pts_seconds) override {
		const int target = frame_of_pts(pts_seconds);
		next_index_ = keyframe_at_or_before(target);
		return true;
	}

	std::optional<VideoFrame> next_video_frame() override {
		if (next_index_ >= kTotalFrames) {
			return std::nullopt;
		}
		const int idx = next_index_++;
		if (live_) {
			live_->fetch_add(1, std::memory_order_relaxed);
		}
		VideoFrame f;
		f.pts_seconds = idx / double(kFps);
		f.height = idx; // carry frame index for the marker assertion
		f.pixel_format = PixelFormat::NV12;
		std::atomic<int> *live = live_;
		auto released = std::make_shared<std::atomic<bool>>(false);
		f.release = [live, released]() {
			if (!released->exchange(true) && live) {
				live->fetch_sub(1, std::memory_order_relaxed);
			}
		};
		return f;
	}

	std::optional<core::AudioChunk> next_audio_chunk() override { return std::nullopt; }

private:
	std::atomic<int> *live_;
	int next_index_ = 0;
};

// Pull the first frame the scheduler delivers after a (re)seek, spinning briefly
// while the worker pumps. Releases nothing — caller owns the returned frame.
std::optional<VideoFrame> wait_first_frame(DecodeScheduler &sched, const StreamHandle &s) {
	auto f = sched.next_frame(s);
	const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
	while (!f.has_value()) {
		std::this_thread::sleep_for(std::chrono::microseconds(50));
		f = sched.next_frame(s);
		REQUIRE(std::chrono::steady_clock::now() < deadline);
	}
	return f;
}

// Map a ScrubResolve onto the scheduler. A Keyframe resolve just reseeks to the
// (keyframe-snapped) target and presents whatever the backend yields first. An
// Exact resolve reseeks to the same place but then DROPS forward to the precise
// target frame before presenting — the decode-forward the issue describes.
//
// `frames_to_present` is the number of frames the CONSUMER had to pop to put the
// resolved frame on screen (1 for a keyframe scrub; keyframe..target inclusive
// for an exact resolve). This is the scrub-latency proxy: it is deterministic and
// independent of background decode-ahead prefetch, unlike a raw backend decode
// counter that races the worker pool. Bigger == more decode-forward == higher
// latency to first feedback.
struct ResolveResult {
	int presented_index = -1;
	long frames_to_present = 0;
};

ResolveResult apply_resolve(DecodeScheduler &sched, const StreamHandle &s,
		const ScrubResolve &r) {
	sched.request_seek(s, r.target_seconds);

	auto f = wait_first_frame(sched, s);
	int presented = f->height;
	long popped = 1;

	if (r.mode == ResolveMode::Exact) {
		// Decode forward to the exact target frame, dropping the keyframe + any
		// inter-frames before it.
		const int want = frame_of_pts(r.target_seconds);
		while (presented < want) {
			if (f->release) {
				f->release();
			}
			f = wait_first_frame(sched, s);
			presented = f->height;
			++popped;
		}
	}
	if (f->release) {
		f->release();
	}
	return { presented, popped };
}

} // namespace

TEST_CASE("exact-frame-on-settle: settle resolves to the precise target frame") {
	std::atomic<int> live{ 0 };
	// Force-synchronous: decode runs inline on this thread, so request_seek's flush
	// + reseek and the decode-forward are fully deterministic with no worker race —
	// the marker assertion below is exact, not best-effort.
	DecodeScheduler sched(1, /*force_synchronous=*/true);
	auto s = sched.register_stream(std::make_unique<KeyframeBackend>(&live));

	Scrubber scrub(make_config());

	// A fast drag burst: targets that do NOT sit on the keyframe grid, so a
	// keyframe scrub lands on a DIFFERENT frame than the exact target — making the
	// settle assertion meaningful.
	const double targets[] = { 10.40, 12.70, 15.15 }; // frames 312, 381, 454
	double now_ms = 0.0;
	ScrubResolve last{};
	scrub.on_seek(2.0, now_ms); // prime
	for (double t : targets) {
		now_ms += 20.0; // 20ms apart -> fast burst -> keyframe
		last = scrub.on_seek(t, now_ms);
		CHECK(last.mode == ResolveMode::Keyframe);
		ResolveResult kf = apply_resolve(sched, s, last);
		// Keyframe scrub lands on the keyframe at/before the target (approximate).
		CHECK(kf.presented_index == keyframe_at_or_before(frame_of_pts(t)));
	}

	// The user stops moving. After the debounce, the Scrubber emits an Exact
	// resolve at the LAST target.
	now_ms += 150.0;
	std::optional<ScrubResolve> settle = scrub.poll(now_ms);
	REQUIRE(settle.has_value());
	CHECK(settle->mode == ResolveMode::Exact);

	ResolveResult exact = apply_resolve(sched, s, *settle);
	// MARKER ASSERTION: the settled frame is EXACTLY the last drag target.
	const int want = frame_of_pts(targets[2]);
	CHECK(exact.presented_index == want);

	sched.unregister_stream(s);
	CHECK(live.load() == 0);
}

TEST_CASE("scrub-latency perf metric: keyframe scrub reaches a frame far sooner than exact") {
	std::atomic<int> live{ 0 };
	// Force-synchronous so the consumer-side pop count is a clean, deterministic
	// latency proxy (no background decode-ahead inflating either side).
	DecodeScheduler sched(1, /*force_synchronous=*/true);
	auto s = sched.register_stream(std::make_unique<KeyframeBackend>(&live));

	// Target deliberately near the END of a GOP so an exact resolve must decode a
	// near-full GOP forward, while a keyframe scrub stops at the keyframe.
	const double target = (kGopFrames - 1) / double(kFps) + 20.0; // ~frame 629
	const int want = frame_of_pts(target);

	// Keyframe scrub cost (the feedback-latency proxy during a drag).
	ScrubResolve kf_resolve{ ResolveMode::Keyframe, target };
	ResolveResult kf = apply_resolve(sched, s, kf_resolve);
	CHECK(kf.presented_index == keyframe_at_or_before(want));

	// Exact resolve cost (the precise settle/resume path).
	ScrubResolve exact_resolve{ ResolveMode::Exact, target };
	ResolveResult exact = apply_resolve(sched, s, exact_resolve);
	CHECK(exact.presented_index == want);

	// Perf metric, surfaced to the CI log like the A/V-drift harness. Frames the
	// consumer must pop to put the resolved frame on screen == scrub-feedback
	// latency. The whole point of keyframe-on-drag is that a fast scrub does a small
	// fraction of the work an exact resolve does. This count is deterministic
	// (consumer-side), unlike the worker pool's background decode-ahead.
	MESSAGE("scrub-latency: keyframe scrub popped " << kf.frames_to_present
			<< " frame(s), exact resolve popped " << exact.frames_to_present
			<< " frame(s) to reach frame " << want
			<< " (speedup ~" << (double(exact.frames_to_present) / double(std::max<long>(1, kf.frames_to_present)))
			<< "x)");
	// A keyframe scrub presents immediately (one frame); exact decodes forward.
	CHECK(kf.frames_to_present == 1);
	CHECK(kf.frames_to_present < exact.frames_to_present);
	// Real win, not a one-frame edge: with the target at the back of the GOP, exact
	// must decode forward at least half a GOP further than the keyframe scrub.
	CHECK(exact.frames_to_present >= kf.frames_to_present + (kGopFrames / 2));

	sched.unregister_stream(s);
	CHECK(live.load() == 0);
}
