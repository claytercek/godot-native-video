// -----------------------------------------------------------------------
// test_avf_clip_matrix.mm — real-clip format-matrix coverage for the AVF
// (macOS) Decoder-mode Backend. NO Godot, NO RenderingDevice.
//
// Drives every clip in tests/fixtures/matrix/matrix.list through
// avf::AvfBackend and asserts the real-world decode contract:
//   - dimensions exact (width/height match the manifest);
//   - decode succeeds with no error;
//   - decoded video frame count within +/-1 of the manifest (GOP/timebase slack);
//   - audio: AAC stereo at 48 kHz, monotonic PTS, ~clip duration of samples;
//   - PTS drift within budget: each video PTS stays within half a frame interval
//     of its ideal index*interval position (real encoder timebase quirks must
//     not accumulate drift).
//
// The clips are Git-LFS binaries. If a clip is missing or is still an LFS
// pointer (smudge didn't run, ffmpeg didn't regenerate), that clip is skipped
// with a WARN — never a hard failure — so the suite stays green in environments
// without the media, exactly like the synthetic-clip test.
// -----------------------------------------------------------------------

#include "vendor/doctest.h"
#include "common/clip_matrix.h"

#include "avf_backend.h"

#include <cmath>
#include <string>

TEST_CASE("AVF backend decodes the real-clip format matrix") {
	const auto clips = clip_matrix::load();
	if (clips.empty()) {
		WARN_MESSAGE(false, "clip matrix manifest absent — skipping real-clip coverage");
		return;
	}

	int decoded_clips = 0;

	for (const auto &clip : clips) {
		const std::string path = clip_matrix::clip_path(clip);

		if (!clip_matrix::file_exists(path)) {
			WARN_MESSAGE(false, ("matrix clip missing (LFS not pulled / not generated): " + clip.file).c_str());
			continue;
		}
		if (clip_matrix::is_lfs_pointer(path)) {
			WARN_MESSAGE(false, ("matrix clip is an LFS pointer, run `git lfs pull`: " + clip.file).c_str());
			continue;
		}

		CAPTURE(clip.file);

		avf::AvfBackend backend;
		REQUIRE(backend.open(path));

		// --- Dimensions: exact ---
		CHECK(backend.video_width() == clip.width);
		CHECK(backend.video_height() == clip.height);

		// --- Audio track shape: AAC stereo @ 48 kHz ---
		CHECK(backend.audio_sample_rate() == clip.audio_rate);
		CHECK(backend.audio_channel_count() == clip.audio_channels);

		// --- Video: decode-success + count + PTS drift within budget ---
		const double interval = 1.0 / static_cast<double>(clip.fps);
		const double budget = interval * 0.5; // half a frame interval

		int video_count = 0;
		double last_pts = -1.0;
		double max_drift = 0.0;
		while (auto frame = backend.next_video_frame()) {
			CHECK(frame->pixel_format == core::PixelFormat::NV12);
			CHECK(frame->native_handle != nullptr);
			CHECK(frame->width == clip.width);
			CHECK(frame->height == clip.height);

			// Monotonic non-decreasing PTS.
			CHECK(frame->pts_seconds >= last_pts);
			last_pts = frame->pts_seconds;

			// Drift of this frame's PTS from its ideal index*interval slot.
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

		// --- Audio: re-open (single-pass reader), pump PCM, monotonic PTS ---
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

		// At least half the nominal duration of samples (AAC priming/padding fuzz).
		const long nominal =
				static_cast<long>(static_cast<double>(clip.audio_rate) * clip.frames / clip.fps);
		CHECK(audio_frames_total >= nominal / 2);

		++decoded_clips;
	}

	// If the manifest listed clips but none were decodable (all missing / LFS
	// pointers), warn loudly so an operator knows coverage didn't actually run.
	if (decoded_clips == 0) {
		WARN_MESSAGE(false, "no matrix clips were decodable — run tools/gen_clip_matrix.sh or `git lfs pull`");
	}
}
