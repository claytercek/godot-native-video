// -----------------------------------------------------------------------
// avf_shim.h — pure C ABI over the AVFoundation decode object graph.
//
// The shim (avf_shim.m, compiled with -fobjc-arc) owns ALL AVFoundation /
// Objective-C state: the AVURLAsset, the combined AVAssetReader with its
// per-track outputs, the dedicated audio-only reader used for mid-decode
// track reselect, track enumeration, colorimetry extraction, and sample
// pumping. It exposes nothing but this header's opaque handle and C
// functions (prefix `nv_avf_`). All policy — the state machine, retries,
// EOS/error interpretation, clamping, track bookkeeping — lives in the Zig
// backend (avf_backend.zig), which mirrors these declarations by hand.
//
// Enum values below are chosen to match core::/backend.zig numeric tags so
// the Zig side can @enumFromInt directly.
// -----------------------------------------------------------------------
#ifndef NV_AVF_SHIM_H
#define NV_AVF_SHIM_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// --- Colorimetry tag values (mirror backend.zig enums) ---
enum {
	NV_AVF_MATRIX_UNSPECIFIED = 0,
	NV_AVF_MATRIX_BT709 = 1,
	NV_AVF_MATRIX_BT601 = 2,
	NV_AVF_MATRIX_BT2020 = 3,
};
enum {
	NV_AVF_PRIM_UNSPECIFIED = 0,
	NV_AVF_PRIM_BT709 = 1,
	NV_AVF_PRIM_BT601_625 = 2,
	NV_AVF_PRIM_BT601_525 = 3,
	NV_AVF_PRIM_BT2020 = 4,
	NV_AVF_PRIM_DCI_P3 = 5,
};
enum {
	NV_AVF_TRANSFER_UNSPECIFIED = 0,
	NV_AVF_TRANSFER_BT709 = 1,
	NV_AVF_TRANSFER_PQ = 2,
	NV_AVF_TRANSFER_HLG = 3,
};
enum {
	NV_AVF_RANGE_UNSPECIFIED = 0,
	NV_AVF_RANGE_VIDEO = 1,
	NV_AVF_RANGE_FULL = 2,
};
enum {
	NV_AVF_PIXFMT_UNKNOWN = 0,
	NV_AVF_PIXFMT_NV12 = 1,
	NV_AVF_PIXFMT_X420 = 2,
	NV_AVF_PIXFMT_BGRA8 = 3,
};

// Tri-state result code shared by every shim entry point that can fail.
// FAIL is always a hard failure (state torn back down); OK is always
// success; NONE is a soft/clean outcome whose meaning is call-site specific
// (e.g. end-of-stream, or "no matching track") — see each function's doc
// comment for which of the three it actually returns.
typedef enum {
	NV_AVF_FAIL = -1,
	NV_AVF_NONE = 0,
	NV_AVF_OK = 1,
} nv_avf_result;

// Opaque backend handle. Created by nv_avf_create, freed by nv_avf_destroy.
typedef struct nv_avf_backend nv_avf_backend;

typedef struct {
	int matrix; // NV_AVF_MATRIX_*
	int primaries; // NV_AVF_PRIM_*
	int transfer; // NV_AVF_TRANSFER_*
	int range; // NV_AVF_RANGE_*
	int bit_depth; // 8 or 10
} nv_avf_colorimetry;

typedef struct {
	double duration_seconds;
	int width; // display width (preferred transform applied)
	int height;
	int has_video; // 1 if a video track was resolved
	int audio_track_count;
	nv_avf_colorimetry color; // negotiated stream colorimetry
} nv_avf_open_info;

typedef struct {
	// BCP 47 / ISO 639-2 language tag, NUL-terminated. Shim-owned storage,
	// valid until nv_avf_close / nv_avf_destroy. Never NULL; "" when absent.
	const char *language;
	int channels;
	int sample_rate;
	int is_default; // 1 for the container-default track
} nv_avf_audio_track_info;

typedef struct {
	// CVPixelBufferRef carrying a +1 retain. The caller owns it and MUST
	// hand it to nv_avf_frame_release exactly once.
	void *pixel_buffer;
	double pts_seconds;
	int width;
	int height;
	int pixel_format; // NV_AVF_PIXFMT_*
	nv_avf_colorimetry color; // per-frame, from CVImageBuffer attachments
} nv_avf_video_frame;

typedef struct {
	// Interleaved float32 PCM, channel-major. Shim-owned scratch; valid until
	// the next nv_avf_next_audio_chunk / nv_avf_close / nv_avf_destroy.
	const float *samples;
	double pts_seconds;
	int frame_count; // per-channel sample count
	int float_count; // total float elements in `samples`
	// Actual delivered format, read off this sample buffer's own format
	// description (not the track's pre-negotiation native descriptor from
	// nv_avf_audio_track_info). 0 if the format description was unavailable
	// for this buffer. Diagnostic: lets the Zig side confirm whether what
	// AVFoundation actually hands back matches what was declared at open.
	int channels;
	int sample_rate;
} nv_avf_audio_chunk;

// Actual sizes and per-field offsets of the five structs above, as this
// translation unit's compiler laid them out. avf_backend.zig hand-mirrors
// these as extern structs (no @cImport by project convention); nothing
// short of a runtime probe catches one side's field order or size drifting
// from the other. Filled by nv_avf_abi_probe_fill and compared field-by-field
// against @sizeOf/@offsetOf on the Zig side, so a reorder of same-size
// fields (which leaves sizeof unchanged) is caught too.
typedef struct {
	size_t sizeof_colorimetry;
	size_t off_colorimetry[5]; // matrix, primaries, transfer, range, bit_depth

	size_t sizeof_open_info;
	size_t off_open_info[6]; // duration_seconds, width, height, has_video, audio_track_count, color

	size_t sizeof_audio_track_info;
	size_t off_audio_track_info[4]; // language, channels, sample_rate, is_default

	size_t sizeof_video_frame;
	size_t off_video_frame[6]; // pixel_buffer, pts_seconds, width, height, pixel_format, color

	size_t sizeof_audio_chunk;
	size_t off_audio_chunk[6]; // samples, pts_seconds, frame_count, float_count, channels, sample_rate
} nv_avf_abi_probe;

void nv_avf_abi_probe_fill(nv_avf_abi_probe *out);

// --- Lifecycle ---
nv_avf_backend *nv_avf_create(void);
void nv_avf_destroy(nv_avf_backend *h);

// Open the asset, resolve tracks, parse negotiated colorimetry, and
// enumerate audio tracks. Does NOT build a reader — the caller drives that
// with nv_avf_build_reader so track selection stays a Zig-side decision.
// Assumes `h` is already closed (a fresh handle, or one that's been through
// nv_avf_close); calling this on an already-open handle leaks the prior
// asset's track table instead of replacing it. Returns NV_AVF_OK (info
// filled) or NV_AVF_NONE (info zeroed) — never NV_AVF_FAIL. A media with
// neither a video nor any audio track counts as NV_AVF_NONE.
nv_avf_result nv_avf_open(nv_avf_backend *h, const char *url_or_path, nv_avf_open_info *info);

// Release all reader/asset/track state and free shim-owned strings + scratch.
// Safe to call repeatedly.
void nv_avf_close(nv_avf_backend *h);

// Per-track metadata. Returns 1 and fills *out for a valid index, else 0.
int nv_avf_get_audio_track_info(nv_avf_backend *h, int index, nv_avf_audio_track_info *out);

// --- Reader construction ---
// Build the combined reader from `start_time` seconds. `audio_track_index`
// selects which audio track to include; < 0 omits audio. Returns NV_AVF_OK
// on success, NV_AVF_NONE when a requested output cannot be attached, and
// NV_AVF_FAIL on hard failure (reader create/start failed).
nv_avf_result nv_avf_build_reader(nv_avf_backend *h, double start_time, int audio_track_index);

// Atomically reselect the audio track mid-decode: build a dedicated
// audio-only reader for `track_index`, then, when video exists, rebuild the
// combined reader as video-only from `start_time` so video resumes near the
// requested position instead of repeating from the clip start. Rolls the
// audio-only reader back if video construction fails, so the caller never
// observes a half-applied reselect. Returns NV_AVF_OK on success, NV_AVF_NONE
// on soft failure (bad track index / an output rejected), NV_AVF_FAIL on hard
// failure (reader create/start failed).
nv_avf_result nv_avf_reselect_audio_track(nv_avf_backend *h, int track_index, double start_time);

// --- Decode pump ---
// Returns NV_AVF_OK with *out filled, NV_AVF_NONE on clean end-of-stream,
// NV_AVF_FAIL on decode error.
nv_avf_result nv_avf_next_video_frame(nv_avf_backend *h, nv_avf_video_frame *out);

// Reads from the audio-only reader when active, else the combined reader's
// audio output. Returns NV_AVF_OK with *out filled, NV_AVF_NONE on clean
// EOS, NV_AVF_FAIL on error.
nv_avf_result nv_avf_next_audio_chunk(nv_avf_backend *h, nv_avf_audio_chunk *out);

// Release a CVPixelBufferRef handed out by nv_avf_next_video_frame.
void nv_avf_frame_release(void *pixel_buffer);

#ifdef __cplusplus
}
#endif

#endif // NV_AVF_SHIM_H
