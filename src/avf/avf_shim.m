// -----------------------------------------------------------------------
// avf_shim.m — AVFoundation decode object graph behind a pure C ABI.
//
// Compiled with -fobjc-arc. ARC manages the Objective-C object graph
// (AVURLAsset, AVAssetReader, track outputs); the Core Video / Core Media
// CFTypeRefs that cross the C boundary (CVPixelBufferRef, CMSampleBufferRef,
// CMBlockBufferRef) are NOT ARC-managed and are retained/released explicitly.
//
// This file is pure mechanism: it drives the AVFoundation object graph
// behind a C ABI and makes no policy decisions. All policy (track
// selection/clamping, EOS/error interpretation) lives in avf_backend.zig.
// -----------------------------------------------------------------------
#import "avf_shim.h"

#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>

#include <stdlib.h>
#include <string.h>

// One audio track's shim-owned metadata. `language` is strdup'd and freed on
// close so the pointer stays valid until close/destroy — the returned
// AudioTrackInfo borrows it rather than owning a copy.
typedef struct {
	char *language;
	int channels;
	int sample_rate;
	int is_default;
} nv_avf_track;

// State container. Held via an opaque nv_avf_backend* using __bridge_retained
// so ARC keeps the strong Objective-C members alive across C calls.
@interface NvAvfState : NSObject {
@public
	// AVAssetReader with one output per track. Recreated on open()/seek()
	// because AVAssetReader is single-pass and cannot be rewound.
	AVURLAsset *asset;
	AVAssetReader *reader;
	AVAssetReaderTrackOutput *video_out;
	AVAssetReaderTrackOutput *audio_out;

	AVAssetTrack *video_track;

	// All audio track objects, indexed by position in the `tracks` array.
	NSArray<AVAssetTrack *> *all_audio_tracks;

	// Dedicated audio-only reader for mid-decode track reselect. Non-nil only
	// after nv_avf_reselect_audio_track; the combined reader keeps feeding
	// video undisturbed, and nv_avf_next_audio_chunk prefers this reader when
	// set.
	AVAssetReader *audio_reader;
	AVAssetReaderTrackOutput *audio_only_out;

	// Negotiated colorimetry parsed from the video track's format descriptions
	// at open. Drives make_video_output's pixel-format choice.
	nv_avf_colorimetry color;

	double duration;
	int width;
	int height;
	int has_video;

	// Per-track audio metadata. Populated during open, freed on close.
	nv_avf_track *tracks;
	int track_count;

	// Backing store for the most recent decoded audio chunk. nv_avf_audio_chunk
	// borrows this pointer, so it must outlive the returned chunk; it stays
	// valid until the next nv_avf_next_audio_chunk / close.
	float *audio_scratch;
	size_t audio_scratch_cap; // capacity in floats
}
@end

@implementation NvAvfState
@end

static inline NvAvfState *state_of(nv_avf_backend *h) {
	return (__bridge NvAvfState *)h;
}

// -----------------------------------------------------------------------
// Colorimetry helpers — map CV / CM attachment CFStrings to shim enum tags.
// -----------------------------------------------------------------------
static int parse_ycbcr_matrix(CFStringRef val) {
	if (!val) return NV_AVF_MATRIX_UNSPECIFIED;
	if (CFEqual(val, kCVImageBufferYCbCrMatrix_ITU_R_709_2)) return NV_AVF_MATRIX_BT709;
	if (CFEqual(val, kCVImageBufferYCbCrMatrix_ITU_R_601_4)) return NV_AVF_MATRIX_BT601;
	if (CFEqual(val, kCVImageBufferYCbCrMatrix_ITU_R_2020)) return NV_AVF_MATRIX_BT2020;
	return NV_AVF_MATRIX_UNSPECIFIED;
}

static int parse_color_primaries(CFStringRef val) {
	if (!val) return NV_AVF_PRIM_UNSPECIFIED;
	if (CFEqual(val, kCVImageBufferColorPrimaries_ITU_R_709_2)) return NV_AVF_PRIM_BT709;
	if (CFEqual(val, kCVImageBufferColorPrimaries_EBU_3213)) return NV_AVF_PRIM_BT601_625;
	if (CFEqual(val, kCVImageBufferColorPrimaries_SMPTE_C)) return NV_AVF_PRIM_BT601_525;
	if (CFEqual(val, kCVImageBufferColorPrimaries_ITU_R_2020)) return NV_AVF_PRIM_BT2020;
	if (CFEqual(val, kCVImageBufferColorPrimaries_DCI_P3)) return NV_AVF_PRIM_DCI_P3;
	return NV_AVF_PRIM_UNSPECIFIED;
}

static int parse_transfer_function(CFStringRef val) {
	if (!val) return NV_AVF_TRANSFER_UNSPECIFIED;
	if (CFEqual(val, kCVImageBufferTransferFunction_ITU_R_709_2)) return NV_AVF_TRANSFER_BT709;
	if (CFEqual(val, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ)) return NV_AVF_TRANSFER_PQ;
	if (CFEqual(val, kCVImageBufferTransferFunction_ITU_R_2100_HLG)) return NV_AVF_TRANSFER_HLG;
	if (CFEqual(val, kCVImageBufferTransferFunction_sRGB)) return NV_AVF_TRANSFER_BT709;
	return NV_AVF_TRANSFER_UNSPECIFIED;
}

// -----------------------------------------------------------------------
// Biplanar 4:2:0 pixel format knowledge — single source of truth for which
// OSType corresponds to which (bit depth, range) pair. Indexed
// [bit_depth >= 10][range == full]; is_10bit_biplanar, is_full_range, and
// biplanar_pixel_format all derive from this table instead of each
// open-coding the same four-constant comparison.
// -----------------------------------------------------------------------
static const OSType kBiplanarPixelFormats[2][2] = {
	// range: video,                                     full
	{ kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange }, // 8-bit
	{ kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange }, // 10-bit
};

// Pick the biplanar pixel format for a requested bit depth (10-bit vs 8-bit)
// and range (full vs video).
static OSType biplanar_pixel_format(BOOL bit10, BOOL full_range) {
	return kBiplanarPixelFormats[bit10 ? 1 : 0][full_range ? 1 : 0];
}

// Whether `fmt` is one of the two 10-bit biplanar formats.
static bool is_10bit_biplanar(OSType fmt) {
	return fmt == kBiplanarPixelFormats[1][0] || fmt == kBiplanarPixelFormats[1][1];
}

// Whether `fmt` is one of the two full-range biplanar formats (8- or 10-bit).
static bool is_full_range(OSType fmt) {
	return fmt == kBiplanarPixelFormats[0][1] || fmt == kBiplanarPixelFormats[1][1];
}

// Read colorimetry from a CVPixelBuffer's CV attachment dictionary — the most
// reliable per-frame source (set by the decoder from the encoded metadata).
static void populate_frame_colorimetry(CVPixelBufferRef pb, nv_avf_colorimetry *out) {
	out->matrix = NV_AVF_MATRIX_UNSPECIFIED;
	out->primaries = NV_AVF_PRIM_UNSPECIFIED;
	out->transfer = NV_AVF_TRANSFER_UNSPECIFIED;

	CFTypeRef val;
	val = CVBufferCopyAttachment(pb, kCVImageBufferYCbCrMatrixKey, NULL);
	if (val) {
		out->matrix = parse_ycbcr_matrix((CFStringRef)val);
		CFRelease(val);
	}
	val = CVBufferCopyAttachment(pb, kCVImageBufferColorPrimariesKey, NULL);
	if (val) {
		out->primaries = parse_color_primaries((CFStringRef)val);
		CFRelease(val);
	}
	val = CVBufferCopyAttachment(pb, kCVImageBufferTransferFunctionKey, NULL);
	if (val) {
		out->transfer = parse_transfer_function((CFStringRef)val);
		CFRelease(val);
	}
	// Range and bit depth from the pixel format type (covers 8- and 10-bit
	// biplanar formats).
	OSType fmt = CVPixelBufferGetPixelFormatType(pb);
	out->range = is_full_range(fmt) ? NV_AVF_RANGE_FULL : NV_AVF_RANGE_VIDEO;
	out->bit_depth = is_10bit_biplanar(fmt) ? 10 : 8;
}

// -----------------------------------------------------------------------
// Output configuration.
// -----------------------------------------------------------------------

// Biplanar Y'CbCr video output. Pixel format follows the negotiated bit depth
// (NV12 for 8-bit, x420 for 10-bit) and range. IOSurface-backed + Metal
// compatible so the decode stays on the GPU path for zero-copy present.
static AVAssetReaderTrackOutput *make_video_output(AVAssetTrack *track, const nv_avf_colorimetry *color) {
	OSType pixel_format = biplanar_pixel_format(color->bit_depth >= 10, color->range == NV_AVF_RANGE_FULL);
	NSDictionary *settings = @{
		(NSString *)kCVPixelBufferPixelFormatTypeKey : @(pixel_format),
		(NSString *)kCVPixelBufferIOSurfacePropertiesKey : @{},
		(NSString *)kCVPixelBufferMetalCompatibilityKey : @YES,
	};
	return [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track
													 outputSettings:settings];
}

// Interleaved float32 LPCM, native (little) endianness.
static AVAssetReaderTrackOutput *make_audio_output(AVAssetTrack *track) {
	NSDictionary *settings = @{
		(NSString *)AVFormatIDKey : @(kAudioFormatLinearPCM),
		(NSString *)AVLinearPCMBitDepthKey : @32,
		(NSString *)AVLinearPCMIsFloatKey : @YES,
		(NSString *)AVLinearPCMIsBigEndianKey : @NO,
		(NSString *)AVLinearPCMIsNonInterleaved : @NO,
	};
	return [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track
													 outputSettings:settings];
}

// -----------------------------------------------------------------------
// Teardown helpers.
// -----------------------------------------------------------------------
static void teardown_audio_reader(NvAvfState *s) {
	if (s->audio_reader) {
		[s->audio_reader cancelReading];
	}
	s->audio_reader = nil;
	s->audio_only_out = nil;
}

static void teardown_combined(NvAvfState *s) {
	if (s->reader) {
		[s->reader cancelReading];
	}
	s->reader = nil;
	s->video_out = nil;
	s->audio_out = nil;
}

static void free_tracks(NvAvfState *s) {
	if (s->tracks) {
		for (int i = 0; i < s->track_count; ++i) {
			free(s->tracks[i].language);
		}
		free(s->tracks);
		s->tracks = NULL;
	}
	s->track_count = 0;
}

// -----------------------------------------------------------------------
// ABI probe.
// -----------------------------------------------------------------------
void nv_avf_abi_probe_fill(nv_avf_abi_probe *out) {
	out->sizeof_colorimetry = sizeof(nv_avf_colorimetry);
	out->off_colorimetry[0] = offsetof(nv_avf_colorimetry, matrix);
	out->off_colorimetry[1] = offsetof(nv_avf_colorimetry, primaries);
	out->off_colorimetry[2] = offsetof(nv_avf_colorimetry, transfer);
	out->off_colorimetry[3] = offsetof(nv_avf_colorimetry, range);
	out->off_colorimetry[4] = offsetof(nv_avf_colorimetry, bit_depth);

	out->sizeof_open_info = sizeof(nv_avf_open_info);
	out->off_open_info[0] = offsetof(nv_avf_open_info, duration_seconds);
	out->off_open_info[1] = offsetof(nv_avf_open_info, width);
	out->off_open_info[2] = offsetof(nv_avf_open_info, height);
	out->off_open_info[3] = offsetof(nv_avf_open_info, has_video);
	out->off_open_info[4] = offsetof(nv_avf_open_info, audio_track_count);
	out->off_open_info[5] = offsetof(nv_avf_open_info, color);

	out->sizeof_audio_track_info = sizeof(nv_avf_audio_track_info);
	out->off_audio_track_info[0] = offsetof(nv_avf_audio_track_info, language);
	out->off_audio_track_info[1] = offsetof(nv_avf_audio_track_info, channels);
	out->off_audio_track_info[2] = offsetof(nv_avf_audio_track_info, sample_rate);
	out->off_audio_track_info[3] = offsetof(nv_avf_audio_track_info, is_default);

	out->sizeof_video_frame = sizeof(nv_avf_video_frame);
	out->off_video_frame[0] = offsetof(nv_avf_video_frame, pixel_buffer);
	out->off_video_frame[1] = offsetof(nv_avf_video_frame, pts_seconds);
	out->off_video_frame[2] = offsetof(nv_avf_video_frame, width);
	out->off_video_frame[3] = offsetof(nv_avf_video_frame, height);
	out->off_video_frame[4] = offsetof(nv_avf_video_frame, pixel_format);
	out->off_video_frame[5] = offsetof(nv_avf_video_frame, color);

	out->sizeof_audio_chunk = sizeof(nv_avf_audio_chunk);
	out->off_audio_chunk[0] = offsetof(nv_avf_audio_chunk, samples);
	out->off_audio_chunk[1] = offsetof(nv_avf_audio_chunk, pts_seconds);
	out->off_audio_chunk[2] = offsetof(nv_avf_audio_chunk, frame_count);
	out->off_audio_chunk[3] = offsetof(nv_avf_audio_chunk, float_count);
	out->off_audio_chunk[4] = offsetof(nv_avf_audio_chunk, channels);
	out->off_audio_chunk[5] = offsetof(nv_avf_audio_chunk, sample_rate);
}

// -----------------------------------------------------------------------
// Lifecycle.
// -----------------------------------------------------------------------
nv_avf_backend *nv_avf_create(void) {
	NvAvfState *s = [[NvAvfState alloc] init];
	s->color.matrix = NV_AVF_MATRIX_BT709;
	s->color.primaries = NV_AVF_PRIM_BT709;
	s->color.transfer = NV_AVF_TRANSFER_BT709;
	s->color.range = NV_AVF_RANGE_VIDEO;
	s->color.bit_depth = 8;
	return (__bridge_retained nv_avf_backend *)s;
}

void nv_avf_close(nv_avf_backend *h) {
	NvAvfState *s = state_of(h);
	teardown_audio_reader(s);
	teardown_combined(s);
	s->asset = nil;
	s->video_track = nil;
	s->all_audio_tracks = nil;
	free_tracks(s);
	free(s->audio_scratch);
	s->audio_scratch = NULL;
	s->audio_scratch_cap = 0;
	s->duration = 0.0;
	s->width = 0;
	s->height = 0;
	s->has_video = 0;
}

void nv_avf_destroy(nv_avf_backend *h) {
	if (!h) return;
	nv_avf_close(h);
	NvAvfState *s = (__bridge_transfer NvAvfState *)h; // ARC releases
	(void)s;
}

nv_avf_result nv_avf_open(nv_avf_backend *h, const char *url_or_path, nv_avf_open_info *info) {
	NvAvfState *s = state_of(h);
	// Resetting a previously-open handle is the caller's job (nv_avf_close);
	// this only ever runs against a handle that's already closed.
	if (info) {
		memset(info, 0, sizeof(*info));
	}

	@autoreleasepool {
		// Accept either a file:// URL (or any scheme://) or a bare path.
		NSString *str = [NSString stringWithUTF8String:url_or_path];
		NSURL *url = nil;
		if ([str hasPrefix:@"file://"] || [str containsString:@"://"]) {
			url = [NSURL URLWithString:str];
		} else {
			url = [NSURL fileURLWithPath:str];
		}
		if (!url) {
			return NV_AVF_NONE;
		}

		AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
		if (!asset) {
			return NV_AVF_NONE;
		}
		s->asset = asset;
		s->duration = CMTimeGetSeconds(asset.duration);

		// Synchronous track resolution: exactly right for a local-file headless
		// decoder. The sync accessors are deprecated for the async load API;
		// suppress the deprecation locally.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
		NSArray<AVAssetTrack *> *vtracks = [asset tracksWithMediaType:AVMediaTypeVideo];
		NSArray<AVAssetTrack *> *atracks = [asset tracksWithMediaType:AVMediaTypeAudio];
#pragma clang diagnostic pop

		if (vtracks.count > 0) {
			s->video_track = vtracks[0];
			s->has_video = 1;
			CGSize sz = s->video_track.naturalSize;
			// Apply the preferred transform so rotated clips report displayed
			// dimensions (identity for our synthetic clips).
			CGSize disp = CGSizeApplyAffineTransform(sz, s->video_track.preferredTransform);
			s->width = (int)fabs(disp.width);
			s->height = (int)fabs(disp.height);

			// Parse negotiated colorimetry from the format description
			// extensions. Empty for untagged clips → the BT.709/video-range
			// defaults stay. Per-frame CV attachments override at decode time.
			NSArray *vfmts = s->video_track.formatDescriptions;
			if (vfmts.count > 0) {
				CMVideoFormatDescriptionRef vfd =
						(__bridge CMVideoFormatDescriptionRef)vfmts[0];
				CFStringRef val;

				val = (CFStringRef)CMFormatDescriptionGetExtension(vfd,
						kCMFormatDescriptionExtension_YCbCrMatrix);
				if (val) {
					s->color.matrix = parse_ycbcr_matrix(val);
				}
				val = (CFStringRef)CMFormatDescriptionGetExtension(vfd,
						kCMFormatDescriptionExtension_ColorPrimaries);
				if (val) {
					s->color.primaries = parse_color_primaries(val);
				}
				val = (CFStringRef)CMFormatDescriptionGetExtension(vfd,
						kCMFormatDescriptionExtension_TransferFunction);
				if (val) {
					s->color.transfer = parse_transfer_function(val);
				}

				// Bit depth from BitsPerComponent (8 default; HEVC Main10 → 10).
				s->color.bit_depth = 8;
				CFNumberRef bpc_ref = (CFNumberRef)CMFormatDescriptionGetExtension(vfd,
						kCMFormatDescriptionExtension_BitsPerComponent);
				if (bpc_ref) {
					int32_t bpc;
					if (CFNumberGetValue(bpc_ref, kCFNumberSInt32Type, &bpc)) {
						s->color.bit_depth = (bpc >= 10) ? 10 : 8;
					}
				}
				// Range from FullRangeVideo (default video range).
				CFBooleanRef full_range = (CFBooleanRef)CMFormatDescriptionGetExtension(vfd,
						kCMFormatDescriptionExtension_FullRangeVideo);
				if (full_range && CFBooleanGetValue(full_range)) {
					s->color.range = NV_AVF_RANGE_FULL;
				} else {
					s->color.range = NV_AVF_RANGE_VIDEO;
				}
			}
		}

		// Enumerate all audio tracks with per-track metadata.
		int acount = (int)atracks.count;
		s->all_audio_tracks = atracks;
		if (acount > 0) {
			s->tracks = (nv_avf_track *)calloc((size_t)acount, sizeof(nv_avf_track));
			s->track_count = acount;
			for (int i = 0; i < acount; ++i) {
				AVAssetTrack *at = atracks[i];
				nv_avf_track *meta = &s->tracks[i];

				// Language: extended tag (BCP 47) when available, else ISO 639-2.
				NSString *lang = at.extendedLanguageTag;
				if (!lang) {
					lang = at.languageCode;
				}
				meta->language = strdup(lang ? [lang UTF8String] : "");

				// Name is left empty; AVFoundation doesn't surface a track name.

				// First track is the container default absent an explicit flag.
				meta->is_default = (i == 0) ? 1 : 0;

				NSArray *fmts = at.formatDescriptions;
				if (fmts.count > 0) {
					CMAudioFormatDescriptionRef afd =
							(__bridge CMAudioFormatDescriptionRef)fmts[0];
					const AudioStreamBasicDescription *asbd =
							CMAudioFormatDescriptionGetStreamBasicDescription(afd);
					if (asbd) {
						meta->channels = (int)asbd->mChannelsPerFrame;
						meta->sample_rate = (int)asbd->mSampleRate;
					}
				}
			}
		}

		if (!s->has_video && acount == 0) {
			return NV_AVF_NONE;
		}

		if (info) {
			info->duration_seconds = s->duration;
			info->width = s->width;
			info->height = s->height;
			info->has_video = s->has_video;
			info->audio_track_count = s->track_count;
			info->color = s->color;
		}
		return NV_AVF_OK;
	}
}

int nv_avf_get_audio_track_info(nv_avf_backend *h, int index, nv_avf_audio_track_info *out) {
	NvAvfState *s = state_of(h);
	if (index < 0 || index >= s->track_count) {
		return 0;
	}
	nv_avf_track *t = &s->tracks[index];
	out->language = t->language ? t->language : "";
	out->channels = t->channels;
	out->sample_rate = t->sample_rate;
	out->is_default = t->is_default;
	return 1;
}

// -----------------------------------------------------------------------
// Reader construction.
// -----------------------------------------------------------------------

// Which of the two requested outputs actually attached to the reader a
// create_started_reader call produced. `reader` is nil on any failure.
typedef struct {
	AVAssetReader *reader;
	BOOL video_attached;
	BOOL audio_attached;
} started_reader_t;

// Shared skeleton behind all three reader constructors below: create an
// AVAssetReader for `asset`, window it to [start_time, +inf) when
// start_time > 0 (AVAssetReader decodes from the keyframe at or before
// start; PTS values stay in absolute media time), attach whichever of
// `video_output`/`audio_output` are non-nil, and start reading.
//
// A `*_required` output the reader rejects (canAddOutput false) makes the
// whole call NV_AVF_NONE before startReading ever runs; a non-required
// output that's rejected is silently dropped (out->*_attached stays NO)
// and the reader still starts — this is how the combined reader tolerates
// a track it can't back without failing video or audio outright.
static nv_avf_result create_started_reader(AVURLAsset *asset, double start_time,
		AVAssetReaderTrackOutput *video_output, BOOL video_required,
		AVAssetReaderTrackOutput *audio_output, BOOL audio_required,
		started_reader_t *out) {
	out->reader = nil;
	out->video_attached = NO;
	out->audio_attached = NO;

	NSError *err = nil;
	AVAssetReader *r = [AVAssetReader assetReaderWithAsset:asset error:&err];
	if (!r || err) {
		return NV_AVF_FAIL;
	}
	if (start_time > 0.0) {
		CMTime start = CMTimeMakeWithSeconds(start_time, 600);
		r.timeRange = CMTimeRangeMake(start, kCMTimePositiveInfinity);
	}

	// alwaysCopiesSampleData = NO on every output: hand out the decoder's
	// own surface/buffer instead of a defensive copy.
	if (video_output) {
		video_output.alwaysCopiesSampleData = NO;
		if ([r canAddOutput:video_output]) {
			[r addOutput:video_output];
			out->video_attached = YES;
		} else if (video_required) {
			return NV_AVF_NONE;
		}
	}
	if (audio_output) {
		audio_output.alwaysCopiesSampleData = NO;
		if ([r canAddOutput:audio_output]) {
			[r addOutput:audio_output];
			out->audio_attached = YES;
		} else if (audio_required) {
			return NV_AVF_NONE;
		}
	}

	if (![r startReading]) {
		return NV_AVF_FAIL;
	}
	out->reader = r;
	return NV_AVF_OK;
}

nv_avf_result nv_avf_build_reader(nv_avf_backend *h, double start_time, int audio_track_index) {
	NvAvfState *s = state_of(h);
	teardown_audio_reader(s);
	teardown_combined(s);

	@autoreleasepool {
		AVAssetTrack *use_audio = nil;
		if (audio_track_index >= 0 && s->all_audio_tracks &&
				audio_track_index < (int)s->all_audio_tracks.count) {
			use_audio = s->all_audio_tracks[audio_track_index];
		}

		AVAssetReaderTrackOutput *vo = s->video_track ? make_video_output(s->video_track, &s->color) : nil;
		AVAssetReaderTrackOutput *ao = use_audio ? make_audio_output(use_audio) : nil;

		// Both outputs are optional here: a track that can't be added is
		// dropped rather than failing the whole combined reader.
		started_reader_t started;
		nv_avf_result rc = create_started_reader(s->asset, start_time, vo, NO, ao, NO, &started);
		if (rc != NV_AVF_OK) {
			return rc;
		}
		s->reader = started.reader;
		s->video_out = started.video_attached ? vo : nil;
		s->audio_out = started.audio_attached ? ao : nil;
		return NV_AVF_OK;
	}
}

// Build a dedicated audio-only reader for `track_index` from `start_time`.
// Internal step of nv_avf_reselect_audio_track. NV_AVF_NONE on bad index or
// a rejected output, NV_AVF_FAIL on reader create/start failure.
static nv_avf_result build_audio_reader(NvAvfState *s, int track_index, double start_time) {
	teardown_audio_reader(s);

	if (track_index < 0 || !s->all_audio_tracks ||
			track_index >= (int)s->all_audio_tracks.count) {
		return NV_AVF_NONE;
	}
	AVAssetTrack *use_audio = s->all_audio_tracks[track_index];
	if (!use_audio) {
		return NV_AVF_NONE;
	}

	@autoreleasepool {
		AVAssetReaderTrackOutput *ao = make_audio_output(use_audio);

		started_reader_t started;
		nv_avf_result rc = create_started_reader(s->asset, start_time, nil, NO, ao, YES, &started);
		if (rc != NV_AVF_OK) {
			return rc;
		}
		s->audio_reader = started.reader;
		s->audio_only_out = ao;
		return NV_AVF_OK;
	}
}

// Build a video-only reader from `start_time`, tearing down only the
// combined reader (leaves any audio-only reader intact). Internal step of
// nv_avf_reselect_audio_track. NV_AVF_NONE when there's no video or the
// output is rejected, NV_AVF_FAIL on reader create/start failure.
static nv_avf_result build_video_reader(NvAvfState *s, double start_time) {
	teardown_combined(s);

	if (!s->video_track) {
		return NV_AVF_NONE;
	}

	@autoreleasepool {
		AVAssetReaderTrackOutput *vo = make_video_output(s->video_track, &s->color);

		started_reader_t started;
		nv_avf_result rc = create_started_reader(s->asset, start_time, vo, YES, nil, NO, &started);
		if (rc != NV_AVF_OK) {
			return rc;
		}
		s->reader = started.reader;
		s->video_out = vo;
		// audio_out stays nil — no audio output to back up and block video.
		return NV_AVF_OK;
	}
}

nv_avf_result nv_avf_reselect_audio_track(nv_avf_backend *h, int track_index, double start_time) {
	NvAvfState *s = state_of(h);

	nv_avf_result ar = build_audio_reader(s, track_index, start_time);
	if (ar != NV_AVF_OK) {
		return ar;
	}
	nv_avf_result vr = build_video_reader(s, start_time);
	if (vr != NV_AVF_OK) {
		// Partial failure: don't leave a dedicated audio reader dangling
		// with no matching video-only combined reader behind it.
		teardown_audio_reader(s);
		return vr;
	}
	return NV_AVF_OK;
}

void nv_avf_teardown_audio_reader(nv_avf_backend *h) {
	teardown_audio_reader(state_of(h));
}

// -----------------------------------------------------------------------
// Decode pump.
// -----------------------------------------------------------------------
nv_avf_result nv_avf_next_video_frame(nv_avf_backend *h, nv_avf_video_frame *out) {
	NvAvfState *s = state_of(h);
	if (!s->reader || !s->video_out) {
		return NV_AVF_NONE;
	}
	@autoreleasepool {
		CMSampleBufferRef sample = [s->video_out copyNextSampleBuffer];
		if (!sample) {
			return (s->reader.status == AVAssetReaderStatusFailed) ? NV_AVF_FAIL : NV_AVF_NONE;
		}

		CMTime pts = CMSampleBufferGetPresentationTimeStamp(sample);
		CVImageBufferRef image = CMSampleBufferGetImageBuffer(sample);
		if (!image) {
			CFRelease(sample);
			return NV_AVF_FAIL;
		}

		// Adopt a +1 retain on the pixel buffer for the caller; the sample
		// buffer is released immediately, the pixel buffer outlives it.
		CVPixelBufferRef pb = (CVPixelBufferRef)image;
		CVPixelBufferRetain(pb);

		out->pixel_buffer = (void *)pb;
		out->pts_seconds = CMTimeGetSeconds(pts);
		out->width = (int)CVPixelBufferGetWidth(pb);
		out->height = (int)CVPixelBufferGetHeight(pb);
		OSType pb_fmt = CVPixelBufferGetPixelFormatType(pb);
		out->pixel_format = is_10bit_biplanar(pb_fmt) ? NV_AVF_PIXFMT_X420 : NV_AVF_PIXFMT_NV12;
		// Per-frame colorimetry from CVImageBuffer attachments (most reliable).
		populate_frame_colorimetry(pb, &out->color);

		CFRelease(sample);
		return NV_AVF_OK;
	}
}

nv_avf_result nv_avf_next_audio_chunk(nv_avf_backend *h, nv_avf_audio_chunk *out) {
	NvAvfState *s = state_of(h);

	// Prefer the dedicated audio-only reader when active (mid-decode reselect),
	// else read the combined reader's audio output.
	AVAssetReader *active_reader = s->audio_reader ? s->audio_reader : s->reader;
	AVAssetReaderTrackOutput *active_out = s->audio_reader ? s->audio_only_out : s->audio_out;
	if (!active_reader || !active_out) {
		return NV_AVF_NONE;
	}

	@autoreleasepool {
		CMSampleBufferRef sample = [active_out copyNextSampleBuffer];
		if (!sample) {
			return (active_reader.status == AVAssetReaderStatusFailed) ? NV_AVF_FAIL : NV_AVF_NONE;
		}

		CMTime pts = CMSampleBufferGetPresentationTimeStamp(sample);
		CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample);
		CMItemCount num_frames = CMSampleBufferGetNumSamples(sample);
		if (!block || num_frames <= 0) {
			CFRelease(sample);
			return NV_AVF_FAIL;
		}

		size_t total_len = 0;
		char *data_ptr = NULL;
		OSStatus st = CMBlockBufferGetDataPointer(block, 0, NULL, &total_len, &data_ptr);
		if (st != kCMBlockBufferNoErr || !data_ptr) {
			CFRelease(sample);
			return NV_AVF_FAIL;
		}

		size_t float_count = total_len / sizeof(float);

		// Copy into shim scratch so the borrowed pointer outlives the sample
		// buffer (released before returning); valid until the next call/close.
		if (float_count > s->audio_scratch_cap) {
			float *grown = (float *)realloc(s->audio_scratch, float_count * sizeof(float));
			if (!grown) {
				CFRelease(sample);
				return NV_AVF_FAIL;
			}
			s->audio_scratch = grown;
			s->audio_scratch_cap = float_count;
		}
		if (float_count > 0) {
			memcpy(s->audio_scratch, data_ptr, float_count * sizeof(float));
		}

		out->samples = s->audio_scratch;
		out->pts_seconds = CMTimeGetSeconds(pts);
		out->frame_count = (int)num_frames;
		out->float_count = (int)float_count;

		// Diagnostic: the actual delivered format, off this sample buffer's
		// own format description -- distinct from nv_avf_audio_track_info's
		// pre-negotiation native descriptor. Cheap (no extra decode work);
		// left 0 if unavailable, which the Zig side treats as "no readback".
		out->channels = 0;
		out->sample_rate = 0;
		CMFormatDescriptionRef fd = CMSampleBufferGetFormatDescription(sample);
		if (fd) {
			const AudioStreamBasicDescription *asbd =
					CMAudioFormatDescriptionGetStreamBasicDescription((CMAudioFormatDescriptionRef)fd);
			if (asbd) {
				out->channels = (int)asbd->mChannelsPerFrame;
				out->sample_rate = (int)asbd->mSampleRate;
			}
		}

		CFRelease(sample);
		return NV_AVF_OK;
	}
}

void nv_avf_frame_release(void *pixel_buffer) {
	if (pixel_buffer) {
		CVPixelBufferRelease((CVPixelBufferRef)pixel_buffer);
	}
}
