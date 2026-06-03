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

protected:
	static void _bind_methods();
};

} // namespace godot
