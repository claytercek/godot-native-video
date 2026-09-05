//! object_id.zig — passing a Godot ObjectID back into an engine call.
//!
//! Godot stores an ObjectID as a u64 and tags every RefCounted object's id with
//! bit 63 (OBJECTDB_REFERENCE_BIT). gdzig types Object.get_instance_id() as u64
//! because its extension_api.json entry carries `"meta": "uint64"`, but
//! @GlobalScope utility functions carry no meta, so instance_from_id() takes an
//! i64. An id is an opaque bit pattern rather than a magnitude, so it is
//! reinterpreted across that seam, not range-checked: Resource-derived ids are
//! always >= 2^63 and no Resource id would ever fit in an i64.
//!
//! Lives in src/godot/ but imports nothing from Godot, so its tests run in the
//! standalone `test` step rather than needing the full extension build.

const std = @import("std");

/// Convert an ObjectID into the i64 that gdzig's generated utility-function
/// bindings (instanceFromId) expect.
pub fn toEngineInt(id: u64) i64 {
    return @bitCast(id);
}

test "a RefCounted object id survives conversion to an engine call argument" {
    // Godot sets bit 63 on the id of every RefCounted object. VideoStreamPlayback
    // is Resource-derived and therefore RefCounted, so a playback id always has
    // this bit set and is out of range for a signed 64-bit integer.
    var id: u64 = (1 << 63) | 0x1234;
    _ = &id; // keep the value runtime-known so the conversion isn't const-folded

    try std.testing.expectEqual(
        @as(i64, std.math.minInt(i64) + 0x1234),
        toEngineInt(id),
    );
}
