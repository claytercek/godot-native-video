// -----------------------------------------------------------------------
// test_mf_clip_matrix.cpp — real-clip format-matrix coverage for the Media
// Foundation (Windows) Decoder-mode Backend. NO Godot, NO RenderingDevice.
//
// Structural mirror of tests/avf/test_avf_clip_matrix.mm: both platform files
// are thin TEST_CASE wrappers around the shared case bodies in
// tests/common/clip_matrix_cases.h, which drive every clip in
// tests/fixtures/matrix/matrix.list through the platform's Backend and assert
// the same real-world decode contract (dimensions exact, decode success,
// frame count +/-1, AAC stereo @ 48 kHz, monotonic PTS, PTS drift within half
// a frame) plus colorimetry: per-clip matrix/primaries/transfer/range
// assertions, keyed by clip filename. Untagged clips default to BT.709
// video-range. BT.601 and PQ/HLG BT.2020 clips report their real tags from
// the container-level 'colr' box.
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
// Store-distributed "HEVC Video Extensions" package) — see
// hevc_decoder_available() below, MF's half of the format-matrix case's
// hevc_available customization point.
// -----------------------------------------------------------------------

#include "vendor/doctest.h"

#if defined(_WIN32)

#include "common/clip_matrix_cases.h"
#include "mf_backend.h"

#include <mfapi.h>
#include <mfidl.h>

namespace {

// GitHub-hosted Windows runners (and many headless Windows Server images) do
// not ship a Media Foundation HEVC decoder MFT — it is an optional, licensed
// component ("HEVC Video Extensions") distributed via the Microsoft Store and
// never present on server SKUs. Probe for one so HEVC rows degrade to a WARN
// skip on hosts without it, exactly like a missing matrix clip, rather than a
// hard failure caused by the environment rather than the backend. AVF's twin
// of this probe always returns true (see test_avf_clip_matrix.mm).
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

// MF tags every decoded frame from the stream-level negotiated colorimetry
// (see mf_backend.cpp's read_colorimetry), so per-frame checks can assert all
// four fields on every clip, tagged or not. AVF's per-frame CV attachments
// don't carry that guarantee — see the narrower checker in
// test_avf_clip_matrix.mm.
void check_frame_colorimetry(const core::VideoFrame &frame, const std::string &file) {
	clip_matrix_cases::ColorimetryExpect exp;
	const bool tagged = clip_matrix_cases::expect_colorimetry(file, exp);
	if (!tagged) {
		CHECK(frame.color.matrix == core::ColorMatrix::BT709);
		CHECK(frame.color.primaries == core::ColorPrimaries::BT709);
		CHECK(frame.color.transfer == core::TransferFunction::BT709);
		CHECK(frame.color.range == core::ColorRange::Video);
		return;
	}
	CHECK(frame.color.matrix == exp.matrix);
	CHECK(frame.color.primaries == exp.primaries);
	CHECK(frame.color.transfer == exp.transfer);
	CHECK(frame.color.range == exp.range);
}

} // namespace

TEST_CASE("MF backend decodes the real-clip format matrix") {
	clip_matrix_cases::run_format_matrix_case<mf::MfBackend>(hevc_decoder_available(), check_frame_colorimetry);
}

TEST_CASE("MF backend selects pre-play audio track from multi-track matrix clip") {
	clip_matrix_cases::run_preplay_selection_case<mf::MfBackend>();
}

TEST_CASE("MF backend performs mid-stream audio track switch on multi-track matrix clip") {
	clip_matrix_cases::run_midstream_switch_case<mf::MfBackend>();
}

TEST_CASE("MF backend reselects to same track on multi-track matrix clip") {
	clip_matrix_cases::run_same_track_reselect_case<mf::MfBackend>();
}

TEST_CASE("MF backend reselect clamps out-of-range index on multi-track matrix clip") {
	clip_matrix_cases::run_reselect_clamp_case<mf::MfBackend>();
}

#endif // _WIN32
