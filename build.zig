const std = @import("std");
const Build = std.Build;
const gdzig = @import("gdzig");

// Machine-specific default so `zig build run` works with zero args; override
// with -Dgodot-path.
const default_godot = "/Users/clay/.gdvm/installs/registry.gdvm.io-7999f4302078c203/default/4.6.3-stable/Godot.app/Contents/MacOS/Godot";

pub fn build(b: *Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const godot_path = b.option([]const u8, "godot-path", "Path to a Godot executable") orelse default_godot;

    // --- Core: pure Zig, no Godot dependency. Mirrors src/core/ in C++. ---
    const core_mod = b.createModule(.{
        .root_source_file = b.path("src/core/core.zig"),
        .target = target,
        .optimize = optimize,
    });

    const core_tests = b.addTest(.{ .root_module = core_mod });
    const test_step = b.step("test", "Run core unit tests (no Godot needed)");
    test_step.dependOn(&b.addRunArtifact(core_tests).step);

    // --- Godot extension: gdzig glue + AVFoundation backend. ---
    const gdzig_dep = b.dependency("gdzig", .{
        .target = target,
        .optimize = optimize,
        .@"godot-path" = godot_path,
    });

    // AVFoundation backend as its own module so src/avf can import "core"
    // without escaping a module root.
    const avf_mod = b.createModule(.{
        .root_source_file = b.path("src/avf/avf_backend.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core", .module = core_mod },
        },
    });

    const ext_mod = b.createModule(.{
        .root_source_file = b.path("src/godot/extension.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "godot", .module = gdzig_dep.module("gdzig") },
            .{ .name = "core", .module = core_mod },
            .{ .name = "avf", .module = avf_mod },
        },
    });

    const extension = gdzig.addExtension(b, .{
        .name = "native_video_zig",
        .root_module = ext_mod,
        .entry_symbol = "native_video_init",
        .target = target,
        .optimize = optimize,
    }) orelse return;

    // AVFoundation ObjC shim + frameworks (macOS only). The shim file check
    // lets the skeleton build before the backend port lands.
    if (target.result.os.tag == .macos) {
        if (std.fs.cwd().access("src/avf/avf_shim.m", .{})) |_| {
            extension.compile.root_module.addCSourceFile(.{
                .file = b.path("src/avf/avf_shim.m"),
                .flags = &.{"-fobjc-arc"},
            });
        } else |_| {}
        extension.compile.root_module.linkFramework("Foundation", .{});
        extension.compile.root_module.linkFramework("AVFoundation", .{});
        extension.compile.root_module.linkFramework("CoreMedia", .{});
        extension.compile.root_module.linkFramework("CoreVideo", .{});
        extension.compile.root_module.linkFramework("Metal", .{});
    }

    // Standalone decode harness: pumps the AVF backend without Godot.
    if (target.result.os.tag == .macos) {
        const smoke_mod = b.createModule(.{
            .root_source_file = b.path("src/avf/decode_smoke.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "core", .module = core_mod },
            },
        });
        smoke_mod.addCSourceFile(.{
            .file = b.path("src/avf/avf_shim.m"),
            .flags = &.{"-fobjc-arc"},
        });
        smoke_mod.linkFramework("Foundation", .{});
        smoke_mod.linkFramework("AVFoundation", .{});
        smoke_mod.linkFramework("CoreMedia", .{});
        smoke_mod.linkFramework("CoreVideo", .{});
        const smoke_exe = b.addExecutable(.{ .name = "decode-smoke", .root_module = smoke_mod });
        const smoke_run = b.addRunArtifact(smoke_exe);
        smoke_run.addArg(b.pathFromRoot("project/synthetic.mp4"));
        b.step("decode-smoke", "Pump the AVF backend without Godot").dependOn(&smoke_run.step);
    }

    const install = b.addInstallFileWithDir(extension.output, .{ .custom = "../project/lib" }, extension.filename);
    b.default_step.dependOn(&install.step);

    const run = Build.Step.Run.create(b, "run godot demo");
    run.addFileArg(gdzig_dep.namedLazyPath("godot"));
    run.addArg("--path");
    run.addDirectoryArg(b.path("./project"));
    run.step.dependOn(&install.step);
    b.step("run", "Run the demo project in Godot").dependOn(&run.step);
}
