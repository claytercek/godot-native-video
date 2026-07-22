//! godot_dict.zig — small typed helper for building Godot Dictionaries.
//!
//! Both the VideoStream (audio-track metadata) and the VideoStreamPlayback
//! (colorimetry info) build result Dictionaries the same way: a Latin-1 key
//! String plus a value Variant. This hoists that one pattern so the Variant
//! conversions live in exactly one place.

const godot = @import("godot");
const String = godot.builtin.String;
const Dictionary = godot.builtin.Dictionary;
const Variant = godot.builtin.Variant;

/// Sets `dict[key] = value`, choosing the Variant conversion from `value`'s
/// type: integers box as i64, bools as bool, and byte slices as a String
/// (UTF-8, Latin-1 fallback). These are the exact conversions the former
/// per-file setDictInt/setDictBool/setDictString helpers performed.
pub fn setDict(dict: *Dictionary, comptime key: [:0]const u8, value: anytype) void {
    var k = String.fromLatin1(key);
    defer k.deinit();
    const kv = Variant.init(String, k);
    switch (@typeInfo(@TypeOf(value))) {
        .bool => _ = dict.set(kv, Variant.init(bool, value)),
        .int, .comptime_int => _ = dict.set(kv, Variant.init(i64, @intCast(value))),
        .pointer => {
            var v = String.fromUtf8(value) catch String.fromLatin1(value);
            defer v.deinit();
            _ = dict.set(kv, Variant.init(String, v));
        },
        else => @compileError("setDict: unsupported value type " ++ @typeName(@TypeOf(value))),
    }
}
