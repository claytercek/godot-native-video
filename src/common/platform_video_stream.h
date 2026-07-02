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

namespace godot {

class PlatformVideoStream : public VideoStream {
	GDCLASS(PlatformVideoStream, VideoStream)

public:
	PlatformVideoStream() = default;
	~PlatformVideoStream() override = default;

	Ref<VideoStreamPlayback> _instantiate_playback() override;

	/// True when the platform supports 10-bit and HDR hardware decode output
	/// (x420 biplanar surfaces) through the zero-copy Metal import path. On
	/// macOS this is always true (Apple Silicon or Intel with Metal-accelerated
	/// VideoToolbox). On other platforms (Windows, Linux) returns false.
	static bool hdr_decode_supported();

protected:
	static void _bind_methods();
};

} // namespace godot
