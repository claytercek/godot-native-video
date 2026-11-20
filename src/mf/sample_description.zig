const std = @import("std");

pub const Codec = enum { vp9, av1 };

const Box = struct {
    kind: [4]u8,
    payload: []const u8,

    fn take(bytes: *[]const u8) ?Box {
        const data = bytes.*;
        if (data.len < 8) return null;
        const short_size = std.mem.readInt(u32, data[0..4], .big);
        const header: usize = if (short_size == 1) 16 else 8;
        if (data.len < header) return null;
        const size: u64 = if (short_size == 1) std.mem.readInt(u64, data[8..16], .big) else short_size;
        // Size zero extends to EOF, which an isolated MF attribute cannot establish.
        if (size < header or size > data.len) return null;
        const end: usize = @intCast(size);
        bytes.* = data[end..];
        return .{ .kind = data[4..8].*, .payload = data[header..end] };
    }

    fn is(self: Box, kind: *const [4]u8) bool {
        return std.mem.eql(u8, &self.kind, kind);
    }
};

/// MF supplies a complete stsd box and a zero-based current sample entry index.
/// An absent index identifies an entry only in a single-entry box.
pub fn bitDepth(codec: Codec, stsd: []const u8, index: ?u32) ?i32 {
    var bytes = stsd;
    const root = Box.take(&bytes) orelse return null;
    if (bytes.len != 0 or !root.is("stsd")) return null;
    const data = root.payload;
    if (data.len < 8 or std.mem.readInt(u32, data[0..4], .big) != 0) return null;
    const count = std.mem.readInt(u32, data[4..8], .big);
    const selected = index orelse if (count == 1) @as(u32, 0) else return null;
    if (selected >= count) return null;

    var entries = data[8..];
    var depth: ?i32 = null;
    for (0..count) |i| {
        const entry = Box.take(&entries) orelse return null;
        if (i == selected) depth = entryDepth(codec, entry) orelse return null;
    }
    return if (entries.len == 0) depth else null;
}

fn entryDepth(codec: Codec, entry: Box) ?i32 {
    if (!entry.is(switch (codec) {
        .vp9 => "vp09",
        .av1 => "av01",
    })) return null;
    const visual_sample_entry_size = 78;
    if (entry.payload.len < visual_sample_entry_size) return null;
    var children = entry.payload[visual_sample_entry_size..];
    var depth: ?i32 = null;
    while (children.len != 0) {
        const child = Box.take(&children) orelse return null;
        if (!child.is(switch (codec) {
            .vp9 => "vpcC",
            .av1 => "av1C",
        })) continue;
        if (depth != null) return null;
        depth = (switch (codec) {
            .vp9 => vp9Depth(child.payload),
            .av1 => av1Depth(child.payload),
        }) orelse return null;
    }
    return depth;
}

fn vp9Depth(data: []const u8) ?i32 {
    // VP9 forbids codec initialization data even when the declared length fits.
    if (data.len != 12 or std.mem.readInt(u16, data[10..12], .big) != 0) return null;
    if (!std.mem.eql(u8, data[0..4], "\x01\x00\x00\x00")) return null;
    switch (data[5]) {
        0, 10, 11, 20, 21, 30, 31, 40, 41, 50, 51, 52, 60, 61, 62 => {},
        else => return null,
    }
    const chroma = (data[6] >> 1) & 7;
    if (chroma > 1 or data[9] == 0) return null; // Identity (RGB) requires 4:4:4.
    const depth = data[6] >> 4;
    return switch (data[4]) {
        0 => if (depth == 8) 8 else null,
        2 => if (depth == 10) 10 else null,
        else => null,
    };
}

fn av1Depth(data: []const u8) ?i32 {
    if (data.len < 4 or data[0] != 0x81) return null;
    const profile = data[1] >> 5;
    const level = data[1] & 0x1f;
    if (profile != 0 or (level > 23 and level != 31)) return null;
    const flags = data[2];
    if (flags & 0x80 != 0 and level <= 7) return null;
    const twelve_bit = flags & 0x20 != 0;
    const monochrome = flags & 0x10 != 0;
    const subsampling_xy = (flags >> 2) & 3;
    const chroma_position = flags & 3;
    if (twelve_bit or monochrome or subsampling_xy != 3 or chroma_position == 3) return null;
    const delay = data[3];
    if (delay & 0xe0 != 0 or (delay & 0x10 == 0 and delay != 0)) return null;
    return if (flags & 0x40 != 0) 10 else 8;
}

const testing = std.testing;
const visual_header: [78]u8 = @splat(0);
const vp9_8 = "\x01\x00\x00\x00\x00\x14\x80\x02\x02\x02\x00\x00";
const vp9_10 = "\x01\x00\x00\x00\x02\x14\xa2\x02\x02\x02\x00\x00";
const av1_8 = "\x81\x00\x0d\x00";
const av1_10 = "\x81\x00\x4c\x00";

fn box(kind: *const [4]u8, data: anytype) [8 + data.len]u8 {
    var size: [4]u8 = undefined;
    std.mem.writeInt(u32, &size, 8 + data.len, .big);
    return size ++ kind.* ++ data.*;
}

fn extendedBox(kind: *const [4]u8, data: anytype) [16 + data.len]u8 {
    var size: [8]u8 = undefined;
    std.mem.writeInt(u64, &size, 16 + data.len, .big);
    return "\x00\x00\x00\x01".* ++ kind.* ++ size ++ data.*;
}

fn stsdBox(count: u32, entries: anytype) [16 + entries.len]u8 {
    var count_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &count_bytes, count, .big);
    return box("stsd", &("\x00\x00\x00\x00".* ++ count_bytes ++ entries.*));
}

const vp09_8 = box("vp09", &(visual_header ++ box("vpcC", vp9_8)));
const vp09_10 = box("vp09", &(visual_header ++ box("vpcC", vp9_10)));
const av01_8 = box("av01", &(visual_header ++ box("av1C", av1_8)));
const av01_10 = box("av01", &(visual_header ++ box("av1C", av1_10)));

test "select only the current zero-based entry, without guessing from its type" {
    const entries = vp09_8 ++ vp09_10 ++ av01_10 ++ av01_8;
    const stsd = stsdBox(4, &entries);
    try testing.expectEqual(@as(?i32, 8), bitDepth(.vp9, &stsd, 0));
    try testing.expectEqual(@as(?i32, 10), bitDepth(.vp9, &stsd, 1));
    try testing.expectEqual(@as(?i32, 10), bitDepth(.av1, &stsd, 2));
    try testing.expectEqual(@as(?i32, 8), bitDepth(.av1, &stsd, 3));
    try testing.expectEqual(null, bitDepth(.av1, &stsd, 1));
    try testing.expectEqual(null, bitDepth(.vp9, &stsd, null));
    try testing.expectEqual(null, bitDepth(.av1, &stsd, 4));
    try testing.expectEqual(@as(?i32, 10), bitDepth(.vp9, &stsdBox(1, &vp09_10), null));
}

test "bounded extended sizes and sibling boxes" {
    const children = box("pasp", "abcdefgh") ++ extendedBox("av1C", av1_10 ++ "\x12\x00") ++ box("btrt", "abcdefgh1234");
    const entry = extendedBox("av01", &(visual_header ++ children));
    const stsd = extendedBox("stsd", &("\x00\x00\x00\x00\x00\x00\x00\x01".* ++ entry));
    try testing.expectEqual(@as(?i32, 10), bitDepth(.av1, &stsd, null));
    for (0..stsd.len) |n| try testing.expectEqual(null, bitDepth(.av1, stsd[0..n], null));
    for ([_]usize{ 0, 24, 24 + 16 + 78 + 16 }) |start| {
        for ([_]u64{ 0, 15, 9999, std.math.maxInt(u64) }) |size| {
            var bad = stsd;
            std.mem.writeInt(u64, bad[start + 8 ..][0..8], size, .big);
            try testing.expectEqual(null, bitDepth(.av1, &bad, null));
        }
    }
}

test "require entire stsd, counted entries, and well-framed direct config child" {
    const cfg = box("av1C", av1_10);
    const stsd = stsdBox(1, &av01_10);
    try testing.expectEqual(null, bitDepth(.av1, &av01_10, null));
    try testing.expectEqual(null, bitDepth(.av1, &cfg, null));
    try testing.expectEqual(null, bitDepth(.av1, &(stsd ++ "x".*), null));
    try testing.expectEqual(null, bitDepth(.av1, &stsdBox(2, &av01_10), 0));
    try testing.expectEqual(null, bitDepth(.av1, &stsdBox(1, &(av01_10 ++ av01_8)), 0));
    for ([_]usize{ 0, 4, 8, 11, 16, 16 + 8 + 78 }) |offset| {
        var bad = stsd;
        bad[offset] = 0xff;
        try testing.expectEqual(null, bitDepth(.av1, &bad, null));
    }
    inline for (.{
        cfg,
        visual_header,
        visual_header ++ box("pasp", &cfg),
        visual_header ++ box("vpcC", vp9_10),
        visual_header ++ cfg ++ cfg,
        visual_header ++ cfg ++ "x".*,
        visual_header ++ "\x00\x00\x00\x00av1C".* ++ av1_10.*,
    }) |payload| {
        try testing.expectEqual(null, bitDepth(.av1, &stsdBox(1, &box("av01", &payload)), null));
    }
}

test "vpcC rejects incompatible fields and nonempty or misdeclared initialization data" {
    for ([_][2]u8{
        .{ 0, 0 },   .{ 0, 2 },    .{ 3, 1 },    .{ 4, 0 },    .{ 4, 1 },    .{ 4, 3 }, .{ 4, 4 },
        .{ 5, 255 }, .{ 6, 0x82 }, .{ 6, 0xc2 }, .{ 6, 0xa4 }, .{ 6, 0xae }, .{ 9, 0 }, .{ 10, 1 },
        .{ 11, 1 },
    }) |change| {
        var bad = vp9_10.*;
        bad[change[0]] = change[1];
        try testing.expectEqual(null, vp9Depth(&bad));
    }
    var full = vp9_10.* ++ "x".*;
    try testing.expectEqual(null, vp9Depth(&full));
    full[11] = 1;
    try testing.expectEqual(null, vp9Depth(&full));
    try testing.expectEqual(null, vp9Depth(vp9_10[0..11]));
}

test "av1C checks marker, version, Main profile, tier, 4:2:0 chroma, and reserved bits" {
    for ([_][2]u8{
        .{ 0, 0x01 }, .{ 0, 0x80 }, .{ 0, 0x82 }, .{ 1, 0x20 }, .{ 1, 0x40 }, .{ 1, 24 },
        .{ 2, 0xcc }, .{ 2, 0x6c }, .{ 2, 0x5c }, .{ 2, 0x44 }, .{ 2, 0x48 }, .{ 2, 0x4f },
        .{ 3, 0x20 }, .{ 3, 0x01 },
    }) |change| {
        var bad = av1_10.*;
        bad[change[0]] = change[1];
        try testing.expectEqual(null, av1Depth(&bad));
    }
    try testing.expectEqual(null, av1Depth(av1_10[0..3]));
    try testing.expectEqual(@as(?i32, 10), av1Depth("\x81\x08\xce\x1f"));
}
