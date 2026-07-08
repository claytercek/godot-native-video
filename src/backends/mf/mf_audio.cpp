// -----------------------------------------------------------------------
// mf_audio.cpp — Media Foundation Backend audio-track machinery (Windows).
//
// Audio-track enumeration (container-order normalization, language-tag
// conversion) and track selection/reselection for mf::MfBackend. Split out
// of mf_backend.cpp to keep both translation units well under the
// file-size ceiling; the video decode pump and open/close/seek lifecycle
// stay in mf_backend.cpp, sharing the MfBackend::Impl definition via
// mf_backend_impl.h.
//
// Track selection has two halves, mirroring AvfBackend:
//   - select_audio_track() only records the desired track and refreshes the
//     channel/rate metadata; per the Backend contract it takes effect on the
//     next seek()/open(). switch_audio_track() is what actually reconfigures
//     the shared reader (deselect old stream, select new, renegotiate PCM),
//     and seek() calls it when the applied track is stale.
//   - reselect_audio_track() is the mid-decode path: it builds a dedicated
//     audio-only IMFSourceReader (build_audio_reader) primed at the request
//     position, because a stream deselected while the shared reader's media
//     source is running never delivers samples again until the source is
//     restarted by a position change — which would also disturb video.
// -----------------------------------------------------------------------

#include "mf_backend_impl.h"

#if defined(_WIN32)

#include <propvarutil.h>

#include <algorithm>
#include <string>
#include <utility>
#include <vector>

namespace mf {

// MF reports MF_SD_LANGUAGE as an RFC 1766 tag ("en", "es"); AVF reports the
// container's ISO 639-2 code ("eng", "spa"). Convert to ISO 639-2/T so track
// metadata is identical across platforms; unknown tags pass through unchanged.
std::string normalize_language_tag(const std::string &tag) {
	if (tag.empty()) {
		return tag;
	}
	wchar_t wide[LOCALE_NAME_MAX_LENGTH] = {};
	if (MultiByteToWideChar(CP_UTF8, 0, tag.c_str(), -1, wide, LOCALE_NAME_MAX_LENGTH) <= 0) {
		return tag;
	}
	wchar_t iso[9] = {};
	if (GetLocaleInfoEx(wide, LOCALE_SISO639LANGNAME2, iso, 9) <= 0) {
		return tag;
	}
	char narrow[9] = {};
	WideCharToMultiByte(CP_UTF8, 0, iso, -1, narrow, sizeof(narrow), nullptr, nullptr);
	return std::string(narrow);
}

std::string MfBackend::Impl::read_stream_string_attribute(DWORD stream_index, REFGUID guid) {
	PROPVARIANT var;
	PropVariantInit(&var);
	HRESULT hr = reader->GetPresentationAttribute(stream_index, guid, &var);
	std::string result;
	if (SUCCEEDED(hr) && var.vt == VT_LPWSTR && var.pwszVal) {
		const int len = WideCharToMultiByte(CP_UTF8, 0, var.pwszVal, -1, nullptr, 0, nullptr, nullptr);
		if (len > 1) {
			result.resize(static_cast<size_t>(len) - 1); // len counts the NUL
			WideCharToMultiByte(CP_UTF8, 0, var.pwszVal, -1, result.data(), len, nullptr, nullptr);
		}
	}
	PropVariantClear(&var);
	return result;
}

void MfBackend::Impl::reorder_audio_tracks_by_container_order() {
	if (audio_tracks.size() < 2) {
		return;
	}
	// The MF MP4/MOV source enumerates streams in the exact REVERSE of the
	// container's trak order (verified against multi-track fixtures: file order
	// video/eng/fra/deu surfaces as deu/fra/eng/video). The real trak IDs are
	// not recoverable — IMFStreamDescriptor::GetStreamIdentifier just returns
	// 1..N in the source's own (reversed) order — so reversing the scan order
	// is the only way to line audio track index N up with AVF and the file.
	// The language-checked multi-track tests pin this; if a future Windows
	// changes the enumeration order, they fail loudly.
	std::reverse(audio_tracks.begin(), audio_tracks.end());
	std::reverse(audio_stream_indices.begin(), audio_stream_indices.end());
	for (size_t k = 0; k < audio_tracks.size(); ++k) {
		audio_tracks[k].is_default = (k == 0);
	}
	// The default (pre-selection) audio stream is the container's first track.
	audio_stream_index = audio_stream_indices[0];
}

bool MfBackend::Impl::switch_audio_track(int track_index) {
	if (audio_stream_indices.empty()) {
		return false;
	}
	if (track_index < 0 ||
			static_cast<size_t>(track_index) >= audio_stream_indices.size()) {
		return false;
	}

	// Deselect the old audio stream (if any) so the reader stops producing
	// samples from it. This is safe even if no old stream is selected.
	if (audio_stream_index >= 0) {
		reader->SetStreamSelection(
				static_cast<DWORD>(audio_stream_index), FALSE);
	}

	// Select the new audio stream index and apply PCM output type.
	const int new_mf_index = audio_stream_indices[static_cast<size_t>(track_index)];
	audio_stream_index = new_mf_index;

	const DWORD aidx = static_cast<DWORD>(new_mf_index);
	if (!configure_pcm_output(reader.get(), aidx)) {
		// PCM negotiation failed; deselect this stream too.
		reader->SetStreamSelection(aidx, FALSE);
		audio_stream_index = -1;
		return false;
	}
	// This IS the application of a selection: the shared reader is now
	// actually configured for track_index, so selected and applied agree.
	selected_audio_track = track_index;
	applied_audio_track = track_index;
	return true;
}

bool MfBackend::Impl::configure_pcm_output(
		IMFSourceReader *target_reader, DWORD aidx) {
	target_reader->SetStreamSelection(aidx, TRUE);

	ComPtr<IMFMediaType> pcm;
	HRESULT hr = MFCreateMediaType(pcm.put());
	if (SUCCEEDED(hr)) {
		pcm->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
		pcm->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_Float);
		hr = target_reader->SetCurrentMediaType(aidx, nullptr, pcm.get());
	}
	if (FAILED(hr)) {
		return false;
	}

	// Read back the negotiated type to get actual channels and rate.
	ComPtr<IMFMediaType> current;
	hr = target_reader->GetCurrentMediaType(aidx, current.put());
	if (SUCCEEDED(hr) && current) {
		UINT32 ch = 0, rate = 0;
		current->GetUINT32(MF_MT_AUDIO_NUM_CHANNELS, &ch);
		current->GetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, &rate);
		audio_channels = static_cast<int>(ch);
		audio_rate = static_cast<int>(rate);
	}
	return true;
}

bool MfBackend::Impl::build_audio_reader(int track_index, double start_time) {
	audio_reader.reset();

	// Plain source reader from the same URL — audio decode needs no DXGI
	// device manager or hardware transforms.
	ComPtr<IMFSourceReader> ar;
	HRESULT hr = MFCreateSourceReaderFromURL(path.c_str(), nullptr, ar.put());
	if (FAILED(hr) || !ar) {
		return false;
	}
	ar->SetStreamSelection(
			static_cast<DWORD>(MF_SOURCE_READER_ALL_STREAMS), FALSE);

	const DWORD aidx = static_cast<DWORD>(
			audio_stream_indices[static_cast<size_t>(track_index)]);
	if (!configure_pcm_output(ar.get(), aidx)) {
		return false;
	}

	// Prime at the requested position (nearest sample at or before it —
	// compressed audio frames are all sync points, so this is ~exact).
	PROPVARIANT pos;
	InitPropVariantFromInt64(seconds_to_mf_ticks(start_time), &pos);
	// MinGW's import libs don't always provide storage for the GUID_NULL
	// symbol (MSVC gets it from uuid.lib); a zero-initialized GUID is
	// semantically identical and sidesteps the link error.
	const GUID null_guid = { 0, 0, 0, { 0, 0, 0, 0, 0, 0, 0, 0 } };
	hr = ar->SetCurrentPosition(null_guid, pos);
	PropVariantClear(&pos);
	if (FAILED(hr)) {
		return false;
	}

	audio_reader = std::move(ar);
	return true;
}

// -----------------------------------------------------------------------
// MfBackend — audio-track public API
// -----------------------------------------------------------------------
int MfBackend::audio_track_count() const {
	return impl_ ? static_cast<int>(impl_->audio_tracks.size()) : 0;
}
core::AudioTrackInfo MfBackend::audio_track_info(int index) const {
	if (!impl_ || index < 0 ||
			static_cast<size_t>(index) >= impl_->audio_tracks.size()) {
		return {};
	}
	return impl_->audio_tracks[static_cast<size_t>(index)];
}
void MfBackend::select_audio_track(int index) {
	if (!impl_ || impl_->audio_stream_indices.empty()) {
		return;
	}
	const int count = static_cast<int>(impl_->audio_tracks.size());
	if (count == 0) {
		return;
	}
	const int clamped = std::clamp(index, 0, count - 1);
	impl_->selected_audio_track = clamped;
	// Per the Backend contract, the selection itself takes effect on the next
	// seek()/open() — the shared reader is left alone here. Update the
	// channel/rate metadata immediately, though, so a caller inspecting
	// audio_channel_count()/audio_sample_rate() before playback sees the
	// selected track's format (mirrors AvfBackend::Impl::apply_track_selection).
	const auto &meta = impl_->audio_tracks[static_cast<size_t>(clamped)];
	impl_->audio_channels = meta.channels;
	impl_->audio_rate = meta.sample_rate;
}

bool MfBackend::reselect_audio_track(int index, double pts_seconds) {
	if (!impl_ || impl_->audio_stream_indices.empty()) {
		return false;
	}
	const int count = static_cast<int>(impl_->audio_tracks.size());
	if (count == 0) {
		return false;
	}
	const int clamped = std::clamp(index, 0, count - 1);
	const double target = pts_seconds < 0.0 ? 0.0 : pts_seconds;

	// Mirror the AVF design: a dedicated audio-only reader for the new track,
	// primed at `target`, while the shared reader keeps decoding video from
	// its current position. Toggling per-stream selection on the shared
	// reader alone does not work — an MF stream that was deselected when the
	// source last started reports end-of-stream instead of delivering, and
	// restarting the source to fix that would also reposition video.
	if (!impl_->build_audio_reader(clamped, target)) {
		return false;
	}

	// Stop the shared reader from queueing the old track's audio.
	if (impl_->audio_stream_index >= 0) {
		impl_->reader->SetStreamSelection(
				static_cast<DWORD>(impl_->audio_stream_index), FALSE);
	}
	impl_->audio_stream_index =
			impl_->audio_stream_indices[static_cast<size_t>(clamped)];
	// The dedicated audio reader now serves this track directly; seek() will
	// re-home it onto the shared reader later, so selected and applied both
	// reflect the new track immediately.
	impl_->selected_audio_track = clamped;
	impl_->applied_audio_track = clamped;
	return true;
}

} // namespace mf

#else // !_WIN32

// On non-Windows hosts this backend is never selected. We still want the file
// to compile to nothing harmlessly so SConstruct mis-wiring doesn't break the
// build.

#endif // _WIN32
