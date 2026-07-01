// -----------------------------------------------------------------------
// platform_video_stream.cpp — see header.
// -----------------------------------------------------------------------

#include "platform_video_stream.h"
#include "platform_video_stream_playback.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/object.hpp> // ObjectDB::get_instance
#include <godot_cpp/classes/project_settings.hpp>
#include <godot_cpp/variant/dictionary.hpp>

#include "../core/backend.h"
#include "backend_factory.h"

using namespace godot;

void PlatformVideoStream::_bind_methods() {
	ClassDB::bind_static_method("PlatformVideoStream", D_METHOD("hdr_decode_supported"),
			&PlatformVideoStream::hdr_decode_supported);

	ClassDB::bind_method(D_METHOD("set_output_mode", "mode"), &PlatformVideoStream::set_output_mode);
	ClassDB::bind_method(D_METHOD("get_output_mode"), &PlatformVideoStream::get_output_mode);
	ADD_PROPERTY(PropertyInfo(Variant::INT, "output_mode", PROPERTY_HINT_ENUM, "SDR,HDR"),
			"set_output_mode", "get_output_mode");

	// Expose the audio-track probe so GDScript can enumerate tracks before
	// playback. Returns an Array of Dictionaries with per-track metadata;
	// array position is the track index for VideoStreamPlayer.audio_track.
	ClassDB::bind_method(D_METHOD("get_audio_tracks"), &PlatformVideoStream::get_audio_tracks);
}

bool PlatformVideoStream::hdr_decode_supported() {
#if defined(__APPLE__)
	// macOS (and iOS) have Metal-accelerated VideoToolbox which can produce
	// 10-bit biplanar surfaces (x420) that we import zero-copy via
	// CVMetalTextureCache. Return true unconditionally: every Metal-capable
	// Mac (Intel since 2012, all Apple Silicon) supports this path.
	return true;
#elif defined(_WIN32)
	// Windows Media Foundation negotiates P010 output for 10-bit HEVC (Main10)
	// sources on every Import Path (CPU-Copy readback by default; the
	// zero-copy DXGI/D3D12 paths when enabled), matching the source instead
	// of down-converting to 8-bit NV12.
	return true;
#else
	// Linux does not yet support the 10-bit decode path. Return false.
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

Array PlatformVideoStream::get_audio_tracks() {
	if (audio_tracks_probed_) {
		return cached_audio_tracks_;
	}
	audio_tracks_probed_ = true;

	// Lazy probe: open the clip briefly to read audio track metadata, then
	// close the backend. The result (including empty, on failure or for a
	// legitimately audio-less clip) is cached so subsequent queries are free
	// and the probe only ever happens once.
	std::unique_ptr<core::Backend> backend = platform_media::make_backend();

	String os_path = ProjectSettings::get_singleton()->globalize_path(get_file());
	const std::string utf8 = os_path.utf8().get_data();

	if (!backend->open(utf8)) {
		// Cache an empty array on failure (caller checks is_empty()).
		cached_audio_tracks_ = Array();
		return cached_audio_tracks_;
	}

	const int count = backend->audio_track_count();
	Array tracks;
	tracks.resize(count);

	for (int i = 0; i < count; ++i) {
		const core::AudioTrackInfo info = backend->audio_track_info(i);
		Dictionary dict;
		dict["language"] = String(info.language.c_str());
		dict["name"] = String(info.name.c_str());
		dict["channels"] = info.channels;
		dict["sample_rate"] = info.sample_rate;
		dict["default"] = info.is_default;
		tracks[i] = dict;
	}

	backend->close();
	cached_audio_tracks_ = tracks;
	return cached_audio_tracks_;
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
