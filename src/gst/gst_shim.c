#include "gst_shim.h"
#include <gst/gst.h>
#include <gst/app/gstappsink.h>
#include <gst/video/video.h>
#include <gst/audio/audio.h>
#include <gst/pbutils/pbutils.h>
#include <math.h>
#include <string.h>
#include <glib/gstdio.h>
#include <sys/stat.h>

#define DEADLINE (10 * GST_SECOND)
const size_t *nv_gst_abi_layout(void) {
#define OFF(T, F) offsetof(T, F)
    static const size_t layout[] = {
        sizeof(nv_gst_color), OFF(nv_gst_color,matrix), OFF(nv_gst_color,primaries), OFF(nv_gst_color,transfer), OFF(nv_gst_color,range), OFF(nv_gst_color,bit_depth),
        sizeof(nv_gst_info), OFF(nv_gst_info,duration), OFF(nv_gst_info,width), OFF(nv_gst_info,height), OFF(nv_gst_info,audio_count), OFF(nv_gst_info,ten_bit), OFF(nv_gst_info,color),
        sizeof(nv_gst_track), OFF(nv_gst_track,language), OFF(nv_gst_track,name), OFF(nv_gst_track,channels), OFF(nv_gst_track,rate), OFF(nv_gst_track,is_default),
        sizeof(nv_gst_video), OFF(nv_gst_video,planes), OFF(nv_gst_video,strides), OFF(nv_gst_video,width), OFF(nv_gst_video,height), OFF(nv_gst_video,format), OFF(nv_gst_video,crop_x), OFF(nv_gst_video,crop_y), OFF(nv_gst_video,crop_width), OFF(nv_gst_video,crop_height), OFF(nv_gst_video,pts), OFF(nv_gst_video,color),
        sizeof(nv_gst_audio), OFF(nv_gst_audio,samples), OFF(nv_gst_audio,count), OFF(nv_gst_audio,channels), OFF(nv_gst_audio,rate), OFF(nv_gst_audio,pts),
    };
#undef OFF
    return layout;
}
struct nv_gst_asset {
    gchar *uri, *error;
    GstDiscovererInfo *info;
    GList *audio;
    gboolean *defaults;
    const gchar *video_id;
    nv_gst_info public_info;
};
struct nv_gst_reader {
    GstElement *pipeline;
    GstAppSink *sink;
    gchar *error;
    GstSample *sample;
    GstVideoFrame video;
    GstMapInfo audio;
    GstBuffer *audio_buffer;
    gboolean video_mapped, audio_mapped, terminal, ready, video_only;
};
static void set_error(gchar **dest, const char *message) {
    g_free(*dest);
    *dest = g_strdup(message ? message : "unknown GStreamer failure");
}
static nv_gst_color color_from_info(const GstVideoInfo *info) {
    const GstVideoColorimetry *c = &info->colorimetry;
    nv_gst_color out = {0,0,0,0, GST_VIDEO_INFO_COMP_DEPTH(info, 0)};
    switch (c->matrix) {
    case GST_VIDEO_COLOR_MATRIX_BT709: out.matrix = 1; break;
    case GST_VIDEO_COLOR_MATRIX_BT601: out.matrix = 2; break;
    case GST_VIDEO_COLOR_MATRIX_BT2020: out.matrix = 3; break;
    default: break;
    }
    switch (c->primaries) {
    case GST_VIDEO_COLOR_PRIMARIES_BT709: out.primaries = 1; break;
    case GST_VIDEO_COLOR_PRIMARIES_BT470BG: out.primaries = 2; break;
    case GST_VIDEO_COLOR_PRIMARIES_SMPTE170M: out.primaries = 3; break;
    case GST_VIDEO_COLOR_PRIMARIES_BT2020: out.primaries = 4; break;
    case GST_VIDEO_COLOR_PRIMARIES_SMPTEEG432: out.primaries = 5; break;
    default: break;
    }
    switch (c->transfer) {
    case GST_VIDEO_TRANSFER_BT709: case GST_VIDEO_TRANSFER_BT601:
    case GST_VIDEO_TRANSFER_SRGB: case GST_VIDEO_TRANSFER_BT2020_10:
    case GST_VIDEO_TRANSFER_BT2020_12: out.transfer = 1; break;
    case GST_VIDEO_TRANSFER_SMPTE2084: out.transfer = 2; break;
    case GST_VIDEO_TRANSFER_ARIB_STD_B67: out.transfer = 3; break;
    default: break;
    }
    if (c->range == GST_VIDEO_COLOR_RANGE_16_235) out.range = 1;
    if (c->range == GST_VIDEO_COLOR_RANGE_0_255) out.range = 2;
    return out;
}
typedef struct { nv_gst_asset *asset; GstElement *pipeline; gboolean got_video, failed; } Probe;
static void probe_pad_added(GstElement *decodebin, GstPad *pad, gpointer data) {
    (void)decodebin;
    Probe *p = data;
    GstCaps *caps = gst_pad_get_current_caps(pad);
    GstVideoInfo vi;
    gchar *id = gst_pad_get_stream_id(pad);
    if (caps && gst_video_info_from_caps(&vi, caps) &&
        (!p->asset->video_id || !g_strcmp0(id, p->asset->video_id))) {
        int depth = GST_VIDEO_INFO_COMP_DEPTH(&vi, 0);
        /* Native decoded raw precision, not compressed profile spelling or
         * the container's optional bit-depth field, determines upload caps. */
        if (depth <= 0 || depth > 10) p->failed = TRUE;
        else {
            p->asset->public_info.ten_bit = depth > 8;
            p->asset->public_info.color = color_from_info(&vi);
            p->got_video = TRUE;
        }
    }
    GstEvent *start = gst_pad_get_sticky_event(pad, GST_EVENT_STREAM_START, 0);
    if (start) {
        GstStreamFlags flags = GST_STREAM_FLAG_NONE;
        gst_event_parse_stream_flags(start, &flags);
        int index = 0;
        for (GList *a = p->asset->audio; a; a = a->next, ++index) {
            const char *audio_id = gst_discoverer_stream_info_get_stream_id(a->data);
            if (id && audio_id && !strcmp(id, audio_id))
                p->asset->defaults[index] = (flags & GST_STREAM_FLAG_SELECT) != 0;
        }
        gst_event_unref(start);
    }
    g_free(id);
    if (caps) gst_caps_unref(caps);
    GstElement *sink = gst_element_factory_make("fakesink", NULL);
    if (!sink) { p->failed = TRUE; return; }
    g_object_set(sink, "sync", FALSE, "async", FALSE, "enable-last-sample", FALSE, NULL);
    gst_bin_add(GST_BIN(p->pipeline), sink);
    GstPad *dest = gst_element_get_static_pad(sink, "sink");
    if (gst_pad_link(pad, dest) != GST_PAD_LINK_OK) p->failed = TRUE;
    gst_object_unref(dest);
    gst_element_sync_state_with_parent(sink);
}
static gboolean probe_raw_format(nv_gst_asset *a) {
    GstElement *pipeline = gst_pipeline_new(NULL);
    GstElement *decode = gst_element_factory_make("uridecodebin", NULL);
    if (!pipeline || !decode) {
        if (pipeline) gst_object_unref(pipeline);
        if (decode) gst_object_unref(decode);
        set_error(&a->error, "raw format probe plugins unavailable"); return FALSE;
    }
    Probe p = {a, pipeline, FALSE, FALSE};
    GstCaps *caps = gst_caps_from_string("video/x-raw(ANY);audio/x-raw(ANY);text/x-raw");
    g_object_set(decode, "uri", a->uri, "caps", caps, NULL);
    gst_caps_unref(caps);
    gst_bin_add(GST_BIN(pipeline), decode);
    g_signal_connect(decode, "pad-added", G_CALLBACK(probe_pad_added), &p);
    GstStateChangeReturn state = gst_element_set_state(pipeline, GST_STATE_PAUSED);
    if (state != GST_STATE_CHANGE_FAILURE)
        state = gst_element_get_state(pipeline, NULL, NULL, DEADLINE);
    GstBus *bus = gst_element_get_bus(pipeline);
    GstMessage *message = gst_bus_pop_filtered(bus, GST_MESSAGE_ERROR);
    gst_object_unref(bus);
    gboolean ok = state != GST_STATE_CHANGE_FAILURE && state != GST_STATE_CHANGE_ASYNC &&
        !message && !p.failed && (!a->public_info.width || p.got_video);
    if (!ok) set_error(&a->error, "native decoded precision/stream metadata probe failed or exceeded deadline");
    if (message) gst_message_unref(message);
    gst_element_set_state(pipeline, GST_STATE_NULL);
    gst_object_unref(pipeline);
    return ok;
}
nv_gst_asset *nv_gst_discover(const char *path) {
    nv_gst_asset *a = g_try_new0(nv_gst_asset, 1);
    if (!a) return NULL;
    GError *error = NULL;
    if (!gst_init_check(NULL, NULL, &error)) goto fail;
    gchar *filename = NULL;
    if (gst_uri_is_valid(path)) {
        gchar *protocol = gst_uri_get_protocol(path);
        gboolean local = protocol && g_ascii_strcasecmp(protocol, "file") == 0;
        g_free(protocol);
        if (!local) { set_error(&a->error, "only local regular media files are supported"); return a; }
        gchar *hostname = NULL;
        filename = g_filename_from_uri(path, &hostname, &error);
        if (hostname && *hostname && g_ascii_strcasecmp(hostname, "localhost")) {
            g_free(filename); filename = NULL;
        }
        g_free(hostname);
    } else filename = g_canonicalize_filename(path, NULL);
    GStatBuf statbuf;
    if (!filename || g_stat(filename, &statbuf) != 0 || !S_ISREG(statbuf.st_mode)) {
        g_free(filename); g_clear_error(&error);
        set_error(&a->error, "input must be an existing local regular file (not a FIFO, directory or device)");
        return a;
    }
    a->uri = gst_filename_to_uri(filename, &error);
    g_free(filename);
    if (!a->uri) goto fail;
    GstDiscoverer *d = gst_discoverer_new(DEADLINE, &error);
    if (!d) goto fail;
    a->info = gst_discoverer_discover_uri(d, a->uri, &error);
    g_object_unref(d);
    if (!a->info || gst_discoverer_info_get_result(a->info) != GST_DISCOVERER_OK) goto fail;
    a->public_info.duration = GST_CLOCK_TIME_IS_VALID(gst_discoverer_info_get_duration(a->info))
        ? (double)gst_discoverer_info_get_duration(a->info) / GST_SECOND : 0;
    a->public_info.color = (nv_gst_color){1,1,1,1,8};
    a->audio = gst_discoverer_info_get_audio_streams(a->info);
    a->public_info.audio_count = g_list_length(a->audio);
    a->defaults = g_new0(gboolean, a->public_info.audio_count);
    GList *videos = gst_discoverer_info_get_video_streams(a->info);
    if (videos) {
        GstDiscovererVideoInfo *v = videos->data;
        a->public_info.width = gst_discoverer_video_info_get_width(v);
        a->public_info.height = gst_discoverer_video_info_get_height(v);
        a->video_id = gst_discoverer_stream_info_get_stream_id(GST_DISCOVERER_STREAM_INFO(v));
    }
    gst_discoverer_stream_info_list_free(videos);
    if (!a->public_info.width && !a->public_info.audio_count) {
        set_error(&a->error, "no decodable audio/video streams");
        return a;
    }
    probe_raw_format(a);
    return a;
fail:
    set_error(&a->error, error ? error->message : "media discovery failed or codecs unavailable");
    g_clear_error(&error);
    return a;
}
int nv_gst_asset_info(nv_gst_asset *a, nv_gst_info *out) {
    if (!a || a->error) return 0;
    *out = a->public_info;
    return 1;
}
int nv_gst_asset_track(nv_gst_asset *a, int index, nv_gst_track *out) {
    if (index < 0) return 0;
    GstDiscovererAudioInfo *ai = g_list_nth_data(a->audio, index);
    if (!ai) return 0;
    memset(out, 0, sizeof(*out));
    out->language = gst_discoverer_audio_info_get_language(ai);
    const GstTagList *tags = gst_discoverer_stream_info_get_tags(GST_DISCOVERER_STREAM_INFO(ai));
    const GValue *title = tags ? gst_tag_list_get_value_index(tags, GST_TAG_TITLE, 0) : NULL;
    out->name = title && G_VALUE_HOLDS_STRING(title) ? g_value_get_string(title) : "";
    out->channels = gst_discoverer_audio_info_get_channels(ai);
    out->rate = gst_discoverer_audio_info_get_sample_rate(ai);
    out->is_default = a->defaults[index];
    return 1;
}
const char *nv_gst_asset_error(nv_gst_asset *a) { return a ? a->error : "allocation failure"; }
void nv_gst_asset_destroy(nv_gst_asset *a) {
    if (!a) return;
    gst_discoverer_stream_info_list_free(a->audio);
    if (a->info) gst_discoverer_info_unref(a->info);
    g_free(a->defaults); g_free(a->uri); g_free(a->error); g_free(a);
}
static gboolean bus_error(nv_gst_reader *r) {
    GstBus *bus = gst_element_get_bus(r->pipeline);
    GstMessage *message = gst_bus_pop_filtered(bus, GST_MESSAGE_ERROR);
    gst_object_unref(bus);
    if (!message) return FALSE;
    GError *error = NULL; gchar *debug = NULL;
    gst_message_parse_error(message, &error, &debug);
    set_error(&r->error, error ? error->message : "pipeline error");
    g_clear_error(&error); g_free(debug); gst_message_unref(message);
    r->terminal = TRUE;
    return TRUE;
}
static gboolean autoplug_continue(GstElement *decodebin, GstPad *pad, GstCaps *caps, gpointer data) {
    (void)decodebin; (void)pad;
    nv_gst_reader *r = data;
    if (!caps || gst_caps_is_empty(caps)) return TRUE;
    const char *type = gst_structure_get_name(gst_caps_get_structure(caps, 0));
    /* Expose the unused encoded stream without constructing its decoder.
     * Playbin's disabled stream flag discards that output. */
    if (r->video_only && g_str_has_prefix(type, "audio/")) return FALSE;
    /* video/quicktime and video/mpegts are containers, not video elementary
     * streams: audio-only graphs must still demux those. */
    if (!r->video_only && (g_str_equal(type, "video/x-h264") || g_str_equal(type, "video/x-h265") ||
        g_str_equal(type, "video/x-raw") || g_str_has_prefix(type, "image/"))) return FALSE;
    return TRUE;
}
static void decoder_added(GstBin *bin, GstBin *sub, GstElement *element, gpointer data) {
    (void)bin; (void)sub;
    if (g_signal_lookup("autoplug-continue", G_OBJECT_TYPE(element)))
        g_signal_connect(element, "autoplug-continue", G_CALLBACK(autoplug_continue), data);
    GstElementFactory *f = gst_element_get_factory(element);
    const char *klass = f ? gst_element_factory_get_metadata(f, GST_ELEMENT_METADATA_KLASS) : NULL;
    if (klass && strstr(klass, "Codec/Decoder"))
        g_printerr("[gst_backend] actual decoder: %s (%s)\n", gst_plugin_feature_get_name(GST_PLUGIN_FEATURE(f)), klass);
}
static gboolean wait_ready(nv_gst_reader *r) {
    GstStateChangeReturn result = gst_element_get_state(r->pipeline, NULL, NULL, DEADLINE);
    if (bus_error(r)) return FALSE;
    if (result == GST_STATE_CHANGE_FAILURE || result == GST_STATE_CHANGE_ASYNC) {
        set_error(&r->error, result == GST_STATE_CHANGE_ASYNC ? "pipeline preroll deadline exceeded" : "pipeline state failure");
        r->terminal = TRUE;
        return FALSE;
    }
    return TRUE;
}
nv_gst_reader *nv_gst_reader_create(nv_gst_asset *a, int video, int track) {
    nv_gst_reader *r = g_try_new0(nv_gst_reader, 1);
    if (!r) return NULL;
    r->pipeline = gst_element_factory_make("playbin", NULL);
    GstElement *sink = gst_element_factory_make("appsink", NULL);
    if (!r->pipeline || !sink) {
        if (sink) gst_object_unref(sink);
        set_error(&r->error, "playbin/appsink plugin unavailable");
        return r;
    }
    /* Keep our own sink reference; playbin's property also retains it. */
    gst_object_ref_sink(sink);
    r->sink = GST_APP_SINK(sink);
    GstCaps *caps = video ? gst_caps_new_simple("video/x-raw", "format", G_TYPE_STRING,
        a->public_info.ten_bit ? "P010_10LE" : "NV12", NULL)
        : gst_caps_from_string("audio/x-raw,format=F32LE,layout=interleaved");
    g_object_set(sink, "caps", caps, "sync", FALSE, "max-buffers", 2u,
        "drop", FALSE, "wait-on-eos", FALSE, "enable-last-sample", FALSE, NULL);
    gst_caps_unref(caps);
    r->video_only = video != 0;
    g_signal_connect(r->pipeline, "deep-element-added", G_CALLBACK(decoder_added), r);
    /* Disabling the other stream in playbin avoids its preroll/backpressure
     * altogether; these are separate source/demux/decode graphs. */
    GstElement *unused = gst_element_factory_make("fakesink", NULL);
    if (!unused) { set_error(&r->error, "fakesink plugin unavailable"); return r; }
    gst_object_ref_sink(unused);
    g_object_set(unused, "sync", FALSE, "async", FALSE, "enable-last-sample", FALSE, NULL);
    g_object_set(r->pipeline, "uri", a->uri, "flags", video ? 1u : 2u,
        video ? "video-sink" : "audio-sink", sink,
        video ? "audio-sink" : "video-sink", unused, NULL);
    gst_object_unref(unused);
    if (gst_element_set_state(r->pipeline, GST_STATE_PAUSED) == GST_STATE_CHANGE_FAILURE || !wait_ready(r)) {
        if (!r->error) set_error(&r->error, "unable to preroll reader");
        return r;
    }
    if (!video) {
        gint count = 0;
        g_object_get(r->pipeline, "n-audio", &count, NULL);
        if (track < 0 || track >= count) { set_error(&r->error, "audio track unavailable"); return r; }
        g_object_set(r->pipeline, "current-audio", track, NULL);
        if (track != 0 && !nv_gst_reader_seek(r, 0)) return r;
    }
    /* Read negotiated video metadata without consuming the first sample. */
    r->ready = TRUE;
    return r;
}
int nv_gst_reader_ready(nv_gst_reader *r) { return r && r->ready && !r->error; }
int nv_gst_reader_video_info(nv_gst_reader *r, nv_gst_info *out) {
    GstPad *pad = gst_element_get_static_pad(GST_ELEMENT(r->sink), "sink");
    GstCaps *caps = gst_pad_get_current_caps(pad);
    gst_object_unref(pad);
    GstVideoInfo info;
    gboolean ok = caps && gst_video_info_from_caps(&info, caps);
    if (caps) gst_caps_unref(caps);
    if (!ok) return 0;
    memset(out, 0, sizeof(*out));
    out->width = GST_VIDEO_INFO_WIDTH(&info); out->height = GST_VIDEO_INFO_HEIGHT(&info);
    out->color = color_from_info(&info);
    return 1;
}
int nv_gst_reader_seek(nv_gst_reader *r, double seconds) {
    if (!r || !r->pipeline || !isfinite(seconds) || seconds < 0 || seconds > (double)G_MAXINT64 / GST_SECOND) return 0;
    nv_gst_reader_unmap(r);
    if (gst_element_set_state(r->pipeline, GST_STATE_PAUSED) == GST_STATE_CHANGE_FAILURE || !wait_ready(r)) return 0;
    r->terminal = FALSE;
    g_clear_pointer(&r->error, g_free);
    if (!gst_element_seek_simple(r->pipeline, GST_FORMAT_TIME,
        GST_SEEK_FLAG_FLUSH | (r->video_only ? (GST_SEEK_FLAG_KEY_UNIT | GST_SEEK_FLAG_SNAP_BEFORE) : GST_SEEK_FLAG_ACCURATE),
        (gint64)(seconds * GST_SECOND))) {
        set_error(&r->error, "keyframe seek rejected"); r->terminal = TRUE; return 0;
    }
    return wait_ready(r);
}
void nv_gst_reader_unmap(nv_gst_reader *r) {
    if (!r) return;
    if (r->video_mapped) gst_video_frame_unmap(&r->video);
    if (r->audio_mapped) gst_buffer_unmap(r->audio_buffer, &r->audio);
    gst_clear_buffer(&r->audio_buffer);
    r->video_mapped = r->audio_mapped = FALSE;
    if (r->sample) gst_sample_unref(r->sample);
    r->sample = NULL;
}
static int pull(nv_gst_reader *r) {
    nv_gst_reader_unmap(r);
    if (r->terminal) return r->error ? -1 : 0;
    if (gst_element_set_state(r->pipeline, GST_STATE_PLAYING) == GST_STATE_CHANGE_FAILURE) {
        set_error(&r->error, "unable to start reader"); r->terminal = TRUE; return -1;
    }
    r->sample = gst_app_sink_try_pull_sample(r->sink, DEADLINE);
    if (r->sample) return 1;
    if (bus_error(r)) return -1;
    r->terminal = TRUE;
    if (gst_app_sink_is_eos(r->sink)) return 0;
    set_error(&r->error, "sample deadline exceeded (terminal decode failure, not EOS)");
    return -1;
}
static double buffer_pts(GstSample *sample, GstBuffer *buffer) {
    GstClockTime pts = GST_BUFFER_PTS(buffer);
    const GstSegment *segment = gst_sample_get_segment(sample);
    if (!GST_CLOCK_TIME_IS_VALID(pts)) return -1;
    /* Container PTS may include decode/reorder or MP4 edit-list offsets.
     * Backend timestamps are media stream time, never raw buffer time. */
    if (segment && segment->format == GST_FORMAT_TIME)
        pts = gst_segment_to_stream_time(segment, GST_FORMAT_TIME, pts);
    return GST_CLOCK_TIME_IS_VALID(pts) ? (double)pts / GST_SECOND : -1;
}
int nv_gst_reader_video(nv_gst_reader *r, nv_gst_video *out) {
    int result = pull(r);
    if (result != 1) return result;
    GstVideoInfo info;
    if (!gst_video_info_from_caps(&info, gst_sample_get_caps(r->sample)) ||
        (GST_VIDEO_INFO_FORMAT(&info) != GST_VIDEO_FORMAT_NV12 && GST_VIDEO_INFO_FORMAT(&info) != GST_VIDEO_FORMAT_P010_10LE) ||
        !gst_video_frame_map(&r->video, &info, gst_sample_get_buffer(r->sample), GST_MAP_READ)) goto fail;
    r->video_mapped = TRUE;
    memset(out, 0, sizeof(*out));
    out->width = GST_VIDEO_INFO_WIDTH(&info); out->height = GST_VIDEO_INFO_HEIGHT(&info);
    out->format = GST_VIDEO_INFO_FORMAT(&info) == GST_VIDEO_FORMAT_NV12 ? 1 : 2;
    for (int p = 0; p < 2; ++p) {
        out->planes[p] = GST_VIDEO_FRAME_PLANE_DATA(&r->video, p);
        out->strides[p] = GST_VIDEO_FRAME_PLANE_STRIDE(&r->video, p);
    }
    GstVideoCropMeta *crop = gst_buffer_get_video_crop_meta(gst_sample_get_buffer(r->sample));
    if (crop) {
        out->crop_x = crop->x; out->crop_y = crop->y;
        out->crop_width = crop->width; out->crop_height = crop->height;
    }
    out->pts = buffer_pts(r->sample, gst_sample_get_buffer(r->sample));
    out->color = color_from_info(&info);
    if (out->pts >= 0) return 1;
fail:
    set_error(&r->error, "invalid/unmappable video sample or missing PTS"); r->terminal = TRUE; return -1;
}
int nv_gst_reader_audio(nv_gst_reader *r, nv_gst_audio *out) {
    int result = pull(r);
    if (result != 1) return result;
    GstAudioInfo info;
    if (!gst_audio_info_from_caps(&info, gst_sample_get_caps(r->sample)) ||
        GST_AUDIO_INFO_FORMAT(&info) != GST_AUDIO_FORMAT_F32LE ||
        GST_AUDIO_INFO_LAYOUT(&info) != GST_AUDIO_LAYOUT_INTERLEAVED) goto fail;
    /* Accurate seeks can yield a PCM buffer straddling the segment start.
     * Clip its memory AND timestamp at the sample boundary, rather than
     * labelling old samples with the requested new position. */
    r->audio_buffer = gst_audio_buffer_clip(gst_buffer_ref(gst_sample_get_buffer(r->sample)),
        gst_sample_get_segment(r->sample), GST_AUDIO_INFO_RATE(&info), GST_AUDIO_INFO_BPF(&info));
    if (!r->audio_buffer || !gst_buffer_map(r->audio_buffer, &r->audio, GST_MAP_READ)) goto fail;
    r->audio_mapped = TRUE;
    out->samples = (const float *)r->audio.data;
    out->count = r->audio.size / sizeof(float);
    out->channels = GST_AUDIO_INFO_CHANNELS(&info); out->rate = GST_AUDIO_INFO_RATE(&info);
    out->pts = buffer_pts(r->sample, r->audio_buffer);
    if (out->pts >= 0 && out->channels > 0 && out->rate > 0 &&
        r->audio.size % (sizeof(float) * out->channels) == 0) return 1;
fail:
    set_error(&r->error, "invalid/unmappable float32 PCM sample or missing PTS"); r->terminal = TRUE; return -1;
}
const char *nv_gst_reader_error(nv_gst_reader *r) { return r ? r->error : "reader allocation failure"; }
void nv_gst_reader_destroy(nv_gst_reader *r) {
    if (!r) return;
    nv_gst_reader_unmap(r);
    if (r->pipeline) {
        gst_element_set_state(r->pipeline, GST_STATE_NULL);
        gst_object_unref(r->pipeline);
    }
    if (r->sink) gst_object_unref(r->sink);
    g_free(r->error); g_free(r);
}
