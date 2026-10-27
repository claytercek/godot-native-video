//! Windows importer selection and delegation for the present pipeline.
//! initialize() reads the RD driver and Godot version from RenderingServer and
//! Engine, then calls importer_selector.selectImporter. D3D12 zero-copy requires
//! the d3d12 driver and Godot >= 4.5; Vulkan always uses CPU-copy because its
//! DXGI zero-copy path is not ported (see importer_selector.zig).
//!
//! D3D12 binding or permanent interop failure switches to CPU-copy for the rest
//! of the session. Both paths expose the same interface to the present pipeline.

const std = @import("std");

const core = @import("core");

const godot = @import("godot");
const RenderingDevice = godot.class.RenderingDevice;
const RenderingServer = godot.class.RenderingServer;
const Engine = godot.class.Engine;
const String = godot.builtin.String;
const Dictionary = godot.builtin.Dictionary;
const Variant = godot.builtin.Variant;

const importer_selector = @import("importer_selector.zig");
const selectImporter = importer_selector.selectImporter;
const ImporterKind = importer_selector.ImporterKind;

const si = @import("surface_importer.zig");
const ImportResult = si.ImportResult;

const D3D12SurfaceImporter = @import("d3d12_surface_importer.zig").D3D12SurfaceImporter;
const CpuCopySurfaceImporter = @import("cpu_copy_surface_importer.zig").CpuCopySurfaceImporter;

const log = std.log.scoped(.native_video_windows_import);

/// The active concrete importer, chosen at initialize().
const Concrete = union(enum) {
    d3d12: D3D12SurfaceImporter,
    cpu_copy: CpuCopySurfaceImporter,
};

pub const WindowsSurfaceImporter = struct {
    allocator: std.mem.Allocator,
    concrete: ?Concrete = null,
    // Kept so the runtime CPU-copy fallback can bind a fresh importer.
    rd: ?*RenderingDevice = null,
    pub fn init(allocator: std.mem.Allocator) WindowsSurfaceImporter {
        return .{ .allocator = allocator };
    }

    /// Select and initialize an importer from the live driver/version.
    /// If D3D12 cannot bind its device, initialize CPU-copy instead.
    /// Returns the selected importer's initialization result.
    pub fn initialize(self: *WindowsSurfaceImporter, rd: *RenderingDevice) bool {
        if (self.concrete != null) return self.isInitialized();
        self.rd = rd;

        var driver_buf: [64]u8 = undefined;
        var driver_str = RenderingServer.getCurrentRenderingDriverName();
        defer driver_str.deinit();
        const driver = driver_str.toUtf8Buf(driver_buf[0..]);

        const major, const minor = readGodotVersion();
        const kind = selectImporter(driver, major, minor);
        log.info("selected {s} import path (driver \"{s}\", Godot {d}.{d}).", .{ @tagName(kind), driver, major, minor });

        switch (kind) {
            .d3d12 => {
                self.concrete = .{ .d3d12 = D3D12SurfaceImporter.init(self.allocator) };
                if (self.concrete.?.d3d12.initialize(rd)) return true;
                // Could not bind Godot's D3D12 device; fall back permanently.
                log.warn("D3D12 importer failed to initialize; falling back to CPU-copy import.", .{});
                return self.degradeToCpuCopy(rd);
            },
            .cpu_copy => {
                self.concrete = .{ .cpu_copy = CpuCopySurfaceImporter.init(self.allocator) };
                return self.concrete.?.cpu_copy.initialize(rd);
            },
        }
    }

    pub fn isInitialized(self: *const WindowsSurfaceImporter) bool {
        const c = self.concrete orelse return false;
        return switch (c) {
            .d3d12 => |*imp| imp.isInitialized(),
            .cpu_copy => |*imp| imp.isInitialized(),
        };
    }

    pub fn import(self: *WindowsSurfaceImporter, frame_info: core.backend.VideoFrame, submission: u64) ImportResult {
        const c = &(self.concrete orelse return .transient_failure);
        switch (c.*) {
            .d3d12 => |*imp| {
                const result = imp.import(frame_info, submission);
                switch (result) {
                    .capability_unavailable => {},
                    else => return result,
                }
                log.warn("D3D12 zero-copy capability unavailable; falling back to CPU-copy import permanently.", .{});
                const rd = self.rd orelse return .transient_failure;
                if (!self.degradeToCpuCopy(rd)) return .transient_failure;
                return self.concrete.?.cpu_copy.import(frame_info, submission);
            },
            .cpu_copy => |*imp| return imp.import(frame_info, submission),
        }
    }

    /// Tear down D3D12 and bind a new CPU-copy importer to rd for this session.
    /// Used after device-binding failure or permanent interop failure, such as
    /// cross-adapter OpenSharedHandle failure before the first successful import.
    ///
    /// On return, concrete holds the initialized CPU-copy importer or null,
    /// never the torn-down D3D12 instance. CPU-copy initialization is
    /// driver-agnostic, but callers must still use isInitialized()/import(),
    /// which handle null as not ready.
    fn degradeToCpuCopy(self: *WindowsSurfaceImporter, rd: *RenderingDevice) bool {
        if (self.concrete) |*c| {
            if (c.* == .d3d12) c.d3d12.deinit();
        }
        self.concrete = null;
        var cpu_copy = CpuCopySurfaceImporter.init(self.allocator);
        if (!cpu_copy.initialize(rd)) return false;
        self.concrete = .{ .cpu_copy = cpu_copy };
        return true;
    }

    /// Successful CPU-copy imports this session, whether selected initially
    /// or used after D3D12 fallback.
    pub fn cpuCopyCount(self: *const WindowsSurfaceImporter) u64 {
        const c = &(self.concrete orelse return 0);
        return switch (c.*) {
            .d3d12 => 0,
            .cpu_copy => |*imp| imp.cpu_copy_count,
        };
    }

    pub fn deinit(self: *WindowsSurfaceImporter) void {
        if (self.concrete) |*c| {
            switch (c.*) {
                .d3d12 => |*imp| imp.deinit(),
                .cpu_copy => |*imp| imp.deinit(),
            }
            self.concrete = null;
        }
    }
};

/// Read Godot's major/minor from the Engine singleton's version_info dictionary.
/// Missing/non-integer fields fall back to 0, which selectImporter treats as a
/// pre-4.5 engine (CPU-copy).
fn readGodotVersion() struct { i32, i32 } {
    var vi = Engine.getVersionInfo();
    defer vi.deinit();
    return .{ versionField(&vi, "major"), versionField(&vi, "minor") };
}

fn versionField(vi: *const Dictionary, comptime name: [:0]const u8) i32 {
    var key = String.fromLatin1(name);
    defer key.deinit();
    var key_v = Variant.init(String, key);
    defer key_v.deinit();
    var value = vi.get(key_v, .{});
    defer value.deinit();
    return @intCast(value.as(i64) orelse 0);
}
