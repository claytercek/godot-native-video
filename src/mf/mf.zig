//! Media Foundation module exposing Windows bindings (`win`) and the decoder
//! (`backend`). build.zig supplies the named core import within this module root.

pub const win = @import("win.zig");
pub const backend = @import("mf_backend.zig");

/// Construct a Media Foundation backend as the core.Backend ptr+vtable
/// interface. Re-exported from mf_backend.zig so callers use `mf.create`.
pub const create = backend.create;

test {
    // Pull in the bindings-layer tests (win.zig's vtable-slot / runtime
    // round-trip decls), the colorimetry parser unit tests, and the backend +
    // pipeline decls so all run under `zig build test`.
    _ = @import("win.zig");
    _ = @import("colorimetry.zig");
    _ = @import("pipeline.zig");
    _ = @import("com_executor.zig");
    _ = @import("mf_backend.zig");
}
