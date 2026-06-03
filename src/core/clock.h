#pragma once

#include <cstdint>

namespace core {

// -----------------------------------------------------------------------
// Clock — abstract media-time interface.
//
// The Engine Core owns the master playback clock. The audio subsystem
// drives it when audio is present (audio-master mode); a monotonic delta
// fallback is used when no audio track exists.
//
// All times are in seconds using double precision to represent PTS values
// accurately for media up to several hours long.
// -----------------------------------------------------------------------
class Clock {
public:
	virtual ~Clock() = default;

	// Return the current media presentation time in seconds.
	// This is the time against which frame PTS values are compared.
	virtual double media_time() const = 0;

	// Advance the clock by `delta_seconds` (monotonic fallback path).
	// Audio-master implementations may ignore this and advance solely from
	// sample-count accounting.
	virtual void advance(double delta_seconds) = 0;

	// Seek the clock to an absolute media time (e.g. after a scrub).
	virtual void set_time(double time_seconds) = 0;

	// Pause / resume ticking. A paused clock returns a constant media_time().
	virtual void set_paused(bool paused) = 0;
	virtual bool is_paused() const = 0;
};

// -----------------------------------------------------------------------
// MonotonicClock — simple non-audio-master reference implementation.
//
// Accumulates time from advance() calls; suitable for unit tests and for
// silent streams.
// -----------------------------------------------------------------------
class MonotonicClock final : public Clock {
public:
	explicit MonotonicClock(double initial_time = 0.0) :
			time_(initial_time), paused_(false) {}

	double media_time() const override { return time_; }

	void advance(double delta_seconds) override {
		if (!paused_ && delta_seconds > 0.0) {
			time_ += delta_seconds;
		}
	}

	void set_time(double time_seconds) override { time_ = time_seconds; }

	void set_paused(bool paused) override { paused_ = paused; }
	bool is_paused() const override { return paused_; }

private:
	double time_;
	bool paused_;
};

// -----------------------------------------------------------------------
// AudioMasterClock — drives media time from audio sample consumption.
//
// The mix callback reports `mixed_frames` PCM frames at `sample_rate`;
// the clock converts them to seconds and accumulates. An initial latency
// compensation offset accounts for the audio buffer depth so that media
// time reflects what the listener hears, not what was queued.
// -----------------------------------------------------------------------
class AudioMasterClock final : public Clock {
public:
	// `latency_seconds` is subtracted from the running time so that
	// media_time() represents "what the speaker is emitting now" rather
	// than "what was last pushed into the audio buffer."
	explicit AudioMasterClock(int sample_rate, double latency_seconds = 0.0) :
			sample_rate_(sample_rate),
			latency_seconds_(latency_seconds),
			accumulated_seconds_(0.0),
			paused_(false) {}

	// Called by the audio mix callback after mixing `frame_count` frames.
	void on_audio_mixed(int frame_count) {
		if (!paused_ && sample_rate_ > 0) {
			accumulated_seconds_ += static_cast<double>(frame_count) / static_cast<double>(sample_rate_);
		}
	}

	double media_time() const override {
		double t = accumulated_seconds_ - latency_seconds_;
		return t < 0.0 ? 0.0 : t;
	}

	// advance() is a no-op for the audio-master clock; time is governed
	// entirely by on_audio_mixed().
	void advance(double /*delta_seconds*/) override {}

	void set_time(double time_seconds) override {
		// After a seek the audio subsystem resets; re-anchor here.
		accumulated_seconds_ = time_seconds + latency_seconds_;
	}

	void set_paused(bool paused) override { paused_ = paused; }
	bool is_paused() const override { return paused_; }

	int sample_rate() const { return sample_rate_; }
	double latency_seconds() const { return latency_seconds_; }

private:
	int sample_rate_;
	double latency_seconds_;
	double accumulated_seconds_;
	bool paused_;
};

} // namespace core
