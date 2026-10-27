//! Write std.log records to stderr and Godot, whose editor does not capture
//! GDExtension stderr. extension.zig installs logFn through std_options,
//! re-exported by gdzig's generated entrypoint. Errors use push_error, warnings
//! use push_warning, and info/debug use print_verbose.
//!
//! Godot calls require a live GDExtension interface. extension.zig enables them
//! through setAvailable at register() and disables them at unregister(). Outside
//! that window, and in standalone binaries such as mf_tests and decode-smoke,
//! logging uses stderr alone.

const std = @import("std");

const godot = @import("godot");
const String = godot.builtin.String;
const Variant = godot.builtin.Variant;

/// Maximum message length forwarded to Godot's single-Variant APIs.
/// Longer messages are truncated; stderr retains the full text.
const max_message_len = 1024;

var available: std.atomic.Value(bool) = .init(false);

/// Flip whether Godot's utility functions are safe to call. Only
/// extension.zig's register()/unregister() should call this.
pub fn setAvailable(value: bool) void {
    available.store(value, .release);
}

/// Extension-wide std.Options.logFn (extension.zig). Main and decode threads
/// share only the atomic availability flag; formatting uses a stack buffer
/// per call.
pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    // Preserve complete stderr output in std.log's format.
    std.log.defaultLog(level, scope, format, args);

    if (!available.load(.acquire)) return;

    var buf: [max_message_len]u8 = undefined;
    forward(level, formatMessage(&buf, level, scope, format, args));
}

/// Format "level(scope): message", omitting scope when default, without
/// std.log's color codes or trailing newline. Truncate overflow with "...".
fn formatMessage(
    buf: []u8,
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    writeMessage(&w, level, scope, format, args) catch {
        const ellipsis = "...";
        @memcpy(buf[buf.len - ellipsis.len ..], ellipsis);
        return buf;
    };
    return w.buffered();
}

fn writeMessage(
    w: *std.Io.Writer,
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) std.Io.Writer.Error!void {
    try w.writeAll(level.asText());
    if (scope != .default) try w.print("({t})", .{scope});
    try w.writeAll(": ");
    try w.print(format, args);
}

/// Send errors/warnings to Godot's editor lists through push_error/push_warning.
/// info/debug use print_verbose and require --verbose/-v or
/// debug/settings/stdout/verbose_stdout.
fn forward(comptime level: std.log.Level, message: []const u8) void {
    var msg_str = String.fromUtf8(message) catch String.fromLatin1(message);
    defer msg_str.deinit();
    var v = Variant.init(String, msg_str);
    defer v.deinit();

    switch (level) {
        .err => godot.general.pushError(v, .{}),
        .warn => godot.general.pushWarning(v, .{}),
        .info, .debug => godot.general.printVerbose(v, .{}),
    }
}
