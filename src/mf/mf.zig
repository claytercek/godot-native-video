//! mf.zig — root of the Media Foundation Windows backend module.
//!
//! Bundles the hand-written Windows bindings (`win`) and the MF decoder backend
//! (`backend`) into one module so both can be reached through a single import
//! and so the backend can pull in `core` via the build.zig-wired named module
//! without escaping a module root. Mirrors how avf_backend.zig is exposed on
//! macOS.

pub const win = @import("win.zig");
pub const backend = @import("mf_backend.zig");

/// Construct a Media Foundation backend as the core.Backend ptr+vtable
/// interface. Re-exported from mf_backend.zig so callers use `mf.create`.
pub const create = backend.create;

test {
    // Pull in the bindings-layer tests (win.zig's vtable-slot / runtime
    // round-trip decls) and the backend's comptime layout asserts so both run
    // under `zig build test`.
    _ = @import("win.zig");
    _ = @import("mf_backend.zig");
}
