// -----------------------------------------------------------------------
// test_mf_clip_matrix.cpp — real-clip format-matrix coverage for the Media
// Foundation (Windows) Decoder-mode Backend. NO Godot, NO RenderingDevice.
//
// Structural mirror of tests/avf/test_avf_clip_matrix.mm. Drives every clip in
// tests/fixtures/matrix/matrix.list through mf::MfBackend and asserts the same
// real-world decode contract (dimensions exact, decode success, frame count
// +/-1, AAC stereo @ 48 kHz, monotonic PTS, PTS drift within half a frame).
//
// WINDOWS-ONLY: the body is under #if _WIN32 and is compiled only by
// `scons target=mf_tests platform=windows`. Clips missing because
// tools/gen_clip_matrix.sh hasn't run are skipped with a WARN, never a failure.
//
// STATUS: implemented but NOT compiled/run/verified on the authoring host
// (macOS, no Windows toolchain). A Windows dev / CI runner must build + run it.
// -----------------------------------------------------------------------

#include "vendor/doctest.h"

#if defined(_WIN32)

#include "common/clip_matrix.h"
#include "mf_backend.h"

#include <cmath>
#include <string>

TEST_CASE("MF backend decodes the real-clip format matrix") {
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

		CAPTURE(clip.file);

		mf::MfBackend backend;
		REQUIRE(backend.open(path));

		CHECK(backend.video_width() == clip.width);
		CHECK(backend.video_height() == clip.height);
		CHECK(backend.audio_sample_rate() == clip.audio_rate);
		CHECK(backend.audio_channel_count() == clip.audio_channels);

		const double interval = 1.0 / static_cast<double>(clip.fps);
		const double budget = interval * 0.5;

		int video_count = 0;
		double last_pts = -1.0;
		double max_drift = 0.0;
		while (auto frame = backend.next_video_frame()) {
			CHECK(frame->pixel_format == core::PixelFormat::NV12);
			CHECK(frame->native_handle != nullptr);
			CHECK(frame->width == clip.width);
			CHECK(frame->height == clip.height);

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
