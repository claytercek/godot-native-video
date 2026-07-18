//! media_source.zig — port of src/core/media_source.h.
//!
//! Abstracts byte/file input so tests feed fixtures and the Binding feeds
//! Godot FileAccess. No Godot types appear here — this module is
//! Godot-independent.
//!
//! C++ pure-virtual class → ptr + vtable interface (composition, not
//! inheritance), matching backend.zig's style. The one C++ virtual with a
//! default body (name()) becomes an optional vtable entry.

const std = @import("std");

pub const MediaSource = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Total byte length of the source, or 0 if unknown / streaming.
        size: *const fn (*anyopaque) u64,
        /// Current read position.
        tell: *const fn (*anyopaque) u64,
        /// Seek to an absolute byte offset. Returns true on success.
        seek: *const fn (*anyopaque, offset: u64) bool,
        /// Read up to `buf.len` bytes into `buf`. Returns the number of bytes
        /// actually read; returns 0 on EOF or error.
        read: *const fn (*anyopaque, buf: []u8) usize,
        /// True when the source has no more data to deliver.
        eof: *const fn (*anyopaque) bool,

        /// Human-readable name/path for diagnostics, may be empty.
        /// null → "" (the C++ base-class default).
        name: ?*const fn (*anyopaque) []const u8 = null,

        /// Virtual destructor equivalent: free the implementation.
        deinit: ?*const fn (*anyopaque) void = null,
    };

    pub fn size(self: MediaSource) u64 {
        return self.vtable.size(self.ptr);
    }
    pub fn tell(self: MediaSource) u64 {
        return self.vtable.tell(self.ptr);
    }
    pub fn seek(self: MediaSource, offset: u64) bool {
        return self.vtable.seek(self.ptr, offset);
    }
    pub fn read(self: MediaSource, buf: []u8) usize {
        return self.vtable.read(self.ptr, buf);
    }
    pub fn eof(self: MediaSource) bool {
        return self.vtable.eof(self.ptr);
    }
    pub fn name(self: MediaSource) []const u8 {
        if (self.vtable.name) |f| return f(self.ptr);
        return "";
    }
    pub fn deinit(self: MediaSource) void {
        if (self.vtable.deinit) |f| f(self.ptr);
    }
};

test "MediaSource default name() mirrors the C++ base class" {
    const Fake = struct {
        data: []const u8,
        pos: u64 = 0,

        fn sizeFn(p: *anyopaque) u64 {
            const self: *@This() = @ptrCast(@alignCast(p));
            return self.data.len;
        }
        fn tellFn(p: *anyopaque) u64 {
            const self: *@This() = @ptrCast(@alignCast(p));
            return self.pos;
        }
        fn seekFn(p: *anyopaque, offset: u64) bool {
            const self: *@This() = @ptrCast(@alignCast(p));
            if (offset > self.data.len) return false;
            self.pos = offset;
            return true;
        }
        fn readFn(p: *anyopaque, buf: []u8) usize {
            const self: *@This() = @ptrCast(@alignCast(p));
            const remaining = self.data.len - self.pos;
            const n = @min(remaining, buf.len);
            @memcpy(buf[0..n], self.data[self.pos .. self.pos + n]);
            self.pos += n;
            return n;
        }
        fn eofFn(p: *anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(p));
            return self.pos >= self.data.len;
        }

        const vtable: MediaSource.VTable = .{
            .size = sizeFn,
            .tell = tellFn,
            .seek = seekFn,
            .read = readFn,
            .eof = eofFn,
        };
    };

    var fake: Fake = .{ .data = "hello" };
    const src: MediaSource = .{ .ptr = &fake, .vtable = &Fake.vtable };

    try std.testing.expectEqual(@as(u64, 5), src.size());
    try std.testing.expect(!src.eof());
    try std.testing.expectEqualStrings("", src.name());

    var buf: [3]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 3), src.read(&buf));
    try std.testing.expectEqualStrings("hel", &buf);
    try std.testing.expectEqual(@as(u64, 3), src.tell());

    try std.testing.expect(src.seek(0));
    try std.testing.expectEqual(@as(u64, 0), src.tell());
}
