// -----------------------------------------------------------------------
// platform_video_stream.cpp — see header.
// -----------------------------------------------------------------------

#include "platform_video_stream.h"
#include "platform_video_stream_playback.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/object.hpp> // ObjectDB::get_instance

using namespace godot;

void PlatformVideoStream::_bind_methods() {
	ClassDB::bind_static_method("PlatformVideoStream", D_METHOD("hdr_decode_supported"),
			&PlatformVideoStream::hdr_decode_supported);

	ClassDB::bind_method(D_METHOD("set_output_mode", "mode"), &PlatformVideoStream::set_output_mode);
	ClassDB::bind_method(D_METHOD("get_output_mode"), &PlatformVideoStream::get_output_mode);
	ADD_PROPERTY(PropertyInfo(Variant::INT, "output_mode", PROPERTY_HINT_ENUM, "SDR,HDR"),
			"set_output_mode", "get_output_mode");
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

std::vector<PlatformVideoStreamPlayback *> PlatformVideoStream::live_playbacks() {
	std::vector<PlatformVideoStreamPlayback *> live;
	std::vector<uint64_t> alive;
	live.reserve(playback_ids_.size());
	alive.reserve(playback_ids_.size());
	for (uint64_t id : playback_ids_) {
		auto *playback =
				Object::cast_to<PlatformVideoStreamPlayback>(ObjectDB::get_instance(id));
		if (playback != nullptr) {
			live.push_back(playback);
			alive.push_back(id);
		}
	}
	playback_ids_ = std::move(alive);
	return live;
}

void PlatformVideoStream::set_output_mode(int mode) {
	if (mode < 0 || mode > 1) {
		return;
	}
	output_mode_ = mode;
	// Forward to every still-alive playback instantiated from this stream.
	for (PlatformVideoStreamPlayback *playback : live_playbacks()) {
		playback->set_output_mode(output_mode_);
	}
}

int PlatformVideoStream::get_output_mode() const {
	return output_mode_;
}

Ref<VideoStreamPlayback> PlatformVideoStream::_instantiate_playback() {
	Ref<PlatformVideoStreamPlayback> playback;
	playback.instantiate();
	playback->set_output_mode(output_mode_);

	// Prune dead ids, then record the new playback's id so set_output_mode()
	// can reach it later. The list stays bounded across many instantiations.
	live_playbacks();
	playback_ids_.push_back(playback->get_instance_id());

	// VideoStream::get_file() holds the path the ResourceFormatLoader recorded.
	if (!playback->load(get_file())) {
		// Return an (empty) playback rather than null so the player degrades
		// gracefully instead of crashing; _get_texture() yields a null texture.
		return playback;
	}
	return playback;
}
