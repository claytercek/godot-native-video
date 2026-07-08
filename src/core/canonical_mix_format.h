#pragma once

// -----------------------------------------------------------------------
// canonical_mix_format.h — pure derivation of a playback's Canonical Mix
// Format from a Backend's audio tracks.
//
// The Canonical Mix Format (channel count + sample rate) is fixed for a
// playback's entire lifetime once load() returns. Deriving it is a pure
// function of a Backend's audio_track_count()/audio_track_info() queries —
// no DecodeScheduler, no clock, no state. Pulling it out of
// PlaybackController::load() lets the mixed-sample-rate / channel-clamp
// logic be unit-tested without spinning up the process-wide scheduler
// singleton the controller registers with.
//
// canonical_channels   — max channel count across all audio tracks,
//                        clamped to kMaxMixSourceChannels.
// canonical_sample_rate — the FIRST audio-bearing track's rate (NOT a
//                        shared rate across tracks). Mixed-sample-rate
//                        clips are a documented limitation: the default
//                        track's rate wins, and a later track with a
//                        differing rate gets exactly one warning here.
// has_audio             — true when any track carries audio.
// track_infos           — per-track metadata cached for mid-stream switch
//                        sample-rate validation.
// warnings              — mixed-sample-rate notice(s) generated during
//                        derivation; the controller drains these into its
//                        own take_warnings() queue.
// -----------------------------------------------------------------------

#include <string>
#include <vector>

#include "backend.h"
#include "channel_mixer.h"

namespace core {

struct CanonicalMixFormat {
	int channels = 0;
	int sample_rate = 0;
	bool has_audio = false;
	std::vector<AudioTrackInfo> track_infos;
	std::vector<std::string> warnings;
};

// Derive the Canonical Mix Format from a backend's audio tracks. Pure: reads
// only audio_track_count()/audio_track_info(), no scheduler, no side effects.
CanonicalMixFormat derive_canonical_mix_format(const Backend &backend);

} // namespace core
