//! Standalone MF decode harness — pumps the backend without Godot to isolate
//! decode-side lifetime bugs from the import/present path. Windows analog of
//! src/avf/decode_smoke.zig.
const std = @import("std");
const mf = @import("mf_backend.zig");
const core = @import("core").backend;

fn matrixName(m: core.ColorMatrix) []const u8 {
    return switch (m) {
        .unspecified => "unspecified",
        .bt709 => "bt709",
        .bt601 => "bt601",
        .bt2020 => "bt2020",
    };
}
fn transferName(t: core.TransferFunction) []const u8 {
    return switch (t) {
        .unspecified => "unspecified",
        .bt709 => "bt709",
        .pq => "pq",
        .hlg => "hlg",
    };
}
fn rangeName(r: core.ColorRange) []const u8 {
    return switch (r) {
        .unspecified => "unspecified",
        .video => "video",
        .full => "full",
    };
}
fn pixfmtName(f: core.PixelFormat) []const u8 {
    return switch (f) {
        .unknown => "unknown",
        .nv12 => "nv12",
        .x420 => "x420(P010)",
        .bgra8 => "bgra8",
    };
}

pub fn main(init: std.process.Init) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const path = if (args.len >= 2) args[1] else return error.MissingPath;

    const backend = try mf.create(allocator);
    defer backend.deinit();

    if (!backend.open(path)) return error.OpenFailed;

    const color = backend.colorimetry();
    std.debug.print(
        "open ok: {d}x{d} {d:.2}s | color: matrix={s} transfer={s} range={s} bit_depth={d}\n",
        .{
            backend.videoWidth(),          backend.videoHeight(),
            backend.durationSeconds(),     matrixName(color.matrix),
            transferName(color.transfer),  rangeName(color.range),
            color.bit_depth,
        },
    );

    const track_count = backend.audioTrackCount();
    std.debug.print("audio: {d} track(s), selected ch={d} rate={d}\n", .{
        track_count, backend.audioChannelCount(), backend.audioSampleRate(),
    });
    var ti: i32 = 0;
    while (ti < track_count) : (ti += 1) {
        const info = backend.audioTrackInfo(ti);
        std.debug.print("  track {d}: lang=\"{s}\" name=\"{s}\" ch={d} rate={d} default={}\n", .{
            ti, info.language, info.name, info.channels, info.sample_rate, info.is_default,
        });
    }

    // Three passes with seeks between, mirroring scrub behavior.
    for (0..3) |pass| {
        if (!backend.seek(0.0)) return error.SeekFailed;
        var frames: usize = 0;
        var chunks: usize = 0;
        var first_pts: f64 = -1.0;
        var last_pts: f64 = 0.0;
        var pixfmt: core.PixelFormat = .unknown;
        while (backend.nextVideoFrame()) |frame| {
            if (frames == 0) {
                first_pts = frame.pts_seconds;
                pixfmt = frame.pixel_format;
            }
            last_pts = frame.pts_seconds;
            frames += 1;
            frame.release();
        }
        while (backend.nextAudioChunk()) |_| {
            chunks += 1;
        }
        std.debug.print(
            "pass {d}: {d} video frames [{s}] pts {d:.3}..{d:.3}, {d} audio chunks\n",
            .{ pass, frames, pixfmtName(pixfmt), first_pts, last_pts, chunks },
        );
        if (frames == 0) return error.NoFrames;
    }
    backend.close();
    std.debug.print("DECODE_SMOKE_PASS\n", .{});
}
