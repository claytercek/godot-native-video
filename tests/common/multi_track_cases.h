#pragma once
// -----------------------------------------------------------------------
// multi_track_cases.h — shared TEST_CASE bodies for the synthetic
// multi-track-fixture coverage in tests/avf/test_avf_backend.mm and
// tests/mf/test_mf_backend.cpp. Both platform files generate the same
// 6-frame/3-fps/3-track fixture (tools/gen_test_media.sh --multi-track 3)
// and drive it through their own core::Backend implementation, asserting
// the same audio-track enumeration / selection / reselect contract. Each
// platform TU wraps these templates in a thin TEST_CASE that instantiates
// with its own backend type, so doctest registration and per-platform test
// names stay in the platform files.
//
// Fixture generation itself (ensure_multi_track_fixture) stays per-platform:
// beyond the fixture filename suffix, the shell invocation genuinely differs
// (POSIX `command -v` + /dev/null vs. Windows `where` + NUL + an explicit
// `bash` prefix), so there is nothing to share there beyond these constants.
// -----------------------------------------------------------------------

#include "vendor/doctest.h"

#include "backend.h"

#include <cstddef>
#include <string>
#include <vector>

namespace multi_track_cases {

// Multi-track fixture shape: 6 frames at 3 fps, 3 audio streams with
// disjoint frequency bands. Identical on both platforms.
constexpr int kMultiFrames = 6;
constexpr int kMultiFps = 3;
constexpr int kMultiTracks = 3;

// -----------------------------------------------------------------------
// Sync Ladder track identification for the multi-track fixture.
//
// tools/multitrack_lib.sh encodes each track k's frame i as a sine tone at
// (k * kTrackStrideHz + kTrackBaseHz) + 200 * i Hz — disjoint, widely-spaced
// bands per track (track 0: ~200-1200 Hz, track 1: ~3200-4200 Hz, track 2:
// ~6200-7200 Hz for this fixture's kMultiFrames). The gaps between bands are
// thousands of Hz, so a coarse zero-crossing frequency estimate is enough to
// identify which track produced a stretch of decoded PCM — no FFT needed.
// -----------------------------------------------------------------------
constexpr int kTrackStrideHz = 3000;
constexpr int kTrackBaseHz = 200;

inline double estimate_dominant_frequency_hz(const std::vector<float> &mono_samples, int sample_rate) {
	if (mono_samples.size() < 2 || sample_rate <= 0) {
		return 0.0;
	}
	int crossings = 0;
	for (std::size_t i = 1; i < mono_samples.size(); ++i) {
		if ((mono_samples[i - 1] < 0.0f) != (mono_samples[i] < 0.0f)) {
			++crossings;
		}
	}
	const double duration = static_cast<double>(mono_samples.size()) / sample_rate;
	return duration > 0.0 ? (crossings / 2.0) / duration : 0.0;
}

// True if `freq_hz` falls within track `track`'s Sync Ladder band, with a
// margin generous enough to absorb the zero-crossing estimate's error.
inline bool frequency_in_track_band(double freq_hz, int track) {
	const double lo = track * kTrackStrideHz + kTrackBaseHz - 300.0;
	const double hi = track * kTrackStrideHz + kTrackBaseHz + 200.0 * (kMultiFrames - 1) + 300.0;
	return freq_hz >= lo && freq_hz <= hi;
}

// Accumulate at least `min_seconds` of channel-0 samples from `backend`'s
// audio stream (fewer at end-of-stream). Deinterleaves channel 0 out of each
// chunk's frame-major PCM.
template <typename Backend>
std::vector<float> accumulate_mono_audio(Backend &backend, int sample_rate, double min_seconds) {
	std::vector<float> mono;
	const std::size_t target = static_cast<std::size_t>(static_cast<double>(sample_rate) * min_seconds);
	while (mono.size() < target) {
		auto chunk = backend.next_audio_chunk();
		if (!chunk) {
			break;
		}
		const int channels = chunk->channel_count > 0 ? chunk->channel_count : 1;
		for (int i = 0; i < chunk->frame_count; ++i) {
			mono.push_back(chunk->samples[static_cast<std::size_t>(i) * channels]);
		}
	}
	return mono;
}

// run_multi_track_enumeration_case — "<platform> backend enumerates audio
// tracks for multi-track clip".
//
// `check_track0` is a genuine per-platform behavior: AVF's AudioTrackInfo
// never populates `name` (v1 leaves it empty on every platform call), while
// MF synthesizes "Track N (lang)" — see the single-track enumeration test in
// each platform file, which is not shared because its assertions differ too
// much to templatize usefully. Here MF passes a no-op; AVF asserts
// `t0.name.empty()`.
template <typename Backend, typename CheckTrack0>
void run_multi_track_enumeration_case(const std::string &fixture, CheckTrack0 check_track0) {
	if (fixture.empty()) {
		WARN_MESSAGE(false, "ffmpeg unavailable or fixture generation failed — skipping multi-track audio enumeration");
		return;
	}

	Backend backend;
	REQUIRE(backend.open(fixture));

	CHECK(backend.audio_track_count() == kMultiTracks);

	// Track 0: eng, default — indices follow container track order.
	const auto t0 = backend.audio_track_info(0);
	CHECK(t0.language == "eng");
	CHECK(t0.is_default == true);
	CHECK(t0.channels >= 1);
	CHECK(t0.sample_rate == 48000);
	check_track0(t0);

	// Track 1: fra, non-default
	const auto t1 = backend.audio_track_info(1);
	CHECK(t1.language == "fra");
	CHECK(t1.is_default == false);
	CHECK(t1.channels >= 1);
	CHECK(t1.sample_rate == 48000);

	// Track 2: deu, non-default
	const auto t2 = backend.audio_track_info(2);
	CHECK(t2.language == "deu");
	CHECK(t2.is_default == false);

	// Out-of-range: empty struct.
	const auto t99 = backend.audio_track_info(99);
	CHECK(t99.channels == 0);
	CHECK(t99.language.empty());
	CHECK(t99.sample_rate == 0);
	CHECK(t99.is_default == false);
}

// run_preplay_selection_case — "<platform> backend selects audio track
// pre-play for multi-track clip". Identical on both platforms:
// select_audio_track() is deferred until the next seek()/open() by the
// Backend contract, so both call seek(0.0) before decoding.
template <typename Backend>
void run_preplay_selection_case(const std::string &fixture) {
	if (fixture.empty()) {
		WARN_MESSAGE(false, "ffmpeg unavailable or fixture generation failed -- skipping multi-track selection");
		return;
	}

	// ---- Open with default (track 0), verify default metadata ----
	Backend backend;
	REQUIRE(backend.open(fixture));
	CHECK(backend.audio_track_count() == kMultiTracks);
	const auto t0 = backend.audio_track_info(0);
	CHECK(t0.language == "eng");
	CHECK(t0.is_default == true);
	CHECK(t0.channels >= 1);
	CHECK(t0.sample_rate == 48000);

	// ---- Select track 1 and verify audio decoding ----
	REQUIRE(backend.open(fixture));
	backend.select_audio_track(1);

	// Verify the metadata still reports track 1 correctly.
	const auto t1_check = backend.audio_track_info(1);
	CHECK(t1_check.language == "fra");
	CHECK(t1_check.is_default == false);
	CHECK(t1_check.channels >= 1);
	CHECK(t1_check.sample_rate == 48000);

	// select_audio_track() takes effect on the next seek()/open() (Backend
	// contract) rather than immediately, so seek before decoding.
	REQUIRE(backend.seek(0.0));

	// Decode audio from the selected track and verify valid PCM output.
	int audio_chunks = 0;
	long audio_frames_total = 0;
	double last_audio_pts = -1.0;
	while (auto chunk = backend.next_audio_chunk()) {
		CHECK(chunk->samples != nullptr);
		CHECK(chunk->frame_count > 0);
		CHECK(chunk->channel_count >= 1);
		CHECK(chunk->sample_rate == 48000);
		CHECK(chunk->pts_seconds >= last_audio_pts);
		last_audio_pts = chunk->pts_seconds;
		audio_frames_total += chunk->frame_count;
		++audio_chunks;
	}
	CHECK_FALSE(backend.had_error());
	CHECK(audio_chunks > 0);
	const long nominal = static_cast<long>(48000.0 * kMultiFrames / kMultiFps);
	CHECK(audio_frames_total >= nominal / 2);

	// ---- Out-of-range selection falls back to default ----
	// The backend clamps to the nearest valid index (0 for negative, count-1
	// for too-large). Track 0 is the default and should produce valid PCM.
	REQUIRE(backend.open(fixture));
	backend.select_audio_track(99); // out of range
	CHECK(backend.audio_channel_count() >= 1);
	CHECK(backend.audio_sample_rate() == 48000);
	REQUIRE(backend.seek(0.0));

	// Decode should still produce valid PCM from the fallback.
	audio_chunks = 0;
	audio_frames_total = 0;
	while (auto chunk = backend.next_audio_chunk()) {
		CHECK(chunk->samples != nullptr);
		CHECK(chunk->frame_count > 0);
		audio_frames_total += chunk->frame_count;
		++audio_chunks;
	}
	CHECK_FALSE(backend.had_error());
	CHECK(audio_chunks > 0);
	CHECK(audio_frames_total >= nominal / 2);
}

// run_midstream_reselect_case — "<platform> backend reselects audio track
// mid-decode without disturbing video".
template <typename Backend>
void run_midstream_reselect_case(const std::string &fixture) {
	if (fixture.empty()) {
		WARN_MESSAGE(false, "ffmpeg unavailable or fixture generation failed -- skipping reselect test");
		return;
	}

	Backend backend;
	REQUIRE(backend.open(fixture));
	CHECK(backend.audio_track_count() == kMultiTracks);

	// --- Decode some video + audio frames from track 0 ---
	double last_video_pts = -1.0;
	for (int i = 0; i < 4; ++i) {
		auto frame = backend.next_video_frame();
		REQUIRE(frame.has_value());
		CHECK(frame->pts_seconds >= last_video_pts);
		last_video_pts = frame->pts_seconds;
		frame->release();
	}

	int audio_pre = 0;
	double last_audio_pts = -1.0;
	while (auto chunk = backend.next_audio_chunk()) {
		CHECK(chunk->pts_seconds >= last_audio_pts);
		last_audio_pts = chunk->pts_seconds;
		++audio_pre;
		if (audio_pre >= 3) {
			break;
		}
	}
	CHECK(audio_pre >= 3);
	CHECK_FALSE(backend.had_error());

	// --- Reselect to track 1 at current position ---
	double reselect_time = last_video_pts;
	REQUIRE(backend.reselect_audio_track(1, reselect_time));

	// --- Video keeps flowing after reselect ---
	int video_post = 0;
	last_video_pts = -1.0;
	while (auto frame = backend.next_video_frame()) {
		CHECK(frame->pixel_format == core::PixelFormat::NV12);
		CHECK(frame->native_handle != nullptr);
		CHECK(frame->pts_seconds >= last_video_pts);
		last_video_pts = frame->pts_seconds;
		frame->release();
		++video_post;
		if (video_post >= 3) {
			break;
		}
	}
	CHECK(video_post >= 1);

	// --- Audio from the new track ---
	int audio_post = 0;
	last_audio_pts = -1.0;
	while (auto chunk = backend.next_audio_chunk()) {
		CHECK(chunk->samples != nullptr);
		CHECK(chunk->frame_count > 0);
		CHECK(chunk->channel_count >= 1);
		CHECK(chunk->sample_rate == 48000);
		CHECK(chunk->pts_seconds >= last_audio_pts);
		last_audio_pts = chunk->pts_seconds;
		++audio_post;
		if (audio_post >= 3) {
			break;
		}
	}
	CHECK(audio_post >= 1);
	CHECK_FALSE(backend.had_error());

	// --- Drain remaining video + audio to verify no errors ---
	while (auto frame = backend.next_video_frame()) {
		CHECK(frame->pts_seconds >= last_video_pts);
		last_video_pts = frame->pts_seconds;
		frame->release();
	}
	while (auto chunk = backend.next_audio_chunk()) {
		CHECK(chunk->pts_seconds >= last_audio_pts);
		last_audio_pts = chunk->pts_seconds;
	}
	CHECK_FALSE(backend.had_error());
}

// run_near_end_reselect_case — "<platform> backend reselects audio track
// near end-of-stream".
//
// The post-reselect video PTS bound is a genuine per-platform behavior, not
// a copy-paste artifact: AVF resumes video decode near the seek target after
// reselect_audio_track(), so it asserts the first post-reselect frame stays
// close to `near_end` (an upper bound). MF's reader position is left
// untouched by reselect, so video simply continues from wherever it already
// was (a lower bound only, unbounded above). `check_pts_bound` carries the
// platform-specific assertion — see the other platform's call site for the
// mirror-image check.
template <typename Backend, typename PtsBoundCheck>
void run_near_end_reselect_case(const std::string &fixture, PtsBoundCheck check_pts_bound) {
	if (fixture.empty()) {
		WARN_MESSAGE(false, "ffmpeg unavailable or fixture generation failed -- skipping end-of-stream reselect test");
		return;
	}

	Backend backend;
	REQUIRE(backend.open(fixture));

	// Drain video to end-of-stream.
	int video_total = 0;
	while (auto frame = backend.next_video_frame()) {
		frame->release();
		++video_total;
	}
	CHECK(video_total >= kMultiFrames - 1);
	CHECK_FALSE(backend.had_error());

	// Re-open and reselect near end.
	REQUIRE(backend.open(fixture));
	const double near_end = static_cast<double>(kMultiFrames) / static_cast<double>(kMultiFps) - 0.5;
	REQUIRE(backend.seek(near_end));

	// Reselect to track 1 near end-of-stream.
	REQUIRE(backend.reselect_audio_track(1, near_end));

	// Video still flows after reselect.
	int video_after = 0;
	double first_video_pts = -1.0;
	while (auto frame = backend.next_video_frame()) {
		if (first_video_pts < 0.0) {
			first_video_pts = frame->pts_seconds;
		}
		frame->release();
		++video_after;
	}
	CHECK(first_video_pts >= 0.0);
	check_pts_bound(first_video_pts, near_end);
	CHECK(video_after >= 1);

	// Audio from the new track.
	int audio_after = 0;
	while (auto chunk = backend.next_audio_chunk()) {
		CHECK(chunk->samples != nullptr);
		CHECK(chunk->frame_count > 0);
		++audio_after;
	}
	CHECK(audio_after >= 1);
	CHECK_FALSE(backend.had_error());
}

// run_same_track_reselect_case — "<platform> backend reselect to same track
// is valid".
template <typename Backend>
void run_same_track_reselect_case(const std::string &fixture) {
	if (fixture.empty()) {
		WARN_MESSAGE(false, "ffmpeg unavailable or fixture generation failed -- skipping same-track reselect test");
		return;
	}

	Backend backend;
	REQUIRE(backend.open(fixture));

	// Decode a few frames.
	auto frame = backend.next_video_frame();
	REQUIRE(frame.has_value());
	frame->release();

	auto chunk = backend.next_audio_chunk();
	REQUIRE(chunk.has_value());

	// Reselect to the same track at the current position.
	REQUIRE(backend.reselect_audio_track(0, chunk->pts_seconds));

	// Video still flows.
	int video_count = 0;
	while (auto f = backend.next_video_frame()) {
		f->release();
		++video_count;
	}
	CHECK(video_count >= 1);

	// Audio from the reselected (same) track.
	int audio_count = 0;
	while (auto ac = backend.next_audio_chunk()) {
		CHECK(ac->samples != nullptr);
		CHECK(ac->frame_count > 0);
		++audio_count;
	}
	CHECK(audio_count >= 1);
	CHECK_FALSE(backend.had_error());
}

// run_reselect_clamp_case — "<platform> backend reselect clamps
// out-of-range index".
template <typename Backend>
void run_reselect_clamp_case(const std::string &fixture) {
	if (fixture.empty()) {
		WARN_MESSAGE(false, "ffmpeg unavailable or fixture generation failed -- skipping reselect clamp test");
		return;
	}

	Backend backend;
	REQUIRE(backend.open(fixture));

	// Decode one video frame.
	auto frame = backend.next_video_frame();
	REQUIRE(frame.has_value());
	frame->release();

	// Out-of-range index should clamp and succeed.
	REQUIRE(backend.reselect_audio_track(99, 0.0));

	// Video still flows.
	int video_count = 0;
	while (auto f = backend.next_video_frame()) {
		f->release();
		++video_count;
	}
	CHECK(video_count >= 1);
	CHECK_FALSE(backend.had_error());

	// Audio from the clamped track (last valid track, kMultiTracks-1).
	int audio_count = 0;
	while (auto ac = backend.next_audio_chunk()) {
		CHECK(ac->samples != nullptr);
		++audio_count;
	}
	CHECK(audio_count >= 1);
	CHECK_FALSE(backend.had_error());
}

// run_defers_select_until_seek_case — "<platform> backend defers
// select_audio_track() until the next seek". Cross-platform regression: the
// Backend contract defers the selection itself to the next seek()/open() on
// both platforms (see run_preplay_selection_case above).
template <typename Backend>
void run_defers_select_until_seek_case(const std::string &fixture) {
	if (fixture.empty()) {
		WARN_MESSAGE(false, "ffmpeg unavailable or fixture generation failed -- skipping deferred selection regression");
		return;
	}

	Backend backend;
	REQUIRE(backend.open(fixture));

	backend.select_audio_track(1);

	// The metadata effect of select_audio_track() (channel count / sample
	// rate for the newly selected track) is immediate even though the shared
	// reader isn't reconfigured until the next seek()/open() -- the Backend
	// contract defers the selection itself.
	const auto t1 = backend.audio_track_info(1);
	CHECK(backend.audio_channel_count() == t1.channels);
	CHECK(backend.audio_sample_rate() == t1.sample_rate);

	// The selection itself only takes effect on the next seek().
	REQUIRE(backend.seek(0.0));

	const std::vector<float> mono = accumulate_mono_audio(backend, backend.audio_sample_rate(), 0.15);
	REQUIRE(mono.size() > 1);
	const double freq = estimate_dominant_frequency_hz(mono, backend.audio_sample_rate());
	CAPTURE(freq);
	CHECK(frequency_in_track_band(freq, 1));
	CHECK_FALSE(frequency_in_track_band(freq, 0));
	CHECK_FALSE(frequency_in_track_band(freq, 2));
	CHECK_FALSE(backend.had_error());
}

// run_reselect_keeps_across_seek_case — "<platform> backend keeps a
// reselected audio track across a later seek". Cross-platform regression:
// seek() must not silently drop a mid-decode reselect back to track 0.
template <typename Backend>
void run_reselect_keeps_across_seek_case(const std::string &fixture) {
	if (fixture.empty()) {
		WARN_MESSAGE(false, "ffmpeg unavailable or fixture generation failed -- skipping reselect+seek regression");
		return;
	}

	Backend backend;
	REQUIRE(backend.open(fixture));

	// Decode a bit of video + track-0 audio, same setup as the mid-decode
	// reselect tests above.
	double last_video_pts = -1.0;
	for (int i = 0; i < 2; ++i) {
		auto frame = backend.next_video_frame();
		REQUIRE(frame.has_value());
		last_video_pts = frame->pts_seconds;
		frame->release();
	}
	auto pre_chunk = backend.next_audio_chunk();
	REQUIRE(pre_chunk.has_value());

	REQUIRE(backend.reselect_audio_track(1, last_video_pts));

	// seek() tears down the dedicated reselect reader and re-homes audio onto
	// the shared reader; selected/applied bookkeeping must keep the
	// reselected track (1) rather than silently falling back to track 0.
	REQUIRE(backend.seek(0.5));

	const std::vector<float> mono = accumulate_mono_audio(backend, backend.audio_sample_rate(), 0.15);
	REQUIRE(mono.size() > 1);
	const double freq = estimate_dominant_frequency_hz(mono, backend.audio_sample_rate());
	CAPTURE(freq);
	CHECK(frequency_in_track_band(freq, 1));
	CHECK_FALSE(frequency_in_track_band(freq, 0));
	CHECK_FALSE(frequency_in_track_band(freq, 2));
	CHECK_FALSE(backend.had_error());
}

} // namespace multi_track_cases
