//! Preserve ObjectID bits across gdzig's u64/i64 API boundary.
//!
//! Object.getInstanceId() returns u64 through `"meta": "uint64"`, but the
//! generated instanceFromId() takes i64 because utility functions lack meta.
//! Godot sets bit 63 for RefCounted IDs, including Resources, so conversion must
//! reinterpret the bits rather than range-check them.
//!
//! The non-exhaustive ObjectId enum prevents accidental @intCast. gdzig's
//! builtin/variant.zig defines an ObjectId but does not re-export it through
//! generated bindings.

/// A Godot ObjectID. Non-exhaustive: every u64 is a valid id, and the engine
/// owns the bit layout.
pub const ObjectId = enum(u64) { _ };

/// Adopt a raw id as handed back by Object.getInstanceId().
pub fn fromRaw(raw: u64) ObjectId {
    return @fromBackingInt(@intCast(raw));
}

/// Convert an ObjectID into the i64 that gdzig's generated utility-function
/// bindings (instanceFromId) expect.
pub fn toEngineInt(id: ObjectId) i64 {
    return @bitCast(@backingInt(id));
}
