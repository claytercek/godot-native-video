#pragma once

// -----------------------------------------------------------------------
// mf_backend_impl.h — MfBackend::Impl definition, shared by mf_backend.cpp
// (open/close/video decode pump) and mf_audio.cpp (audio-track enumeration
// + selection). Split out of mf_backend.cpp to keep both translation units
// well under the file-size ceiling; there is exactly one Impl definition,
// included by both .cpp files.
// -----------------------------------------------------------------------

#include "mf_backend.h"
#include "com_raii.h"

#if defined(_WIN32)

#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <d3d11.h>
#include <dxgi.h>

#include <string>
#include <vector>

// MFTIME / LONGLONG sample times are in 100-nanosecond units (10^7 per
// second), the Media Foundation time base. PTS in seconds = mf_time / 1e7.
// Shared by mf_backend.cpp (read_duration/seek/decode pump) and
// mf_audio.cpp (build_audio_reader's initial position).
namespace {
constexpr double kMfTicksPerSecond = 10'000'000.0;

inline double mf_ticks_to_seconds(LONGLONG ticks) {
	return static_cast<double>(ticks) / kMfTicksPerSecond;
}
inline LONGLONG seconds_to_mf_ticks(double seconds) {
	return static_cast<LONGLONG>(seconds * kMfTicksPerSecond + 0.5);
}
} // namespace

namespace mf {

// MF reports MF_SD_LANGUAGE as an RFC 1766 tag ("en", "es"); AVF reports the
// container's ISO 639-2 code ("eng", "spa"). Convert to ISO 639-2/T so track
// metadata is identical across platforms; unknown tags pass through
// unchanged. Defined in mf_audio.cpp; called from mf_backend.cpp's
// configure_video_stream() during the initial audio-track scan.
std::string normalize_language_tag(const std::string &tag);

// -----------------------------------------------------------------------
// MfBackend::Impl — holds the MF/D3D11 objects (COM-managed via ComPtr) and the
// scratch buffer whose lifetime backs the audio pointer we return. This mirrors
// AvfBackend::Impl one-for-one.
// -----------------------------------------------------------------------
class MfBackend::Impl {
public:
	// D3D11 device + the DXGI device manager that the source reader uses to
	// hardware-decode straight into D3D11 NV12 textures. Created once in open()
	// and reused across seek() (unlike the source reader, which is single-pass
	// in the same sense AVAssetReader is, so we recreate it on seek via a fresh
	// SetCurrentPosition — MF supports rewinding a reader, so we keep one reader
	// and just seek it).
	ComPtr<ID3D11Device> d3d_device;
	ComPtr<ID3D11DeviceContext> d3d_context;
	ComPtr<IMFDXGIDeviceManager> dxgi_manager;
	ComPtr<IMFSourceReader> reader;

	// Non-null only after reselect_audio_track(); reset by open()/seek().
	// Dedicated audio-only source reader so a mid-decode track switch can
	// prime the new track at the requested position without repositioning
	// (and thus disturbing) the shared reader's video stream. Toggling
	// per-stream selection on the shared reader alone cannot implement
	// reselect: a stream that was deselected when the media source last
	// started never delivers samples — ReadSample reports end-of-stream —
	// until the source is restarted by a position change.
	// next_audio_chunk() reads from audio_reader when it is non-null.
	ComPtr<IMFSourceReader> audio_reader;

	std::wstring path;

	double duration = 0.0;
	int width = 0;
	int height = 0;
	int audio_channels = 0;
	int audio_rate = 0;

	int video_stream_index = -1;
	int audio_stream_index = -1;

	// Negotiated colorimetry (read from the video stream's current media type
	// at open time, and re-read on a native-type change mid-stream). Defaults:
	// BT.709, video range, 8-bit — same as today's hard-coded shader constants
	// and the AVF backend's untagged-clip default. bit_depth is set by
	// configure_video_stream() before open() returns: 10 when the video
	// stream output type is P010 (10-bit source, matched), 8 for NV12 (8-bit
	// source, or a 10-bit source whose P010 request failed and fell back to
	// NV12).
	core::Colorimetry color_ = core::Colorimetry::bt709_defaults();

	bool error = false;
	bool com_initialized = false;
	bool mf_started = false;

	// Per-track audio metadata. Populated by configure_video_stream()
	// during the initial stream scan.
	std::vector<core::AudioTrackInfo> audio_tracks;

	// Maps audio track index (position in audio_tracks) to the MF source
	// reader stream index used by SetStreamSelection / SetCurrentMediaType.
	std::vector<int> audio_stream_indices;

	// The desired audio track index (set by select_audio_track()/
	// reselect_audio_track()). Per the Backend contract, a select_audio_track()
	// call takes effect on the next seek()/open() rather than immediately.
	int selected_audio_track = 0;
	// The audio track index the shared reader (`reader`) is actually
	// configured for. Differs from selected_audio_track between a
	// select_audio_track() call and the following seek(), which is when
	// switch_audio_track() catches the shared reader up.
	int applied_audio_track = 0;

	// Backing store for the most recent decoded audio chunk. core::AudioChunk
	// returns a borrowed const float*, so the buffer must outlive the returned
	// chunk; it stays valid until the next next_audio_chunk() call.
	std::vector<float> audio_scratch;

	bool create_device();
	bool create_reader();
	bool configure_video_stream();
	bool configure_audio_stream();
	// Switch audio output to the track at `track_index` (position in
	// audio_tracks). Deselects the old audio stream, selects the new one,
	// and reconfigures PCM output. Returns true on success; on failure
	// the old stream selection is left deselected and audio_stream_index
	// is set to -1 (no audio).
	bool switch_audio_track(int track_index);
	// Select stream `aidx` on `target_reader` and negotiate interleaved
	// float32 PCM output, updating audio_channels / audio_rate from the
	// negotiated type. Shared by the combined reader and the dedicated
	// audio-only reader.
	bool configure_pcm_output(IMFSourceReader *target_reader, DWORD aidx);
	// Build a dedicated audio-only source reader for `track_index`,
	// positioned at `start_time`. Used by reselect_audio_track().
	bool build_audio_reader(int track_index, double start_time);
	void read_duration();
	void read_colorimetry(IMFMediaType *type);
	// Read a wide-string stream-descriptor attribute (e.g. MF_SD_LANGUAGE)
	// for stream `stream_index` and return it as UTF-8; empty if absent.
	std::string read_stream_string_attribute(DWORD stream_index, REFGUID guid);
	// Sort audio_tracks/audio_stream_indices into container track order.
	// MF's MP4 source enumerates streams in an order unrelated to the file's
	// trak order (observed: reversed), but the cross-platform contract is that
	// audio track index N names the same physical track on every backend.
	void reorder_audio_tracks_by_container_order();

	void teardown() {
		audio_reader.reset();
		reader.reset();
		dxgi_manager.reset();
		d3d_context.reset();
		d3d_device.reset();
		if (mf_started) {
			MFShutdown();
			mf_started = false;
		}
		if (com_initialized) {
			CoUninitialize();
			com_initialized = false;
		}
	}
};

} // namespace mf

#endif // _WIN32
