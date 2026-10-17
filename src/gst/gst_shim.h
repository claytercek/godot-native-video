#ifndef NV_GST_SHIM_H
#define NV_GST_SHIM_H
#include <stddef.h>
#include <stdint.h>

/* C owns framework objects; Zig owns policy and retained frame copies.
 * Input is local regular media files only (including regular-file symlinks).
 * Discovery/state waits and sample pulls have finite deadlines; synchronous
 * native state transitions/teardown still depend on GStreamer plugins and
 * drivers returning. No unsafe timeout-abandon thread is used. Error strings
 * belong to the discovery/reader until its next operation or destruction. */
typedef struct nv_gst_asset nv_gst_asset;
typedef struct nv_gst_reader nv_gst_reader;
typedef struct { int matrix, primaries, transfer, range, bit_depth; } nv_gst_color;
typedef struct {
    double duration;
    int width, height, audio_count, ten_bit;
    nv_gst_color color;
} nv_gst_info;
typedef struct {
    const char *language, *name;
    int channels, rate, is_default;
} nv_gst_track;
typedef struct {
    const uint8_t *planes[2];
    ptrdiff_t strides[2];
    int width, height, format;
    int crop_x, crop_y, crop_width, crop_height;
    double pts;
    nv_gst_color color;
} nv_gst_video;
typedef struct {
    const float *samples;
    size_t count;
    int channels, rate;
    double pts;
} nv_gst_audio;
/* Asset may be returned even on discovery failure, for error retrieval. */
nv_gst_asset *nv_gst_discover(const char *path);
int nv_gst_asset_info(nv_gst_asset *, nv_gst_info *);
int nv_gst_asset_track(nv_gst_asset *, int index, nv_gst_track *);
const char *nv_gst_asset_error(nv_gst_asset *);
void nv_gst_asset_destroy(nv_gst_asset *);
/* sizeof followed by every offsetof, for color/info/track/video/audio. */
const size_t *nv_gst_abi_layout(void);
/* video != 0 builds a VIDEO ONLY pipeline, otherwise AUDIO ONLY.
 * Explicit track index and output caps. NULL on allocation/init failure. */
nv_gst_reader *nv_gst_reader_create(nv_gst_asset *, int video, int track);
int nv_gst_reader_ready(nv_gst_reader *);
int nv_gst_reader_video_info(nv_gst_reader *, nv_gst_info *);
int nv_gst_reader_seek(nv_gst_reader *, double seconds);
/* 1 sample, 0 genuine appsink EOS, -1 terminal failure (including timeout).
 * Mapped sample remains valid until unmap or reader destruction. */
int nv_gst_reader_video(nv_gst_reader *, nv_gst_video *);
int nv_gst_reader_audio(nv_gst_reader *, nv_gst_audio *);
void nv_gst_reader_unmap(nv_gst_reader *);
const char *nv_gst_reader_error(nv_gst_reader *);
void nv_gst_reader_destroy(nv_gst_reader *);
#endif
