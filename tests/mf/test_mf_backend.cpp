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
// WINDOWS-ONLY: this file is compiled only by `scons target=mf_tests` on
// Windows. It is excluded everywhere else (the whole body is under #if _WIN32),
// so it must NEVER be added to the macOS / core_tests source sets.
// -----------------------------------------------------------------------

#include "vendor/doctest.h"

#if defined(_WIN32)

#include "mf_backend.h"

#include <d3d11.h>

#include <sys/stat.h>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

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

// Multi-track fixture: 6 frames at 3 fps, 3 audio streams with disjoint freq bands.
constexpr int kMultiFrames = 6;
constexpr int kMultiFps = 3;
constexpr int kMultiTracks = 3;

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
			root.c_str(), kMultiFrames, kMultiFps, fixture.c_str(), kMultiTracks);
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

double estimate_dominant_frequency_hz(const std::vector<float> &mono_samples, int sample_rate) {
	if (mono_samples.size() < 2 || sample_rate <= 0) {
		return 0.0;
	}
	int crossings = 0;
	for (size_t i = 1; i < mono_samples.size(); ++i) {
		if ((mono_samples[i - 1] < 0.0f) != (mono_samples[i] < 0.0f)) {
			++crossings;
		}
	}
	const double duration = static_cast<double>(mono_samples.size()) / sample_rate;
	return duration > 0.0 ? (crossings / 2.0) / duration : 0.0;
}

// True if `freq_hz` falls within track `track`'s Sync Ladder band, with a
// margin generous enough to absorb the zero-crossing estimate's error.
bool frequency_in_track_band(double freq_hz, int track) {
	const double lo = track * kTrackStrideHz + kTrackBaseHz - 300.0;
	const double hi = track * kTrackStrideHz + kTrackBaseHz + 200.0 * (kMultiFrames - 1) + 300.0;
	return freq_hz >= lo && freq_hz <= hi;
}

// Accumulate at least `min_seconds` of channel-0 samples from `backend`'s
// audio stream (fewer at end-of-stream). Deinterleaves channel 0 out of each
// chunk's frame-major PCM.
std::vector<float> accumulate_mono_audio(mf::MfBackend &backend, int sample_rate, double min_seconds) {
	std::vector<float> mono;
	const size_t target = static_cast<size_t>(static_cast<double>(sample_rate) * min_seconds);
	while (mono.size() < target) {
		auto chunk = backend.next_audio_chunk();
		if (!chunk) {
			break;
		}
		const int channels = chunk->channel_count > 0 ? chunk->channel_count : 1;
		for (int i = 0; i < chunk->frame_count; ++i) {
			mono.push_back(chunk->samples[static_cast<size_t>(i) * channels]);
		}
	}
	return mono;
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
	const std::string fixture = ensure_multi_track_fixture();
	if (fixture.empty()) {
		WARN_MESSAGE(false, "ffmpeg unavailable or fixture generation failed — skipping multi-track audio enumeration");
		return;
	}

	mf::MfBackend backend;
	REQUIRE(backend.open(fixture));

	CHECK(backend.audio_track_count() == kMultiTracks);

	// Track 0: eng, default — indices follow container track order, matching AVF.
	const auto t0 = backend.audio_track_info(0);
	CHECK(t0.language == "eng");
	CHECK(t0.is_default == true);
	CHECK(t0.channels >= 1);
	CHECK(t0.sample_rate == 48000);

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

TEST_CASE("MF backend selects audio track pre-play for multi-track clip") {
	const std::string fixture = ensure_multi_track_fixture();
	if (fixture.empty()) {
		WARN_MESSAGE(false, "ffmpeg unavailable or fixture generation failed -- skipping multi-track selection");
		return;
	}

	// ---- Open with default (track 0), verify default metadata ----
	mf::MfBackend backend;
	REQUIRE(backend.open(fixture));
	CHECK(backend.audio_track_count() == kMultiTracks);
	// Track 0: eng, default
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

TEST_CASE("MF backend reselects audio track mid-decode without disturbing video") {
	const std::string fixture = ensure_multi_track_fixture();
	if (fixture.empty()) {
		WARN_MESSAGE(false, "ffmpeg unavailable or fixture generation failed -- skipping reselect test");
		return;
	}

	mf::MfBackend backend;
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

TEST_CASE("MF backend reselects audio track near end-of-stream") {
	const std::string fixture = ensure_multi_track_fixture();
	if (fixture.empty()) {
		WARN_MESSAGE(false, "ffmpeg unavailable or fixture generation failed -- skipping end-of-stream reselect test");
		return;
	}

	mf::MfBackend backend;
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
	// On MF, the reader's position is unchanged by reselect, so video
	// should continue from where it was (near `near_end` for this test).
	CHECK(first_video_pts >= 0.0);
	CHECK(first_video_pts >= near_end - 1.0);
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

TEST_CASE("MF backend reselect to same track is valid") {
	const std::string fixture = ensure_multi_track_fixture();
	if (fixture.empty()) {
		WARN_MESSAGE(false, "ffmpeg unavailable or fixture generation failed -- skipping same-track reselect test");
		return;
	}

	mf::MfBackend backend;
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

TEST_CASE("MF backend reselect clamps out-of-range index") {
	const std::string fixture = ensure_multi_track_fixture();
	if (fixture.empty()) {
		WARN_MESSAGE(false, "ffmpeg unavailable or fixture generation failed -- skipping reselect clamp test");
		return;
	}

	mf::MfBackend backend;
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

TEST_CASE("MF backend defers select_audio_track() until the next seek") {
	const std::string fixture = ensure_multi_track_fixture();
	if (fixture.empty()) {
		WARN_MESSAGE(false, "ffmpeg unavailable or fixture generation failed -- skipping deferred selection regression");
		return;
	}

	mf::MfBackend backend;
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

TEST_CASE("MF backend keeps a reselected audio track across a later seek") {
	const std::string fixture = ensure_multi_track_fixture();
	if (fixture.empty()) {
		WARN_MESSAGE(false, "ffmpeg unavailable or fixture generation failed -- skipping reselect+seek regression");
		return;
	}

	mf::MfBackend backend;
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

#endif // _WIN32
