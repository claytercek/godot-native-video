//! Root of the pure-Zig engine core — mirrors src/core/ in the C++ tree.
//! No Godot, no RenderingDevice, no platform SDK types.

pub const backend = @import("backend.zig");
pub const wall_clock = @import("wall_clock.zig");
pub const frame_queue = @import("frame_queue.zig");
pub const audio_ring = @import("audio_ring.zig");
pub const retire_ring = @import("retire_ring.zig");
pub const channel_mixer = @import("channel_mixer.zig");
pub const canonical_mix_format = @import("canonical_mix_format.zig");
pub const decode_scheduler = @import("decode_scheduler.zig");
pub const playback_controller = @import("playback_controller.zig");
pub const shaders = @import("shaders.zig");
pub const clock = @import("clock.zig");
pub const scrubber = @import("scrubber.zig");
pub const present_selector = @import("present_selector.zig");
pub const hdr_color_math = @import("hdr_color_math.zig");
pub const push_constants = @import("push_constants.zig");
pub const sys_clock = @import("sys_clock.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("test_support.zig");
    _ = @import("av_drift_test.zig");
    _ = @import("colorimetry_test.zig");
    _ = @import("audio_eos_fallback_test.zig");
    _ = @import("marker_clip_test.zig");
    _ = @import("scrubber_integration_test.zig");
    _ = @import("color_matrix_test.zig");
}
