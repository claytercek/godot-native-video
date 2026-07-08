#include "vendor/doctest.h"

#include "../../src/core/playback_controller.h"

#include <algorithm>
#include <memory>
#include <optional>
#include <string>
#include <vector>

using core::AudioChunk;
using core::AudioTrackInfo;
using core::Backend;
using core::MixSink;
using core::PlaybackController;
using core::VideoFrame;

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

	void select_audio_track(int index) override { live_track_ = index; }

	bool reselect_audio_track(int index, double /*pts_seconds*/) override {
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

private:
	std::vector<TrackSpec> tracks_;
	int chunk_frames_;
	int next_index_ = 0;
	int live_track_ = 0;
	bool reselect_should_succeed_ = true;
	std::vector<float> samples_;
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
	controller.play(/*now_ms=*/0.0);

	// The sink accepts far fewer frames than fill_audio() will have topped
	// the ring up with, so the clock must advance by exactly the accepted
	// count (mix back-pressure), never the full offered/available amount.
	CappedMixSink sink(/*accept_cap=*/100);
	std::optional<VideoFrame> frame = controller.tick(/*delta_seconds=*/1.0 / 60.0, /*now_ms=*/16.6, sink);
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
	controller.play(0.0);

	controller.request_audio_track(1); // deferred: applied on the next tick()
	CHECK(controller.desired_audio_track() == 1);

	CappedMixSink sink(4096);
	controller.tick(1.0 / 60.0, 16.6, sink);

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
	CHECK_FALSE(controller.tick(1.0 / 60.0, 0.0, sink).has_value());

	controller.load(make_stereo_backend(), 0.0);
	controller.play(0.0);
	CHECK(controller.is_playing());

	controller.stop();
	CHECK_FALSE(controller.is_playing());
	CHECK(controller.position() == doctest::Approx(0.0));

	controller.shutdown();
}
