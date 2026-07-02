#include "vendor/doctest.h"
#include "avf_backend.h"
#include <cstdio>
#include <sys/stat.h>

namespace {
bool file_exists(const std::string &p) { struct stat st; return ::stat(p.c_str(), &st) == 0; }
std::string repo_root() {
    if (const char *env = std::getenv("REPO_ROOT")) return std::string(env);
    return ".";
}
}

TEST_CASE("DEBUG reselect") {
    std::string fixture = repo_root() + "/tests/fixtures/synthetic_multitrack_avf.mp4";
    if (!file_exists(fixture)) {
        WARN("fixture not found");
        return;
    }
    
    avf::AvfBackend backend;
    REQUIRE(backend.open(fixture));
    printf("tracks=%d ch=%d rate=%d\n", 
           backend.audio_track_count(), backend.audio_channel_count(), backend.audio_sample_rate());
    
    // Print track info
    for (int i = 0; i < backend.audio_track_count(); ++i) {
        auto info = backend.audio_track_info(i);
        printf("  track %d: lang=%s ch=%d rate=%d default=%d\n",
               i, info.language.c_str(), info.channels, info.sample_rate, info.is_default);
    }
    
    // Decode 4 frames
    printf("Pre-reselect: decoding 4 frames\n");
    double last_pts = -1.0;
    for (int i = 0; i < 4; ++i) {
        auto f = backend.next_video_frame();
        if (!f) { printf("  frame %d: NULL (EOS?)\n", i); break; }
        printf("  frame %d: pts=%.3f\n", i, f->pts_seconds);
        last_pts = f->pts_seconds;
        f->release();
    }
    
    printf("Reselect to track 1 at %.3f\n", last_pts);
    bool ok = backend.reselect_audio_track(1, last_pts);
    printf("  reselect: %s  had_error=%d\n", ok?"ok":"FAIL", backend.had_error());
    
    // Try video after reselect
    printf("Post-reselect: trying next_video_frame\n");
    auto f = backend.next_video_frame();
    printf("  frame: %s  pts=%.3f\n", f.has_value()?"yes":"no", f?f->pts_seconds:-1.0);
    if (f) f->release();
    
    printf("had_error=%d\n", backend.had_error());
    CHECK_FALSE(backend.had_error());
}
