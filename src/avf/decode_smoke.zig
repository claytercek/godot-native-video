//! Standalone AVF decode harness — pumps the backend without Godot to isolate
//! decode-side lifetime bugs from the import/present path.
const std = @import("std");
const avf = @import("avf_backend.zig");

pub fn main(init: std.process.Init) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const path = if (args.len >= 2) args[1] else return error.MissingPath;

    const backend = try avf.create(allocator);
    defer backend.deinit();

    if (!backend.open(path)) return error.OpenFailed;
    std.debug.print("open ok: {d}x{d} {d:.2}s audio_ch={d}\n", .{
        backend.videoWidth(),
        backend.videoHeight(),
        backend.durationSeconds(),
        backend.audioChannelCount(),
    });

    // Three passes with seeks between, mirroring scrub behavior.
    for (0..3) |pass| {
        if (!backend.seek(0.0)) return error.SeekFailed;
        var frames: usize = 0;
        var chunks: usize = 0;
        while (backend.nextVideoFrame()) |frame| {
            frames += 1;
            frame.release();
        }
        while (backend.nextAudioChunk()) |_| {
            chunks += 1;
        }
        std.debug.print("pass {d}: {d} video frames, {d} audio chunks\n", .{ pass, frames, chunks });
        if (frames == 0) return error.NoFrames;
    }
    backend.close();
    std.debug.print("DECODE_SMOKE_PASS\n", .{});
}
