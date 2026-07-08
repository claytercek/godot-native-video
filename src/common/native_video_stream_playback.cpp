// -----------------------------------------------------------------------
// native_video_stream_playback.cpp — see header.
// -----------------------------------------------------------------------

#include "native_video_stream_playback.h"

#include <godot_cpp/classes/audio_server.hpp>
#include <godot_cpp/classes/project_settings.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>

#include <algorithm>
#include <chrono>

#include "backend_factory.h"

using namespace godot;

namespace {

// -----------------------------------------------------------------------
// GodotMixSink — the Binding's core::MixSink implementation.
//
// The one Godot API call the Engine Core's audio drive reaches through:
// wraps VideoStreamPlayback::mix_audio(). Owns its own PackedFloat32Array
// scratch buffer (resized as needed, never per-tick) so the seam costs
// nothing beyond the copy from the controller's plain-float scratch into
// Godot's array type.
// -----------------------------------------------------------------------
class GodotMixSink final : public core::MixSink {
public:
	explicit GodotMixSink(VideoStreamPlayback &owner) :
			owner_(owner) {}

	int mix(const float *interleaved, int frame_count, int channel_count) override {
		const int64_t total = static_cast<int64_t>(frame_count) * channel_count;
		if (buffer_.size() < total) {
			buffer_.resize(total);
		}
		std::copy(interleaved, interleaved + total, buffer_.ptrw());
		return owner_.mix_audio(frame_count, buffer_, 0);
	}

private:
	VideoStreamPlayback &owner_;
	PackedFloat32Array buffer_;
};

} // namespace

NativeVideoStreamPlayback::NativeVideoStreamPlayback() :
		mix_sink_(std::make_unique<GodotMixSink>(*this)) {}

NativeVideoStreamPlayback::~NativeVideoStreamPlayback() {
	// Unregister from the shared pool first: this blocks until any in-flight
	// decode slice for our stream completes and releases every buffered surface,
	// so no worker can touch our Backend after this returns (no use-after-free).
	controller_.shutdown();
	present_.shutdown();
}

void NativeVideoStreamPlayback::_bind_methods() {
	ClassDB::bind_method(D_METHOD("get_color_info"), &NativeVideoStreamPlayback::get_color_info);

	ClassDB::bind_method(D_METHOD("set_output_mode", "mode"), &NativeVideoStreamPlayback::set_output_mode);
	ClassDB::bind_method(D_METHOD("get_output_mode"), &NativeVideoStreamPlayback::get_output_mode);
	ADD_PROPERTY(PropertyInfo(Variant::INT, "output_mode", PROPERTY_HINT_ENUM, "SDR,HDR"),
			"set_output_mode", "get_output_mode");
}

void NativeVideoStreamPlayback::flush_warnings() {
	for (const std::string &message : controller_.take_warnings()) {
		print_error(String(message.c_str()));
	}
}

bool NativeVideoStreamPlayback::load(const String &path) {
	std::unique_ptr<core::Backend> backend = native_video::make_backend();

	// Resolve a Godot res:// / user:// path to an absolute OS path the backend's
	// AVURLAsset can open. globalize_path leaves absolute OS paths untouched.
	String os_path = ProjectSettings::get_singleton()->globalize_path(path);
	const std::string utf8 = os_path.utf8().get_data();

	if (!backend->open(utf8)) {
		return false;
	}

	// Audio-master latency compensation shifts reported media time back so
	// it reflects what the speaker is emitting now, not what was just
	// pushed into the audio buffer. Resolved once here (a Godot query) and
	// handed to the controller as a plain parameter.
	double latency = 0.0;
	if (AudioServer *as = AudioServer::get_singleton()) {
		latency = as->get_output_latency();
	}

	controller_.load(std::move(backend), latency);
	flush_warnings();
	return true;
}

void NativeVideoStreamPlayback::_play() {
	controller_.play(now_ms());
	flush_warnings();
}

void NativeVideoStreamPlayback::_stop() {
	controller_.stop();
	flush_warnings();
}

bool NativeVideoStreamPlayback::_is_playing() const {
	return controller_.is_playing();
}

void NativeVideoStreamPlayback::_set_paused(bool paused) {
	controller_.set_paused(paused);
}

bool NativeVideoStreamPlayback::_is_paused() const {
	return controller_.is_paused();
}

double NativeVideoStreamPlayback::_get_length() const {
	return controller_.length();
}

double NativeVideoStreamPlayback::_get_playback_position() const {
	return controller_.position();
}

double NativeVideoStreamPlayback::now_ms() {
	// Monotonic wall clock for scrub velocity/debounce. steady_clock never jumps.
	using clock = std::chrono::steady_clock;
	const auto t = clock::now().time_since_epoch();
	return std::chrono::duration<double, std::milli>(t).count();
}

void NativeVideoStreamPlayback::_seek(double time) {
	controller_.seek(time, now_ms());
	flush_warnings();
}

void NativeVideoStreamPlayback::_set_audio_track(int idx) {
	controller_.request_audio_track(idx);
	flush_warnings();
}

Ref<Texture2D> NativeVideoStreamPlayback::_get_texture() const {
	// The engine-owned RGBA Texture2DRD. Godot samples ONLY this — never the
	// decoder surface.
	return present_.get_texture();
}

void NativeVideoStreamPlayback::_update(double delta) {
	std::optional<core::VideoFrame> frame = controller_.tick(delta, now_ms(), *mix_sink_);
	flush_warnings();
	if (frame.has_value()) {
		present_.present(std::move(*frame));
	}
}

int NativeVideoStreamPlayback::_get_channels() const {
	// Canonical Mix Format channel count (maximum across all audio tracks,
	// computed at load). Godot sizes its mix buffer from this and queries it
	// exactly once at play start, so it is stable for the playback's lifetime.
	return controller_.canonical_channels();
}

int NativeVideoStreamPlayback::_get_mix_rate() const {
	// Canonical Mix Format sample rate: the FIRST audio-bearing track's rate
	// (mixed-sample-rate clips are a documented limitation — see
	// PlaybackController::load()). The AudioServer resamples from this to
	// the device rate; the master clock uses it for samples->seconds.
	return controller_.canonical_sample_rate();
}

Dictionary NativeVideoStreamPlayback::get_color_info() const {
	const core::Colorimetry color = controller_.colorimetry();
	Dictionary info;
	info["matrix"] = static_cast<int>(color.matrix);
	info["primaries"] = static_cast<int>(color.primaries);
	info["transfer"] = static_cast<int>(color.transfer);
	info["range"] = static_cast<int>(color.range);
	info["bit_depth"] = color.bit_depth;
	// Report the effective output mode so callers can distinguish between
	// an SDR clip in HDR viewport vs a native HDR clip.
	info["output_mode"] = static_cast<int>(present_.output_mode());
	return info;
}

void NativeVideoStreamPlayback::set_output_mode(int mode) {
	if (mode < 0 || mode > 1) {
		return;
	}
	auto om = (mode == 1) ? native_video::OutputMode::HDR
						  : native_video::OutputMode::SDR;
	present_.set_output_mode(om);
}

int NativeVideoStreamPlayback::get_output_mode() const {
	return static_cast<int>(present_.output_mode());
}
