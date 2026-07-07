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
// to the old hard-coded constants). PQ/HLG BT.2020 clips report their real
// tags; see the BT.601 row note below for a platform gap.
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
	// h264_30_bt601_mp4.mp4 falls here too: its H.264 SPS VUI carries
	// matrix_coefficients = smpte170m, but ffmpeg's mp4 muxer does not emit
	// the ISOBMFF 'colr' box for this encode, and Media Foundation's mp4
	// source surfaces colorimetry only from that container-level box (it
	// does not parse SPS VUI itself the way AVFoundation's demuxer does). So
	// on the MF backend this clip is indistinguishable from an untagged
	// clip — a real platform gap, not a bug in this backend.
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

#endif // _WIN32
