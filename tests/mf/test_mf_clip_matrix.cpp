// -----------------------------------------------------------------------
// test_mf_clip_matrix.cpp — real-clip format-matrix coverage for the Media
// Foundation (Windows) Decoder-mode Backend. NO Godot, NO RenderingDevice.
//
// Structural mirror of tests/avf/test_avf_clip_matrix.mm. Drives every clip in
// tests/fixtures/matrix/matrix.list through mf::MfBackend and asserts the same
// real-world decode contract (dimensions exact, decode success, frame count
// +/-1, AAC stereo @ 48 kHz, monotonic PTS, PTS drift within half a frame) plus
// colorimetry: per-clip matrix/primaries/transfer/range assertions, keyed by
// clip filename. Untagged clips default to BT.709 video-range (pixel-identical
// to the old hard-coded constants). BT.601 and PQ/HLG BT.2020 clips report
// their real tags from the container-level 'colr' box.
//
// For multi-track clips (audio_tracks > 1 in the manifest) the test also
// verifies track enumeration (count, language tags, default flag) against the
// manifest metadata. Separate test cases exercise pre-play selection and
// mid-stream track switch against the first available multi-track matrix clip.
//
// WINDOWS-ONLY: the body is under #if _WIN32 and is compiled only by
// `scons target=mf_tests platform=windows`. Clips missing because
// tools/gen_clip_matrix.sh hasn't run are skipped with a WARN, never a
// failure. HEVC rows are skipped the same way on hosts with no HEVC decoder
// MFT registered (e.g. GitHub-hosted Windows runners, which lack the
// Store-distributed "HEVC Video Extensions" package).
// -----------------------------------------------------------------------

#include "vendor/doctest.h"

#if defined(_WIN32)

#include "common/clip_matrix.h"
#include "mf_backend.h"

#include <mfapi.h>
#include <mfidl.h>

#include <cmath>
#include <string>

namespace {

// -----------------------------------------------------------------------
// Colorimetry expectations per clip filename.
// Untagged clips are not listed here; they must default to BT.709 video range.
// -----------------------------------------------------------------------
struct ColorimetryExpect {
	core::ColorMatrix matrix = core::ColorMatrix::BT709;
	core::ColorPrimaries primaries = core::ColorPrimaries::BT709;
	core::TransferFunction transfer = core::TransferFunction::BT709;
	core::ColorRange range = core::ColorRange::Video;
	int bit_depth = 8;
};

bool expect_colorimetry(const std::string &file, ColorimetryExpect &out) {
	// BT.601 NTSC-tagged clip. The generator forces the ISOBMFF 'colr' box
	// (-movflags +write_colr), which is the only place Media Foundation's mp4
	// source reads colorimetry from (it never parses SPS VUI). Matrix and
	// primaries surface as the real SD tags; the SMPTE 170M transfer function
	// is curve-identical to BT.709 and MF canonicalizes it as such.
	if (file == "h264_30_bt601_mp4.mp4") {
		out.matrix = core::ColorMatrix::BT601;
		out.primaries = core::ColorPrimaries::BT601_525;
		out.transfer = core::TransferFunction::BT709;
		out.range = core::ColorRange::Video;
		out.bit_depth = 8;
		return true;
	}
	// HEVC Main10 SDR clip. Negotiates as 10-bit (P010); the bit depth is
	// detected from the native type's MF_MT_MPEG2_PROFILE. The 'colr' box is
	// absent for this encode, so open-time colorimetry stays at the BT.709
	// video-range defaults.
	if (file == "hevc_main10_30_mp4.mp4") {
		out.matrix = core::ColorMatrix::BT709;
		out.primaries = core::ColorPrimaries::BT709;
		out.transfer = core::TransferFunction::BT709;
		out.range = core::ColorRange::Video;
		out.bit_depth = 10;
		return true;
	}
	// HDR10 clip: PQ transfer, BT.2020 primaries, BT.2020 non-constant
	// luminance matrix. The 'colr' box IS present for this HEVC encode, so MF
	// reports the real tags. 10-bit (P010), same Main10 profile as the SDR row.
	if (file == "hevc_pq_bt2020_30_mp4.mp4") {
		out.matrix = core::ColorMatrix::BT2020;
		out.primaries = core::ColorPrimaries::BT2020;
		out.transfer = core::TransferFunction::PQ;
		out.range = core::ColorRange::Video;
		out.bit_depth = 10;
		return true;
	}
	// HLG clip: HLG transfer, BT.2020 primaries, BT.2020 non-constant luminance
	// matrix. 10-bit (P010).
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

// Assert that a matrix/primaries/transfer/range tuple matches the expectation
// for `file` (or the BT.709 video-range defaults for an untagged clip). Shared
// by the open-time backend check and the per-frame check below so both cover
// all four fields identically.
void check_colorimetry(core::ColorMatrix matrix, core::ColorPrimaries primaries,
		core::TransferFunction transfer, core::ColorRange range, const std::string &file) {
	ColorimetryExpect exp;
	if (!expect_colorimetry(file, exp)) {
		CHECK(matrix == core::ColorMatrix::BT709);
		CHECK(primaries == core::ColorPrimaries::BT709);
		CHECK(transfer == core::TransferFunction::BT709);
		CHECK(range == core::ColorRange::Video);
		return;
	}
	CHECK(matrix == exp.matrix);
	CHECK(primaries == exp.primaries);
	CHECK(transfer == exp.transfer);
	CHECK(range == exp.range);
}

// Assert that the backend's open-time colorimetry matches expectations.
void check_backend_colorimetry(mf::MfBackend &backend, const std::string &file) {
	const core::Colorimetry color = backend.colorimetry();
	check_colorimetry(color.matrix, color.primaries, color.transfer, color.range, file);

	ColorimetryExpect exp;
	if (!expect_colorimetry(file, exp)) {
		CHECK(color.bit_depth == 8);
		return;
	}
	CHECK(color.bit_depth == exp.bit_depth);
}

// Assert that the first decoded frame's per-frame colorimetry matches the
// same expectations (the MF backend tags every frame from the stream-level
// negotiated values; see mf_backend.cpp's read_colorimetry).
void check_frame_colorimetry(const core::VideoFrame &frame, const std::string &file) {
	check_colorimetry(frame.color.matrix, frame.color.primaries, frame.color.transfer, frame.color.range, file);
}

// GitHub-hosted Windows runners (and many headless Windows Server images) do
// not ship a Media Foundation HEVC decoder MFT — it is an optional, licensed
// component ("HEVC Video Extensions") distributed via the Microsoft Store and
// never present on server SKUs. Probe for one so HEVC rows degrade to a WARN
// skip on hosts without it, exactly like a missing matrix clip, rather than a
// hard failure caused by the environment rather than the backend.
bool hevc_decoder_available() {
	CoInitializeEx(nullptr, COINIT_MULTITHREADED);

	MFT_REGISTER_TYPE_INFO input_type{ MFMediaType_Video, MFVideoFormat_HEVC };
	IMFActivate **activations = nullptr;
	UINT32 count = 0;
	HRESULT hr = MFTEnumEx(
			MFT_CATEGORY_VIDEO_DECODER,
			MFT_ENUM_FLAG_ALL,
			&input_type,
			nullptr,
			&activations,
			&count);

	const bool available = SUCCEEDED(hr) && count > 0;
	for (UINT32 i = 0; i < count; ++i) {
		activations[i]->Release();
	}
	CoTaskMemFree(activations);

	CoUninitialize();
	return available;
}

bool is_hevc_clip(const clip_matrix::Clip &clip) {
	return clip.file.find("hevc") != std::string::npos;
}

const clip_matrix::Clip *find_multi_track_clip(const std::vector<clip_matrix::Clip> &clips, int min_tracks = 2) {
	for (const auto &clip : clips) {
		if (clip.audio_tracks >= min_tracks) {
			return &clip;
		}
	}
	return nullptr;
}

} // namespace

TEST_CASE("MF backend decodes the real-clip format matrix") {
	const auto clips = clip_matrix::load();
	if (clips.empty()) {
		WARN_MESSAGE(false, "clip matrix manifest absent — skipping real-clip coverage");
		return;
	}

	const bool have_hevc_decoder = hevc_decoder_available();

	int decoded_clips = 0;

	for (const auto &clip : clips) {
		const std::string path = clip_matrix::clip_path(clip);

		if (!clip_matrix::file_exists(path)) {
			WARN_MESSAGE(false, ("matrix clip missing (run tools/gen_clip_matrix.sh): " + clip.file).c_str());
			continue;
		}

		if (is_hevc_clip(clip) && !have_hevc_decoder) {
			WARN_MESSAGE(false, ("no HEVC decoder MFT registered on this host — skipping: " + clip.file).c_str());
			continue;
		}

		CAPTURE(clip.file);

		mf::MfBackend backend;
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
			// P010, tagged x420 (the same logical 16-bit-biplanar tag the AVF
			// backend uses).
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

TEST_CASE("MF backend selects pre-play audio track from multi-track matrix clip") {
	const auto clips = clip_matrix::load();
	if (clips.empty()) {
		WARN_MESSAGE(false, "clip matrix manifest absent — skipping multi-track selection");
		return;
	}

	const clip_matrix::Clip *clip = find_multi_track_clip(clips);
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

	mf::MfBackend backend;
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

TEST_CASE("MF backend performs mid-stream audio track switch on multi-track matrix clip") {
	const auto clips = clip_matrix::load();
	if (clips.empty()) {
		WARN_MESSAGE(false, "clip matrix manifest absent — skipping multi-track reselect");
		return;
	}

	const clip_matrix::Clip *clip = find_multi_track_clip(clips);
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

	mf::MfBackend backend;
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

TEST_CASE("MF backend reselects to same track on multi-track matrix clip") {
	const auto clips = clip_matrix::load();
	if (clips.empty()) {
		WARN_MESSAGE(false, "clip matrix manifest absent — skipping same-track reselect");
		return;
	}

	const clip_matrix::Clip *clip = find_multi_track_clip(clips);
	if (!clip) {
		WARN_MESSAGE(false, "no multi-track clip in matrix — skipping same-track reselect");
		return;
	}

	const std::string path = clip_matrix::clip_path(*clip);
	if (!clip_matrix::file_exists(path)) {
		WARN_MESSAGE(false, ("multi-track clip missing (run tools/gen_clip_matrix.sh): " + clip->file).c_str());
		return;
	}

	mf::MfBackend backend;
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

TEST_CASE("MF backend reselect clamps out-of-range index on multi-track matrix clip") {
	const auto clips = clip_matrix::load();
	if (clips.empty()) {
		WARN_MESSAGE(false, "clip matrix manifest absent — skipping reselect clamp test");
		return;
	}

	const clip_matrix::Clip *clip = find_multi_track_clip(clips);
	if (!clip) {
		WARN_MESSAGE(false, "no multi-track clip in matrix — skipping reselect clamp test");
		return;
	}

	const std::string path = clip_matrix::clip_path(*clip);
	if (!clip_matrix::file_exists(path)) {
		WARN_MESSAGE(false, ("multi-track clip missing (run tools/gen_clip_matrix.sh): " + clip->file).c_str());
		return;
	}

	mf::MfBackend backend;
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

#endif // _WIN32