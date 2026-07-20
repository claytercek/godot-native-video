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
} nv_avf_audio_chunk;

// --- Lifecycle ---
nv_avf_backend *nv_avf_create(void);
void nv_avf_destroy(nv_avf_backend *h);

// Open the asset, resolve tracks, parse negotiated colorimetry, and
// enumerate audio tracks. Does NOT build a reader — the caller drives that
// with nv_avf_build_reader so track selection stays a Zig-side decision.
// Returns NV_AVF_OK (info filled) or NV_AVF_NONE (info zeroed) — never
// NV_AVF_FAIL. A media with neither a video nor any audio track counts as
// NV_AVF_NONE.
nv_avf_result nv_avf_open(nv_avf_backend *h, const char *url_or_path, nv_avf_open_info *info);

// Release all reader/asset/track state and free shim-owned strings + scratch.
// Safe to call repeatedly.
void nv_avf_close(nv_avf_backend *h);

// Per-track metadata. Returns 1 and fills *out for a valid index, else 0.
int nv_avf_get_audio_track_info(nv_avf_backend *h, int index, nv_avf_audio_track_info *out);

// --- Reader construction ---
// Build the combined reader from `start_time` seconds. `audio_track_index`
// selects which audio track to include; < 0 omits audio. Returns NV_AVF_OK
// on success, NV_AVF_FAIL on hard failure (reader create/start failed) —
// never NV_AVF_NONE.
nv_avf_result nv_avf_build_reader(nv_avf_backend *h, double start_time, int audio_track_index);

// Build a dedicated audio-only reader for `track_index` from `start_time`.
// Returns NV_AVF_OK on success, NV_AVF_NONE on soft failure (bad index /
// output rejected), NV_AVF_FAIL on hard failure (reader create/start
// failed).
nv_avf_result nv_avf_build_audio_reader(nv_avf_backend *h, int track_index, double start_time);

// Build a video-only reader from `start_time`, tearing down only the combined
// reader (leaves any audio-only reader intact). Returns NV_AVF_OK on
// success, NV_AVF_NONE on soft failure (no video / output rejected),
// NV_AVF_FAIL on hard failure.
nv_avf_result nv_avf_build_video_reader(nv_avf_backend *h, double start_time);

// Tear down the dedicated audio-only reader (no-op if none).
void nv_avf_teardown_audio_reader(nv_avf_backend *h);

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
