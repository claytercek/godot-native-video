#pragma once

#include <cstddef>
#include <vector>

namespace core {

// -----------------------------------------------------------------------
// AudioRing — Godot-free interleaved-PCM ring buffer for the audio path.
//
// The decode side pushes interleaved float32 samples decoded from the backend
// (core::AudioChunk::samples) into the ring; the mix side drains them into the
// buffer Godot hands us. Keeping this here (no Godot types) makes the partial-
// read / underrun behaviour unit-testable without an AudioServer.
//
// Units: a "frame" is one sample per channel. The ring stores raw interleaved
// floats and tracks channel count so frame<->float arithmetic stays correct.
//
// Threading: this is intended for a single producer (decode pump) and single
// consumer (mix), but unlike FrameQueue it is NOT lock-free — in the binding,
// audio is pumped and drained from the same place inside _update on the main
// thread for this slice (the shared decode-worker pool is a later slice).
// A small ring of plain floats is enough; we guard nothing here and document
// the single-thread assumption.
//
// Behaviour contract (the acceptance criterion: "handle partial reads/underrun
// gracefully, output silence on underrun, never block"):
//   * write() drops samples that don't fit (returns the count actually stored)
//     rather than blocking or growing unboundedly.
//   * read_frames() fills as many frames as are available, ZERO-FILLS the rest
//     (silence on underrun), and reports how many real frames it produced.
// -----------------------------------------------------------------------
class AudioRing {
public:
	// `channel_count` interleaved channels; `frame_capacity` frames of head-room.
	AudioRing(int channel_count, size_t frame_capacity) :
			channels_(channel_count < 1 ? 1 : channel_count),
			capacity_floats_((frame_capacity + 1) * static_cast<size_t>(channels_ < 1 ? 1 : channels_)),
			buffer_(capacity_floats_, 0.0f),
			head_(0),
			tail_(0) {}

	int channel_count() const { return channels_; }

	// Number of whole frames currently buffered.
	size_t available_frames() const {
		return floats_available() / static_cast<size_t>(channels_);
	}

	// Free frames before the ring is full.
	size_t free_frames() const {
		// capacity_floats_ includes one sentinel frame to distinguish full/empty.
		const size_t free_floats = capacity_floats_ - 1 - floats_available();
		return free_floats / static_cast<size_t>(channels_);
	}

	bool empty() const { return head_ == tail_; }

	// Drop everything (e.g. on seek / stop) so stale audio never plays.
	void clear() {
		head_ = 0;
		tail_ = 0;
	}

	// Write `frame_count` frames of interleaved samples (frame_count * channels
	// floats). Stores as many whole frames as fit; returns frames stored.
	size_t write(const float *interleaved, size_t frame_count) {
		const size_t can = free_frames();
		const size_t n = frame_count < can ? frame_count : can;
		const size_t floats = n * static_cast<size_t>(channels_);
		for (size_t i = 0; i < floats; ++i) {
			buffer_[tail_] = interleaved[i];
			tail_ = (tail_ + 1) % capacity_floats_;
		}
		return n;
	}

	// Drain up to `frame_count` frames into `out` (frame_count * channels
	// floats). Frames not available are written as silence (0.0f). Returns the
	// number of REAL (non-silence) frames produced — the caller uses this to
	// advance the master clock by exactly what the listener will hear.
	size_t read_frames(float *out, size_t frame_count) {
		const size_t have = available_frames();
		const size_t real = frame_count < have ? frame_count : have;

		const size_t ch = static_cast<size_t>(channels_);
		// Copy the real frames.
		for (size_t i = 0; i < real * ch; ++i) {
			out[i] = buffer_[head_];
			head_ = (head_ + 1) % capacity_floats_;
		}
		// Zero-fill the underrun tail.
		for (size_t i = real * ch; i < frame_count * ch; ++i) {
			out[i] = 0.0f;
		}
		return real;
	}

private:
	size_t floats_available() const {
		return (tail_ + capacity_floats_ - head_) % capacity_floats_;
	}

	int channels_;
	size_t capacity_floats_;
	std::vector<float> buffer_;
	size_t head_;
	size_t tail_;
};

} // namespace core
