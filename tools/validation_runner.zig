const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const eql = std.mem.eql;
const startsWith = std.mem.startsWith;
const find = std.mem.find;
const findIgnoreCase = std.ascii.findIgnoreCase;

const smoke_marker = "SMOKE: PASS";
const usage = "Usage: validation-runner --godot <path> --project <path> --driver <default|vulkan|d3d12> --log <path> [--marker <text>] [--physical] [--timeout <seconds>] -- [Godot args...]\n";
const Driver = enum { default, vulkan, d3d12 };
const Options = struct {
    godot: []const u8,
    project: []const u8,
    driver: Driver,
    log: []const u8,
    marker: []const u8,
    physical: bool,
    timeout_seconds: u32,
    forwarded: []const [:0]const u8,

    fn parse(args: []const [:0]const u8) ?Options {
        var godot: ?[]const u8 = null;
        var project: ?[]const u8 = null;
        var driver: ?Driver = null;
        var log: ?[]const u8 = null;
        var marker: []const u8 = smoke_marker;
        var physical = false;
        var timeout_seconds: u32 = 75;
        var i: usize = 0;
        while (i < args.len) {
            const flag = args[i];
            i += 1;
            if (eql(u8, flag, "--")) break;
            if (eql(u8, flag, "--physical")) {
                physical = true;
                continue;
            }
            if (i == args.len or args[i].len == 0 or eql(u8, args[i], "--")) return null;
            const value = args[i];
            i += 1;
            if (eql(u8, flag, "--godot")) {
                godot = value;
            } else if (eql(u8, flag, "--project")) {
                project = value;
            } else if (eql(u8, flag, "--driver")) {
                driver = std.meta.stringToEnum(Driver, value) orelse return null;
            } else if (eql(u8, flag, "--log")) {
                log = value;
            } else if (eql(u8, flag, "--timeout")) {
                timeout_seconds = std.fmt.parseInt(u32, value, 10) catch return null;
                if (timeout_seconds == 0) return null;
            } else if (eql(u8, flag, "--marker")) {
                if (std.mem.findAny(u8, value, "\r\n") != null) return null;
                marker = value;
            } else return null;
        }
        return .{
            .godot = godot orelse return null,
            .project = project orelse return null,
            .driver = driver orelse return null,
            .log = log orelse return null,
            .marker = marker,
            .physical = physical,
            .timeout_seconds = timeout_seconds,
            .forwarded = args[i..],
        };
    }

    fn engineArgs(options: Options, arena: std.mem.Allocator, log_path: []const u8) ![]const []const u8 {
        const common = [_][]const u8{
            options.godot, "--path",         options.project, "--rendering-method", "forward_plus",
            "--verbose",   "--audio-driver", "Dummy",         "--max-fps",          "60",
            "--log-file",  log_path,
        };
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(arena, &common);
        if (options.driver != .default)
            try argv.appendSlice(arena, &.{ "--rendering-driver", @tagName(options.driver) });
        for (options.forwarded) |arg| try argv.append(arena, arg);
        return argv.items;
    }
};

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len == 2 and eql(u8, args[1], "--help")) {
        try Io.File.stdout().writeStreamingAll(init.io, usage);
        return 0;
    }
    const options = Options.parse(args[1..]) orelse {
        try Io.File.stderr().writeStreamingAll(init.io, usage);
        return 2;
    };
    return validate(init.io, arena, options) catch |err| {
        std.debug.print("VALIDATION_FAIL {s}: {t}\n", .{ options.log, err });
        return 1;
    };
}

fn validate(io: Io, arena: std.mem.Allocator, options: Options) !u8 {
    const cwd: Io.Dir = .cwd();
    const parent = Io.Dir.path.dirname(options.log) orelse ".";
    try cwd.createDirPath(io, parent);
    // Godot resolves relative log paths against the project, not our cwd.
    const log_path = try Io.Dir.path.join(arena, &.{
        try cwd.realPathFileAlloc(io, parent, arena),
        Io.Dir.path.basename(options.log),
    });
    cwd.deleteFile(io, log_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    // On Windows, redirecting both child streams to one file can give them independent offsets.
    const stdout_path = try std.fmt.allocPrint(arena, "{s}.stdout.log", .{log_path});
    const stderr_path = try std.fmt.allocPrint(arena, "{s}.stderr.log", .{log_path});
    const argv = try options.engineArgs(arena, log_path);
    std.debug.print("VALIDATION_COMMAND {s}\n", .{try std.mem.join(arena, " ", argv)});
    const outcome = run: {
        const stdout = try cwd.createFile(io, stdout_path, .{});
        defer stdout.close(io);
        const stderr = try cwd.createFile(io, stderr_path, .{});
        defer stderr.close(io);
        break :run try runGodot(io, .{
            .argv = argv,
            .stdin = .ignore,
            .stdout = .{ .file = stdout },
            .stderr = .{ .file = stderr },
            .pgid = if (builtin.os.tag == .windows) null else 0,
            .start_suspended = builtin.os.tag == .windows,
        }, options.timeout_seconds);
    };

    var failed = true;
    switch (outcome) {
        .exited => |code| if (code == 0) {
            failed = false;
        } else {
            std.debug.print("Godot exited with code {d}\n", .{code});
        },
        .signal => |sig| std.debug.print("Godot terminated with signal {t}\n", .{sig}),
        .abnormal => std.debug.print("Godot terminated unexpectedly\n", .{}),
        .timed_out => std.debug.print("VALIDATION_TIMEOUT: Godot exceeded its {d}s deadline\n", .{options.timeout_seconds}),
        .cleanup_timeout => std.debug.print("VALIDATION_TIMEOUT: Godot did not exit after forced termination\n", .{}),
    }
    var checks: Checks = .{};
    for ([_][]const u8{ log_path, stdout_path, stderr_path }) |path| {
        const text = cwd.readFileAlloc(io, path, arena, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => {
                std.debug.print("Missing validation log: {s}\n", .{path});
                failed = true;
                continue;
            },
            else => return err,
        };
        scanLog(&checks, text, options.marker, options.driver);
    }
    if (checks.reportErrors()) failed = true;
    if (!checks.marker_found) {
        failed = true;
        std.debug.print("Missing success marker: {s}\n", .{options.marker});
    }
    if (!checks.renderer_found or checks.wrong_renderer) {
        failed = true;
        std.debug.print("Expected only a {t} Forward+ device in engine output\n", .{options.driver});
    }
    if (options.physical and !checks.physicalVulkan()) {
        failed = true;
        std.debug.print("Physical Vulkan renderer was not established in engine output\n", .{});
    }
    if (failed) {
        std.debug.print("VALIDATION_FAIL {s}\n", .{options.log});
        return 1;
    }
    std.debug.print("VALIDATION_PASS {s}\n", .{options.log});
    return 0;
}

const Outcome = union(enum) {
    exited: u32,
    signal: std.posix.SIG,
    abnormal,
    timed_out,
    cleanup_timeout,
};

fn deadlineAfter(io: Io, seconds: i64) Io.Clock.Timestamp {
    return Io.Clock.Timestamp.now(io, .awake).addDuration(.{ .raw = .fromSeconds(seconds), .clock = .awake });
}

fn runGodot(io: Io, spawn_options: std.process.SpawnOptions, timeout_seconds: u32) !Outcome {
    if (builtin.os.tag == .windows) return Windows.run(io, spawn_options, timeout_seconds);
    const child = try std.process.spawn(io, spawn_options);
    const pid = child.id.?;
    const status = waitPosix(io, pid, deadlineAfter(io, timeout_seconds)) catch |err| {
        killGroup(pid);
        _ = waitPosix(io, pid, deadlineAfter(io, 2)) catch null;
        return err;
    };
    if (status) |s| {
        const W = std.posix.W;
        if (W.IFEXITED(s)) return .{ .exited = W.EXITSTATUS(s) };
        if (W.IFSIGNALED(s)) return .{ .signal = W.TERMSIG(s) };
        return .abnormal;
    }
    killGroup(pid);
    return if (try waitPosix(io, pid, deadlineAfter(io, 2)) != null) .timed_out else .cleanup_timeout;
}

fn killGroup(pid: std.posix.pid_t) void {
    std.posix.kill(-pid, .KILL) catch {};
    std.posix.kill(pid, .KILL) catch {};
}

fn waitPosix(io: Io, pid: std.posix.pid_t, deadline: Io.Clock.Timestamp) !?u32 {
    // Child.wait has no timeout, and Child.kill on POSIX sends only SIGTERM.
    while (true) {
        var status: i32 = undefined;
        const rc = std.posix.system.wait4(pid, &status, std.posix.W.NOHANG, null);
        switch (std.posix.errno(rc)) {
            .SUCCESS => if (rc != 0) return @bitCast(status),
            .INTR => {},
            else => |err| return std.posix.unexpectedErrno(err),
        }
        const remaining = deadline.durationFromNow(io).raw;
        if (remaining.nanoseconds <= 0) return null;
        try io.sleep(.fromNanoseconds(@min(remaining.nanoseconds, 20 * std.time.ns_per_ms)), .awake);
    }
}

const Windows = struct {
    const w = std.os.windows;
    extern "kernel32" fn CreateJobObjectW(?*const w.SECURITY_ATTRIBUTES, ?[*:0]const u16) callconv(.winapi) ?w.HANDLE;
    extern "kernel32" fn AssignProcessToJobObject(w.HANDLE, w.HANDLE) callconv(.winapi) w.BOOL;
    extern "kernel32" fn TerminateJobObject(w.HANDLE, u32) callconv(.winapi) w.BOOL;
    extern "kernel32" fn TerminateProcess(w.HANDLE, u32) callconv(.winapi) w.BOOL;
    extern "kernel32" fn GetExitCodeProcess(w.HANDLE, *u32) callconv(.winapi) w.BOOL;

    fn run(io: Io, spawn_options: std.process.SpawnOptions, timeout_seconds: u32) !Outcome {
        const job = CreateJobObjectW(null, null) orelse return error.CreateGodotJobFailed;
        defer w.CloseHandle(job);
        const child = try std.process.spawn(io, spawn_options);
        const process = child.id.?;
        defer w.CloseHandle(process);
        defer w.CloseHandle(child.thread_handle);
        errdefer {
            _ = TerminateProcess(process, 1);
            _ = wait(io, process, deadlineAfter(io, 2)) catch false;
        }
        // A console wrapper can start another Godot process as soon as it runs.
        if (!AssignProcessToJobObject(job, process).toBool()) return error.AssignGodotJobFailed;
        defer _ = TerminateJobObject(job, 1);
        if (w.ntdll.NtResumeThread(child.thread_handle, null) != .SUCCESS) return error.ResumeGodotFailed;
        if (try wait(io, process, deadlineAfter(io, timeout_seconds))) {
            // Child.wait truncates the Windows exit status to u8.
            var code: u32 = undefined;
            if (!GetExitCodeProcess(process, &code).toBool()) return error.GodotExitCodeUnavailable;
            return .{ .exited = code };
        }
        if (!TerminateJobObject(job, 1).toBool()) return error.TerminateGodotJobFailed;
        return if (try wait(io, process, deadlineAfter(io, 2))) .timed_out else .cleanup_timeout;
    }

    fn wait(io: Io, process: w.HANDLE, deadline: Io.Clock.Timestamp) !bool {
        const ns = deadline.durationFromNow(io).raw.nanoseconds;
        const timeout: w.LARGE_INTEGER = -@as(w.LARGE_INTEGER, @intCast(@divTrunc(@max(ns, 0), 100)));
        return switch (w.ntdll.NtWaitForSingleObject(process, .FALSE, &timeout)) {
            .WAIT_0 => true,
            .TIMEOUT => false,
            else => |status| w.unexpectedStatus(status),
        };
    }
};

const Checks = struct {
    marker_found: bool = false,
    renderer_found: bool = false,
    wrong_renderer: bool = false,
    vulkan: bool = false,
    software_vulkan: bool = false,
    error_count: usize = 0,
    errors: [20][]const u8 = undefined,

    fn physicalVulkan(checks: Checks) bool {
        return checks.vulkan and !checks.software_vulkan;
    }

    fn reportErrors(checks: Checks) bool {
        for (checks.errors[0..@min(checks.error_count, checks.errors.len)]) |line|
            std.debug.print("{s}\n", .{line});
        return checks.error_count != 0;
    }
};

fn scanLog(result: *Checks, text: []const u8, marker: []const u8, driver: Driver) void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = if (std.mem.endsWith(u8, raw, "\r")) raw[0 .. raw.len - 1] else raw;
        if (eql(u8, line, marker) or
            (!eql(u8, marker, smoke_marker) and startsWith(u8, line, marker) and line[marker.len] == ' '))
            result.marker_found = true;
        if (engineError(line)) {
            if (result.error_count < result.errors.len) result.errors[result.error_count] = line;
            result.error_count += 1;
        }
        if (find(u8, line, " - Using Device")) |device| {
            const vulkan = startsWith(u8, line, "Vulkan ");
            const metal = startsWith(u8, line, "Metal ");
            const d3d12 = startsWith(u8, line, "D3D12 ") or startsWith(u8, line, "Direct3D 12 ");
            const opengl = startsWith(u8, line, "OpenGL ");
            if (vulkan) {
                result.vulkan = true;
                if (containsAny(line, &.{ "llvmpipe", "lavapipe", "swiftshader", "software" }))
                    result.software_vulkan = true;
            }
            if (!(vulkan or metal or d3d12 or opengl)) continue;
            const matches_driver = switch (driver) {
                .default => vulkan or metal,
                .vulkan => vulkan,
                .d3d12 => d3d12,
            };
            if (matches_driver and std.mem.endsWith(u8, line[0..device], " - Forward+")) {
                result.renderer_found = true;
            } else result.wrong_renderer = true;
        }
    }
}

fn containsAny(line: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| if (findIgnoreCase(line, needle) != null) return true;
    return false;
}

fn engineError(line: []const u8) bool {
    if (containsAny(line, &.{ "undefined symbol", "error loading extension", "leaked at exit", "ObjectDB instances leaked", "segmentation fault" }))
        return true;
    if (findIgnoreCase(line, "failed to load")) |at| {
        if (containsAny(line[at + "failed to load".len ..], &.{ "gdextension", "libnative_video" })) return true;
    }
    if (findIgnoreCase(line, "memory address ")) |at| {
        const rest = line[at + "memory address ".len ..];
        if (findIgnoreCase(rest, " leaked") != null) return true;
    }
    for (line, 0..) |c, i| {
        if (i != 0 and !std.ascii.isWhitespace(line[i - 1])) continue;
        const rest = line[i..];
        if (std.ascii.toLower(c) == 'p' and std.ascii.startsWithIgnoreCase(rest, "panic:")) return true;
        if (std.ascii.toLower(c) != 'e' or !std.ascii.startsWithIgnoreCase(rest, "error")) continue;
        const suffix = rest["error".len..];
        if (startsWith(u8, suffix, ":")) return true;
        if (startsWith(u8, suffix, "(")) {
            const close = std.mem.findScalar(u8, suffix, ')') orelse continue;
            if (startsWith(u8, suffix[close + 1 ..], ":")) return true;
        }
    }
    return false;
}

test "synthetic smoke is exact and other markers can have space-separated details" {
    const test_cases = .{
        .{ "SMOKE: PASS\r\n", smoke_marker, true },
        .{ "SMOKE: PASS ticks=1", smoke_marker, false },
        .{ "SMOKE: PASSED", smoke_marker, false },
        .{ "prefix SMOKE: PASS", smoke_marker, false },
        .{ " SMOKE: PASS", smoke_marker, false },
        .{ "TEST_PASS", "TEST_PASS", true },
        .{ "TEST_PASS ticks=1\r\n", "TEST_PASS", true },
        .{ "TEST_PASSING", "TEST_PASS", false },
        .{ "prefix TEST_PASS ticks=1", "TEST_PASS", false },
        .{ "TEST_PASS\tticks=1", "TEST_PASS", false },
    };
    inline for (test_cases) |t| {
        var checks: Checks = .{};
        scanLog(&checks, t[0], t[1], .vulkan);
        try std.testing.expectEqual(t[2], checks.marker_found);
    }
}

test "only the first delimiter is consumed and default does not inject arguments" {
    const argv = &[_][:0]const u8{
        "--godot", "Godot path", "--project", "test project", "--driver", "default", "--log", "test log",
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const expected = [_][]const u8{
        "Godot path",     "--path", "test project", "--rendering-method", "forward_plus", "--verbose",
        "--audio-driver", "Dummy",  "--max-fps",    "60",                 "--log-file",   "test.log",
    };
    const no_args = try Options.parse(argv).?.engineArgs(arena.allocator(), "test.log");
    try std.testing.expectEqualDeep(@as([]const []const u8, &expected), no_args);
    try std.testing.expectEqual(expected.len, no_args.len);
    const forwarded = &[_][:0]const u8{ "--display-driver", "x11", "--script", "res://test.gd", "--", "--file=a b" };
    const with_args = try Options.parse(argv ++ &[_][:0]const u8{"--"} ++ forwarded).?.engineArgs(arena.allocator(), "test.log");
    try std.testing.expectEqual(@as(usize, expected.len + forwarded.len), with_args.len);
    for (forwarded, with_args[expected.len..]) |arg, actual| try std.testing.expectEqualStrings(arg, actual);
}
