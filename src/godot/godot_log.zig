//! godot_log.zig — routes std.log through to Godot's own output surface.
//!
//! Godot's editor Output panel never shows a GDExtension's stderr, so a
//! console-less editor run silently drops every std.log line -- a developer
//! debugging an instrumented build can watch nothing happen while a
//! console.exe run of that same build captures everything. This module
//! installs a custom logFn (wired in extension.zig's `std_options`, which
//! gdzig's generated entrypoint re-exports as the whole binary's actual log
//! config) that mirrors every record to push_error / push_warning / print,
//! in addition to -- not instead of -- the normal stderr write.
//!
//! Godot's utility functions need the GDExtension interface to be live.
//! `setAvailable` gates the Godot-side mirror on that: extension.zig flips it
//! on right after gdzig's interface is initialized (register()) and back off
//! at final teardown (unregister()). Before that window, after it, and in
//! standalone binaries that link core/mf but never call register() at all
//! (mf_tests, decode-smoke) the flag just stays false and every record falls
//! through to plain stderr, exactly as it did before this module existed.

const std = @import("std");

const godot = @import("godot");
const String = godot.builtin.String;
const Variant = godot.builtin.Variant;

/// Longest formatted message forwarded to Godot. Godot's utility functions
/// take one Variant, not a stream, so a hard cap plus truncation beats
/// growing this per call. Log lines are diagnostics, not payloads -- callers
/// needing more should read the (untruncated) stderr copy.
const max_message_len = 1024;

var available: std.atomic.Value(bool) = .init(false);

/// Flip whether Godot's utility functions are safe to call. Only
/// extension.zig's register()/unregister() should call this.
pub fn setAvailable(value: bool) void {
    available.store(value, .release);
}

/// The `std.Options.logFn` installed for the whole extension binary (see
/// extension.zig's `std_options`). Reached from decode worker threads as
/// well as the main thread; touches no shared mutable state beyond the
/// atomic availability flag above -- the formatted message lives in a
/// per-call stack buffer, so concurrent callers never share a scratch spot.
pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    // Always write stderr first, in the stdlib's own format, so a console-exe
    // run keeps capturing every line exactly as before -- Godot's Output
    // panel is an addition, never a replacement.
    std.log.defaultLog(level, scope, format, args);

    if (!available.load(.acquire)) return;

    var buf: [max_message_len]u8 = undefined;
    forward(level, formatMessage(&buf, level, scope, format, args));
}

/// Formats "level(scope): message" (or "level: message" for the default
/// scope) into `buf`, matching std.log's own stderr layout minus the color
/// codes and trailing newline. Truncates with an ellipsis instead of
/// dropping the record when it doesn't fit.
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

/// Hands the formatted message to Godot's own reporting surface. err lands
/// in the editor's error list (push_error), warn in its warning list
/// (push_warning); info/debug go through print_verbose, so they only reach
/// the console when Godot itself is run verbose (`--verbose`/`-v`, or
/// `debug/settings/stdout/verbose_stdout`) -- same gating GDScript's
/// `print_verbose()` gets, instead of GDScript's unconditional `print()`.
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
