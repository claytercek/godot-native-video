const std = @import("std");
const builtin = @import("builtin");
const paths = @import("paths");
const Io = std.Io;
const testing = std.testing;

const Run = struct {
    term: std.process.Child.Term,
    stderr: []const u8,
    engine_stdout: []const u8,
    engine_stderr: []const u8,
    engine_log: []const u8,
};

fn runCli(allocator: std.mem.Allocator, dir: Io.Dir, mode: []const u8, marker: []const u8) !Run {
    const log = try Io.Dir.path.join(allocator, &.{
        try dir.realPathFileAlloc(testing.io, ".", allocator), "test run.log",
    });
    const run = try std.process.run(allocator, testing.io, .{
        .argv = &.{
            paths.runner, "--godot", paths.engine, "--project", ".",         "--driver", "vulkan",
            "--log",      log,       "--marker",   marker,      "--timeout", "2",        "--",
            mode,
        },
        .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(20) } },
    });
    return .{
        .term = run.term,
        .stderr = run.stderr,
        .engine_stdout = try dir.readFileAlloc(testing.io, "test run.log.stdout.log", allocator, .limited(4096)),
        .engine_stderr = try dir.readFileAlloc(testing.io, "test run.log.stderr.log", allocator, .limited(4096)),
        .engine_log = try dir.readFileAlloc(testing.io, "test run.log", allocator, .limited(4096)),
    };
}

test "the CLI rejects native diagnostics absent from the engine log" {
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const run = try runCli(arena.allocator(), temp.dir, "diagnostic", "SMOKE: PASS");
    try testing.expectEqual(std.process.Child.Term{ .exited = 1 }, run.term);
    try testing.expect(std.mem.find(u8, run.stderr, "loader: undefined symbol: native_init") != null);
    try testing.expect(std.mem.endsWith(u8, run.engine_log, "SMOKE: PASS\n"));
    try testing.expectEqualStrings("loader: undefined symbol: native_init\n", run.engine_stderr);
    const stdout_error = try runCli(arena.allocator(), temp.dir, "stdout-error", "SMOKE: PASS");
    try testing.expectEqual(std.process.Child.Term{ .exited = 1 }, stdout_error.term);
    try testing.expect(std.mem.find(u8, stdout_error.stderr, "ERROR: native startup failed") != null);
}

test "the CLI rejects a nonzero engine exit despite valid output" {
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const run = try runCli(arena.allocator(), temp.dir, "nonzero", "SMOKE: PASS");
    try testing.expectEqual(std.process.Child.Term{ .exited = 1 }, run.term);
    try testing.expect(std.mem.find(u8, run.stderr, "Godot exited with code 17") != null);
    try testing.expect(std.mem.endsWith(u8, run.engine_log, "SMOKE: PASS\n"));
}

test "the CLI accepts exact smoke and detailed transport markers" {
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const smoke = try runCli(arena.allocator(), temp.dir, "file-only", "SMOKE: PASS");
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, smoke.term);
    const transport = try runCli(arena.allocator(), temp.dir, "transport", "LINUX_TRANSPORT_PASS");
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, transport.term);
    const details = try runCli(arena.allocator(), temp.dir, "smoke-details", "SMOKE: PASS");
    try testing.expectEqual(std.process.Child.Term{ .exited = 1 }, details.term);
    try testing.expect(std.mem.find(u8, details.stderr, "Missing success marker: SMOKE: PASS") != null);
}

test "the CLI grants the full timeout and reaps a timed-out engine" {
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const start = Io.Clock.Timestamp.now(testing.io, .awake);
    const run = try runCli(arena.allocator(), temp.dir, "hang", "SMOKE: PASS");
    const elapsed = start.durationTo(Io.Clock.Timestamp.now(testing.io, .awake)).raw;
    try testing.expectEqual(std.process.Child.Term{ .exited = 1 }, run.term);
    try testing.expect(std.mem.find(u8, run.stderr, "VALIDATION_TIMEOUT: Godot exceeded its 2s deadline") != null);
    try testing.expect(elapsed.nanoseconds >= 2 * std.time.ns_per_s);

    var lines = std.mem.splitScalar(u8, run.engine_stdout, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "PID: ")) continue;
        const pid = try std.fmt.parseInt(u32, line["PID: ".len..], 10);
        try expectProcessGone(pid);
        return;
    }
    return error.MissingEnginePid;
}

fn expectProcessGone(pid: u32) !void {
    if (builtin.os.tag == .windows) {
        const w = std.os.windows;
        const win = struct {
            extern "kernel32" fn OpenProcess(u32, w.BOOL, u32) callconv(.winapi) ?w.HANDLE;
            extern "kernel32" fn GetLastError() callconv(.winapi) w.Win32Error;
        };
        if (win.OpenProcess(0x00100000, .FALSE, pid)) |process| {
            defer w.CloseHandle(process);
            try testing.expectEqual(w.NTSTATUS.WAIT_0, w.ntdll.NtWaitForSingleObject(process, .FALSE, &0));
        } else try testing.expectEqual(w.Win32Error.INVALID_PARAMETER, win.GetLastError());
    } else {
        const result = std.posix.system.kill(@intCast(pid), @fromBackingInt(@intCast(0)));
        try testing.expectEqual(std.posix.E.SRCH, std.posix.errno(result));
    }
}
