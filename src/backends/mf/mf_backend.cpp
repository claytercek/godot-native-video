// -----------------------------------------------------------------------
// mf_backend.cpp — Media Foundation Decoder-mode Backend (Windows).
//
// Drives an IMFSourceReader + IMFDXGIDeviceManager as a pure hardware decoder
// by design. Video is negotiated to match the source's bit depth: 8-bit
// sources request NV12 8-bit D3D11 textures (DXGI_FORMAT_NV12); 10-bit HEVC
// (Main10) sources request P010 10-bit D3D11 textures (DXGI_FORMAT_P010)
// instead of letting the video processor MFT down-convert to 8-bit —
// mirroring the AVF backend's x420 negotiation. Colorimetry
// (matrix/primaries/transfer/range) is read from the stream's
// *native* media type and tagged onto every frame regardless of bit depth, so
// BT.601/BT.2020/PQ/HLG clips still get the right shader treatment. Audio is
// configured for interleaved float32 LPCM. Each decoded video frame hands out
// the underlying ID3D11Texture2D as a native surface handle owned by a
// move-only RAII wrapper (mf::ComPtr) and released via the
// core::VideoFrame::release callback. This is the structural mirror of
// avf_backend.mm.
//
// Audio-track enumeration and selection (select_audio_track(),
// reselect_audio_track(), and the machinery behind them) live in
// mf_audio.cpp, sharing the MfBackend::Impl definition declared in
// mf_backend_impl.h.
//
// No Godot / RenderingDevice symbols appear here.
//
// STATUS: VERIFIED on Windows 11 (AMD hardware decode). tests/mf passes the
// full synthetic + real-clip matrix (H.264 and HEVC, MP4/MOV, 24/30/60 fps):
// NV12/P010 D3D11 textures with correct marker content, monotonic PTS,
// float32 PCM, and colorimetry matching each clip's tagged VUI/colr metadata.
// Note the decoder MFT emits frames as slices of one shared texture *array*;
// the slice index is reported in VideoFrame::plane_slice (see below).
// -----------------------------------------------------------------------

#include "mf_backend_impl.h"

// This entire backend is Windows-only. On any other platform it compiles to an
// empty translation unit so the macOS build (which never globs it) is safe even
// if the file is accidentally added to a source list.
#if defined(_WIN32)

// Media Foundation + D3D11 + DXGI.
#include <mferror.h>
#include <mftransform.h>
#include <Mfobjects.h>
#include <propvarutil.h>
#include <codecapi.h> // eAVEncH265VProfile_*

#include <cmath>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

namespace {

// -----------------------------------------------------------------------
// Colorimetry helpers — map MF_MT_YUV_MATRIX / MF_MT_VIDEO_PRIMARIES /
// MF_MT_TRANSFER_FUNCTION / MF_MT_VIDEO_NOMINAL_RANGE attribute values to our
// enums. Structural mirror of avf_backend.mm's CVImageBuffer attachment
// parsers. Unrecognised/absent values map to Unspecified so the caller's
// BT.709 video-range defaults stay in effect.
// -----------------------------------------------------------------------
core::ColorMatrix parse_ycbcr_matrix(UINT32 val) {
	switch (val) {
		case MFVideoTransferMatrix_BT709: return core::ColorMatrix::BT709;
		case MFVideoTransferMatrix_BT601: return core::ColorMatrix::BT601;
		case MFVideoTransferMatrix_BT2020_10:
		case MFVideoTransferMatrix_BT2020_12: return core::ColorMatrix::BT2020;
		default: return core::ColorMatrix::Unspecified;
	}
}

core::ColorPrimaries parse_color_primaries(UINT32 val) {
	switch (val) {
		case MFVideoPrimaries_BT709: return core::ColorPrimaries::BT709;
		case MFVideoPrimaries_BT470_2_SysBG:
		case MFVideoPrimaries_EBU3213: return core::ColorPrimaries::BT601_625;
		case MFVideoPrimaries_SMPTE170M:
		case MFVideoPrimaries_SMPTE_C: return core::ColorPrimaries::BT601_525;
		case MFVideoPrimaries_BT2020: return core::ColorPrimaries::BT2020;
		case MFVideoPrimaries_DCI_P3: return core::ColorPrimaries::DCI_P3;
		default: return core::ColorPrimaries::Unspecified;
	}
}

core::TransferFunction parse_transfer_function(UINT32 val) {
	switch (val) {
		case MFVideoTransFunc_709:
		case MFVideoTransFunc_sRGB: return core::TransferFunction::BT709;
		case MFVideoTransFunc_2084: return core::TransferFunction::PQ;
		case MFVideoTransFunc_HLG: return core::TransferFunction::HLG;
		default: return core::TransferFunction::Unspecified;
	}
}

// MFNominalRange_0_255 / MFNominalRange_16_235 are the unambiguous names for
// full/video range respectively (the aliased MFNominalRange_Normal /
// MFNominalRange_Wide names in mfobjects.h are easy to misread backwards).
core::ColorRange parse_color_range(UINT32 val) {
	switch (val) {
		case MFNominalRange_0_255: return core::ColorRange::Full;
		case MFNominalRange_16_235: return core::ColorRange::Video;
		default: return core::ColorRange::Unspecified;
	}
}

// Detect the source's bit depth from the native (pre-conversion) video media
// type. MF_MT_MPEG2_PROFILE (an alias of MF_MT_VIDEO_PROFILE) carries the
// demuxer-parsed HEVC general_profile_idc for HEVC streams; profile 2
// (eAVEncH265VProfile_Main_420_10) identifies a 10-bit 4:2:0 source — the
// profile every 10-bit clip in the coverage matrix (Main10 SDR, PQ, HLG)
// encodes to. Absent or any other value (including all H.264 streams, which
// have no 10-bit profile in this project's scope) defaults to 8-bit, matching
// the AVF backend's "match-the-source, default to 8-bit" contract.
int detect_bit_depth(IMFMediaType *native) {
	UINT32 profile = 0;
	if (SUCCEEDED(native->GetUINT32(MF_MT_MPEG2_PROFILE, &profile))) {
		if (profile == eAVEncH265VProfile_Main_420_10) {
			return 10;
		}
	}
	return 8;
}
} // namespace

namespace mf {

// Create a hardware D3D11 device with BGRA + video support and wrap it in an
// IMFDXGIDeviceManager so the source reader can decode into D3D11 textures.
bool MfBackend::Impl::create_device() {
	// BGRA support is required for D3D11 video; VIDEO_SUPPORT enables the video
	// device used by the MF decoder MFT.
	UINT flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT | D3D11_CREATE_DEVICE_VIDEO_SUPPORT;

	D3D_FEATURE_LEVEL got_level = D3D_FEATURE_LEVEL_11_0;
	HRESULT hr = D3D11CreateDevice(
			nullptr, // default adapter
			D3D_DRIVER_TYPE_HARDWARE,
			nullptr,
			flags,
			nullptr, 0, // default feature levels
			D3D11_SDK_VERSION,
			d3d_device.put(),
			&got_level,
			d3d_context.put());
	if (FAILED(hr) || !d3d_device) {
		return false;
	}

	// The device is shared across MF's decoder thread and our pump; mark it
	// multithread-protected so concurrent access is serialized by the driver.
	ComPtr<ID3D10Multithread> multithread;
	if (SUCCEEDED(d3d_device->QueryInterface(IID_PPV_ARGS(multithread.put())))) {
		multithread->SetMultithreadProtected(TRUE);
	}

	// Wrap the device in an MF DXGI device manager keyed by a reset token.
	UINT reset_token = 0;
	hr = MFCreateDXGIDeviceManager(&reset_token, dxgi_manager.put());
	if (FAILED(hr) || !dxgi_manager) {
		return false;
	}
	hr = dxgi_manager->ResetDevice(d3d_device.get(), reset_token);
	if (FAILED(hr)) {
		return false;
	}
	return true;
}

// Build the source reader bound to the DXGI device manager so decode output is
// D3D11-backed (DXGI buffers). Enables advanced video processing + hardware
// transforms.
bool MfBackend::Impl::create_reader() {
	ComPtr<IMFAttributes> attrs;
	HRESULT hr = MFCreateAttributes(attrs.put(), 4);
	if (FAILED(hr)) {
		return false;
	}
	// Hand the reader our DXGI device manager: this routes decode through a
	// D3D11-aware decoder MFT, producing IMFDXGIBuffer-backed samples.
	attrs->SetUnknown(MF_SOURCE_READER_D3D_MANAGER, dxgi_manager.get());
	// Allow hardware-accelerated MFTs and let the reader insert format
	// converters (so we can request NV12 even if the decoder's native output
	// differs slightly).
	attrs->SetUINT32(MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS, TRUE);
	attrs->SetUINT32(MF_SOURCE_READER_ENABLE_ADVANCED_VIDEO_PROCESSING, TRUE);

	hr = MFCreateSourceReaderFromURL(path.c_str(), attrs.get(), reader.put());
	if (FAILED(hr) || !reader) {
		return false;
	}
	return true;
}

// Configure the video stream output type, matching the source's bit depth:
// NV12 (D3D11-friendly 8-bit 4:2:0) for 8-bit sources, P010 (10-bit 4:2:0) for
// 10-bit HEVC Main10 sources. We select the first video stream, deselect
// everything, then re-select the streams we want, exactly like the AVF reader
// picks one track per type.
//
// During the initial stream scan we also enumerate all audio stream indices
// and collect per-track metadata (channel count, sample rate, language).
// MF reports MF_SD_LANGUAGE as an RFC 1766 tag ("en", "es"); AVF reports the
// container's ISO 639-2 code ("eng", "spa"). normalize_language_tag()
// (mf_audio.cpp) converts to ISO 639-2/T so track metadata is identical
// across platforms; unknown tags pass through unchanged.
bool MfBackend::Impl::configure_video_stream() {
	// Find the first video stream by walking native media types.
	audio_tracks.clear();
	audio_stream_indices.clear();
	for (DWORD i = 0;; ++i) {
		ComPtr<IMFMediaType> native;
		HRESULT hr = reader->GetNativeMediaType(i, 0, native.put());
		if (hr == MF_E_INVALIDSTREAMNUMBER) {
			break; // no more streams
		}
		if (FAILED(hr) || !native) {
			continue;
		}
		GUID major = {};
		native->GetGUID(MF_MT_MAJOR_TYPE, &major);
		if (major == MFMediaType_Video && video_stream_index < 0) {
			video_stream_index = static_cast<int>(i);
			// Colorimetry and bit depth live on the *native* (pre-conversion)
			// type: the NV12/P010 output type requested below goes through a
			// video processor MFT that does not carry these attributes forward
			// onto its negotiated output type, so reading them post-conversion
			// would always see the unspecified defaults.
			read_colorimetry(native.get());
			color_.bit_depth = detect_bit_depth(native.get());
		} else if (major == MFMediaType_Audio) {
			// Collect per-track metadata from the native audio media type.
			core::AudioTrackInfo meta;
			UINT32 ch = 0, rate = 0;
			native->GetUINT32(MF_MT_AUDIO_NUM_CHANNELS, &ch);
			native->GetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, &rate);
			meta.channels = static_cast<int>(ch);
			meta.sample_rate = static_cast<int>(rate);
			meta.is_default = audio_tracks.empty(); // first track is default
			// Stream-descriptor attributes are reachable through the source
			// reader: GetPresentationAttribute with a stream index queries the
			// stream descriptor. The MP4/MOV source surfaces the mdhd language
			// (ISO 639-2, e.g. "eng") as MF_SD_LANGUAGE — same raw tag AVF
			// reports, so the two backends stay comparable.
			meta.language = normalize_language_tag(read_stream_string_attribute(i, MF_SD_LANGUAGE));
			meta.name = read_stream_string_attribute(i, MF_SD_STREAM_NAME);
			audio_tracks.push_back(meta);
			audio_stream_indices.push_back(static_cast<int>(i));
			if (audio_stream_index < 0) {
				audio_stream_index = static_cast<int>(i);
			}
		}
	}

	if (video_stream_index < 0) {
		return false; // no video track — caller decides if that's fatal
	}

	reorder_audio_tracks_by_container_order();

	const DWORD vidx = static_cast<DWORD>(video_stream_index);

	// Request the output subtype matching the detected bit depth. The reader
	// inserts a video processor MFT if the decoder doesn't natively output
	// that subtype. If the 10-bit (P010) request fails — e.g. no MFT in the
	// chain can produce it — fall back to NV12 and correct color_.bit_depth so
	// the frames we hand out accurately report what was actually negotiated.
	auto request_subtype = [&](const GUID &subtype) -> HRESULT {
		ComPtr<IMFMediaType> out_type;
		HRESULT hr2 = MFCreateMediaType(out_type.put());
		if (FAILED(hr2)) {
			return hr2;
		}
		out_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
		out_type->SetGUID(MF_MT_SUBTYPE, subtype);
		return reader->SetCurrentMediaType(vidx, nullptr, out_type.get());
	};

	HRESULT hr = request_subtype(color_.bit_depth >= 10 ? MFVideoFormat_P010 : MFVideoFormat_NV12);
	if (FAILED(hr) && color_.bit_depth >= 10) {
		color_.bit_depth = 8;
		hr = request_subtype(MFVideoFormat_NV12);
	}
	if (FAILED(hr)) {
		return false;
	}

	reader->SetStreamSelection(vidx, TRUE);

	// Read back the negotiated type to capture frame dimensions.
	ComPtr<IMFMediaType> current;
	hr = reader->GetCurrentMediaType(vidx, current.put());
	if (SUCCEEDED(hr) && current) {
		UINT32 w = 0, h = 0;
		if (SUCCEEDED(MFGetAttributeSize(current.get(), MF_MT_FRAME_SIZE, &w, &h))) {
			width = static_cast<int>(w);
			height = static_cast<int>(h);
		}
	}
	return true;
}

// Read colorimetry attributes off a negotiated video media type. Only present
// when the source tagged them (e.g. via VUI); an absent attribute leaves the
// existing default (BT.709 video range) untouched, matching the AVF backend's
// "untagged clips keep the old defaults" contract.
void MfBackend::Impl::read_colorimetry(IMFMediaType *type) {
	UINT32 val = 0;
	if (SUCCEEDED(type->GetUINT32(MF_MT_YUV_MATRIX, &val))) {
		color_.matrix = parse_ycbcr_matrix(val);
	}
	if (SUCCEEDED(type->GetUINT32(MF_MT_VIDEO_PRIMARIES, &val))) {
		color_.primaries = parse_color_primaries(val);
	}
	if (SUCCEEDED(type->GetUINT32(MF_MT_TRANSFER_FUNCTION, &val))) {
		color_.transfer = parse_transfer_function(val);
	}
	if (SUCCEEDED(type->GetUINT32(MF_MT_VIDEO_NOMINAL_RANGE, &val))) {
		color_.range = parse_color_range(val);
	}
}

// Configure the audio stream output to interleaved float32 PCM (matches the AVF
// audio output settings) and read channel count + sample rate.
bool MfBackend::Impl::configure_audio_stream() {
	if (audio_stream_index < 0) {
		return true; // no audio is fine (silent clip)
	}
	const DWORD aidx = static_cast<DWORD>(audio_stream_index);

	ComPtr<IMFMediaType> pcm;
	HRESULT hr = MFCreateMediaType(pcm.put());
	if (FAILED(hr)) {
		return false;
	}
	pcm->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
	// MFAudioFormat_Float == 32-bit IEEE float PCM, interleaved by channel.
	pcm->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_Float);
	hr = reader->SetCurrentMediaType(aidx, nullptr, pcm.get());
	if (FAILED(hr)) {
		// Couldn't get float PCM; leave audio unselected rather than fail hard.
		audio_stream_index = -1;
		return true;
	}
	reader->SetStreamSelection(aidx, TRUE);

	ComPtr<IMFMediaType> current;
	hr = reader->GetCurrentMediaType(aidx, current.put());
	if (SUCCEEDED(hr) && current) {
		UINT32 ch = 0, rate = 0;
		current->GetUINT32(MF_MT_AUDIO_NUM_CHANNELS, &ch);
		current->GetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, &rate);
		audio_channels = static_cast<int>(ch);
		audio_rate = static_cast<int>(rate);
	}
	return true;
}

// Read total duration from the presentation descriptor (100ns units -> seconds).
void MfBackend::Impl::read_duration() {
	PROPVARIANT var;
	PropVariantInit(&var);
	HRESULT hr = reader->GetPresentationAttribute(
			static_cast<DWORD>(MF_SOURCE_READER_MEDIASOURCE), MF_PD_DURATION, &var);
	if (SUCCEEDED(hr) && var.vt == VT_UI8) {
		duration = mf_ticks_to_seconds(static_cast<LONGLONG>(var.uhVal.QuadPart));
	}
	PropVariantClear(&var);
}

// -----------------------------------------------------------------------
// MfBackend
// -----------------------------------------------------------------------
MfBackend::MfBackend() :
		impl_(std::make_unique<Impl>()) {}

MfBackend::~MfBackend() {
	close();
}

MfBackend::MfBackend(MfBackend &&) noexcept = default;
MfBackend &MfBackend::operator=(MfBackend &&) noexcept = default;

bool MfBackend::open(const std::string &url_or_path) {
	close();
	impl_ = std::make_unique<Impl>();

	// COM + Media Foundation must be initialized on this thread before any MF
	// call. We pair these with MFShutdown/CoUninitialize in teardown().
	HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
	if (SUCCEEDED(hr) || hr == S_FALSE) {
		impl_->com_initialized = true;
	}
	hr = MFStartup(MF_VERSION, MFSTARTUP_LITE);
	if (FAILED(hr)) {
		impl_->error = true;
		return false;
	}
	impl_->mf_started = true;

	// MFCreateSourceReaderFromURL takes a wide string. Convert the UTF-8 path,
	// accepting either a file path or a file:// URL (MF resolves both).
	{
		const int needed = MultiByteToWideChar(
				CP_UTF8, 0, url_or_path.c_str(), -1, nullptr, 0);
		if (needed <= 0) {
			impl_->error = true;
			return false;
		}
		impl_->path.resize(static_cast<size_t>(needed - 1));
		MultiByteToWideChar(CP_UTF8, 0, url_or_path.c_str(), -1,
				impl_->path.data(), needed);
	}

	if (!impl_->create_device()) {
		impl_->error = true;
		return false;
	}
	if (!impl_->create_reader()) {
		impl_->error = true;
		return false;
	}

	// Deselect all streams first, then enable just the ones we configure — this
	// mirrors the AVF reader adding only the outputs it wants.
	impl_->reader->SetStreamSelection(
			static_cast<DWORD>(MF_SOURCE_READER_ALL_STREAMS), FALSE);

	if (!impl_->configure_video_stream()) {
		// No usable video stream. Audio-only is out of scope for the video pump,
		// but match AVF: fail only if there is neither audio nor video.
		if (impl_->audio_stream_index < 0) {
			impl_->error = true;
			return false;
		}
	}
	if (!impl_->configure_audio_stream()) {
		impl_->error = true;
		return false;
	}

	impl_->read_duration();
	return true;
}

void MfBackend::close() {
	if (impl_) {
		impl_->teardown();
	}
}

double MfBackend::duration_seconds() const {
	return impl_ ? impl_->duration : 0.0;
}
int MfBackend::video_width() const {
	return impl_ ? impl_->width : 0;
}
int MfBackend::video_height() const {
	return impl_ ? impl_->height : 0;
}
int MfBackend::audio_channel_count() const {
	return impl_ ? impl_->audio_channels : 0;
}
int MfBackend::audio_sample_rate() const {
	return impl_ ? impl_->audio_rate : 0;
}

bool MfBackend::had_error() const {
	return impl_ && impl_->error;
}

core::Colorimetry MfBackend::colorimetry() const {
	return impl_ ? impl_->color_ : core::Colorimetry::bt709_defaults();
}

bool MfBackend::seek(double pts_seconds) {
	if (!impl_ || !impl_->reader) {
		return false;
	}
	if (pts_seconds < 0.0) {
		pts_seconds = 0.0;
	}
	// Tear down any dedicated audio-only reader and re-home audio on the
	// shared reader (mirrors AVF rebuilding its combined reader on seek).
	bool audio_reader_torn_down = false;
	if (impl_->audio_reader) {
		impl_->audio_reader.reset();
		audio_reader_torn_down = true;
	}
	// Catch the shared reader up to a pending select_audio_track() (the
	// Backend contract defers selection to the next seek()/open()), and/or
	// re-home audio after a dedicated reselect reader. Re-selecting the
	// stream is safe here because SetCurrentPosition below restarts the
	// media source, which is what makes a newly (re)selected stream actually
	// deliver samples — a stream selected after the source started does not
	// deliver until a reposition.
	if (audio_reader_torn_down || impl_->applied_audio_track != impl_->selected_audio_track) {
		impl_->switch_audio_track(impl_->selected_audio_track);
	}
	// Unlike AVAssetReader (single-pass, recreated on seek), IMFSourceReader can
	// be repositioned in place. SetCurrentPosition seeks to the nearest keyframe
	// at or before the requested time; subsequent ReadSample calls resume there.
	PROPVARIANT pos;
	InitPropVariantFromInt64(seconds_to_mf_ticks(pts_seconds), &pos);
	HRESULT hr = impl_->reader->SetCurrentPosition(GUID_NULL, pos);
	PropVariantClear(&pos);
	if (FAILED(hr)) {
		impl_->error = true;
		return false;
	}
	return true;
}

std::optional<core::VideoFrame> MfBackend::next_video_frame() {
	if (!impl_ || !impl_->reader || impl_->video_stream_index < 0) {
		return std::nullopt;
	}

	const DWORD vidx = static_cast<DWORD>(impl_->video_stream_index);

	// MF may return a status with no sample (e.g. a format change or a gap); loop
	// until we get a sample, hit EOS, or error — mirroring copyNextSampleBuffer
	// returning the next decoded buffer.
	for (;;) {
		DWORD stream_flags = 0;
		LONGLONG timestamp = 0;
		ComPtr<IMFSample> sample;
		HRESULT hr = impl_->reader->ReadSample(
				vidx, 0, nullptr, &stream_flags, &timestamp, sample.put());
		if (FAILED(hr)) {
			impl_->error = true;
			return std::nullopt;
		}
		if (stream_flags & MF_SOURCE_READERF_ENDOFSTREAM) {
			return std::nullopt; // clean EOS
		}
		if (!sample) {
			// No sample this call (e.g. stream-tick or a mid-stream native format
			// change signaled by MF_SOURCE_READERF_NATIVEMEDIATYPECHANGED). A
			// changed native type could in principle carry new colorimetry, but
			// re-probing it safely means resolving the *current* native type
			// (MF_SOURCE_READER_CURRENT_TYPE_INDEX) and deciding whether an
			// absent attribute should reset to defaults or keep the prior
			// segment's tag — real complexity with no clip in the matrix to test
			// it against. Limitation: a mid-stream colorimetry change keeps the
			// colorimetry captured at open(), same as the AVFoundation backend.
			continue;
		}

		// One contiguous D3D11 buffer per decoded video sample. Get the first
		// buffer and query its IMFDXGIBuffer to reach the ID3D11Texture2D.
		ComPtr<IMFMediaBuffer> media_buffer;
		hr = sample->GetBufferByIndex(0, media_buffer.put());
		if (FAILED(hr) || !media_buffer) {
			impl_->error = true;
			return std::nullopt;
		}

		ComPtr<IMFDXGIBuffer> dxgi_buffer;
		hr = media_buffer->QueryInterface(IID_PPV_ARGS(dxgi_buffer.put()));
		if (FAILED(hr) || !dxgi_buffer) {
			// Not a D3D11-backed sample — the DXGI device manager wasn't honored.
			impl_->error = true;
			return std::nullopt;
		}

		// The resource is an ID3D11Texture2D. GetResource returns a +1 reference
		// we adopt into a ComPtr owner.
		ID3D11Texture2D *raw_tex = nullptr;
		hr = dxgi_buffer->GetResource(IID_PPV_ARGS(&raw_tex));
		if (FAILED(hr) || !raw_tex) {
			impl_->error = true;
			return std::nullopt;
		}
		ComPtr<ID3D11Texture2D> tex = ComPtr<ID3D11Texture2D>::adopt(raw_tex);

		// A single NV12 D3D11 texture can be a texture *array*; the decoder packs
		// frames as array slices. The subresource index tells the importer which
		// slice this frame lives in.
		UINT subresource = 0;
		dxgi_buffer->GetSubresourceIndex(&subresource);

		core::VideoFrame frame;
		frame.pts_seconds = mf_ticks_to_seconds(timestamp);
		frame.native_handle = static_cast<void *>(tex.get());
		frame.width = impl_->width;
		frame.height = impl_->height;
		// 8-bit sources negotiated NV12; 10-bit HEVC Main10 sources negotiated
		// P010, tagged as PixelFormat::x420 — the same logical tag the AVF
		// backend uses for its 10-bit biplanar surfaces.
		frame.pixel_format = impl_->color_.bit_depth >= 10 ? core::PixelFormat::x420 : core::PixelFormat::NV12;
		// Record the array-slice index so the importer can address the right
		// subresource of the shared decoder texture array.
		frame.plane_slice = static_cast<uint32_t>(subresource);

		// Tag with the stream's negotiated colorimetry. MF does not expose
		// per-IMFSample colorimetry overrides the way CoreVideo attaches
		// per-buffer keys, so the current media type is the most granular
		// source available.
		frame.color = impl_->color_;

		// Move the texture owner into the release closure so the D3D11 texture is
		// Released exactly once when the consumer is done — the COM analog of the
		// CVPixelBuffer release in the AVF backend. shared_ptr lets the copyable
		// std::function hold the move-only owner.
		auto owner = std::make_shared<ComPtr<ID3D11Texture2D>>(std::move(tex));
		frame.release = [owner]() mutable { owner->reset(); };

		return frame;
	}
}

std::optional<core::AudioChunk> MfBackend::next_audio_chunk() {
	if (!impl_ || !impl_->reader || impl_->audio_stream_index < 0) {
		return std::nullopt;
	}

	// When a dedicated audio-only reader is active (from
	// reselect_audio_track), read from it; otherwise use the shared reader.
	// Both readers enumerate the same source, so the stream index matches.
	IMFSourceReader *active_reader =
			impl_->audio_reader ? impl_->audio_reader.get() : impl_->reader.get();
	const DWORD aidx = static_cast<DWORD>(impl_->audio_stream_index);

	for (;;) {
		DWORD stream_flags = 0;
		LONGLONG timestamp = 0;
		ComPtr<IMFSample> sample;
		HRESULT hr = active_reader->ReadSample(
				aidx, 0, nullptr, &stream_flags, &timestamp, sample.put());
		if (FAILED(hr)) {
			impl_->error = true;
			return std::nullopt;
		}
		if (stream_flags & MF_SOURCE_READERF_ENDOFSTREAM) {
			return std::nullopt; // clean EOS
		}
		if (!sample) {
			continue;
		}

		// Flatten the sample's buffers into one contiguous block and lock it.
		ComPtr<IMFMediaBuffer> media_buffer;
		hr = sample->ConvertToContiguousBuffer(media_buffer.put());
		if (FAILED(hr) || !media_buffer) {
			impl_->error = true;
			return std::nullopt;
		}

		BYTE *data = nullptr;
		DWORD cur_len = 0;
		hr = media_buffer->Lock(&data, nullptr, &cur_len);
		if (FAILED(hr) || !data) {
			impl_->error = true;
			return std::nullopt;
		}

		const int channels = impl_->audio_channels > 0 ? impl_->audio_channels : 1;
		const size_t float_count = cur_len / sizeof(float);

		// Copy into scratch so the borrowed pointer outlives the locked buffer
		// (which we unlock before returning) — mirrors the AVF audio scratch copy.
		impl_->audio_scratch.resize(float_count);
		std::memcpy(impl_->audio_scratch.data(), data, float_count * sizeof(float));
		media_buffer->Unlock();

		const int frame_count =
				channels > 0 ? static_cast<int>(float_count / channels) : 0;

		core::AudioChunk chunk;
		chunk.pts_seconds = mf_ticks_to_seconds(timestamp);
		chunk.samples = impl_->audio_scratch.data();
		chunk.frame_count = frame_count;
		chunk.channel_count = channels;
		chunk.sample_rate = impl_->audio_rate;

		return chunk;
	}
}

} // namespace mf

#else // !_WIN32

// On non-Windows hosts this backend is never selected. We still want the file to
// compile to nothing harmlessly so SConstruct mis-wiring doesn't break the build.

#endif // _WIN32
