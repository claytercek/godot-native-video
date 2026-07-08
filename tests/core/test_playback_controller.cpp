#include "vendor/doctest.h"

#include "../../src/core/canonical_mix_format.h"
#include "../../src/core/playback_controller.h"
#include "../../src/core/wall_clock.h"

#include "../../src/core/channel_mixer.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <memory>
#include <optional>
#include <string>
#include <type_traits>
#include <vector>

using core::AudioChunk;
using core::AudioTrackInfo;
using core::Backend;
using core::MixSink;
using core::PlaybackController;
using core::VideoFrame;
using core::WallClockMs;

// WallClockMs must NOT implicitly convert from double — the whole point of
// the type is forcing a caller to opt into treating a number as wall time.
static_assert(!std::is_convertible_v<double, WallClockMs>,
		"WallClockMs must not implicitly convert from double");
static_assert(std::is_default_constructible_v<WallClockMs>,
		"WallClockMs must be default constructible");

TEST_CASE("WallClockMs holds its value and supports comparison/arithmetic via .ms") {
	WallClockMs a(100.0);
	WallClockMs b(30.0);
	CHECK(a.ms == 100.0);
	CHECK(b.ms == 30.0);
	CHECK(a.ms - b.ms == doctest::Approx(70.0));
	// Default-constructed is zero (the pre-load / pre-tick sentinel).
	CHECK(WallClockMs().ms == 0.0);
}

// -----------------------------------------------------------------------
// A lean sanity suite for the newly-extracted PlaybackController — no Godot,
// no GPU. This is NOT the exhaustive executable spec (full Track Switch /
// scrub / clock doctests) left to a follow-up; it exists to give this
// behavior-preserving extraction its own safety net for the pieces
// that are deterministic without depending on DecodeScheduler's real
// background worker pool (the controller registers with the process-wide
// DecodeScheduler::instance() singleton, same as the Binding did before this
// extraction — video decode-ahead timing is therefore not exercised here;
// that is what the headless smoke suite is for).
// -----------------------------------------------------------------------

namespace {

// A deterministic, Godot-free decoder mock with a configurable set of audio
// tracks and an effectively unbounded audio-chunk supply, so fill_audio()'s
// half-fill loop can run to completion without hitting EOS mid-test. Distinct
// from test_decode_scheduler.cpp's FakeBackend (a single-track, release-
// tracking video mock for scheduler concurrency tests) — this one models
// multi-track audio selection instead.
class MultiTrackFakeBackend : public Backend {
public:
	struct TrackSpec {
		int channels;
		int sample_rate;
	};

	explicit MultiTrackFakeBackend(std::vector<TrackSpec> tracks, int chunk_frames = 4096) :
			tracks_(std::move(tracks)), chunk_frames_(chunk_frames) {}

	bool open(const std::string &) override { return true; }
	void close() override {}
	double duration_seconds() const override { return 10.0; }
	int video_width() const override { return 640; }
	int video_height() const override { return 360; }
	int audio_channel_count() const override {
		return tracks_.empty() ? 0 : tracks_[0].channels;
	}
	int audio_sample_rate() const override {
		return tracks_.empty() ? 0 : tracks_[0].sample_rate;
	}

	int audio_track_count() const override { return static_cast<int>(tracks_.size()); }

	AudioTrackInfo audio_track_info(int index) const override {
		AudioTrackInfo info;
		if (index >= 0 && static_cast<size_t>(index) < tracks_.size()) {
			info.channels = tracks_[static_cast<size_t>(index)].channels;
			info.sample_rate = tracks_[static_cast<size_t>(index)].sample_rate;
			info.is_default = index == 0;
		}
		return info;
	}

	void select_audio_track(int index) override {
		live_track_ = index;
		++select_calls_;
	}

	bool reselect_audio_track(int index, double /*pts_seconds*/) override {
		++reselect_calls_;
		if (!reselect_should_succeed_) {
			return false;
		}
		live_track_ = index;
		return true;
	}

	bool seek(double pts_seconds) override {
		next_index_ = static_cast<int>(pts_seconds * 30.0);
		if (next_index_ < 0) {
			next_index_ = 0;
		}
		return true;
	}

	std::optional<VideoFrame> next_video_frame() override {
		if (next_index_ >= 300) {
			return std::nullopt;
		}
		VideoFrame f;
		f.pts_seconds = next_index_ / 30.0;
		f.release = []() {};
		++next_index_;
		return f;
	}

	std::optional<AudioChunk> next_audio_chunk() override {
		if (tracks_.empty() || live_track_ < 0 ||
				static_cast<size_t>(live_track_) >= tracks_.size()) {
			return std::nullopt;
		}
		const TrackSpec &t = tracks_[static_cast<size_t>(live_track_)];
		samples_.assign(static_cast<size_t>(chunk_frames_) * static_cast<size_t>(t.channels), 0.25f);
		AudioChunk chunk;
		chunk.samples = samples_.data();
		chunk.frame_count = chunk_frames_;
		chunk.channel_count = t.channels;
		chunk.sample_rate = t.sample_rate;
		return chunk;
	}

	void set_reselect_should_succeed(bool ok) { reselect_should_succeed_ = ok; }

	int select_calls() const { return select_calls_; }
	int reselect_calls() const { return reselect_calls_; }

private:
	std::vector<TrackSpec> tracks_;
	int chunk_frames_;
	int next_index_ = 0;
	int live_track_ = 0;
	bool reselect_should_succeed_ = true;
	std::vector<float> samples_;
	int select_calls_ = 0;
	int reselect_calls_ = 0;
};

// -----------------------------------------------------------------------
// AcceptAllMixSink — a MixSink that accepts every frame offered, including
// underrun silence. Distinct from CappedMixSink (which models downstream
// back-pressure): this one exists to prove the INVERSE risk — that a sink
// accepting silence in full must never be mistaken for real audio progress.
// -----------------------------------------------------------------------
class AcceptAllMixSink : public MixSink {
public:
	int mix(const float *, int frame_count, int /*channel_count*/) override {
		return frame_count;
	}
};

// -----------------------------------------------------------------------
// ShortAudioBackend — one audio track that yields exactly ONE real chunk of
// `total_frames` frames, then permanent EOS. Models a clip whose audio track
// is much shorter than its video (or than the tick horizon), so audio_eos_ +
// an emptied ring (audio_exhausted()) is reached deterministically and fast.
// Video is a plain 30fps linear sequence, unused by the tests that use this
// backend except to keep tick()'s present step well-defined.
// -----------------------------------------------------------------------
class ShortAudioBackend : public Backend {
public:
	explicit ShortAudioBackend(int total_frames) :
			total_frames_(total_frames) {}

	bool open(const std::string &) override { return true; }
	void close() override {}
	double duration_seconds() const override { return 10.0; }
	int video_width() const override { return 640; }
	int video_height() const override { return 360; }
	int audio_channel_count() const override { return 2; }
	int audio_sample_rate() const override { return 48000; }

	bool seek(double pts_seconds) override {
		next_index_ = static_cast<int>(pts_seconds * 30.0);
		if (next_index_ < 0) {
			next_index_ = 0;
		}
		return true;
	}

	std::optional<VideoFrame> next_video_frame() override {
		if (next_index_ >= 300) {
			return std::nullopt;
		}
		VideoFrame f;
		f.pts_seconds = next_index_ / 30.0;
		f.release = []() {};
		++next_index_;
		return f;
	}

	std::optional<AudioChunk> next_audio_chunk() override {
		if (delivered_) {
			return std::nullopt; // permanent EOS after the one real chunk
		}
		delivered_ = true;
		samples_.assign(static_cast<size_t>(total_frames_) * 2, 0.5f);
		AudioChunk chunk;
		chunk.samples = samples_.data();
		chunk.frame_count = total_frames_;
		chunk.channel_count = 2;
		chunk.sample_rate = 48000;
		return chunk;
	}

private:
	int total_frames_;
	int next_index_ = 0;
	bool delivered_ = false;
	std::vector<float> samples_;
};

// -----------------------------------------------------------------------
// Scrub-resolve fixtures — video-only (silent) backends driving
// PlaybackController::seek()/tick() through the real scheduler seam, mirroring
// test_scrubber.cpp's KeyframeBackend but scoped to this file (anonymous
// namespaces are not shared across translation units) and instrumented with a
// release/drop counter so a test can measure how many frames a resolve
// dropped without reaching into the scheduler directly.
// -----------------------------------------------------------------------
constexpr int kScrubFps = 30;
constexpr int kScrubGopFrames = 30; // 1s GOP
constexpr int kScrubTotalFrames = 1200; // 40s clip

int scrub_frame_of_pts(double pts) {
	return static_cast<int>(std::lround(pts * kScrubFps));
}
int scrub_keyframe_at_or_before(int frame) {
	return (frame / kScrubGopFrames) * kScrubGopFrames;
}

class ScrubGridBackend : public Backend {
public:
	explicit ScrubGridBackend(std::atomic<int> *drop_counter) :
			drop_counter_(drop_counter) {}

	bool open(const std::string &) override { return true; }
	void close() override {}
	double duration_seconds() const override { return kScrubTotalFrames / double(kScrubFps); }
	int video_width() const override { return 0; }
	int video_height() const override { return 1; }
	int audio_channel_count() const override { return 0; }
	int audio_sample_rate() const override { return 0; }

	bool seek(double pts_seconds) override {
		const int target = scrub_frame_of_pts(pts_seconds);
		next_index_ = scrub_keyframe_at_or_before(target);
		return true;
	}

	std::optional<VideoFrame> next_video_frame() override {
		if (next_index_ >= kScrubTotalFrames) {
			return std::nullopt;
		}
		const int idx = next_index_++;
		VideoFrame f;
		f.pts_seconds = idx / double(kScrubFps);
		std::atomic<int> *counter = drop_counter_;
		f.release = [counter]() {
			if (counter) {
				counter->fetch_add(1, std::memory_order_relaxed);
			}
		};
		return f;
	}

	std::optional<AudioChunk> next_audio_chunk() override { return std::nullopt; }

private:
	std::atomic<int> *drop_counter_;
	int next_index_ = 0;
};

// -----------------------------------------------------------------------
// ExactPtsBackend — an explicit, hand-picked PTS sequence, used only to probe
// apply_scrub_resolve()'s epsilon boundary (`head_pts + eps >= target`) with
// exact control over how far each frame sits from the target. The sequence
// only "arms" once seek() is called: the initial decode-ahead that
// register_stream() kicks off (before the test's own seek()) would otherwise
// race to consume these hand-picked frames first.
// -----------------------------------------------------------------------
class ExactPtsBackend : public Backend {
public:
	ExactPtsBackend(std::vector<double> pts_sequence, std::atomic<int> *drop_counter) :
			pts_sequence_(std::move(pts_sequence)), drop_counter_(drop_counter) {}

	bool open(const std::string &) override { return true; }
	void close() override {}
	double duration_seconds() const override { return 100.0; }
	int video_width() const override { return 0; }
	int video_height() const override { return 1; }
	int audio_channel_count() const override { return 0; }
	int audio_sample_rate() const override { return 0; }

	bool seek(double /*pts_seconds*/) override {
		armed_ = true;
		idx_ = 0;
		return true;
	}

	std::optional<VideoFrame> next_video_frame() override {
		if (!armed_ || idx_ >= pts_sequence_.size()) {
			return std::nullopt;
		}
		VideoFrame f;
		f.pts_seconds = pts_sequence_[idx_++];
		std::atomic<int> *counter = drop_counter_;
		f.release = [counter]() {
			if (counter) {
				counter->fetch_add(1, std::memory_order_relaxed);
			}
		};
		return f;
	}

	std::optional<AudioChunk> next_audio_chunk() override { return std::nullopt; }

private:
	std::vector<double> pts_sequence_;
	size_t idx_ = 0;
	bool armed_ = false;
	std::atomic<int> *drop_counter_;
};

// A MixSink test double that accepts at most `accept_cap` frames per call,
// regardless of how many are offered — the seam that lets a test exercise
// the "accepted-and-real-only" clock back-pressure accounting.
class CappedMixSink : public MixSink {
public:
	explicit CappedMixSink(int accept_cap) :
			accept_cap_(accept_cap) {}

	int mix(const float *, int frame_count, int /*channel_count*/) override {
		last_offered_ = frame_count;
		return std::min(frame_count, accept_cap_);
	}

	int last_offered() const { return last_offered_; }

private:
	int accept_cap_;
	int last_offered_ = 0;
};

std::unique_ptr<Backend> make_stereo_backend() {
	return std::make_unique<MultiTrackFakeBackend>(std::vector<MultiTrackFakeBackend::TrackSpec>{{2, 48000}});
}

} // namespace

TEST_CASE("load() derives the Canonical Mix Format and warns once on a mixed sample rate") {
	auto backend = std::make_unique<MultiTrackFakeBackend>(std::vector<MultiTrackFakeBackend::TrackSpec>{
			{1, 44100}, // track 0: default -> canonical rate
			{2, 48000}, // track 1: differing rate -> one warning
			{6, 44100}, // track 2: matches canonical rate -> no warning
	});

	PlaybackController controller;
	controller.load(std::move(backend), /*audio_output_latency_seconds=*/0.0);

	CHECK(controller.is_loaded());
	CHECK(controller.canonical_channels() == 6); // max across tracks
	CHECK(controller.canonical_sample_rate() == 44100); // first audio-bearing track

	std::vector<std::string> warnings = controller.take_warnings();
	REQUIRE(warnings.size() == 1);
	CHECK(warnings[0].find("differs from the canonical rate") != std::string::npos);

	controller.shutdown();
}

TEST_CASE("a silent clip (no audio tracks) reports zero channels and no warnings") {
	auto backend = std::make_unique<MultiTrackFakeBackend>(std::vector<MultiTrackFakeBackend::TrackSpec>{});

	PlaybackController controller;
	controller.load(std::move(backend), 0.0);

	CHECK(controller.is_loaded());
	CHECK(controller.canonical_channels() == 0);
	CHECK(controller.canonical_sample_rate() == 0);
	CHECK(controller.take_warnings().empty());

	controller.shutdown();
}

TEST_CASE("an out-of-range pre-load track selection is validated and reset once load() runs") {
	auto backend = std::make_unique<MultiTrackFakeBackend>(std::vector<MultiTrackFakeBackend::TrackSpec>{{2, 48000}});

	PlaybackController controller;
	// Pre-load selection: no stream yet, so this just records desired_track_.
	controller.request_audio_track(2);
	CHECK(controller.take_warnings().empty()); // no validation possible yet

	controller.load(std::move(backend), 0.0);

	CHECK(controller.desired_audio_track() == 0); // out of range -> fell back to 0
	std::vector<std::string> warnings = controller.take_warnings();
	REQUIRE(warnings.size() == 1);
	CHECK(warnings[0].find("out of range") != std::string::npos);

	controller.shutdown();
}

TEST_CASE("drive_audio advances the clock by only the accepted-and-real frame count") {
	PlaybackController controller;
	controller.load(make_stereo_backend(), 0.0);
	controller.play(WallClockMs(0.0));

	// The sink accepts far fewer frames than fill_audio() will have topped
	// the ring up with, so the clock must advance by exactly the accepted
	// count (mix back-pressure), never the full offered/available amount.
	CappedMixSink sink(/*accept_cap=*/100);
	std::optional<VideoFrame> frame = controller.tick(/*delta_seconds=*/1.0 / 60.0, WallClockMs(16.6), sink);
	(void)frame; // no video frames are queued in this test; present is a Hold

	REQUIRE(sink.last_offered() > 100); // proves back-pressure was actually exercised
	CHECK(controller.media_time() == doctest::Approx(100.0 / 48000.0).epsilon(0.01));

	controller.shutdown();
}

TEST_CASE("a mid-stream reselect the backend refuses rolls the desired track back") {
	auto backend = std::make_unique<MultiTrackFakeBackend>(std::vector<MultiTrackFakeBackend::TrackSpec>{
			{2, 48000}, {2, 48000}});
	MultiTrackFakeBackend *raw = backend.get();
	raw->set_reselect_should_succeed(false);

	PlaybackController controller;
	controller.load(std::move(backend), 0.0);
	controller.play(WallClockMs(0.0));

	controller.request_audio_track(1); // deferred: applied on the next tick()
	CHECK(controller.desired_audio_track() == 1);

	CappedMixSink sink(4096);
	controller.tick(1.0 / 60.0, WallClockMs(16.6), sink);

	CHECK(controller.desired_audio_track() == 0); // rolled back
	CHECK(controller.live_audio_track() == 0);
	std::vector<std::string> warnings = controller.take_warnings();
	REQUIRE(warnings.size() == 1);
	CHECK(warnings[0].find("failed; recovering via seek") != std::string::npos);

	controller.shutdown();
}

TEST_CASE("stop() resets transport state and tick() is a no-op before load()") {
	PlaybackController controller;
	CappedMixSink sink(4096);
	CHECK_FALSE(controller.tick(1.0 / 60.0, WallClockMs(0.0), sink).has_value());

	controller.load(make_stereo_backend(), 0.0);
	controller.play(WallClockMs(0.0));
	CHECK(controller.is_playing());

	controller.stop();
	CHECK_FALSE(controller.is_playing());
	CHECK(controller.position() == doctest::Approx(0.0));

	controller.shutdown();
}

// -----------------------------------------------------------------------
// Track Switch reconcile — the remaining branches. "a mid-stream reselect the
// backend refuses rolls the desired track back" above already covers the
// failure/rollback branch.
// -----------------------------------------------------------------------

TEST_CASE("request_audio_track while stopped applies immediately via select_audio_track (cheap apply)") {
	auto backend = std::make_unique<MultiTrackFakeBackend>(std::vector<MultiTrackFakeBackend::TrackSpec>{
			{ 2, 48000 }, { 2, 48000 } });
	MultiTrackFakeBackend *raw = backend.get();

	PlaybackController controller;
	controller.load(std::move(backend), 0.0);
	CHECK_FALSE(controller.is_playing());

	controller.request_audio_track(1);

	CHECK(controller.desired_audio_track() == 1);
	CHECK(controller.live_audio_track() == 1); // applied immediately, no tick() needed
	CHECK(raw->select_calls() == 1);
	CHECK(raw->reselect_calls() == 0); // the cheap path never touches reselect
	CHECK(controller.take_warnings().empty());

	controller.shutdown();
}

TEST_CASE("a live reselect success converges desired/live, and a converged reconcile is a no-op") {
	auto backend = std::make_unique<MultiTrackFakeBackend>(std::vector<MultiTrackFakeBackend::TrackSpec>{
			{ 2, 48000 }, { 2, 48000 } });
	MultiTrackFakeBackend *raw = backend.get();

	PlaybackController controller;
	controller.load(std::move(backend), 0.0);
	controller.play(WallClockMs(0.0));

	controller.request_audio_track(1); // deferred: applied on the next tick()
	CHECK(controller.desired_audio_track() == 1);
	CHECK(controller.live_audio_track() == 0); // not yet reconciled

	CappedMixSink sink(4096);
	controller.tick(1.0 / 60.0, WallClockMs(16.6), sink); // reconciles: reselect succeeds

	CHECK(controller.desired_audio_track() == 1);
	CHECK(controller.live_audio_track() == 1);
	CHECK(raw->reselect_calls() == 1);
	CHECK(controller.take_warnings().empty());

	// Further ticks: desired == live now, so reconcile_audio_track's own no-op
	// guard must stop it from reselecting again every tick.
	controller.tick(1.0 / 60.0, WallClockMs(33.2), sink);
	controller.tick(1.0 / 60.0, WallClockMs(49.8), sink);
	CHECK(raw->reselect_calls() == 1); // unchanged

	controller.shutdown();
}

TEST_CASE("requesting the already-desired track is a no-op and never touches the backend") {
	auto backend = std::make_unique<MultiTrackFakeBackend>(std::vector<MultiTrackFakeBackend::TrackSpec>{
			{ 2, 48000 }, { 2, 48000 } });
	MultiTrackFakeBackend *raw = backend.get();

	PlaybackController controller;
	controller.load(std::move(backend), 0.0);
	CHECK(raw->select_calls() == 0); // load() had no pending switch to apply

	controller.request_audio_track(0); // already desired -> short-circuits

	CHECK(raw->select_calls() == 0);
	CHECK(raw->reselect_calls() == 0);
	CHECK(controller.take_warnings().empty());

	controller.shutdown();
}

// -----------------------------------------------------------------------
// One-clock rule — the update path in tick() must never double-advance the
// clock across the audio-advanced / audio-exhausted / audio-master gates.
// -----------------------------------------------------------------------

TEST_CASE("one-clock rule: audio-master tick() never adds the render delta on top of accepted audio frames") {
	PlaybackController controller;
	controller.load(make_stereo_backend(), 0.0);
	controller.play(WallClockMs(0.0));

	CappedMixSink sink(/*accept_cap=*/480); // 480 frames @ 48kHz = 10ms of real audio
	// A deliberately huge render delta: if the clock ever added this on top of
	// the accepted-frame accounting, media_time would be off by orders of
	// magnitude (~1s instead of ~10ms).
	controller.tick(/*delta_seconds=*/1.0, WallClockMs(16.6), sink);

	CHECK(controller.media_time() == doctest::Approx(480.0 / 48000.0).epsilon(0.01));

	controller.shutdown();
}

TEST_CASE("one-clock rule: a silent clip advances the clock by exactly the render delta, once per tick") {
	auto backend = std::make_unique<MultiTrackFakeBackend>(std::vector<MultiTrackFakeBackend::TrackSpec>{});
	PlaybackController controller;
	controller.load(std::move(backend), 0.0);
	controller.play(WallClockMs(0.0));

	CappedMixSink sink(4096); // never invoked: no audio track

	controller.tick(0.1, WallClockMs(100.0), sink);
	CHECK(controller.media_time() == doctest::Approx(0.1));
	controller.tick(0.1, WallClockMs(200.0), sink);
	CHECK(controller.media_time() == doctest::Approx(0.2)); // linear, not doubled

	controller.shutdown();
}

TEST_CASE("one-clock rule: audio exhaustion falls back to the render delta exactly once per tick") {
	PlaybackController controller;
	controller.load(std::make_unique<ShortAudioBackend>(/*total_frames=*/100), 0.0);
	controller.play(WallClockMs(0.0));
	AcceptAllMixSink sink;

	// Tick 1: the ring's one real chunk (100 frames) drains in full — the
	// clock advances from real audio accounting only.
	controller.tick(/*delta_seconds=*/1.0 / 60.0, WallClockMs(16.6), sink);
	CHECK(controller.media_time() == doctest::Approx(100.0 / 48000.0).epsilon(0.01));

	// Ticks 2-4: the ring is now empty and EOS'd (audio_exhausted()), so each
	// tick must fall back to exactly one render-delta advance — not zero
	// (stuck), and not doubled by also counting the now-silent audio path.
	controller.tick(0.1, WallClockMs(33.2), sink);
	controller.tick(0.1, WallClockMs(50.0), sink);
	controller.tick(0.1, WallClockMs(66.6), sink);

	CHECK(controller.media_time() == doctest::Approx(100.0 / 48000.0 + 0.3).epsilon(0.01));

	controller.shutdown();
}

// -----------------------------------------------------------------------
// Accepted-vs-real frame accounting. "drive_audio advances the clock by only
// the accepted-and-real frame count" above covers the back-pressure
// direction (accepted < real); this covers the opposite direction (accepted
// counts silence that isn't real).
// -----------------------------------------------------------------------

TEST_CASE("accepted-vs-real: silence offered during underrun is never counted as real audio") {
	PlaybackController controller;
	controller.load(std::make_unique<ShortAudioBackend>(/*total_frames=*/100), 0.0);
	controller.play(WallClockMs(0.0));
	AcceptAllMixSink sink; // accepts every frame offered, including underrun silence

	controller.tick(1.0 / 60.0, WallClockMs(16.6), sink); // drains the one real 100-frame chunk
	const double after_real = controller.media_time();

	// The ring is now empty and EOS'd: drive_audio() offers 256 silent frames
	// and this sink accepts all 256 (accepted == 256), but real_frames == 0 —
	// the clock must advance by the render-delta fallback only, NOT by an
	// extra 256/48000s of "accepted" silence stacked on top of it.
	controller.tick(/*delta_seconds=*/0.1, WallClockMs(33.2), sink);

	CHECK(controller.media_time() == doctest::Approx(after_real + 0.1).epsilon(0.01));

	controller.shutdown();
}

// -----------------------------------------------------------------------
// -----------------------------------------------------------------------
// derive_canonical_mix_format — the pure, scheduler-free half of load().
// These exercise the derivation directly against a mock Backend WITHOUT
// constructing a PlaybackController (and therefore without the
// DecodeScheduler::instance() singleton the controller registers with). They
// are the executable spec the load()-level tests above only approximate.
// -----------------------------------------------------------------------

TEST_CASE("derive_canonical_mix_format: max channel count across tracks; first audio-bearing rate wins") {
	auto backend = std::make_unique<MultiTrackFakeBackend>(std::vector<MultiTrackFakeBackend::TrackSpec>{
			{1, 44100}, // track 0: default -> canonical rate
			{2, 48000}, // track 1: more channels, differing rate
			{6, 44100}, // track 2: matches canonical rate
	});

	const core::CanonicalMixFormat fmt = core::derive_canonical_mix_format(*backend);

	CHECK(fmt.has_audio);
	CHECK(fmt.channels == 6); // max across tracks
	CHECK(fmt.sample_rate == 44100); // first audio-bearing track
	REQUIRE(fmt.track_infos.size() == 3);
	CHECK(fmt.track_infos[2].sample_rate == 44100);
}

TEST_CASE("derive_canonical_mix_format: mixed sample rate warns exactly once, later matching tracks silent") {
	auto backend = std::make_unique<MultiTrackFakeBackend>(std::vector<MultiTrackFakeBackend::TrackSpec>{
			{1, 44100}, {2, 48000}, {6, 44100}, {2, 48000},
	});

	const core::CanonicalMixFormat fmt = core::derive_canonical_mix_format(*backend);

	REQUIRE(fmt.warnings.size() == 1);
	CHECK(fmt.warnings[0].find("differs from the canonical rate") != std::string::npos);
}

TEST_CASE("derive_canonical_mix_format: a silent clip (no tracks) yields no audio and no warnings") {
	auto backend = std::make_unique<MultiTrackFakeBackend>(std::vector<MultiTrackFakeBackend::TrackSpec>{});

	const core::CanonicalMixFormat fmt = core::derive_canonical_mix_format(*backend);

	CHECK_FALSE(fmt.has_audio);
	CHECK(fmt.channels == 0);
	CHECK(fmt.sample_rate == 0);
	CHECK(fmt.warnings.empty());
}

TEST_CASE("derive_canonical_mix_format: channel count clamped to kMaxMixSourceChannels") {
	auto backend = std::make_unique<MultiTrackFakeBackend>(
			std::vector<MultiTrackFakeBackend::TrackSpec>{ { 8, 48000 } }); // 8ch exceeds the 6ch cap

	const core::CanonicalMixFormat fmt = core::derive_canonical_mix_format(*backend);

	CHECK(fmt.channels == core::kMaxMixSourceChannels);
}

TEST_CASE("derive_canonical_mix_format: track metadata without sample-rate audio is still collected") {
	// A track reporting channels but sample_rate==0 is treated as non-audio-
	// bearing (no canonical rate contribution) but still appears in track_infos
	// so mid-stream validation has its metadata.
	auto backend = std::make_unique<MultiTrackFakeBackend>(std::vector<MultiTrackFakeBackend::TrackSpec>{
			{2, 0},
	});

	const core::CanonicalMixFormat fmt = core::derive_canonical_mix_format(*backend);

	CHECK_FALSE(fmt.has_audio);
	CHECK(fmt.sample_rate == 0);
	CHECK(fmt.channels == 2); // channel count is still tracked
	REQUIRE(fmt.track_infos.size() == 1);
}

// Canonical Mix Format. "load() derives the Canonical Mix Format and warns
// once on a mixed sample rate" above covers the first-track-rate and
// one-time-warning branches; this covers the channel clamp and the
// mid-stream switch refusal.
// -----------------------------------------------------------------------

TEST_CASE("load() clamps a track's channel count to kMaxMixSourceChannels") {
	auto backend = std::make_unique<MultiTrackFakeBackend>(
			std::vector<MultiTrackFakeBackend::TrackSpec>{ { 8, 48000 } }); // 8ch exceeds the 6ch cap

	PlaybackController controller;
	controller.load(std::move(backend), 0.0);

	CHECK(controller.canonical_channels() == core::kMaxMixSourceChannels);

	controller.shutdown();
}

TEST_CASE("a mid-stream switch to a differing sample-rate track is refused while playing") {
	auto backend = std::make_unique<MultiTrackFakeBackend>(std::vector<MultiTrackFakeBackend::TrackSpec>{
			{ 2, 48000 }, { 2, 44100 } });

	PlaybackController controller;
	controller.load(std::move(backend), 0.0);
	controller.take_warnings(); // drain load()'s own mixed-sample-rate warning
	controller.play(WallClockMs(0.0));

	controller.request_audio_track(1); // differing rate while playing -> refused

	CHECK(controller.desired_audio_track() == 0); // unchanged
	std::vector<std::string> warnings = controller.take_warnings();
	REQUIRE(warnings.size() == 1);
	CHECK(warnings[0].find("Rejecting switch") != std::string::npos);

	controller.shutdown();
}

TEST_CASE("a switch to a differing sample-rate track is allowed while stopped") {
	auto backend = std::make_unique<MultiTrackFakeBackend>(std::vector<MultiTrackFakeBackend::TrackSpec>{
			{ 2, 48000 }, { 2, 44100 } });

	PlaybackController controller;
	controller.load(std::move(backend), 0.0);
	controller.take_warnings(); // drain load()'s own mixed-sample-rate warning
	CHECK_FALSE(controller.is_playing());

	controller.request_audio_track(1); // stopped: no live audio path to disturb

	CHECK(controller.desired_audio_track() == 1);
	CHECK(controller.live_audio_track() == 1);
	CHECK(controller.take_warnings().empty());

	controller.shutdown();
}

// -----------------------------------------------------------------------
// Scrub resolve — apply_scrub_resolve()'s keyframe-vs-exact branch, the
// epsilon tolerance on its forward-decode spin, the bounded-spin stall guard,
// and the settled-frame outcome. Driven through PlaybackController::seek()/
// tick() and the real scheduler seam (video-only ScrubGridBackend /
// ExactPtsBackend fixtures above), not the Scrubber unit directly — that is
// already covered by test_scrubber.cpp.
// -----------------------------------------------------------------------

TEST_CASE("seek(): a fast burst resolves Keyframe with no forward-decode drops; a lone seek resolves Exact") {
	// Target deliberately near the END of a GOP so an Exact resolve must
	// decode nearly a full GOP forward, while a Keyframe resolve stops dead at
	// the keyframe — the same margin test_scrubber.cpp uses to prove the gap
	// between the two modes is real, not incidental.
	const double target = (kScrubGopFrames - 1) / double(kScrubFps) + 20.0;

	// --- Exact: a lone seek (no prior scrub history) always resolves Exact. ---
	std::atomic<int> exact_drops{ 0 };
	{
		PlaybackController controller;
		controller.load(std::make_unique<ScrubGridBackend>(&exact_drops), 0.0);
		controller.seek(target, WallClockMs(0.0));
		controller.shutdown();
	}
	CHECK(exact_drops.load() >= kScrubGopFrames / 2); // decoded forward across most of a GOP

	// --- Keyframe: priming, then a fast in-burst follow-up seek. ---
	std::atomic<int> kf_drops{ 0 };
	{
		PlaybackController controller;
		controller.load(std::make_unique<ScrubGridBackend>(&kf_drops), 0.0);
		controller.seek(1.0, WallClockMs(0.0)); // prime (Exact, trivial forward decode)
		kf_drops.store(0); // isolate the SECOND (Keyframe) resolve only
		controller.seek(target, WallClockMs(20.0)); // 20ms later, huge jump -> fast drag -> Keyframe
		controller.shutdown();
	}
	// Keyframe skips the forward-decode spin entirely; only request_seek's own
	// bounded queue flush (whatever was already decode-ahead-buffered) can
	// contribute here, so this is capped by the decode-ahead queue's capacity.
	CHECK(kf_drops.load() <= static_cast<int>(core::kDecodeAheadCapacity));
}

TEST_CASE("the exact-resolve spin treats a frame within epsilon of the target as arrived") {
	constexpr double kSpinEps = 1.0 / 120.0; // mirrors apply_scrub_resolve()'s tolerance
	const double target = 10.0;

	// A frame within epsilon of the target is NOT dropped — the spin stops
	// immediately and leaves it for the present step.
	std::atomic<int> drops_in_tolerance{ 0 };
	{
		PlaybackController controller;
		controller.load(std::make_unique<ExactPtsBackend>(
									std::vector<double>{ target - kSpinEps * 0.5 }, &drops_in_tolerance),
				0.0);
		controller.seek(target, WallClockMs(0.0));
		// Check before shutdown(): unregister_stream() releases whatever frame
		// the spin left buffered (the in-tolerance survivor), which would
		// otherwise inflate this count by one after the fact.
		CHECK(drops_in_tolerance.load() == 0);
		controller.shutdown();
	}

	// A frame outside epsilon IS dropped; the spin then stops at the next
	// frame, which is within tolerance.
	std::atomic<int> drops_out_of_tolerance{ 0 };
	{
		PlaybackController controller;
		controller.load(std::make_unique<ExactPtsBackend>(
									std::vector<double>{ target - kSpinEps * 2.0, target - kSpinEps * 0.5 },
									&drops_out_of_tolerance),
				0.0);
		controller.seek(target, WallClockMs(0.0));
		CHECK(drops_out_of_tolerance.load() == 1);
		controller.shutdown();
	}
}

TEST_CASE("seek() past end-of-stream terminates the exact-resolve spin instead of hanging (bounded spin)") {
	std::atomic<int> drops{ 0 };
	PlaybackController controller;
	controller.load(std::make_unique<ScrubGridBackend>(&drops), 0.0);

	// Lone seek -> Exact. The target is far beyond the clip's duration, so the
	// backend reports EOS immediately after the reseek and the forward-decode
	// spin must give up via at_end() rather than hang waiting for a frame that
	// will never arrive.
	const auto start = std::chrono::steady_clock::now();
	controller.seek(kScrubTotalFrames / double(kScrubFps) + 1000.0, WallClockMs(0.0));
	const auto elapsed = std::chrono::steady_clock::now() - start;

	CHECK(elapsed < std::chrono::seconds(5)); // bounded, not hung

	controller.shutdown();
}

TEST_CASE("after a drag burst settles, the next tick presents the exact settled target frame") {
	std::atomic<int> drops{ 0 };
	PlaybackController controller;
	controller.load(std::make_unique<ScrubGridBackend>(&drops), 0.0);
	controller.play(WallClockMs(0.0));

	// Frame-aligned targets sidestep the present-selector's own half-frame
	// tolerance landing on a coin-flip between two adjacent frames.
	const double last_target = 400.0 / kScrubFps;
	controller.seek(100.0 / kScrubFps, WallClockMs(1000.0)); // prime -> Exact
	controller.seek(300.0 / kScrubFps, WallClockMs(1020.0)); // fast -> Keyframe
	controller.seek(last_target, WallClockMs(1040.0)); // fast -> Keyframe (approximate frame on screen)

	CappedMixSink sink(0); // never invoked: this backend carries no audio
	// 150ms later (past the 100ms settle debounce): the pending settle fires
	// inside this tick() and resolves Exact to the last drag target. delta_seconds
	// is kept tiny: tick() advances the (monotonic, silent-clip) clock by it AFTER
	// the settle resolve, and a full 1/60s delta would push `now` to within the
	// present selector's own half-frame tolerance of the NEXT frame too — a
	// coincidental tie this fixture's frame-aligned target would otherwise hit.
	std::optional<VideoFrame> frame = controller.tick(/*delta_seconds=*/0.001, WallClockMs(1190.0), sink);

	REQUIRE(frame.has_value());
	CHECK(frame->pts_seconds == doctest::Approx(last_target));

	controller.shutdown();
}
