// -----------------------------------------------------------------------
// test_avf_backend.mm — headless integration test for the AVFoundation
// Decoder-mode Backend. NO Godot, NO RenderingDevice.
//
// It generates (on demand) a synthetic marker clip via tools/gen_test_media.sh
// and decodes it end-to-end through avf::AvfBackend, asserting:
//   - NV12 video frames are produced with the expected count (±1 GOP slack);
//   - the burned-in white frame-index marker is present (mean luma of the
//     top-left block is bright) on the marked frames, within encode tolerance;
//   - video PTS and audio PTS are each monotonic non-decreasing;
//   - PCM float32 audio is extracted with sane PTS;
//   - no decode errors occur.
//
// If ffmpeg is unavailable the fixture cannot be built and the assertions are
// skipped gracefully (WARN, not fail). On this build machine ffmpeg IS present
// so the assertions run for real.
// -----------------------------------------------------------------------

#include "vendor/doctest.h"

#include "avf_backend.h"
#include "cf_raii.h"

#import <CoreVideo/CoreVideo.h>

#include <sys/stat.h>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

namespace {

// Test-clip parameters. Kept small so the test is fast; the marker block is
// 80x80 px in the top-left, the burned-in text is black inside it.
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
	// `command -v` exits 0 when ffmpeg is on PATH.
	return std::system("command -v ffmpeg >/dev/null 2>&1") == 0;
}

// Locate the repo root from this test's compile-time directory. We resolve
// paths relative to the current working directory (scons runs from repo root)
// and fall back to environment override REPO_ROOT if set.
std::string repo_root() {
	if (const char *env = std::getenv("REPO_ROOT")) {
		return std::string(env);
	}
	return "."; // scons invokes ./bin/avf_tests from the repo root
}

// Generate the fixture if missing. Returns the fixture path, or empty on
// failure (e.g. ffmpeg missing).
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
	const std::string fixture = root + "/tests/fixtures/synthetic_avf.mp4";
	if (file_exists(fixture)) {
		return fixture;
	}
	if (!ffmpeg_available()) {
		return {};
	}
	char cmd[1024];
	std::snprintf(cmd, sizeof(cmd),
			"%s/tools/gen_test_media.sh --frames %d --fps %d --width %d --height %d --output %s "
			">/dev/null 2>&1",
			root.c_str(), kFrames, kFps, kWidth, kHeight, fixture.c_str());
	if (std::system(cmd) != 0) {
		return {};
	}
	return file_exists(fixture) ? fixture : std::string{};
}

// Generate a 3-track multi-track fixture on demand. The fixture is a small
// clip (6 frames at 3 fps) with 3 audio streams at disjoint frequency bands.
// Kept small so the test is fast; only track-level metadata is probed, not
// decoded.
constexpr int kMultiFrames = 6;
constexpr int kMultiFps = 3;
constexpr int kMultiTracks = 3;

std::string ensure_multi_track_fixture() {
	const std::string root = repo_root();
	const std::string fixture = root + "/tests/fixtures/synthetic_multitrack_avf.mp4";
	if (file_exists(fixture)) {
		return fixture;
	}
	if (!ffmpeg_available()) {
		return {};
	}
	char cmd[2048];
	std::snprintf(cmd, sizeof(cmd),
			"%s/tools/gen_test_media.sh --frames %d --fps %d --output %s --multi-track %d "
			">/dev/null 2>&1",
			root.c_str(), kMultiFrames, kMultiFps, fixture.c_str(), kMultiTracks);
	if (std::system(cmd) != 0) {
		return {};
	}
	return file_exists(fixture) ? fixture : std::string{};
}

// Mean luma over the interior of the top-left marker block, read from the NV12
// luma plane (plane 0). We sample the block interior but skip a margin so the
// black burned-in text and any block-edge antialiasing don't dominate.
double mean_block_luma(CVPixelBufferRef pb) {
	CVReturn lk = CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
	REQUIRE(lk == kCVReturnSuccess);

	const uint8_t *luma =
			static_cast<const uint8_t *>(CVPixelBufferGetBaseAddressOfPlane(pb, 0));
	const size_t stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0);
	REQUIRE(luma != nullptr);

	// Sample the bottom-right quadrant of the block to avoid the text glyphs
	// (text is anchored top-left at x=5,y=5 with fontsize 40).
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
	CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
	return n > 0 ? sum / n : 0.0;
}

} // namespace

TEST_CASE("AVF backend decodes synthetic clip to NV12 + PCM with monotonic PTS") {
	const std::string fixture = ensure_fixture();
	if (fixture.empty()) {
		WARN_MESSAGE(false, "ffmpeg unavailable or fixture generation failed — skipping AVF decode assertions");
		return;
	}

	avf::AvfBackend backend;
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

		// PTS must be monotonic non-decreasing.
		CHECK(frame->pts_seconds >= last_video_pts);
		last_video_pts = frame->pts_seconds;

		// Read back the NV12 luma plane and check the marker block is bright.
		// Tolerance rationale: the source block is pure white (Y'=235 in
		// video-range BT.709). H.264 at crf 18 plus 4:2:0 chroma siting and
		// ringing around the black text drags the mean down a little, so we
		// require mean luma >= 170 (out of 255) over the text-free quadrant —
		// comfortably above the black background (~16) and any mid-grey, while
		// leaving generous headroom for encoder loss.
		CVPixelBufferRef pb = static_cast<CVPixelBufferRef>(frame->native_handle);
		double luma = mean_block_luma(pb);
		if (luma >= 170.0) {
			++bright_marker_frames;
		}

		frame->release(); // drop the surface retain
		++video_count;
	}

	CHECK_FALSE(backend.had_error());

	// Expected frame count within ±1: libx264 may trim/duplicate a boundary
	// frame depending on GOP/timebase rounding, so we allow one frame of slack.
	CHECK(video_count >= kFrames - 1);
	CHECK(video_count <= kFrames + 1);

	// Every decoded frame carries the white marker block, so essentially all
	// frames should read bright. Allow the same ±1 slack as the count.
	CHECK(bright_marker_frames >= video_count - 1);

	// ---- Audio: re-open (the reader is single-pass) and pump PCM ----
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

	// Roughly kFrames/kFps seconds of audio at 48 kHz. AAC priming/padding
	// makes the exact sample count fuzzy, so just sanity-check the magnitude:
	// at least half the nominal duration was delivered.
	const long nominal = static_cast<long>(48000.0 * kFrames / kFps);
	CHECK(audio_frames_total >= nominal / 2);
}

TEST_CASE("AVF backend reports error on a bogus path") {
	avf::AvfBackend backend;
	CHECK_FALSE(backend.open("/no/such/file/really_not_here.mp4"));
}

TEST_CASE("AVF backend enumerates audio tracks for single-track clip") {
	const std::string fixture = ensure_fixture();
	if (fixture.empty()) {
		WARN_MESSAGE(false, "ffmpeg unavailable or fixture generation failed — skipping single-track audio enumeration");
		return;
	}

	avf::AvfBackend backend;
	REQUIRE(backend.open(fixture));

	// Single-track clip: count is 1 when audio is present.
	CHECK(backend.audio_track_count() == 1);

	// Per-track metadata for the single track.
	const auto info = backend.audio_track_info(0);
	CHECK(info.channels >= 1);
	CHECK(info.sample_rate == 48000);
	CHECK(info.is_default == true);
	// Language may be set by gen_test_media.sh ('eng') or empty depending
	// on AVAssetTrack resolution; accept either.
	CHECK(info.name.empty()); // name is always empty in v1
}

TEST_CASE("AVF backend enumerates audio tracks for multi-track clip") {
	const std::string fixture = ensure_multi_track_fixture();
	if (fixture.empty()) {
		WARN_MESSAGE(false, "ffmpeg unavailable or fixture generation failed — skipping multi-track audio enumeration");
		return;
	}

	avf::AvfBackend backend;
	REQUIRE(backend.open(fixture));

	CHECK(backend.audio_track_count() == kMultiTracks);

	// Track 0: eng, default
	const auto t0 = backend.audio_track_info(0);
	// gen_test_media.sh tags track 0 as 'eng'
	CHECK(t0.language == "eng");
	CHECK(t0.is_default == true);
	CHECK(t0.channels >= 1);
	CHECK(t0.sample_rate == 48000);
	CHECK(t0.name.empty());

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

	// Out-of-range index returns empty AudioTrackInfo (defined behaviour
	// in the concrete backend, not UB per the virtual contract).
	const auto t99 = backend.audio_track_info(99);
	CHECK(t99.channels == 0);
	CHECK(t99.language.empty());
	CHECK(t99.sample_rate == 0);
	CHECK(t99.is_default == false);
}

TEST_CASE("AVF backend selects audio track pre-play for multi-track clip") {
	const std::string fixture = ensure_multi_track_fixture();
	if (fixture.empty()) {
		WARN_MESSAGE(false, "ffmpeg unavailable or fixture generation failed -- skipping multi-track selection");
		return;
	}

	// ---- Open with default (track 0), verify default metadata ----
	avf::AvfBackend backend;
	REQUIRE(backend.open(fixture));
	CHECK(backend.audio_track_count() == kMultiTracks);
	// Track 0: eng, default
	const auto t0 = backend.audio_track_info(0);
	CHECK(t0.language == "eng");
	CHECK(t0.is_default == true);
	CHECK(t0.channels >= 1);
	CHECK(t0.sample_rate == 48000);

	// ---- Select track 1 (fra, non-default) ----
	backend.select_audio_track(1);
	const auto t1_check = backend.audio_track_info(1);
	CHECK(t1_check.language == "fra");
	// After selection, audio_channel_count/audio_sample_rate should reflect
	// the selected track. Re-open to force a fresh reader so the selection
	// takes effect (select_audio_track with a fresh open applies immediately).
	REQUIRE(backend.open(fixture));
	backend.select_audio_track(1);

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
	// The backend clamps to the nearest valid index. Track 0 (the default)
	// is nearest to index -1 or index >= count.
	REQUIRE(backend.open(fixture));
	backend.select_audio_track(99); // out of range
	// audio_channel_count should still be valid (from track 0, clamped).
	CHECK(backend.audio_channel_count() >= 1);
	CHECK(backend.audio_sample_rate() == 48000);

	// Decode should still produce valid PCM from the fallback (track 0).
	audio_chunks = 0;
	audio_frames_total = 0;
	while (auto chunk = backend.next_audio_chunk()) {
		CHECK(chunk->samples != nullptr);
		CHECK(chunk->frame_count > 0);
		CHECK(chunk->channel_count >= 1);
		CHECK(chunk->sample_rate == 48000);
		audio_frames_total += chunk->frame_count;
		++audio_chunks;
	}
	CHECK_FALSE(backend.had_error());
	CHECK(audio_chunks > 0);
	CHECK(audio_frames_total >= nominal / 2);
}

TEST_CASE("AVF backend reselects audio track mid-decode without disturbing video") {
	const std::string fixture = ensure_multi_track_fixture();
	if (fixture.empty()) {
		WARN_MESSAGE(false, "ffmpeg unavailable or fixture generation failed -- skipping reselect test");
		return;
	}

	avf::AvfBackend backend;
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
		// Read a limited number of chunks before triggering reselect.
		if (audio_pre >= 3) {
			break;
		}
	}
	CHECK(audio_pre >= 3);
	CHECK_FALSE(backend.had_error());

	// --- Reselect to track 1 (fra) at current position ---
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
	// Note: audio may already be at EOS after the early break above, so we
	// drain whatever remains but don't require more chunks.
	while (auto chunk = backend.next_audio_chunk()) {
		CHECK(chunk->pts_seconds >= last_audio_pts);
		last_audio_pts = chunk->pts_seconds;
	}
	CHECK_FALSE(backend.had_error());
}

TEST_CASE("AVF backend reselects audio track near end-of-stream") {
	const std::string fixture = ensure_multi_track_fixture();
	if (fixture.empty()) {
		WARN_MESSAGE(false, "ffmpeg unavailable or fixture generation failed -- skipping end-of-stream reselect test");
		return;
	}

	avf::AvfBackend backend;
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
	// Seek near the end (last keyframe before the last few frames).
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
	// The first post-reselect frame should start near `near_end` (within one
	// keyframe interval), not jump back to position 0.
	CHECK(first_video_pts >= 0.0);
	CHECK(first_video_pts < near_end + 1.0);
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

TEST_CASE("AVF backend reselect to same track is valid") {
	const std::string fixture = ensure_multi_track_fixture();
	if (fixture.empty()) {
		WARN_MESSAGE(false, "ffmpeg unavailable or fixture generation failed -- skipping same-track reselect test");
		return;
	}

	avf::AvfBackend backend;
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

TEST_CASE("AVF backend reselect clamps out-of-range index") {
	const std::string fixture = ensure_multi_track_fixture();
	if (fixture.empty()) {
		WARN_MESSAGE(false, "ffmpeg unavailable or fixture generation failed -- skipping reselect clamp test");
		return;
	}

	avf::AvfBackend backend;
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
