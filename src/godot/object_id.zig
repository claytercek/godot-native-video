//! object_id.zig — passing a Godot ObjectID back into an engine call.
//!
//! gdzig types Object.getInstanceId() as u64 (its extension_api.json entry
//! carries `"meta": "uint64"`), but @GlobalScope utility functions carry no
//! meta, so the generated instanceFromId() takes an i64 instead. An id is an
//! opaque bit pattern, not a magnitude — Godot tags every RefCounted object's
//! id with bit 63, so Resource-derived ids are always >= 2^63 and would
//! narrow incorrectly if range-checked rather than reinterpreted across that
//! seam.
//!
//! ObjectId makes that mistake unrepresentable: holding ids in a
//! non-exhaustive enum rather than a bare u64 means an @intCast of one is a
//! compile error, so this narrowing bug cannot come back by way of a
//! plausible-looking edit. gdzig has its own ObjectId in builtin/variant.zig,
//! but it isn't re-exported through the generated bindings, so it can't be
//! named from here.

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
