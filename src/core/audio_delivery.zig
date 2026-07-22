//! Audio delivery boundary types shared by the playback controller and binding.
//! Keeps sink back-pressure and track-handoff state out of transport control.

const clock_mod = @import("clock.zig");

const ClockBridge = clock_mod.ClockBridge;

pub const MixSink = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        mix: *const fn (*anyopaque, interleaved: []const f32, channel_count: i32) i32,
    };

    pub fn mix(self: MixSink, interleaved: []const f32, channel_count: i32) i32 {
        std.debug.assert(channel_count > 0);
        std.debug.assert(interleaved.len % @as(usize, @intCast(channel_count)) == 0);
        return self.vtable.mix(self.ptr, interleaved, channel_count);
    }
};

const std = @import("std");

pub const TrackHandoff = struct {
    state: State = .stable,

    pub const State = enum {
        stable,
        awaiting_first_chunk,
    };

    pub fn begin(self: *TrackHandoff, clock: *ClockBridge) void {
        clock.handoffToMonotonic();
        self.state = .awaiting_first_chunk;
    }

    pub fn onChunk(self: *TrackHandoff, clock: *ClockBridge) void {
        if (self.state != .awaiting_first_chunk) return;
        clock.reanchorToAudio();
        self.state = .stable;
    }

    pub fn rollback(self: *TrackHandoff, clock: *ClockBridge) void {
        self.state = .stable;
        clock.reanchorToAudio();
    }

    pub fn cancel(self: *TrackHandoff, clock: ?*ClockBridge) void {
        self.state = .stable;
        if (clock) |c| c.reanchorToAudio();
    }
};
