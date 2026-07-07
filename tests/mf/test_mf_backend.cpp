// -----------------------------------------------------------------------
// test_mf_backend.cpp — headless integration test for the Media Foundation
// Decoder-mode Backend (Windows). NO Godot, NO RenderingDevice.
//
// The structural mirror of tests/avf/test_avf_backend.mm. It generates (on
// demand) a synthetic marker clip via tools/gen_test_media.sh and decodes it
// end-to-end through mf::MfBackend, asserting:
//   - NV12 D3D11 video frames are produced with the expected count (±1 GOP slack);
//   - the burned-in white frame-index marker is present (mean luma of the
//     top-left block is bright) — read back from the D3D11 NV12 texture via a
//     CPU staging copy (TEST-ONLY; the present path never does this);
//   - video PTS and audio PTS are each monotonic non-decreasing;
//   - PCM float32 audio is extracted with sane PTS;
//   - no decode errors occur.
//
// The multi-track audio-track selection/reselect coverage below is a thin
// TEST_CASE layer over the shared case bodies in
// tests/common/multi_track_cases.h — see that header for the cross-platform
// contract and the two customization points (track-name checking, and the
// post-reselect video-PTS bound near end-of-stream) it exposes.
//
// WINDOWS-ONLY: this file is compiled only by `scons target=mf_tests` on
// Windows. It is excluded everywhere else (the whole body is under #if _WIN32),
// so it must NEVER be added to the macOS / core_tests source sets.
// -----------------------------------------------------------------------

#include "vendor/doctest.h"

#if defined(_WIN32)

#include "common/multi_track_cases.h"
#include "mf_backend.h"

#include <d3d11.h>

#include <sys/stat.h>
#include <cstdio>
#include <cstdlib>
#include <string>

namespace {

// Test-clip parameters — identical to the AVF test so the same fixture and
// tolerances apply across platforms.
constexpr int kFrames = 30;
constexpr int kFps = 30;
constexpr int kWidth = 320;
constexpr int kHeight = 240;
constexpr int kBlock = 80; // marker block edge length in pixels

bool file_exists(const std::string &p) {
	struct stat st;
	return ::stat(p.c_str(), &st) == 0;
}

bool ffmpeg_available() {
	return std::system("where ffmpeg >NUL 2>&1") == 0;
}

std::string repo_root() {
	if (const char *env = std::getenv("REPO_ROOT")) {
		return std::string(env);
	}
	return "."; // scons invokes the test from the repo root
}

// Generate the fixture if missing (bash + ffmpeg in CI). Returns the path, or
// empty on failure.
std::string ensure_fixture() {
	const std::string root = repo_root();
	// CI generates one shared synthetic clip (30 frames @ 30 fps, 320x240 —
	// exactly the kFrames/kFps/kWidth/kHeight contract) on a media runner and
	// ships it as an artifact; prefer it so the decode assertions run on
	// runners without ffmpeg.
	const std::string shared = root + "/tests/fixtures/synthetic.mp4";
	if (file_exists(shared)) {
		return shared;
	}
	const std::string fixture = root + "/tests/fixtures/synthetic_mf.mp4";
	if (file_exists(fixture)) {
		return fixture;
	}
	if (!ffmpeg_available()) {
		return {};
	}
	char cmd[1024];
	std::snprintf(cmd, sizeof(cmd),
			"bash %s/tools/gen_test_media.sh --frames %d --fps %d --width %d --height %d --output %s "
			">NUL 2>&1",
			root.c_str(), kFrames, kFps, kWidth, kHeight, fixture.c_str());
	if (std::system(cmd) != 0) {
		return {};
	}
	return file_exists(fixture) ? fixture : std::string{};
}

// Multi-track fixture: same shape as AVF's (see multi_track_cases::kMulti*).
// Only the shell invocation differs (bash prefix, NUL vs /dev/null).
std::string ensure_multi_track_fixture() {
	const std::string root = repo_root();
	const std::string fixture = root + "/tests/fixtures/synthetic_multitrack_mf.mp4";
	if (file_exists(fixture)) {
		return fixture;
	}
	if (!ffmpeg_available()) {
		return {};
	}
	char cmd[2048];
	std::snprintf(cmd, sizeof(cmd),
			"bash %s/tools/gen_test_media.sh --frames %d --fps %d --output %s --multi-track %d "
			">NUL 2>&1",
			root.c_str(), multi_track_cases::kMultiFrames, multi_track_cases::kMultiFps,
			fixture.c_str(), multi_track_cases::kMultiTracks);
	if (std::system(cmd) != 0) {
		return {};
	}
	return file_exists(fixture) ? fixture : std::string{};
}

// Mean luma over the bottom-right quadrant of the top-left NV12 marker block,
// read back from a D3D11 NV12 texture. This is a TEST-ONLY CPU read-back via a
// staging texture; the present path imports the texture to the GPU zero-copy and
// never does this. Mirrors mean_block_luma() in the AVF test.
//
// `subresource` is the array-slice index the backend reports in
// core::VideoFrame::plane_slice: DXVA decoders hand out frames as slices of
// one shared texture *array*, so the readback must copy that slice
// (CopySubresourceRegion) — CopyResource into a 1-slice staging texture is an
// array-size mismatch, which D3D11 silently ignores, leaving the staging
// texture black.
double mean_block_luma(ID3D11Texture2D *tex, UINT subresource) {
	if (!tex) {
		return 0.0;
	}
	ID3D11Device *device = nullptr;
	tex->GetDevice(&device);
	if (!device) {
		return 0.0;
	}
	ID3D11DeviceContext *ctx = nullptr;
	device->GetImmediateContext(&ctx);

	D3D11_TEXTURE2D_DESC desc = {};
	tex->GetDesc(&desc);

	// Create a CPU-readable staging copy of the NV12 texture.
	D3D11_TEXTURE2D_DESC sdesc = desc;
	sdesc.Usage = D3D11_USAGE_STAGING;
	sdesc.BindFlags = 0;
	sdesc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
	sdesc.MiscFlags = 0;
	sdesc.ArraySize = 1;
	sdesc.MipLevels = 1;

	ID3D11Texture2D *staging = nullptr;
	double result = 0.0;
	if (SUCCEEDED(device->CreateTexture2D(&sdesc, nullptr, &staging)) && staging) {
		ctx->CopySubresourceRegion(staging, 0, 0, 0, 0, tex, subresource, nullptr);
		D3D11_MAPPED_SUBRESOURCE mapped = {};
		if (SUCCEEDED(ctx->Map(staging, 0, D3D11_MAP_READ, 0, &mapped))) {
			const uint8_t *luma = static_cast<const uint8_t *>(mapped.pData);
			const size_t stride = mapped.RowPitch; // luma plane row pitch

			const int x0 = kBlock / 2;
			const int y0 = kBlock / 2;
			const int x1 = kBlock - 4;
			const int y1 = kBlock - 4;
			double sum = 0.0;
			int n = 0;
			for (int y = y0; y < y1; ++y) {
				const uint8_t *row = luma + static_cast<size_t>(y) * stride;
				for (int x = x0; x < x1; ++x) {
					sum += row[x];
					++n;
				}
			}
			result = n > 0 ? sum / n : 0.0;
			ctx->Unmap(staging, 0);
		}
		staging->Release();
	}
	ctx->Release();
	device->Release();
	return result;
}

// MF synthesizes a "Track N (lang)" display name (see gen_test_media.sh's
// stream-title tagging); AVF's AudioTrackInfo::name is always empty in v1 —
// see the no-op passed at the AVF call site.
void check_track0_name(const core::AudioTrackInfo &t0) {
	CHECK(t0.name == "Track 0 (eng)");
}

// MF's reader position is unchanged by reselect_audio_track(), so video
// simply continues from wherever it already was — see the opposite
// (upper-bound) assertion at the AVF call site in test_avf_backend.mm.
void check_near_end_pts_bound(double first_video_pts, double near_end) {
	CHECK(first_video_pts >= near_end - 1.0);
}

} // namespace

TEST_CASE("MF backend decodes synthetic clip to NV12 + PCM with monotonic PTS") {
	const std::string fixture = ensure_fixture();
	if (fixture.empty()) {
		WARN_MESSAGE(false, "ffmpeg unavailable or fixture generation failed — skipping MF decode assertions");
		return;
	}

	mf::MfBackend backend;
	REQUIRE(backend.open(fixture));

	CHECK(backend.video_width() == kWidth);
	CHECK(backend.video_height() == kHeight);
	CHECK(backend.audio_sample_rate() == 48000);
	CHECK(backend.audio_channel_count() >= 1);

	// ---- Video: pump every frame, check NV12 + marker + monotonic PTS ----
	int video_count = 0;
	double last_video_pts = -1.0;
	int bright_marker_frames = 0;

	while (auto frame = backend.next_video_frame()) {
		CHECK(frame->pixel_format == core::PixelFormat::NV12);
		CHECK(frame->native_handle != nullptr);
		CHECK(frame->width == kWidth);
		CHECK(frame->height == kHeight);

		CHECK(frame->pts_seconds >= last_video_pts);
		last_video_pts = frame->pts_seconds;

		// Same tolerance rationale as the AVF test: white block (Y'=235), encoder
		// loss + chroma siting drags the mean down; require >= 170 over the
		// text-free quadrant.
		ID3D11Texture2D *tex = static_cast<ID3D11Texture2D *>(frame->native_handle);
		double luma = mean_block_luma(tex, static_cast<UINT>(frame->plane_slice));
		if (luma >= 170.0) {
			++bright_marker_frames;
		}

		frame->release();
		++video_count;
	}

	CHECK_FALSE(backend.had_error());
	CHECK(video_count >= kFrames - 1);
	CHECK(video_count <= kFrames + 1);
	CHECK(bright_marker_frames >= video_count - 1);

	// ---- Audio: re-open + seek to 0, pump PCM ----
	REQUIRE(backend.open(fixture));
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

	const long nominal = static_cast<long>(48000.0 * kFrames / kFps);
	CHECK(audio_frames_total >= nominal / 2);
}

TEST_CASE("MF backend reports error on a bogus path") {
	mf::MfBackend backend;
	CHECK_FALSE(backend.open("C:/no/such/file/really_not_here.mp4"));
}

TEST_CASE("MF backend enumerates audio tracks for single-track clip") {
	const std::string fixture = ensure_fixture();
	if (fixture.empty()) {
		WARN_MESSAGE(false, "ffmpeg unavailable or fixture generation failed — skipping single-track audio enumeration");
		return;
	}

	mf::MfBackend backend;
	REQUIRE(backend.open(fixture));

	CHECK(backend.audio_track_count() == 1);

	const auto info = backend.audio_track_info(0);
	CHECK(info.channels >= 1);
	CHECK(info.sample_rate == 48000);
	CHECK(info.is_default == true);
	// gen_test_media.sh tags track 0 as 'eng' with a stream title; the backend
	// normalizes MF's RFC 1766 tag back to the ISO 639-2 code AVF reports.
	CHECK(info.language == "eng");
	CHECK(info.name == "Track 0 (eng)");
}

TEST_CASE("MF backend enumerates audio tracks for multi-track clip") {
	multi_track_cases::run_multi_track_enumeration_case<mf::MfBackend>(ensure_multi_track_fixture(), check_track0_name);
}

TEST_CASE("MF backend selects audio track pre-play for multi-track clip") {
	multi_track_cases::run_preplay_selection_case<mf::MfBackend>(ensure_multi_track_fixture());
}

TEST_CASE("MF backend reselects audio track mid-decode without disturbing video") {
	multi_track_cases::run_midstream_reselect_case<mf::MfBackend>(ensure_multi_track_fixture());
}

TEST_CASE("MF backend reselects audio track near end-of-stream") {
	multi_track_cases::run_near_end_reselect_case<mf::MfBackend>(ensure_multi_track_fixture(), check_near_end_pts_bound);
}

TEST_CASE("MF backend reselect to same track is valid") {
	multi_track_cases::run_same_track_reselect_case<mf::MfBackend>(ensure_multi_track_fixture());
}

TEST_CASE("MF backend reselect clamps out-of-range index") {
	multi_track_cases::run_reselect_clamp_case<mf::MfBackend>(ensure_multi_track_fixture());
}

TEST_CASE("MF backend defers select_audio_track() until the next seek") {
	multi_track_cases::run_defers_select_until_seek_case<mf::MfBackend>(ensure_multi_track_fixture());
}

TEST_CASE("MF backend keeps a reselected audio track across a later seek") {
	multi_track_cases::run_reselect_keeps_across_seek_case<mf::MfBackend>(ensure_multi_track_fixture());
}

#endif // _WIN32
