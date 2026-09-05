//! object_id.zig — passing a Godot ObjectID back into an engine call.
//!
//! Godot stores an ObjectID as a u64 and tags every RefCounted object's id with
//! bit 63 (OBJECTDB_REFERENCE_BIT). gdzig types Object.getInstanceId() as u64
//! because its extension_api.json entry carries `"meta": "uint64"`, but
//! @GlobalScope utility functions carry no meta, so the generated
//! instanceFromId() takes an i64. An id is an opaque bit pattern rather than a
//! magnitude, so it is reinterpreted across that seam, not range-checked:
//! Resource-derived ids are always >= 2^63 and no Resource id would ever fit in
//! an i64.
//!
//! ObjectId exists to make that mistake unrepresentable. Holding ids in a
//! non-exhaustive enum rather than a bare u64 means an @intCast of one is a
//! compile error, so the narrowing bug this module documents cannot come back
//! by way of a plausible-looking edit. gdzig has its own ObjectId in
//! builtin/variant.zig, but it isn't re-exported through the generated
//! bindings, so it can't be named from here.
//!
//! Lives in src/godot/ but imports nothing from Godot, so its tests run in the
//! standalone `test` step rather than needing the full extension build.

const std = @import("std");

/// A Godot ObjectID. Non-exhaustive: every u64 is a valid id, and the engine
/// owns the bit layout.
pub const ObjectId = enum(u64) { _ };

/// Adopt a raw id as handed back by Object.getInstanceId().
pub fn fromRaw(raw: u64) ObjectId {
    return @enumFromInt(raw);
}

/// Convert an ObjectID into the i64 that gdzig's generated utility-function
/// bindings (instanceFromId) expect.
pub fn toEngineInt(id: ObjectId) i64 {
    return @bitCast(@intFromEnum(id));
}

test "a RefCounted object id survives conversion to an engine call argument" {
    // Godot sets bit 63 on the id of every RefCounted object. VideoStreamPlayback
    // is Resource-derived and therefore RefCounted, so a playback id always has
    // this bit set and is out of range for a signed 64-bit integer.
    var raw: u64 = (1 << 63) | 0x1234;
    _ = &raw; // keep the value runtime-known so the conversion isn't const-folded

    try std.testing.expectEqual(
        @as(i64, std.math.minInt(i64) + 0x1234),
        toEngineInt(fromRaw(raw)),
    );
}

test "a plain object id is unchanged by the round trip" {
    var raw: u64 = 0x1234;
    _ = &raw;

    try std.testing.expectEqual(@as(i64, 0x1234), toEngineInt(fromRaw(raw)));
}
