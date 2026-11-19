const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const banner = "Vulkan 1.4 - Forward+ - Using Device #0: Fake GPU\n";

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const log = log: {
        for (args, 0..) |arg, i| {
            if (std.mem.eql(u8, arg, "--log-file")) break :log i + 1;
        }
        return error.MissingEngineLogArgument;
    };
    const mode = args[args.len - 1];
    const marker = if (std.mem.eql(u8, mode, "smoke-details"))
        "SMOKE: PASS ticks=1\n"
    else if (std.mem.eql(u8, mode, "transport"))
        "LINUX_TRANSPORT_PASS ticks=1\n"
    else
        "SMOKE: PASS\n";
    const message = try std.mem.concat(arena, u8, &.{ banner, marker });
    try Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[log], .data = message });
    if (!std.mem.eql(u8, mode, "file-only")) try Io.File.stdout().writeStreamingAll(init.io, message);
    if (std.mem.eql(u8, mode, "diagnostic"))
        try Io.File.stderr().writeStreamingAll(init.io, "loader: undefined symbol: native_init\n");
    if (std.mem.eql(u8, mode, "stdout-error"))
        try Io.File.stdout().writeStreamingAll(init.io, "ERROR: native startup failed\n");
    if (std.mem.eql(u8, mode, "nonzero")) return 17;
    if (std.mem.eql(u8, mode, "hang")) {
        const pid: u32 = switch (builtin.os.tag) {
            .windows => std.os.windows.GetCurrentProcessId(),
            .linux => @intCast(std.os.linux.getpid()),
            else => @intCast(std.c.getpid()),
        };
        try Io.File.stdout().writeStreamingAll(init.io, try std.fmt.allocPrint(arena, "PID: {d}\n", .{pid}));
        // Self-exit if the runner regresses and leaves the engine behind.
        try init.io.sleep(.fromSeconds(15), .awake);
    }
    return 0;
}
