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

#include <cmath>
#include <cstring>
#include <memory>
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

	std::string path;

	double duration = 0.0;
	int width = 0;
	int height = 0;
	int audio_channels = 0;
	int audio_rate = 0;

	bool error = false;

	// Backing store for the most recent decoded audio chunk. core::AudioChunk
	// returns a borrowed `const float*`, so the buffer must outlive the
	// returned chunk; it stays valid until the next next_audio_chunk() call.
	std::vector<float> audio_scratch;

	// Build a fresh AVAssetReader pumping from `start_time` (seconds). Used by
	// both open() (start 0) and seek(). Returns false on failure.
	bool build_reader(double start_time);

	void teardown() {
		if (reader) {
			[reader cancelReading];
		}
		reader = nil;
		video_out = nil;
		audio_out = nil;
	}
};

// Configure the NV12 video output. BT.709 8-bit per D12: NV12 is
// kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange (video-range Y'CbCr).
static AVAssetReaderTrackOutput *make_video_output(AVAssetTrack *track) {
	NSDictionary *settings = @{
		(NSString *)kCVPixelBufferPixelFormatTypeKey :
				@(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
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

bool AvfBackend::Impl::build_reader(double start_time) {
	teardown();
	error = false;

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
		AVAssetReaderTrackOutput *vo = make_video_output(video_track);
		vo.alwaysCopiesSampleData = NO; // hand out the decoder's own surface
		if ([r canAddOutput:vo]) {
			[r addOutput:vo];
			video_out = vo;
		}
	}
	if (audio_track) {
		AVAssetReaderTrackOutput *ao = make_audio_output(audio_track);
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
		}
		if (atracks.count > 0) {
			impl_->audio_track = atracks[0];
			// Pull channel count + sample rate from the format description.
			NSArray *fmts = impl_->audio_track.formatDescriptions;
			if (fmts.count > 0) {
				CMAudioFormatDescriptionRef afd =
						(__bridge CMAudioFormatDescriptionRef)fmts[0];
				const AudioStreamBasicDescription *asbd =
						CMAudioFormatDescriptionGetStreamBasicDescription(afd);
				if (asbd) {
					impl_->audio_channels = static_cast<int>(asbd->mChannelsPerFrame);
					impl_->audio_rate = static_cast<int>(asbd->mSampleRate);
				}
			}
		}

		if (!impl_->video_track && !impl_->audio_track) {
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
bool AvfBackend::had_error() const {
	return impl_ && impl_->error;
}

bool AvfBackend::seek(double pts_seconds) {
	if (!impl_ || !impl_->asset) {
		return false;
	}
	@autoreleasepool {
		if (pts_seconds < 0.0) {
			pts_seconds = 0.0;
		}
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
			// Clean EOS unless the reader reported a failure.
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
		frame.pixel_format = core::PixelFormat::NV12;

		// Move the owner into the release closure; when the consumer calls
		// release() the buffer is dropped exactly once. shared_ptr lets the
		// std::function (copyable) hold the move-only owner.
		auto owner_holder = std::make_shared<PixelBufferRef>(std::move(owner));
		frame.release = [owner_holder]() mutable { owner_holder->reset(); };

		CFRelease(sample);
		return frame;
	}
}

std::optional<core::AudioChunk> AvfBackend::next_audio_chunk() {
	if (!impl_ || !impl_->reader || !impl_->audio_out) {
		return std::nullopt;
	}

	@autoreleasepool {
		CMSampleBufferRef sample = [impl_->audio_out copyNextSampleBuffer];
		if (!sample) {
			if (impl_->reader.status == AVAssetReaderStatusFailed) {
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
