// -----------------------------------------------------------------------
// backend.cpp — default implementations for core::Backend virtual methods
// that have single-track fallbacks.
// -----------------------------------------------------------------------

#include "backend.h"

namespace core {

int Backend::audio_track_count() const {
	return audio_channel_count() > 0 ? 1 : 0;
}

AudioTrackInfo Backend::audio_track_info(int /*index*/) const {
	AudioTrackInfo info;
	info.channels = audio_channel_count();
	info.sample_rate = audio_sample_rate();
	// index 0 is the default when there is only one track
	info.is_default = true;
	return info;
}

} // namespace core
