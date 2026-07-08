// -----------------------------------------------------------------------
// canonical_mix_format.cpp — see header.
// -----------------------------------------------------------------------

#include "canonical_mix_format.h"

#include <sstream>

namespace core {

CanonicalMixFormat derive_canonical_mix_format(const Backend &backend) {
	CanonicalMixFormat fmt;

	const int track_count = backend.audio_track_count();
	bool warned_mixed_sample_rates = false;
	for (int i = 0; i < track_count; ++i) {
		const AudioTrackInfo info = backend.audio_track_info(i);
		fmt.track_infos.push_back(info);
		if (info.channels > fmt.channels) {
			fmt.channels = info.channels;
		}
		if (info.channels > 0 && info.sample_rate > 0) {
			if (!fmt.has_audio) {
				fmt.sample_rate = info.sample_rate;
				fmt.has_audio = true;
			} else if (!warned_mixed_sample_rates && info.sample_rate != fmt.sample_rate) {
				std::ostringstream oss;
				oss << "Audio track " << i << " sample rate " << info.sample_rate
					<< " Hz differs from the canonical rate " << fmt.sample_rate
					<< " Hz. Mixed-sample-rate clips are not supported; this track "
					   "will play at the canonical rate and mid-stream switches to "
					   "it are refused.";
				fmt.warnings.push_back(oss.str());
				warned_mixed_sample_rates = true;
			}
		}
	}
	// Clamp to the max we know how to mix; larger channel counts are passed
	// through unmixed (the ring still fills and plays).
	if (fmt.channels > kMaxMixSourceChannels) {
		fmt.channels = kMaxMixSourceChannels;
	}
	return fmt;
}

} // namespace core
