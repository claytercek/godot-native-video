#pragma once

// -----------------------------------------------------------------------
// platform_video_stream.h — the VideoStream resource for native clips.
//
// A stock VideoStreamPlayer holds a VideoStream and calls
// _instantiate_playback() to get a VideoStreamPlayback. This resource carries
// the clip's file path (set by the ResourceFormatLoader) and instantiates a
// PlatformVideoStreamPlayback bound to it.
// -----------------------------------------------------------------------

#include <godot_cpp/classes/video_stream.hpp>
// Full definition required: GDCLASS registers _instantiate_playback, whose
// Ref<VideoStreamPlayback> return type must be a complete type at instantiation.
#include <godot_cpp/classes/video_stream_playback.hpp>

#include <cstdint>
#include <vector>

namespace godot {

class PlatformVideoStreamPlayback;

class PlatformVideoStream : public VideoStream {
	GDCLASS(PlatformVideoStream, VideoStream)

public:
	PlatformVideoStream() = default;
	~PlatformVideoStream() override = default;

	Ref<VideoStreamPlayback> _instantiate_playback() override;

	// --- Output mode ---
	// Mirrors the playback's output_mode (0 = SDR, 1 = HDR) so GDScript can set
	// it via VideoStreamPlayer.stream on stock Godot 4.4 (no get_stream_playback()).
	// Applied to new playbacks at instantiation and forwarded to live ones.
	// Known limitation: this mirror is one-way. Calling set_output_mode directly
	// on a PlatformVideoStreamPlayback changes that playback's pipeline but does
	// NOT update output_mode_ here, so callers should always drive the mode
	// through the stream rather than the playback.
	void set_output_mode(int mode);
	int get_output_mode() const;

	/// True when the platform supports 10-bit and HDR hardware decode output
	/// (x420 biplanar surfaces) through the zero-copy Metal import path. On
	/// macOS this is always true (Apple Silicon or Intel with Metal-accelerated
	/// VideoToolbox). On other platforms (Windows, Linux) returns false.
	static bool hdr_decode_supported();

protected:
	static void _bind_methods();

private:
	// Resolve playback_ids_ to the playbacks still alive, pruning dead ids.
	std::vector<PlatformVideoStreamPlayback *> live_playbacks();

	int output_mode_ = 0; // matches PlatformVideoStreamPlayback::OutputMode

	// Instance ids of playbacks instantiated from this stream. ObjectIDs, not
	// Refs, on purpose: the stream must never extend a playback's lifetime
	// (resource and playbacks can each outlive the other). Dead ids are pruned
	// whenever the list is walked.
	std::vector<uint64_t> playback_ids_;
};

} // namespace godot
