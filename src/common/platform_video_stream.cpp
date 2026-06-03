// -----------------------------------------------------------------------
// platform_video_stream.cpp — see header.
// -----------------------------------------------------------------------

#include "platform_video_stream.h"
#include "platform_video_stream_playback.h"

#include <godot_cpp/core/class_db.hpp>

using namespace godot;

void PlatformVideoStream::_bind_methods() {
	// set_file/get_file are provided by the VideoStream base class; nothing to add.
}

Ref<VideoStreamPlayback> PlatformVideoStream::_instantiate_playback() {
	Ref<PlatformVideoStreamPlayback> playback;
	playback.instantiate();
	// VideoStream::get_file() holds the path the ResourceFormatLoader recorded.
	if (!playback->load(get_file())) {
		// Return an (empty) playback rather than null so the player degrades
		// gracefully instead of crashing; _get_texture() yields a null texture.
		return playback;
	}
	return playback;
}
