//! Typed Dictionary construction for audio-track metadata and colorimetry.
//! Keys are Latin-1 Strings; value types select their Variant conversions.

const godot = @import("godot");
const String = godot.builtin.String;
const Dictionary = godot.builtin.Dictionary;
const Variant = godot.builtin.Variant;

/// Set dict[key] to value: integers box as i64, bools as bool, and byte slices
/// as Strings (UTF-8 with Latin-1 fallback).
pub fn setDict(dict: *Dictionary, comptime key: [:0]const u8, value: anytype) void {
    var k = String.fromLatin1(key);
    defer k.deinit();
    // dict.set copies both Variants. Deinit the temporaries to release their
    // references, including those to boxed String CoW buffers.
    const kv = Variant.init(String, k);
    defer kv.deinit();
    switch (@typeInfo(@TypeOf(value))) {
        .bool => {
            const vv = Variant.init(bool, value);
            defer vv.deinit();
            _ = dict.set(kv, vv);
        },
        .int, .comptime_int => {
            const vv = Variant.init(i64, @intCast(value));
            defer vv.deinit();
            _ = dict.set(kv, vv);
        },
        .pointer => {
            var v = String.fromUtf8(value) catch String.fromLatin1(value);
            defer v.deinit();
            const vv = Variant.init(String, v);
            defer vv.deinit();
            _ = dict.set(kv, vv);
        },
        else => @compileError("setDict: unsupported value type " ++ @typeName(@TypeOf(value))),
    }
}
