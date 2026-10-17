const std = @import("std");
const Build = std.Build;
const gdzig = @import("gdzig");

pub fn build(b: *Build) !void {
    const target = b.standardTargetOptions(.{});
    switch (target.result.os.tag) {
        .linux, .windows, .macos, .ios => {},
        else => return error.UnsupportedPlatform,
    }
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Prioritize performance, safety, or binary size") orelse .fast;
    // gdzig no longer downloads Godot: it resolves the executable from
    // -Dgodot-path, then GODOT_PATH, then `godot` on PATH, and panics at
    // configure time if none of them hit. The binary is only used to run the
    // demo and the smoke step -- bindings come from the Godot API description
    // gdzig vendors -- but the lookup happens unconditionally, so every build
    // host needs a Godot on hand.
    const env_godot = b.graph.environ_map.get("GODOT_PATH");
    const opt_godot_path = b.option([]const u8, "godot-path", "Path to a Godot executable") orelse env_godot;
    // Precision must match the Godot build the extension loads into: gdzig bakes
    // the Variant/real_t layout in at compile time, so a `float` extension is a
    // memory-layout mismatch in a `double` Godot. Prebuilt binaries ship `float`;
    // double-precision users build from source with `-Dprecision=double`.
    const opt_precision = b.option([]const u8, "precision", "Floating point precision, `float` or `double` [default: `float`]") orelse "float";

    // --- Core: pure Zig, no Godot dependency. ---
    const core_mod = b.createModule(.{
        .root_source_file = b.path("src/core/core.zig"),
        .target = target,
        .optimize = optimize,
    });

    const core_tests = b.addTest(.{ .root_module = core_mod });
    const test_step = b.step("test", "Run core, platform backend, and pure importer tests (build resolves a Godot binary)");
    test_step.dependOn(&b.addRunArtifact(core_tests).step);

    const paused_preview_mod = b.createModule(.{
        .root_source_file = b.path("tools/core_paused_preview_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "core", .module = core_mod }},
    });
    const paused_preview_tests = b.addTest(.{
        .root_module = paused_preview_mod,
        .filters = &.{"paused preview:"},
    });
    const paused_preview_run = b.addRunArtifact(paused_preview_tests);
    b.step("test-paused-preview", "Run focused core paused-seek preview tests").dependOn(&paused_preview_run.step);
    test_step.dependOn(&paused_preview_run.step);

    const fixture_pts_mod = b.createModule(.{
        .root_source_file = b.path("tools/linux_fixture_pts.zig"),
        .target = target,
        .optimize = optimize,
    });
    const fixture_pts_tests = b.addTest(.{ .root_module = fixture_pts_mod });
    const fixture_pts_run = b.addRunArtifact(fixture_pts_tests);
    b.step("test-linux-fixture-pts", "Run indexed Linux fixture PTS oracle tests").dependOn(&fixture_pts_run.step);
    test_step.dependOn(&fixture_pts_run.step);

    // Windows import-path selector: lives in src/godot/ (it picks between the
    // D3D12 zero-copy and CPU-copy surface importers) but is a pure function
    // with zero Godot dependencies, so its tests run standalone here rather
    // than needing the full extension build.
    const importer_selector_mod = b.createModule(.{
        .root_source_file = b.path("src/godot/importer_selector.zig"),
        .target = target,
        .optimize = optimize,
    });
    const importer_selector_tests = b.addTest(.{ .root_module = importer_selector_mod });
    test_step.dependOn(&b.addRunArtifact(importer_selector_tests).step);

    // Preview submission/retry ownership is pure policy: test delayed importer
    // tokens and retained-frame release without Godot or platform backends.
    const preview_presentation_mod = b.createModule(.{
        .root_source_file = b.path("src/godot/preview_presentation.zig"),
        .target = target,
        .optimize = optimize,
    });
    const preview_presentation_tests = b.addTest(.{ .root_module = preview_presentation_mod });
    const preview_presentation_run = b.addRunArtifact(preview_presentation_tests);
    b.step("test-preview-presentation", "Run pure paused-preview presentation policy tests").dependOn(&preview_presentation_run.step);
    test_step.dependOn(&preview_presentation_run.step);

    // Shared CPU plane packing is pure Zig: exercise independent strides and
    // P010/x420 normalization without a RenderingDevice or platform runtime.
    const packing_mod = b.createModule(.{
        .root_source_file = b.path("src/godot/cpu_plane_packing.zig"),
        .target = target,
        .optimize = optimize,
    });
    const packing_tests = b.addTest(.{ .root_module = packing_mod });
    const packing_run = b.addRunArtifact(packing_tests);
    b.step("test-cpu-packing", "Run pure shared CPU plane packing tests").dependOn(&packing_run.step);
    b.step("test-linux-packing", "Alias for test-cpu-packing").dependOn(&packing_run.step);
    test_step.dependOn(&packing_run.step);

    // --- Media Foundation Windows bindings (Windows only). ---
    // Hand-written OS bindings layer that the eventual MF decoder backend and
    // the D3D11/D3D12 surface importers build on. Its own module so the future
    // backend can import "core" without escaping a module root, mirroring how
    // avf_mod is wired below. The runtime bindings test is folded into the main
    // `test` step; it exercises real MF + D3D11 objects, so it needs Windows and
    // a D3D11-capable GPU (it SkipZigTests when no device is available).
    // Held past the Windows block so the Godot extension below can wire it into
    // ext_mod as the "mf" import (the D3D11/D3D12 surface importers reach the
    // bindings through `@import("mf").win`). Null off Windows.
    var mf_mod: ?*Build.Module = null;
    if (target.result.os.tag == .windows) {
        const m = b.createModule(.{
            .root_source_file = b.path("src/mf/mf.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "core", .module = core_mod },
            },
        });
        linkMfLibs(m);
        mf_mod = m;
        const mf_tests = b.addTest(.{ .root_module = m });
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
        smoke_run.addPassthruArgs();
        b.step("decode-smoke", "Pump the MF backend without Godot (pass a media path via -- <path>)").dependOn(&smoke_run.step);
    }

    // --- GStreamer Linux backend, shared by the extension and CLI harness. ---
    var gst_mod: ?*Build.Module = null;
    if (target.result.os.tag == .linux) {
        const m = b.createModule(.{
            .root_source_file = b.path("src/gst/gst_backend.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "core", .module = core_mod }},
        });
        m.addIncludePath(b.path("src/gst"));
        m.addCSourceFile(.{ .file = b.path("src/gst/gst_shim.c"), .flags = &.{"-std=c11"} });
        linkGstLibs(m);
        gst_mod = m;

        const gst_tests = b.addTest(.{ .root_module = m });
        const gst_test_run = b.addRunArtifact(gst_tests);
        b.step("test-gst", "Run Linux GStreamer backend tests").dependOn(&gst_test_run.step);
        test_step.dependOn(&gst_test_run.step);

        const smoke_mod = b.createModule(.{
            .root_source_file = b.path("src/gst/decode_smoke.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "core", .module = core_mod },
                .{ .name = "gst", .module = m },
            },
        });
        linkGstLibs(smoke_mod);
        const smoke_exe = b.addExecutable(.{ .name = "decode-smoke", .root_module = smoke_mod });
        const smoke_run = b.addRunArtifact(smoke_exe);
        smoke_run.addPassthruArgs();
        b.step("decode-smoke", "Pump the GStreamer backend without Godot (pass a media path via -- <path>)").dependOn(&smoke_run.step);

        const regression_mod = b.createModule(.{
            .root_source_file = b.path("tools/linux_decode_regression.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "core", .module = core_mod },
                .{ .name = "gst", .module = m },
            },
        });
        linkGstLibs(regression_mod);
        const regression_exe = b.addExecutable(.{ .name = "linux-decode-regression", .root_module = regression_mod });
        const regression_run = b.addRunArtifact(regression_exe);
        regression_run.addPassthruArgs();
        b.step("linux-decode-regression", "Run the Linux backend acceptance harness (pass fixture arguments after --)").dependOn(&regression_run.step);
    }

    // --- Godot extension: gdzig glue + the target's media backend. ---
    // Hand gdzig an explicit path when we have one; otherwise let it find
    // `godot` on PATH itself.
    const gdzig_dep = if (opt_godot_path) |p| b.dependency("gdzig", .{
        .target = target,
        .optimize = optimize,
        .precision = opt_precision,
        .@"godot-path" = p,
    }) else b.dependency("gdzig", .{
        .target = target,
        .optimize = optimize,
        .precision = opt_precision,
    });

    // AVFoundation is Apple-only, not a fallback for every non-Windows OS.
    const avf_mod = if (target.result.os.tag == .macos or target.result.os.tag == .ios) b.createModule(.{
        .root_source_file = b.path("src/avf/avf_backend.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core", .module = core_mod },
        },
    }) else null;

    const ext_mod = b.createModule(.{
        .root_source_file = b.path("src/godot/extension.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "godot", .module = gdzig_dep.module("gdzig") },
            .{ .name = "core", .module = core_mod },
        },
    });

    // Backend seam: the surface importers and backend-open path resolve their
    // platform module by name. Wire exactly the one the target uses so the
    // comptime switch in native_video_stream_playback.zig has its import.
    if (mf_mod) |m| ext_mod.addImport("mf", m);
    if (avf_mod) |m| ext_mod.addImport("avf", m);
    if (gst_mod) |m| {
        ext_mod.addImport("gst", m);
        linkGstLibs(ext_mod);
    }

    const extension = gdzig.addExtension(b, .{
        .name = "native_video",
        .root_module = ext_mod,
        .entry_symbol = "native_video_init",
        .minimum_initialization_level = .scene,
        .target = target,
        .optimize = optimize,
    }) orelse return;

    if (optimize == .fast or optimize == .small) {
        extension.compile.root_module.strip = true;
        extension.compile.link_gc_sections = true;
    }

    // AVFoundation ObjC shim + frameworks (macOS and iOS — the shim uses only
    // cross-platform AVFoundation/CoreMedia/CoreVideo APIs). Metal is
    // extension-only — the decode harness never presents.
    if (target.result.os.tag == .macos or target.result.os.tag == .ios) {
        addAppleSdkPaths(b, extension.compile.root_module, target);
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
        addAppleSdkPaths(b, smoke_mod, target);
        linkAvfShim(b, smoke_mod);
        const smoke_exe = b.addExecutable(.{ .name = "decode-smoke", .root_module = smoke_mod });
        const smoke_run = b.addRunArtifact(smoke_exe);
        smoke_run.addFileArg(b.path("project/synthetic.mp4"));
        b.step("decode-smoke", "Pump the AVF backend without Godot").dependOn(&smoke_run.step);
    }

    const install = b.addInstallFileWithDir(extension.output, .{ .custom = "../project/lib" }, extension.filename);
    b.default_step.dependOn(&install.step);

    const run = Build.Step.Run.create(b, "run godot demo");
    run.addFileArg(gdzig_dep.namedLazyPath("godot"));
    run.addArg("--path");
    run.addDirectoryArg(b.path("./project"));
    run.addArg("--");
    run.addPassthruArgs();
    run.step.dependOn(&install.step);
    b.step("run", "Run the demo project in Godot (forwards `-- <args>` to the demo's CLI, e.g. a clip path or --file=<path>)").dependOn(&run.step);

    // Pass/fail presentation smoke. This intentionally uses the real display
    // driver: Godot's headless driver has no RenderingDevice and therefore
    // cannot exercise texture import or the conversion shader.
    const smoke = Build.Step.Run.create(b, "run godot demo smoke test");
    smoke.addFileArg(gdzig_dep.namedLazyPath("godot"));
    smoke.addArg("--path");
    smoke.addDirectoryArg(b.path("./project"));
    // The Linux CI/render smoke checks textures and mixer progress, not an
    // audio device. Avoid unrelated ALSA/PulseAudio failures on build hosts.
    if (target.result.os.tag == .linux) smoke.addArgs(&.{ "--audio-driver", "Dummy" });
    smoke.addArgs(&.{ "--", "--smoke" });
    smoke.step.dependOn(&install.step);
    b.step("smoke", "Run the demo project's --smoke pass/fail check (requires display/GPU)").dependOn(&smoke.step);
}

/// Resolve both headers (including @cImport translation) and link flags from
/// the same pkg-config packages. GStreamer is a system dependency on Linux;
/// forcing pkg-config prevents a missing development package going unnoticed.
/// The backend module carries this configuration into tests and the extension.
pub fn linkGstLibs(mod: *Build.Module) void {
    mod.link_libc = true;
    for ([_][]const u8{
        "gstreamer-1.0",       "gstreamer-app-1.0",     "gstreamer-video-1.0",
        "gstreamer-audio-1.0", "gstreamer-pbutils-1.0",
    }) |lib| {
        mod.linkSystemLibrary(lib, .{ .use_pkg_config = .force });
    }
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

/// Add the Apple SDK's framework/library/include search paths to `mod`.
///
/// Zig 0.16 only auto-adds these for the fully-native default target query;
/// any explicit `-Dtarget=...macos`/`...ios` disables that autodetection, so
/// framework lookups (Foundation, AVFoundation, ...) and libobjc fail to
/// resolve. Derive the active SDK path from `xcrun` at build time (never
/// hardcode it — SDK locations vary across Xcode/Command Line Tools installs)
/// and wire it in explicitly. Picks the macOS SDK or the iOS (device) SDK
/// based on the target's OS tag.
fn addAppleSdkPaths(b: *Build, mod: *Build.Module, target: Build.ResolvedTarget) void {
    const sdk = switch (target.result.os.tag) {
        .ios => std.mem.trim(u8, b.run(&.{ "xcrun", "--sdk", "iphoneos", "--show-sdk-path" }), " \n"),
        else => std.mem.trim(u8, b.run(&.{ "xcrun", "--show-sdk-path" }), " \n"),
    };
    mod.addSystemFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "System/Library/Frameworks" }) });
    mod.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/lib" }) });
    mod.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/include" }) });
}
