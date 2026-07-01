#include "vendor/doctest.h"

#include "../../src/core/backend.h"
#include "../../src/core/channel_mixer.h"

#include <memory>
#include <vector>

using core::AudioChunk;
using core::AudioTrackInfo;
using core::Backend;
using core::PixelFormat;
using core::VideoFrame;

// -----------------------------------------------------------------------
// MarkerClipBackend — simulates a clip with mixed audio track channel
// counts (e.g. a stereo commentary track + a 5.1 surround main track).
//
// Track 0: stereo (2 ch, 48000 Hz)
// Track 1: 5.1    (6 ch, 48000 Hz)
//
// Each track produces deterministic audio chunks when pumped. This lets
// us verify that after track selection the canonical channel count is
// independent of which track is selected — the channel mixer converts
// whichever native format the backend emits.
// -----------------------------------------------------------------------
class MarkerClipBackend : public Backend {
public:
	static constexpr int kTrackCount = 2;

	MarkerClipBackend() = default;

	bool open(const std::string &) override { return true; }
	void close() override {}

	double duration_seconds() const override { return 10.0; }
	int video_width() const override { return 1920; }
	int video_height() const override { return 1080; }

	// Legacy single-track fields return track 0 (stereo).
	int audio_channel_count() const override {
		return tracks_[0].channels;
	}
	int audio_sample_rate() const override {
		return tracks_[0].sample_rate;
	}

	int audio_track_count() const override { return kTrackCount; }

	AudioTrackInfo audio_track_info(int index) const override {
		if (index < 0 || index >= kTrackCount) {
			return {};
		}
		AudioTrackInfo info;
		info.channels = tracks_[index].channels;
		info.sample_rate = tracks_[index].sample_rate;
		info.language = index == 0 ? "en" : "en";
		info.name = index == 0 ? "Commentary (Stereo)" : "Main (5.1)";
		info.is_default = index == 0;
		return info;
	}

	void select_audio_track(int index) override {
		selected_ = index;
	}

	bool seek(double) override {
		chunks_pumped_ = 0;
		return true;
	}

	std::optional<VideoFrame> next_video_frame() override {
		return std::nullopt; // video not needed for this test
	}

	std::optional<AudioChunk> next_audio_chunk() override {
		const int track = selected_;
		if (track < 0 || track >= kTrackCount) {
			return std::nullopt;
		}
		const int ch = tracks_[track].channels;
		const int rate = tracks_[track].sample_rate;
		const int frames = 256; // arbitrary chunk size

		// Produce a deterministic, recognisable pattern: each channel gets
		// a distinct value so we can verify the mixer output.
		const size_t n = static_cast<size_t>(frames) * static_cast<size_t>(ch);
		scratch_.resize(n);
		for (int f = 0; f < frames; ++f) {
			for (int c = 0; c < ch; ++c) {
				// Unique per-channel value: encode channel number in the lowest bits
				// so the mixer's output channel assignment is verifiable.
				scratch_[static_cast<size_t>(f) * static_cast<size_t>(ch) + static_cast<size_t>(c)] =
						0.1f * static_cast<float>(c + 1) + 0.01f * static_cast<float>(chunks_pumped_);
			}
		}
		++chunks_pumped_;

		AudioChunk chunk;
		chunk.samples = scratch_.data();
		chunk.frame_count = frames;
		chunk.channel_count = ch;
		chunk.sample_rate = rate;
		chunk.pts_seconds = static_cast<double>(chunks_pumped_) * 0.01;
		return chunk;
	}

	int selected_track() const { return selected_; }

private:
	struct TrackInfo {
		int channels = 0;
		int sample_rate = 0;
	};

	TrackInfo tracks_[kTrackCount] = {
		{ 2, 48000 }, // Track 0: stereo
		{ 6, 48000 }, // Track 1: 5.1
	};

	int selected_ = 0;
	int chunks_pumped_ = 0;
	std::vector<float> scratch_;
};

// -----------------------------------------------------------------------
// Test: canonical format from MarkerClip is max across tracks (6 ch / 48k)
// -----------------------------------------------------------------------

TEST_CASE("MarkerClip canonical channels is max across tracks") {
	MarkerClipBackend backend;
	REQUIRE(backend.open("dummy"));

	int max_ch = 0;
	int max_rate = 0;
	for (int i = 0; i < backend.audio_track_count(); ++i) {
		auto info = backend.audio_track_info(i);
		if (info.channels > max_ch)
			max_ch = info.channels;
		if (info.sample_rate > max_rate)
			max_rate = info.sample_rate;
	}

	// The canonical format is the max across all tracks.
	CHECK(max_ch == 6);   // 5.1 track
	CHECK(max_rate == 48000);

	// The mixer knows how to handle this.
	CHECK(max_ch <= core::kMaxMixSourceChannels);
}

// -----------------------------------------------------------------------
// Test: with track 0 (stereo) selected, mixer converts 2ch -> 6ch
// -----------------------------------------------------------------------

TEST_CASE("MarkerClip stereo track pumps 2ch chunks; mixer converts to 6ch") {
	MarkerClipBackend backend;
	REQUIRE(backend.open("dummy"));

	const int canonical = 6; // max across tracks

	backend.select_audio_track(0); // stereo
	backend.seek(0.0);

	// Pump a chunk from the backend (native stereo).
	auto chunk = backend.next_audio_chunk();
	REQUIRE(chunk.has_value());
	CHECK(chunk->channel_count == 2);
	CHECK(chunk->frame_count == 256);
	CHECK(chunk->sample_rate == 48000);

	// Mix from native (2ch) to canonical (6ch).
	std::vector<float> mixed(static_cast<size_t>(chunk->frame_count) * static_cast<size_t>(canonical), 0.0f);
	core::mix_channels(chunk->samples, chunk->channel_count,
			mixed.data(), canonical, chunk->frame_count);

	// Stereo -> 5.1: L -> L, R -> R; C, LFE, Ls, Rs should be silence.
	// Channel 0 (L) in stereo -> channel 0 (L) in 5.1
	// Channel 1 (R) in stereo -> channel 1 (R) in 5.1
	// For the first chunk (chunks_pumped_ = 0), values are 0.1 and 0.2.
	const float expected_L = 0.1f;
	const float expected_R = 0.2f;

	// Check first frame.
	CHECK(mixed[0] == doctest::Approx(expected_L)); // L
	CHECK(mixed[1] == doctest::Approx(expected_R)); // R
	CHECK(mixed[2] == doctest::Approx(0.0f));       // C (silence)
	CHECK(mixed[3] == doctest::Approx(0.0f));       // LFE (silence)
	CHECK(mixed[4] == doctest::Approx(0.0f));       // Ls (silence)
	CHECK(mixed[5] == doctest::Approx(0.0f));       // Rs (silence)
}

// -----------------------------------------------------------------------
// Test: with track 1 (5.1) selected, mixer passes through 6ch -> 6ch
// -----------------------------------------------------------------------

TEST_CASE("MarkerClip 5.1 track pumps 6ch chunks; mixer passes through") {
	MarkerClipBackend backend;
	REQUIRE(backend.open("dummy"));

	const int canonical = 6; // max across tracks

	backend.select_audio_track(1); // 5.1
	backend.seek(0.0);

	// Pump a chunk from the backend (native 6ch).
	auto chunk = backend.next_audio_chunk();
	REQUIRE(chunk.has_value());
	CHECK(chunk->channel_count == 6);
	CHECK(chunk->frame_count == 256);

	// Mix from native (6ch) to canonical (6ch) — this is identity.
	std::vector<float> mixed(static_cast<size_t>(chunk->frame_count) * static_cast<size_t>(canonical), 0.0f);
	core::mix_channels(chunk->samples, chunk->channel_count,
			mixed.data(), canonical, chunk->frame_count);

	// For the first chunk, values are 0.1, 0.2, 0.3, 0.4, 0.5, 0.6
	CHECK(mixed[0] == doctest::Approx(0.1f)); // L
	CHECK(mixed[1] == doctest::Approx(0.2f)); // R
	CHECK(mixed[2] == doctest::Approx(0.3f)); // C
	CHECK(mixed[3] == doctest::Approx(0.4f)); // LFE
	CHECK(mixed[4] == doctest::Approx(0.5f)); // Ls
	CHECK(mixed[5] == doctest::Approx(0.6f)); // Rs

	// Verify the second frame as well.
	CHECK(mixed[6] == doctest::Approx(0.1f));
	CHECK(mixed[7] == doctest::Approx(0.2f));
	CHECK(mixed[8] == doctest::Approx(0.3f));
	CHECK(mixed[9] == doctest::Approx(0.4f));
	CHECK(mixed[10] == doctest::Approx(0.5f));
	CHECK(mixed[11] == doctest::Approx(0.6f));
}

// -----------------------------------------------------------------------
// Test: verify the two tracks produce different native chunk sizes
// -----------------------------------------------------------------------

TEST_CASE("MarkerClip track selection changes native channel count") {
	MarkerClipBackend backend;
	REQUIRE(backend.open("dummy"));

	// Track 0 (stereo) -> 2ch chunks
	backend.select_audio_track(0);
	backend.seek(0.0);
	auto ch0 = backend.next_audio_chunk();
	REQUIRE(ch0.has_value());
	CHECK(ch0->channel_count == 2);

	// Track 1 (5.1) -> 6ch chunks
	backend.select_audio_track(1);
	backend.seek(0.0);
	auto ch1 = backend.next_audio_chunk();
	REQUIRE(ch1.has_value());
	CHECK(ch1->channel_count == 6);
}