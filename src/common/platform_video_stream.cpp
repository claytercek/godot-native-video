// -----------------------------------------------------------------------
// platform_video_stream.cpp — see header.
// -----------------------------------------------------------------------

#include "platform_video_stream.h"
#include "platform_video_stream_playback.h"

#include <godot_cpp/core/class_db.hpp>

using namespace godot;

void PlatformVideoStream::_bind_methods() {
	ClassDB::bind_static_method("PlatformVideoStream", D_METHOD("hdr_decode_supported"),
			&PlatformVideoStream::hdr_decode_supported);
}

bool PlatformVideoStream::hdr_decode_supported() {
#if defined(__APPLE__)
	// macOS (and iOS) have Metal-accelerated VideoToolbox which can produce
	// 10-bit biplanar surfaces (x420) that we import zero-copy via
	// CVMetalTextureCache. Return true unconditionally: every Metal-capable
	// Mac (Intel since 2012, all Apple Silicon) supports this path.
	return true;
#else
	// Other platforms (Windows w/ DXGI->Vulkan, Linux) do not yet support
	// the 10-bit decode path. Return false.
	return false;
#endif
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
