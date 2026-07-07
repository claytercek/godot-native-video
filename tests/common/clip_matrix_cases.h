#pragma once
// -----------------------------------------------------------------------
// clip_matrix_cases.h — shared TEST_CASE bodies for the real-clip format
// matrix coverage (tests/avf/test_avf_clip_matrix.mm and
// tests/mf/test_mf_clip_matrix.cpp). Both platform files drive the same
// manifest (tests/fixtures/matrix/matrix.list) through their own
// core::Backend implementation and assert the same decode contract; only
// the concrete Backend type and two genuine platform behaviors (called out
// below) differ. Each platform TU wraps these templates in a thin
// TEST_CASE that instantiates with its own backend type, so doctest
// registration and per-platform test names stay in the platform files.
// -----------------------------------------------------------------------

#include "vendor/doctest.h"

#include "backend.h"
#include "common/clip_matrix.h"

#include <cmath>
#include <string>

namespace clip_matrix_cases {

// -----------------------------------------------------------------------
// Colorimetry expectations per clip filename, shared verbatim: both
// backends negotiate the same container-level tags for these clips.
// Untagged clips are not listed here; they must default to BT.709 video
// range.
// -----------------------------------------------------------------------
struct ColorimetryExpect {
	core::ColorMatrix matrix = core::ColorMatrix::BT709;
	core::ColorPrimaries primaries = core::ColorPrimaries::BT709;
	core::TransferFunction transfer = core::TransferFunction::BT709;
	core::ColorRange range = core::ColorRange::Video;
	int bit_depth = 8;
};

inline bool expect_colorimetry(const std::string &file, ColorimetryExpect &out) {
	// BT.601 NTSC-tagged clip. The generator forces the ISOBMFF 'colr' box
	// (-movflags +write_colr), the only place either platform's demuxer reads
	// colorimetry from (neither parses SPS VUI). Matrix and primaries surface
	// as the real SD tags; the SMPTE 170M transfer function is curve-identical
	// to BT.709 and both platforms canonicalize it as such.
	if (file == "h264_30_bt601_mp4.mp4") {
		out.matrix = core::ColorMatrix::BT601;
		out.primaries = core::ColorPrimaries::BT601_525;
		out.transfer = core::TransferFunction::BT709;
		out.range = core::ColorRange::Video;
		out.bit_depth = 8;
		return true;
	}
	// HEVC Main10 SDR clip. Negotiates as 10-bit (P010 on MF, x420 on AVF);
	// the bit depth is detected from the native/negotiated media type. The
	// 'colr' box is absent for this encode, so open-time colorimetry stays at
	// the BT.709 video-range defaults.
	if (file == "hevc_main10_30_mp4.mp4") {
		out.matrix = core::ColorMatrix::BT709;
		out.primaries = core::ColorPrimaries::BT709;
		out.transfer = core::TransferFunction::BT709;
		out.range = core::ColorRange::Video;
		out.bit_depth = 10;
		return true;
	}
	// HDR10 clip: PQ transfer, BT.2020 primaries, BT.2020 non-constant
	// luminance matrix. The 'colr' box IS present for this HEVC encode, so
	// both platforms report the real tags. 10-bit, same Main10 profile as the
	// SDR row.
	if (file == "hevc_pq_bt2020_30_mp4.mp4") {
		out.matrix = core::ColorMatrix::BT2020;
		out.primaries = core::ColorPrimaries::BT2020;
		out.transfer = core::TransferFunction::PQ;
		out.range = core::ColorRange::Video;
		out.bit_depth = 10;
		return true;
	}
	// HLG clip: HLG transfer, BT.2020 primaries, BT.2020 non-constant
	// luminance matrix. 10-bit.
	if (file == "hevc_hlg_bt2020_30_mp4.mp4") {
		out.matrix = core::ColorMatrix::BT2020;
		out.primaries = core::ColorPrimaries::BT2020;
		out.transfer = core::TransferFunction::HLG;
		out.range = core::ColorRange::Video;
		out.bit_depth = 10;
		return true;
	}

	// Untagged — defaults (8-bit NV12).
	return false;
}

// True for clips whose file name marks them as HEVC-coded.
inline bool is_hevc_clip(const clip_matrix::Clip &clip) {
	return clip.file.find("hevc") != std::string::npos;
}

// Assert that the backend's open-time colorimetry (matrix/primaries/transfer/
// range/bit_depth) matches expectations for `file`.
template <typename Backend>
void check_backend_colorimetry(Backend &backend, const std::string &file) {
	const core::Colorimetry color = backend.colorimetry();
	ColorimetryExpect exp;
	if (!expect_colorimetry(file, exp)) {
		CHECK(color.matrix == core::ColorMatrix::BT709);
		CHECK(color.primaries == core::ColorPrimaries::BT709);
		CHECK(color.transfer == core::TransferFunction::BT709);
		CHECK(color.range == core::ColorRange::Video);
		CHECK(color.bit_depth == 8);
		return;
	}
	CHECK(color.matrix == exp.matrix);
	CHECK(color.primaries == exp.primaries);
	CHECK(color.transfer == exp.transfer);
	CHECK(color.range == exp.range);
	CHECK(color.bit_depth == exp.bit_depth);
}

// run_format_matrix_case — "<platform> backend decodes the real-clip format
// matrix".
//
// `hevc_available` lets a platform skip HEVC rows with a WARN instead of a
// hard failure when no HEVC decoder is present on the host (MF: GitHub-hosted
// Windows runners lack the licensed "HEVC Video Extensions" MFT; the caller
// probes for one and passes the result in. AVF always passes true — every
// macOS host used for CI ships hardware HEVC decode).
//
// `check_frame_colorimetry` is a genuine per-platform behavior, not a
// copy-paste artifact: MF tags every decoded frame from the stream-level
// negotiated colorimetry, so it checks all four fields on every clip (tagged
// or not). AVF's per-frame CV attachments only carry reliable colorimetry for
// clips with an explicit container tag, and even then only matrix + range
// (not primaries/transfer) — untagged clips are left unchecked. Each
// platform file supplies its own checker; see the other platform's call site
// for the mirror-image behavior.
template <typename Backend, typename FrameColorimetryCheck>
void run_format_matrix_case(bool hevc_available, FrameColorimetryCheck check_frame_colorimetry) {
	const auto clips = clip_matrix::load();
	if (clips.empty()) {
		WARN_MESSAGE(false, "clip matrix manifest absent — skipping real-clip coverage");
		return;
	}

	int decoded_clips = 0;

	for (const auto &clip : clips) {
		const std::string path = clip_matrix::clip_path(clip);

		if (!clip_matrix::file_exists(path)) {
			WARN_MESSAGE(false, ("matrix clip missing (run tools/gen_clip_matrix.sh): " + clip.file).c_str());
			continue;
		}

		if (is_hevc_clip(clip) && !hevc_available) {
			WARN_MESSAGE(false, ("no HEVC decoder available on this host — skipping: " + clip.file).c_str());
			continue;
		}

		CAPTURE(clip.file);

		Backend backend;
		REQUIRE(backend.open(path));

		CHECK(backend.video_width() == clip.width);
		CHECK(backend.video_height() == clip.height);
		CHECK(backend.audio_sample_rate() == clip.audio_rate);
		CHECK(backend.audio_channel_count() == clip.audio_channels);

		// --- Colorimetry: open-time values ---
		check_backend_colorimetry(backend, clip.file);

		// --- Multi-track enumeration verification ---
		if (clip.audio_tracks > 1) {
			CHECK(backend.audio_track_count() == clip.audio_tracks);

			const auto t0 = backend.audio_track_info(0);
			CHECK(t0.channels == clip.audio_channels);
			CHECK(t0.sample_rate == clip.audio_rate);
			CHECK(t0.is_default == true);
			if (!clip.track_languages.empty()) {
				CHECK(t0.language == clip.track_languages[0]);
			}

			const auto t1 = backend.audio_track_info(1);
			CHECK(t1.is_default == false);
			CHECK(t1.channels == clip.audio_channels);
			CHECK(t1.sample_rate == clip.audio_rate);
			if (clip.track_languages.size() > 1) {
				CHECK(t1.language == clip.track_languages[1]);
			}

			const auto t99 = backend.audio_track_info(99);
			CHECK(t99.channels == 0);
			CHECK(t99.sample_rate == 0);
			CHECK(t99.is_default == false);
		} else {
			CHECK(backend.audio_track_count() == 1);
			const auto t0 = backend.audio_track_info(0);
			CHECK(t0.channels == clip.audio_channels);
			CHECK(t0.sample_rate == clip.audio_rate);
			CHECK(t0.is_default == true);
		}

		const double interval = 1.0 / static_cast<double>(clip.fps);
		const double budget = interval * 0.5;

		int video_count = 0;
		double last_pts = -1.0;
		double max_drift = 0.0;
		bool first_frame = true;
		while (auto frame = backend.next_video_frame()) {
			// 8-bit sources negotiate NV12; 10-bit HEVC Main10 sources negotiate
			// P010/x420 (the same logical 16-bit-biplanar tag on both platforms).
			ColorimetryExpect exp;
			const bool is_10bit = expect_colorimetry(clip.file, exp) && exp.bit_depth >= 10;
			if (is_10bit) {
				CHECK(frame->pixel_format == core::PixelFormat::x420);
				CHECK(frame->color.bit_depth == 10);
			} else {
				CHECK(frame->pixel_format == core::PixelFormat::NV12);
				CHECK(frame->color.bit_depth == 8);
			}
			CHECK(frame->native_handle != nullptr);
			CHECK(frame->width == clip.width);
			CHECK(frame->height == clip.height);

			if (first_frame) {
				check_frame_colorimetry(*frame, clip.file);
				first_frame = false;
			}

			CHECK(frame->pts_seconds >= last_pts);
			last_pts = frame->pts_seconds;

			const double ideal = static_cast<double>(video_count) * interval;
			const double drift = std::fabs(frame->pts_seconds - ideal);
			if (drift > max_drift) {
				max_drift = drift;
			}

			frame->release();
			++video_count;
		}

		CHECK_FALSE(backend.had_error());
		CHECK(video_count >= clip.frames - 1);
		CHECK(video_count <= clip.frames + 1);
		CHECK(max_drift <= budget);

		REQUIRE(backend.open(path));
		long audio_frames_total = 0;
		double last_audio_pts = -1.0;
		int audio_chunks = 0;
		while (auto chunk = backend.next_audio_chunk()) {
			CHECK(chunk->samples != nullptr);
			CHECK(chunk->frame_count > 0);
			CHECK(chunk->channel_count == clip.audio_channels);
			CHECK(chunk->sample_rate == clip.audio_rate);
			CHECK(chunk->pts_seconds >= last_audio_pts);
			last_audio_pts = chunk->pts_seconds;
			audio_frames_total += chunk->frame_count;
			++audio_chunks;
		}
		CHECK_FALSE(backend.had_error());
		CHECK(audio_chunks > 0);

		const long nominal =
				static_cast<long>(static_cast<double>(clip.audio_rate) * clip.frames / clip.fps);
		CHECK(audio_frames_total >= nominal / 2);

		++decoded_clips;
	}

	if (decoded_clips == 0) {
		WARN_MESSAGE(false, "no matrix clips were decodable — run tools/gen_clip_matrix.sh");
	}
}

// run_preplay_selection_case — "<platform> backend selects pre-play audio
// track from multi-track matrix clip". Identical on both platforms:
// select_audio_track() is deferred until the next seek()/open() by the
// Backend contract, so both call seek(0.0) before decoding.
template <typename Backend>
void run_preplay_selection_case() {
	const auto clips = clip_matrix::load();
	if (clips.empty()) {
		WARN_MESSAGE(false, "clip matrix manifest absent — skipping multi-track selection");
		return;
	}

	const clip_matrix::Clip *clip = clip_matrix::find_multi_track_clip(clips);
	if (!clip) {
		WARN_MESSAGE(false, "no multi-track clip in matrix — skipping multi-track selection");
		return;
	}

	const std::string path = clip_matrix::clip_path(*clip);
	if (!clip_matrix::file_exists(path)) {
		WARN_MESSAGE(false, ("multi-track clip missing (run tools/gen_clip_matrix.sh): " + clip->file).c_str());
		return;
	}

	CAPTURE(clip->file);

	Backend backend;
	REQUIRE(backend.open(path));
	CHECK(backend.audio_track_count() == clip->audio_tracks);

	const auto t0 = backend.audio_track_info(0);
	CHECK(t0.is_default == true);
	CHECK(t0.channels == clip->audio_channels);
	CHECK(t0.sample_rate == clip->audio_rate);
	if (!clip->track_languages.empty()) {
		CHECK(t0.language == clip->track_languages[0]);
	}

	REQUIRE(backend.open(path));
	backend.select_audio_track(1);

	const auto t1_check = backend.audio_track_info(1);
	CHECK(t1_check.is_default == false);
	CHECK(t1_check.channels == clip->audio_channels);
	CHECK(t1_check.sample_rate == clip->audio_rate);

	// select_audio_track() takes effect on the next seek()/open() (Backend
	// contract) rather than immediately, so seek before decoding.
	REQUIRE(backend.seek(0.0));

	int audio_chunks = 0;
	long audio_frames_total = 0;
	double last_audio_pts = -1.0;
	while (auto chunk = backend.next_audio_chunk()) {
		CHECK(chunk->samples != nullptr);
		CHECK(chunk->frame_count > 0);
		CHECK(chunk->channel_count >= 1);
		CHECK(chunk->sample_rate == clip->audio_rate);
		CHECK(chunk->pts_seconds >= last_audio_pts);
		last_audio_pts = chunk->pts_seconds;
		audio_frames_total += chunk->frame_count;
		++audio_chunks;
	}
	CHECK_FALSE(backend.had_error());
	CHECK(audio_chunks > 0);

	const long nominal = static_cast<long>(static_cast<double>(clip->audio_rate) * clip->frames / clip->fps);
	CHECK(audio_frames_total >= nominal / 2);

	REQUIRE(backend.open(path));
	backend.select_audio_track(99);
	CHECK(backend.audio_channel_count() >= 1);
	CHECK(backend.audio_sample_rate() == clip->audio_rate);
	REQUIRE(backend.seek(0.0));

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

// run_midstream_switch_case — "<platform> backend performs mid-stream audio
// track switch on multi-track matrix clip".
template <typename Backend>
void run_midstream_switch_case() {
	const auto clips = clip_matrix::load();
	if (clips.empty()) {
		WARN_MESSAGE(false, "clip matrix manifest absent — skipping multi-track reselect");
		return;
	}

	const clip_matrix::Clip *clip = clip_matrix::find_multi_track_clip(clips);
	if (!clip) {
		WARN_MESSAGE(false, "no multi-track clip in matrix — skipping multi-track reselect");
		return;
	}

	const std::string path = clip_matrix::clip_path(*clip);
	if (!clip_matrix::file_exists(path)) {
		WARN_MESSAGE(false, ("multi-track clip missing (run tools/gen_clip_matrix.sh): " + clip->file).c_str());
		return;
	}

	CAPTURE(clip->file);

	Backend backend;
	REQUIRE(backend.open(path));
	CHECK(backend.audio_track_count() == clip->audio_tracks);

	double last_video_pts = -1.0;
	int video_pre = 0;
	for (int i = 0; i < 4 && video_pre < 4; ++i) {
		auto frame = backend.next_video_frame();
		REQUIRE(frame.has_value());
		CHECK(frame->pts_seconds >= last_video_pts);
		last_video_pts = frame->pts_seconds;
		frame->release();
		++video_pre;
	}
	CHECK(video_pre >= 1);

	int audio_pre = 0;
	double last_audio_pts = -1.0;
	while (auto chunk = backend.next_audio_chunk()) {
		CHECK(chunk->pts_seconds >= last_audio_pts);
		last_audio_pts = chunk->pts_seconds;
		++audio_pre;
		if (audio_pre >= 3) break;
	}
	CHECK(audio_pre >= 1);
	CHECK_FALSE(backend.had_error());

	double reselect_time = last_video_pts;
	REQUIRE(backend.reselect_audio_track(1, reselect_time));

	int video_post = 0;
	last_video_pts = -1.0;
	while (auto frame = backend.next_video_frame()) {
		CHECK(frame->pixel_format == core::PixelFormat::NV12);
		CHECK(frame->native_handle != nullptr);
		CHECK(frame->pts_seconds >= last_video_pts);
		last_video_pts = frame->pts_seconds;
		frame->release();
		++video_post;
		if (video_post >= 3) break;
	}
	CHECK(video_post >= 1);

	int audio_post = 0;
	last_audio_pts = -1.0;
	while (auto chunk = backend.next_audio_chunk()) {
		CHECK(chunk->samples != nullptr);
		CHECK(chunk->frame_count > 0);
		CHECK(chunk->channel_count >= 1);
		CHECK(chunk->sample_rate == clip->audio_rate);
		CHECK(chunk->pts_seconds >= last_audio_pts);
		last_audio_pts = chunk->pts_seconds;
		++audio_post;
		if (audio_post >= 3) break;
	}
	CHECK(audio_post >= 1);
	CHECK_FALSE(backend.had_error());

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

// run_same_track_reselect_case — "<platform> backend reselects to same track
// on multi-track matrix clip".
template <typename Backend>
void run_same_track_reselect_case() {
	const auto clips = clip_matrix::load();
	if (clips.empty()) {
		WARN_MESSAGE(false, "clip matrix manifest absent — skipping same-track reselect");
		return;
	}

	const clip_matrix::Clip *clip = clip_matrix::find_multi_track_clip(clips);
	if (!clip) {
		WARN_MESSAGE(false, "no multi-track clip in matrix — skipping same-track reselect");
		return;
	}

	const std::string path = clip_matrix::clip_path(*clip);
	if (!clip_matrix::file_exists(path)) {
		WARN_MESSAGE(false, ("multi-track clip missing (run tools/gen_clip_matrix.sh): " + clip->file).c_str());
		return;
	}

	Backend backend;
	REQUIRE(backend.open(path));

	auto frame = backend.next_video_frame();
	REQUIRE(frame.has_value());
	frame->release();

	auto chunk = backend.next_audio_chunk();
	REQUIRE(chunk.has_value());

	REQUIRE(backend.reselect_audio_track(0, chunk->pts_seconds));

	int video_count = 0;
	while (auto f = backend.next_video_frame()) {
		f->release();
		++video_count;
	}
	CHECK(video_count >= 1);

	int audio_count = 0;
	while (auto ac = backend.next_audio_chunk()) {
		CHECK(ac->samples != nullptr);
		++audio_count;
	}
	CHECK(audio_count >= 1);
	CHECK_FALSE(backend.had_error());
}

// run_reselect_clamp_case — "<platform> backend reselect clamps out-of-range
// index on multi-track matrix clip".
template <typename Backend>
void run_reselect_clamp_case() {
	const auto clips = clip_matrix::load();
	if (clips.empty()) {
		WARN_MESSAGE(false, "clip matrix manifest absent — skipping reselect clamp test");
		return;
	}

	const clip_matrix::Clip *clip = clip_matrix::find_multi_track_clip(clips);
	if (!clip) {
		WARN_MESSAGE(false, "no multi-track clip in matrix — skipping reselect clamp test");
		return;
	}

	const std::string path = clip_matrix::clip_path(*clip);
	if (!clip_matrix::file_exists(path)) {
		WARN_MESSAGE(false, ("multi-track clip missing (run tools/gen_clip_matrix.sh): " + clip->file).c_str());
		return;
	}

	Backend backend;
	REQUIRE(backend.open(path));

	auto frame = backend.next_video_frame();
	REQUIRE(frame.has_value());
	frame->release();

	REQUIRE(backend.reselect_audio_track(99, 0.0));

	int video_count = 0;
	while (auto f = backend.next_video_frame()) {
		f->release();
		++video_count;
	}
	CHECK(video_count >= 1);
	CHECK_FALSE(backend.had_error());

	int audio_count = 0;
	while (auto ac = backend.next_audio_chunk()) {
		CHECK(ac->samples != nullptr);
		++audio_count;
	}
	CHECK(audio_count >= 1);
	CHECK_FALSE(backend.had_error());
}

} // namespace clip_matrix_cases
