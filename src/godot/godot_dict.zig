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
    // Every Variant below is a temporary. `dict.set` copies both key and
    // value into the Dictionary, so the Dictionary owns the surviving copies
    // and each temporary must be deinit'd here -- otherwise its +1 on the
    // boxed String's CoW buffer is never released.
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
