// -----------------------------------------------------------------------
// avf_backend.mm — AVFoundation Decoder-mode Backend (macOS).
//
// Drives AVAssetReader + AVAssetReaderTrackOutput as a pure hardware
// decoder by design. Video is configured for NV12 / BT.709 8-bit (D12);
// audio is configured for interleaved float32 LPCM. Each decoded video
// frame hands out the underlying CVPixelBuffer as a native surface handle
// owned by a move-only RAII wrapper (avf::PixelBufferRef) and released via
// the core::VideoFrame::release callback.
//
// No Godot / RenderingDevice symbols appear here.
// -----------------------------------------------------------------------

#include "avf_backend.h"
#include "cf_raii.h"

#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

namespace avf {

// -----------------------------------------------------------------------
// AvfBackend::Impl — holds the ObjC reader objects (ARC-managed) and the
// scratch buffers whose lifetime backs the pointers we return.
// -----------------------------------------------------------------------
class AvfBackend::Impl {
public:
	// AVAssetReader with one output per track. Recreated on open()/seek()
	// because AVAssetReader is single-pass and cannot be rewound.
	AVAsset *asset = nil;
	AVAssetReader *reader = nil;
	AVAssetReaderTrackOutput *video_out = nil;
	AVAssetReaderTrackOutput *audio_out = nil;

	AVAssetTrack *video_track = nil;
	AVAssetTrack *audio_track = nil;

	// All audio track objects from the asset, indexed by track position
	// in the audio_tracks metadata vector. Selected by select_audio_track().
	NSArray<AVAssetTrack *> *all_audio_tracks = nil;
	int selected_audio_track_index = 0;

	// Per-track audio metadata. Populated during open().
	std::vector<core::AudioTrackInfo> audio_tracks;

	std::string path;

	double duration = 0.0;
	int width = 0;
	int height = 0;
	int audio_channels = 0;
	int audio_rate = 0;

	// Negotiated colorimetry (parsed from the video track's format descriptions
	// at open time). Defaults: BT.709, video range (same as today's hard-coded
	// shader constants). Per-frame values from CV attachments may differ from
	// these per-sample metadata (e.g. a tagged clip that has attachments on the
	// actual pixel buffers but empty format-description extensions).
	core::Colorimetry color_ = core::Colorimetry::bt709_defaults();

	bool error = false;

	// Dedicated audio-only reader for mid-decode track reselect.
	// Non-nil only after reselect_audio_track(); nil after open()/seek().
	// The combined reader (reader) continues providing video undisturbed;
	// next_audio_chunk() reads from audio_reader when it is non-nil.
	AVAssetReader *audio_reader = nil;
	AVAssetReaderTrackOutput *audio_only_out = nil;

	// Backing store for the most recent decoded audio chunk. core::AudioChunk
	// returns a borrowed `const float*`, so the buffer must outlive the
	// returned chunk; it stays valid until the next next_audio_chunk() call.
	std::vector<float> audio_scratch;

	// Build a fresh AVAssetReader pumping from `start_time` (seconds). Used by
	// both open() (start 0) and seek(). Returns false on failure.
	bool build_reader(double start_time);

	// Build an audio-only AVAssetReader for `track_index` (position in
	// audio_tracks / all_audio_tracks) starting from the keyframe at or before
	// `start_time`. Used by reselect_audio_track() to create a dedicated audio
	// reader without disturbing the video reader. Returns false on failure.
	bool build_audio_reader(int track_index, double start_time);

	// Build a video-only AVAssetReader (no audio output) starting from
	// `start_time`. Used by reselect_audio_track() after tearing down the
	// combined reader so the video reader does not have an unconsumed audio
	// output that blocks decode. Returns false on failure.
	bool build_video_reader(double start_time);

	void teardown_audio_reader() {
		if (audio_reader) {
			[audio_reader cancelReading];
		}
		audio_reader = nil;
		audio_only_out = nil;
	}

	void teardown() {
		teardown_audio_reader();
		teardown_combined();
	}

	// Tear down ONLY the combined reader, leaving the dedicated audio-only
	// reader (audio_reader) intact. Used during reselect_audio_track() so
	// the combined reader's audio output does not block video decode.
	void teardown_combined() {
		if (reader) {
			[reader cancelReading];
		}
		reader = nil;
		video_out = nil;
		audio_out = nil;
	}

	// Select the \(i)th audio track (position in audio_tracks) and update
	// the audio_track object and channels/rate from its metadata.
	// The selection is applied on the next build_reader() call.
	bool apply_track_selection(int i) {
		if (i < 0 || static_cast<size_t>(i) >= audio_tracks.size()) {
			return false;
		}
		selected_audio_track_index = i;
		if (all_audio_tracks && i < static_cast<int>(all_audio_tracks.count)) {
			audio_track = all_audio_tracks[i];
		}
		audio_channels = audio_tracks[i].channels;
		audio_rate = audio_tracks[i].sample_rate;
		return true;
	}
};

// Configure the biplanar Y'CbCr video output. Selects the pixel format based
// on the source's bit depth (NV12 for 8-bit, x420 for 10-bit) and range
// (video/full) matching the source. Requests an IOSurface-backed
// buffer so the decode stays on the GPU path; the zero-copy present slice
// imports the surface directly without a CPU copy.
static AVAssetReaderTrackOutput *make_video_output(AVAssetTrack *track,
		const core::Colorimetry &color) {
	OSType pixel_format;
	if (color.bit_depth >= 10) {
		pixel_format = (color.range == core::ColorRange::Full)
				? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange   // 'x42F'
				: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange; // 'x420'
	} else {
		pixel_format = (color.range == core::ColorRange::Full)
				? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange     // 'a420'
				: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;   // '420v'
	}

	NSDictionary *settings = @{
		(NSString *)kCVPixelBufferPixelFormatTypeKey : @(pixel_format),
		// Request an IOSurface-backed buffer so the decode stays on the GPU
		// path; the zero-copy present slice will import this surface directly.
		(NSString *)kCVPixelBufferIOSurfacePropertiesKey : @{},
		(NSString *)kCVPixelBufferMetalCompatibilityKey : @YES,
	};
	return [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track
													  outputSettings:settings];
}

// Configure the audio output as interleaved float32 LPCM, native endianness.
static AVAssetReaderTrackOutput *make_audio_output(AVAssetTrack *track) {
	NSDictionary *settings = @{
		(NSString *)AVFormatIDKey : @(kAudioFormatLinearPCM),
		(NSString *)AVLinearPCMBitDepthKey : @32,
		(NSString *)AVLinearPCMIsFloatKey : @YES,
		(NSString *)AVLinearPCMIsBigEndianKey : @NO,
		(NSString *)AVLinearPCMIsNonInterleaved : @NO, // interleaved, channel-major
	};
	return [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track
													  outputSettings:settings];
}

// -----------------------------------------------------------------------
// Colorimetry helpers — parse CVImageBuffer attachment keys to our enums.
// -----------------------------------------------------------------------

// Parse YCbCr matrix from a CV attachment CFString.
// Returns Unspecified (defaults to BT.709) when the tag is absent or unrecognised.
static core::ColorMatrix parse_ycbcr_matrix(CFStringRef val) {
	if (!val) return core::ColorMatrix::Unspecified;
	if (CFEqual(val, kCVImageBufferYCbCrMatrix_ITU_R_709_2)) return core::ColorMatrix::BT709;
	if (CFEqual(val, kCVImageBufferYCbCrMatrix_ITU_R_601_4)) return core::ColorMatrix::BT601;
	if (CFEqual(val, kCVImageBufferYCbCrMatrix_ITU_R_2020)) return core::ColorMatrix::BT2020;
	return core::ColorMatrix::Unspecified;
}

// Parse color primaries from a CV attachment CFString.
static core::ColorPrimaries parse_color_primaries(CFStringRef val) {
	if (!val) return core::ColorPrimaries::Unspecified;
	if (CFEqual(val, kCVImageBufferColorPrimaries_ITU_R_709_2)) return core::ColorPrimaries::BT709;
	if (CFEqual(val, kCVImageBufferColorPrimaries_EBU_3213)) return core::ColorPrimaries::BT601_625;
	if (CFEqual(val, kCVImageBufferColorPrimaries_SMPTE_C)) return core::ColorPrimaries::BT601_525;
	if (CFEqual(val, kCVImageBufferColorPrimaries_ITU_R_2020)) return core::ColorPrimaries::BT2020;
	if (CFEqual(val, kCVImageBufferColorPrimaries_DCI_P3)) return core::ColorPrimaries::DCI_P3;
	return core::ColorPrimaries::Unspecified;
}

// Parse transfer function from a CV attachment CFString.
static core::TransferFunction parse_transfer_function(CFStringRef val) {
	if (!val) return core::TransferFunction::Unspecified;
	if (CFEqual(val, kCVImageBufferTransferFunction_ITU_R_709_2)) return core::TransferFunction::BT709;
	if (CFEqual(val, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ)) return core::TransferFunction::PQ;
	if (CFEqual(val, kCVImageBufferTransferFunction_ITU_R_2100_HLG)) return core::TransferFunction::HLG;
	if (CFEqual(val, kCVImageBufferTransferFunction_sRGB)) return core::TransferFunction::BT709;
	return core::TransferFunction::Unspecified;
}

// Read colorimetry from a CVPixelBuffer's CV attachment dictionary.
static void populate_colorimetry(CVPixelBufferRef pb, core::VideoFrame &frame) {
	// Read from CV attachment dictionary (the most reliable source for per-frame
	// metadata). These are set by the decoder and reflect the actual encoded
	// colour metadata.
	CFTypeRef val;

	val = CVBufferCopyAttachment(pb, kCVImageBufferYCbCrMatrixKey, nullptr);
	if (val) {
		frame.color.matrix = parse_ycbcr_matrix(static_cast<CFStringRef>(val));
		CFRelease(val);
	}
	val = CVBufferCopyAttachment(pb, kCVImageBufferColorPrimariesKey, nullptr);
	if (val) {
		frame.color.primaries = parse_color_primaries(static_cast<CFStringRef>(val));
		CFRelease(val);
	}
	val = CVBufferCopyAttachment(pb, kCVImageBufferTransferFunctionKey, nullptr);
	if (val) {
		frame.color.transfer = parse_transfer_function(static_cast<CFStringRef>(val));
		CFRelease(val);
	}
	// Range: determine from the pixel format type (handles both 8-bit and 10-bit
	// biplanar formats).
	OSType fmt = CVPixelBufferGetPixelFormatType(pb);
	if (fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
			fmt == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange) {
		frame.color.range = core::ColorRange::Full;
	} else {
		// Video-range variants and all other formats are treated as video range.
		frame.color.range = core::ColorRange::Video;
	}
	// Bit depth from the pixel format.
	if (fmt == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
			fmt == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange) {
		frame.color.bit_depth = 10;
	} else {
		frame.color.bit_depth = 8;
	}
}

bool AvfBackend::Impl::build_reader(double start_time) {
	teardown();
	error = false;

	// apply_track_selection() guarantees selected_audio_track_index is valid
	// whenever any audio tracks exist, so it is safe to index directly here.
	AVAssetTrack *use_audio = (all_audio_tracks.count > 0) ? all_audio_tracks[selected_audio_track_index] : nil;

	NSError *err = nil;
	AVAssetReader *r = [AVAssetReader assetReaderWithAsset:asset error:&err];
	if (!r || err) {
		error = true;
		return false;
	}

	// Restrict the read to [start_time, duration] so seek() can resume mid-clip
	// at the nearest decodable sample. AVAssetReader decodes from the keyframe
	// at or before start; PTS values we report remain in absolute media time.
	if (start_time > 0.0) {
		CMTime start = CMTimeMakeWithSeconds(start_time, 600);
		r.timeRange = CMTimeRangeMake(start, kCMTimePositiveInfinity);
	}

	if (video_track) {
		AVAssetReaderTrackOutput *vo = make_video_output(video_track, color_);
		vo.alwaysCopiesSampleData = NO; // hand out the decoder's own surface
		if ([r canAddOutput:vo]) {
			[r addOutput:vo];
			video_out = vo;
		}
	}
	if (use_audio) {
		AVAssetReaderTrackOutput *ao = make_audio_output(use_audio);
		ao.alwaysCopiesSampleData = NO;
		if ([r canAddOutput:ao]) {
			[r addOutput:ao];
			audio_out = ao;
		}
	}

	if (![r startReading]) {
		error = true;
		return false;
	}
	reader = r;
	return true;
}

bool AvfBackend::Impl::build_audio_reader(int track_index, double start_time) {
	// Tear down any prior audio-only reader first.
	teardown_audio_reader();
	error = false;

	if (track_index < 0 || !all_audio_tracks ||
			track_index >= static_cast<int>(all_audio_tracks.count)) {
		return false;
	}

	AVAssetTrack *use_audio = all_audio_tracks[track_index];
	if (!use_audio) {
		return false;
	}

	NSError *err = nil;
	AVAssetReader *ar = [AVAssetReader assetReaderWithAsset:asset error:&err];
	if (!ar || err) {
		error = true;
		return false;
	}

	// Restrict to [start_time, duration] so we start at the keyframe at or
	// before the requested position, exactly like build_reader() does for
	// video+audio on seek. CMTimePositiveInfinity means "read to end."
	CMTime start = CMTimeMakeWithSeconds(start_time, 600);
	ar.timeRange = CMTimeRangeMake(start, kCMTimePositiveInfinity);

	AVAssetReaderTrackOutput *ao = make_audio_output(use_audio);
	ao.alwaysCopiesSampleData = NO;
	if (![ar canAddOutput:ao]) {
		return false;
	}
	[ar addOutput:ao];

	if (![ar startReading]) {
		error = true;
		return false;
	}
	audio_reader = ar;
	audio_only_out = ao;
	return true;
}

bool AvfBackend::Impl::build_video_reader(double start_time) {
	// Tear down only the combined reader; leave the dedicated audio-only
	// reader intact if it exists.
	teardown_combined();

	if (!video_track) {
		return false;
	}

	NSError *err = nil;
	AVAssetReader *r = [AVAssetReader assetReaderWithAsset:asset error:&err];
	if (!r || err) {
		error = true;
		return false;
	}

	if (start_time > 0.0) {
		CMTime start = CMTimeMakeWithSeconds(start_time, 600);
		r.timeRange = CMTimeRangeMake(start, kCMTimePositiveInfinity);
	}

	AVAssetReaderTrackOutput *vo = make_video_output(video_track);
	vo.alwaysCopiesSampleData = NO;
	if (![r canAddOutput:vo]) {
		error = true;
		return false;
	}
	[r addOutput:vo];

	if (![r startReading]) {
		error = true;
		return false;
	}
	reader = r;
	video_out = vo;
	// audio_out stays nil — this reader has no audio output, so its
	// buffer cannot back up and block video decode.
	return true;
}

// -----------------------------------------------------------------------
// AvfBackend
// -----------------------------------------------------------------------
AvfBackend::AvfBackend() :
		impl_(std::make_unique<Impl>()) {}

AvfBackend::~AvfBackend() {
	close();
}

AvfBackend::AvfBackend(AvfBackend &&) noexcept = default;
AvfBackend &AvfBackend::operator=(AvfBackend &&) noexcept = default;

bool AvfBackend::open(const std::string &url_or_path) {
	close();
	impl_ = std::make_unique<Impl>();

	@autoreleasepool {
		// Accept either a file:// URL or a bare path.
		NSString *str = [NSString stringWithUTF8String:url_or_path.c_str()];
		NSURL *url = nil;
		if ([str hasPrefix:@"file://"] || [str containsString:@"://"]) {
			url = [NSURL URLWithString:str];
		} else {
			url = [NSURL fileURLWithPath:str];
		}
		if (!url) {
			impl_->error = true;
			return false;
		}

		AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
		if (!asset) {
			impl_->error = true;
			return false;
		}
		impl_->asset = asset;
		impl_->path = url_or_path;
		impl_->duration = CMTimeGetSeconds(asset.duration);

		// Resolve tracks. tracksWithMediaType is synchronous on a local file
		// asset, which is exactly the headless use case.
		// The synchronous track accessors are deprecated in favour of the async
		// load API, but for a local-file headless decoder synchronous resolution
		// is exactly what we want. Suppress the deprecation locally.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
		NSArray<AVAssetTrack *> *vtracks = [asset tracksWithMediaType:AVMediaTypeVideo];
		NSArray<AVAssetTrack *> *atracks = [asset tracksWithMediaType:AVMediaTypeAudio];
#pragma clang diagnostic pop

		if (vtracks.count > 0) {
			impl_->video_track = vtracks[0];
			CGSize sz = impl_->video_track.naturalSize;
			// Apply the track's preferred transform so rotated clips report the
			// displayed dimensions; for our synthetic clips this is identity.
			CGSize disp = CGSizeApplyAffineTransform(sz, impl_->video_track.preferredTransform);
			impl_->width = static_cast<int>(std::abs(disp.width));
			impl_->height = static_cast<int>(std::abs(disp.height));

			// Parse colorimetry from the video track's format description extensions.
			// These fields may be empty for untagged clips; in that case the
			// defaults (BT.709, video range) stay in effect — pixel-identical to
			// the old hard-coded behaviour. Per-frame CV attachments (which are
			// more reliable) override these at decode time.
			NSArray *vfmts = impl_->video_track.formatDescriptions;
			if (vfmts.count > 0) {
				CMVideoFormatDescriptionRef vfd =
						(__bridge CMVideoFormatDescriptionRef)vfmts[0];
				CFStringRef val;

				val = (CFStringRef)CMFormatDescriptionGetExtension(vfd,
						kCMFormatDescriptionExtension_YCbCrMatrix);
				if (val) {
					impl_->color_.matrix = parse_ycbcr_matrix(val);
				}

				val = (CFStringRef)CMFormatDescriptionGetExtension(vfd,
						kCMFormatDescriptionExtension_ColorPrimaries);
				if (val) {
					impl_->color_.primaries = parse_color_primaries(val);
				}

				val = (CFStringRef)CMFormatDescriptionGetExtension(vfd,
						kCMFormatDescriptionExtension_TransferFunction);
				if (val) {
					impl_->color_.transfer = parse_transfer_function(val);
				}

				// Bit depth: detect from the format description's BitsPerComponent
				// extension. 8-bit sources return 8, 10-bit sources (HEVC Main10)
				// return 10. Default to 8 if absent (legacy behaviour).
				impl_->color_.bit_depth = 8;
				CFNumberRef bpc_ref = (CFNumberRef)CMFormatDescriptionGetExtension(vfd,
						kCMFormatDescriptionExtension_BitsPerComponent);
				if (bpc_ref) {
					int32_t bpc;
					if (CFNumberGetValue(bpc_ref, kCFNumberSInt32Type, &bpc)) {
						impl_->color_.bit_depth = (bpc >= 10) ? 10 : 8;
					}
				}
				// Source range: read from the format description extension. Default to
				// video range (legacy behaviour).
				CFBooleanRef full_range = (CFBooleanRef)CMFormatDescriptionGetExtension(vfd,
						kCMFormatDescriptionExtension_FullRangeVideo);
				if (full_range && CFBooleanGetValue(full_range)) {
					impl_->color_.range = core::ColorRange::Full;
				} else {
					impl_->color_.range = core::ColorRange::Video;
				}
			}
		}
		// Enumerate all audio tracks with per-track metadata.
		impl_->audio_tracks.clear();
		for (AVAssetTrack *at in atracks) {
			core::AudioTrackInfo meta;

			// Language: use the extended language tag (BCP 47) when available,
			// falling back to the ISO 639-2 language code.
			if (NSString *lang = at.extendedLanguageTag) {
				meta.language = std::string([lang UTF8String]);
			} else if (NSString *code = at.languageCode) {
				meta.language = std::string([code UTF8String]);
			}

			// Name: not directly available on all macOS deployments; we leave it
			// empty in v1. The language code serves as a surrogate identifier.

			// The first audio track is the container default when no explicit
			// default flag is present in the container metadata.
			meta.is_default = (impl_->audio_tracks.empty());

			// Channel count and sample rate from the format description.
			NSArray *fmts = at.formatDescriptions;
			if (fmts.count > 0) {
				CMAudioFormatDescriptionRef afd =
						(__bridge CMAudioFormatDescriptionRef)fmts[0];
				const AudioStreamBasicDescription *asbd =
						CMAudioFormatDescriptionGetStreamBasicDescription(afd);
				if (asbd) {
					meta.channels = static_cast<int>(asbd->mChannelsPerFrame);
					meta.sample_rate = static_cast<int>(asbd->mSampleRate);
				}
			}
			impl_->audio_tracks.push_back(meta);
		}

		// Store all audio track objects for track selection at build_reader() time.
		impl_->all_audio_tracks = atracks;
		impl_->selected_audio_track_index = 0;

		// Initialise the legacy fields from the first audio track.
		if (atracks.count > 0) {
			// Apply track 0 (the default) to populate audio_track, channels, rate.
			impl_->apply_track_selection(0);
		}

		if (!impl_->video_track && !impl_->audio_track && atracks.count == 0) {
			impl_->error = true;
			return false;
		}

		return impl_->build_reader(0.0);
	}
}

void AvfBackend::close() {
	if (impl_) {
		impl_->teardown();
		impl_->asset = nil;
		impl_->video_track = nil;
		impl_->audio_track = nil;
		impl_->all_audio_tracks = nil;
		impl_->audio_tracks.clear();
	}
}

double AvfBackend::duration_seconds() const {
	return impl_ ? impl_->duration : 0.0;
}
int AvfBackend::video_width() const {
	return impl_ ? impl_->width : 0;
}
int AvfBackend::video_height() const {
	return impl_ ? impl_->height : 0;
}
int AvfBackend::audio_channel_count() const {
	return impl_ ? impl_->audio_channels : 0;
}
int AvfBackend::audio_sample_rate() const {
	return impl_ ? impl_->audio_rate : 0;
}
int AvfBackend::audio_track_count() const {
	return impl_ ? static_cast<int>(impl_->audio_tracks.size()) : 0;
}
core::AudioTrackInfo AvfBackend::audio_track_info(int index) const {
	if (!impl_ || index < 0 ||
			static_cast<size_t>(index) >= impl_->audio_tracks.size()) {
		return {};
	}
	return impl_->audio_tracks[static_cast<size_t>(index)];
}
void AvfBackend::select_audio_track(int index) {
	if (!impl_) {
		return;
	}
	const int count = static_cast<int>(impl_->audio_tracks.size());
	if (count == 0) {
		return; // no audio tracks to select from
	}
	// Clamp out-of-range to the nearest valid index.
	const int clamped = std::clamp(index, 0, count - 1);
	impl_->apply_track_selection(clamped);
}

bool AvfBackend::reselect_audio_track(int index, double pts_seconds) {
	if (!impl_ || !impl_->asset) {
		return false;
	}
	const int count = static_cast<int>(impl_->audio_tracks.size());
	if (count == 0) {
		return false; // no audio tracks to select
	}
	// Clamp out-of-range to the nearest valid index.
	const int clamped = std::clamp(index, 0, count - 1);
	const double target = pts_seconds < 0.0 ? 0.0 : pts_seconds;

	@autoreleasepool {
		// Step 1: build a dedicated audio-only reader for the new track.
		if (!impl_->build_audio_reader(clamped, target)) {
			return false;
		}

		// Step 2: tear down the combined reader and rebuild it as video-only
		// starting from `target` so the video resumes near the requested
		// position rather than repeating from the beginning of the clip.
		// The new reader primes from the keyframe at or before `target`,
		// which matches the audio-only reader's start position.
		if (!impl_->build_video_reader(target)) {
			impl_->teardown_audio_reader();
			return false;
		}

		impl_->apply_track_selection(clamped);
		return true;
	}
}

bool AvfBackend::had_error() const {
	return impl_ && impl_->error;
}

core::Colorimetry AvfBackend::colorimetry() const {
	return impl_ ? impl_->color_ : core::Colorimetry::bt709_defaults();
}

bool AvfBackend::seek(double pts_seconds) {
	if (!impl_ || !impl_->asset) {
		return false;
	}
	@autoreleasepool {
		if (pts_seconds < 0.0) {
			pts_seconds = 0.0;
		}
		// Tear down any dedicated audio-only reader so seek builds a fresh
		// combined reader with both video and the selected audio track.
		impl_->teardown_audio_reader();
		return impl_->build_reader(pts_seconds);
	}
}

std::optional<core::VideoFrame> AvfBackend::next_video_frame() {
	if (!impl_ || !impl_->reader || !impl_->video_out) {
		return std::nullopt;
	}
	@autoreleasepool {
		CMSampleBufferRef sample = [impl_->video_out copyNextSampleBuffer];
		if (!sample) {
			if (impl_->reader.status == AVAssetReaderStatusFailed) {
				impl_->error = true;
			}
			return std::nullopt;
		}

		CMTime pts = CMSampleBufferGetPresentationTimeStamp(sample);
		CVImageBufferRef image = CMSampleBufferGetImageBuffer(sample);
		if (!image) {
			CFRelease(sample);
			impl_->error = true;
			return std::nullopt;
		}

		// Adopt a +1 retain on the pixel buffer into a move-only owner, then
		// hand that ownership to the frame's release callback. The CMSampleBuffer
		// itself is released immediately; the CVPixelBuffer outlives it.
		CVPixelBufferRef pb = (CVPixelBufferRef)image;
		PixelBufferRef owner = PixelBufferRef::retain(pb);

		core::VideoFrame frame;
		frame.pts_seconds = CMTimeGetSeconds(pts);
		frame.native_handle = static_cast<void *>(owner.get());
		frame.width = static_cast<int>(CVPixelBufferGetWidth(pb));
		frame.height = static_cast<int>(CVPixelBufferGetHeight(pb));
		// Detect the pixel format from the actual CVPixelBuffer type.
		OSType pb_fmt = CVPixelBufferGetPixelFormatType(pb);
		if (pb_fmt == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
				pb_fmt == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange) {
			frame.pixel_format = core::PixelFormat::x420;
		} else {
			frame.pixel_format = core::PixelFormat::NV12;
		}

		// Move the owner into the release closure; when the consumer calls
		// release() the buffer is dropped exactly once. shared_ptr lets the
		// std::function (copyable) hold the move-only owner.
		auto owner_holder = std::make_shared<PixelBufferRef>(std::move(owner));
		frame.release = [owner_holder]() mutable { owner_holder->reset(); };

		// Populate per-frame colorimetry from CVImageBuffer attachments.
		// This is the most reliable source — the decoder sets these per-sample.
		populate_colorimetry(pb, frame);

		CFRelease(sample);
		return frame;
	}
}

std::optional<core::AudioChunk> AvfBackend::next_audio_chunk() {
	if (!impl_) {
		return std::nullopt;
	}

	// When a dedicated audio-only reader is active (from reselect_audio_track),
	// read from it. Otherwise read from the combined reader's audio output.
	AVAssetReader *active_reader = impl_->audio_reader ? impl_->audio_reader : impl_->reader;
	AVAssetReaderTrackOutput *active_out = impl_->audio_reader ? impl_->audio_only_out : impl_->audio_out;
	if (!active_reader || !active_out) {
		return std::nullopt;
	}

	@autoreleasepool {
		CMSampleBufferRef sample = [active_out copyNextSampleBuffer];
		if (!sample) {
			if (active_reader.status == AVAssetReaderStatusFailed) {
				impl_->error = true;
			}
			return std::nullopt;
		}

		CMTime pts = CMSampleBufferGetPresentationTimeStamp(sample);
		CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample);
		CMItemCount num_frames = CMSampleBufferGetNumSamples(sample);
		if (!block || num_frames <= 0) {
			CFRelease(sample);
			impl_->error = true;
			return std::nullopt;
		}

		size_t total_len = 0;
		char *data_ptr = nullptr;
		OSStatus st = CMBlockBufferGetDataPointer(block, 0, nullptr, &total_len, &data_ptr);
		if (st != kCMBlockBufferNoErr || !data_ptr) {
			CFRelease(sample);
			impl_->error = true;
			return std::nullopt;
		}

		const int channels = impl_->audio_channels > 0 ? impl_->audio_channels : 1;
		const size_t float_count = total_len / sizeof(float);

		// Copy into our scratch buffer so the borrowed pointer outlives the
		// CMSampleBuffer (which we release before returning).
		impl_->audio_scratch.resize(float_count);
		std::memcpy(impl_->audio_scratch.data(), data_ptr, float_count * sizeof(float));

		core::AudioChunk chunk;
		chunk.pts_seconds = CMTimeGetSeconds(pts);
		chunk.samples = impl_->audio_scratch.data();
		chunk.frame_count = static_cast<int>(num_frames);
		chunk.channel_count = channels;
		chunk.sample_rate = impl_->audio_rate;

		CFRelease(sample);
		return chunk;
	}
}

} // namespace avf
