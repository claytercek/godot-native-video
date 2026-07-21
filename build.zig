const std = @import("std");
const Build = std.Build;
const gdzig = @import("gdzig");

// Downloaded by the build for bindgen when no local Godot binary is available
// (e.g. CI, or a dev machine with neither -Dgodot-path nor -Dgodot-version
// set). Resolves to the newest matching stable release.
const default_godot_version = "4.6";

pub fn build(b: *Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Prioritize performance, safety, or binary size") orelse .ReleaseFast;
    const env_godot = b.graph.environ_map.get("GODOT_PATH");
    const opt_godot_path = b.option([]const u8, "godot-path", "Path to a Godot executable") orelse env_godot;
    const opt_godot_version = b.option([]const u8, "godot-version", "Godot version to download for bindgen (e.g. `4.6`)");

    // --- Core: pure Zig, no Godot dependency. ---
    const core_mod = b.createModule(.{
        .root_source_file = b.path("src/core/core.zig"),
        .target = target,
        .optimize = optimize,
    });

    const core_tests = b.addTest(.{ .root_module = core_mod });
    const test_step = b.step("test", "Run core unit tests (no Godot needed)");
    test_step.dependOn(&b.addRunArtifact(core_tests).step);

    // --- Media Foundation Windows bindings (Windows only). ---
    // Hand-written OS bindings layer that the eventual MF decoder backend and
    // the D3D11/D3D12 surface importers build on. Its own module so the future
    // backend can import "core" without escaping a module root, mirroring how
    // avf_mod is wired below. The runtime bindings test is folded into the main
    // `test` step; it exercises real MF + D3D11 objects, so it needs Windows and
    // a D3D11-capable GPU (it SkipZigTests when no device is available).
    if (target.result.os.tag == .windows) {
        const mf_mod = b.createModule(.{
            .root_source_file = b.path("src/mf/mf.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "core", .module = core_mod },
            },
        });
        linkMfLibs(mf_mod);
        const mf_tests = b.addTest(.{ .root_module = mf_mod });
        test_step.dependOn(&b.addRunArtifact(mf_tests).step);

        // Standalone decode harness: pumps the MF backend without Godot. Mirrors
        // the macOS decode-smoke step below.
        const smoke_mod = b.createModule(.{
            .root_source_file = b.path("src/mf/decode_smoke.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "core", .module = core_mod },
            },
        });
        linkMfLibs(smoke_mod);
        const smoke_exe = b.addExecutable(.{ .name = "decode-smoke", .root_module = smoke_mod });
        const smoke_run = b.addRunArtifact(smoke_exe);
        if (b.args) |args| smoke_run.addArgs(args);
        b.step("decode-smoke", "Pump the MF backend without Godot (pass a media path via -- <path>)").dependOn(&smoke_run.step);
    }

    // --- Godot extension: gdzig glue + AVFoundation backend. ---
    // Explicit path > explicit version > downloaded default version.
    const gdzig_dep = if (opt_godot_path) |p| b.dependency("gdzig", .{
        .target = target,
        .optimize = optimize,
        .@"godot-path" = p,
    }) else b.dependency("gdzig", .{
        .target = target,
        .optimize = optimize,
        .@"godot-version" = opt_godot_version orelse default_godot_version,
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
        .name = "native_video",
        .root_module = ext_mod,
        .entry_symbol = "native_video_init",
        .minimum_initialization_level = .scene,
        .target = target,
        .optimize = optimize,
    }) orelse return;

    if (optimize != .Debug) {
        extension.compile.root_module.strip = true;
        extension.compile.link_gc_sections = true;
    }

    // AVFoundation ObjC shim + frameworks (macOS only). Metal is
    // extension-only — the decode harness never presents.
    if (target.result.os.tag == .macos) {
        linkAvfShim(b, extension.compile.root_module);
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
        linkAvfShim(b, smoke_mod);
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

/// Link the Windows system libraries the Media Foundation backend needs.
/// Shared by the bindings/backend test module and the decode-smoke harness so
/// the list lives in exactly one place.
fn linkMfLibs(mod: *Build.Module) void {
    for ([_][]const u8{
        "mfplat", "mfreadwrite", "mf",    "d3d11",
        "dxgi",   "d3d12",       "ole32", "d3dcompiler_47",
    }) |lib| {
        mod.linkSystemLibrary(lib, .{});
    }
}

/// Compile the AVFoundation ObjC shim into `mod` and link the frameworks it
/// needs. Shared by the extension and the decode-smoke harness so the shim
/// path and framework list live in exactly one place. Metal is not included
/// here — only the presenting extension needs it.
fn linkAvfShim(b: *Build, mod: *Build.Module) void {
    mod.addCSourceFile(.{ .file = b.path("src/avf/avf_shim.m"), .flags = &.{"-fobjc-arc"} });
    for ([_][]const u8{ "Foundation", "AVFoundation", "CoreMedia", "CoreVideo" }) |fw| {
        mod.linkFramework(fw, .{});
    }
}
