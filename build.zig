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
    // gdzig requires Godot at configure time: -Dgodot-path, then GODOT_PATH,
    // then `godot` on PATH. Only demo/smoke execution uses the binary; bindings
    // come from gdzig's bundled API description, but all builds need the lookup.
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
    const test_step = b.step("test", "Run core, platform backend, importer, and validation runner tests");
    test_step.dependOn(&b.addRunArtifact(core_tests).step);

    const validation_mod = b.createModule(.{
        .root_source_file = b.path("tools/validation_runner.zig"),
        // CI runs this executable on other hosts of the same OS and architecture.
        .target = b.resolveTargetQuery(.{ .cpu_model = .baseline }),
        .optimize = .fast,
    });
    const validation_exe = b.addExecutable(.{ .name = "validation-runner", .root_module = validation_mod });
    const validation_install = b.addInstallArtifact(validation_exe, .{});
    b.step("validation-runner", "Install the host runner for an existing extension build").dependOn(&validation_install.step);
    const validation_tests = b.step("test-validation-runner", "Test the host validation runner");
    validation_tests.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = validation_mod })).step);
    test_step.dependOn(validation_tests);
    const fake_engine = b.addExecutable(.{
        .name = "fake-engine",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/fake_validation_engine.zig"),
            .target = b.graph.host,
        }),
    });
    const validation_test_paths = b.addOptions();
    validation_test_paths.addOptionPath("runner", validation_exe.getEmittedBin());
    validation_test_paths.addOptionPath("engine", fake_engine.getEmittedBin());
    const validation_cli_mod = b.createModule(.{
        .root_source_file = b.path("tests/validation_runner_cli.zig"),
        .target = b.graph.host,
    });
    validation_cli_mod.addOptions("paths", validation_test_paths);
    validation_tests.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = validation_cli_mod })).step);

    const paused_preview_mod = b.createModule(.{
        .root_source_file = b.path("src/core/paused_preview_test.zig"),
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

    // The Windows importer selector is pure Zig despite living in src/godot/;
    // test D3D12/CPU-copy selection without building the extension.
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

    // Windows MF backend and hand-written bindings. Keep the module for the
    // extension's "mf" import; importers reach bindings via @import("mf").win.
    // Runtime tests exercise MF/D3D11 objects, falling back to WARP or skipping
    // if no device is available. Null on other platforms.
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
        // A separate root keeps fixture paths out of the extension's module.
        const mf_test_mod = b.createModule(.{
            .root_source_file = b.path("src/mf/mf.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "core", .module = core_mod }},
        });
        linkMfLibs(mf_test_mod);
        const mf_test_run = b.addRunArtifact(b.addTest(.{ .root_module = mf_test_mod }));
        const mf_fixtures = FixtureInputs.init(mf_test_mod, mf_test_run);
        mf_fixtures.addSurfaceClips();
        test_step.dependOn(&mf_test_run.step);

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
            .root_source_file = b.path("src/gst/linux_decode_regression.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "core", .module = core_mod },
                .{ .name = "gst", .module = m },
            },
        });
        linkGstLibs(regression_mod);
        const regression_exe = b.addExecutable(.{ .name = "gst-input-regressions", .root_module = regression_mod });
        const extended = b.step("test-gst-extended", "Check GStreamer AAC seek accuracy and input rejection");
        const integration_run = b.addRunArtifact(b.addTest(.{ .root_module = regression_mod }));
        const integration_fixtures = FixtureInputs.init(regression_mod, integration_run);
        integration_fixtures.add("multitrack", "decode/h264-multitrack.mp4");
        extended.dependOn(&integration_run.step);
        const rejection_run = b.addRunArtifact(regression_exe);
        rejection_run.addArg("--test-rejections");
        rejection_run.addFileArg(b.path("tests/fixtures/decode/invalid.mp4"));
        extended.dependOn(&rejection_run.step);
        const missing_run = b.addRunArtifact(regression_exe);
        missing_run.addArg("missing-decoder");
        missing_run.addFileArg(b.path("tests/fixtures/decode/h264-aac.mp4"));
        // GStreamer reads decoder ranks at initialization, so isolate this case.
        missing_run.setEnvironmentVariable("GST_PLUGIN_FEATURE_RANK", "avdec_h264:0,openh264dec:0,vah264dec:0,vaapih264dec:0,nvh264dec:0,nvh264sldec:0,v4l2h264dec:0,v4l2slh264dec:0,vulkanh264dec:0");
        extended.dependOn(&missing_run.step);
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

    if (switch (target.result.os.tag) {
        .macos => avf_mod,
        .windows => mf_mod,
        .linux => gst_mod,
        else => null,
    }) |decoder| {
        const media_mod = b.createModule(.{
            .root_source_file = b.path("tests/media_decode.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "decoder", .module = decoder },
                .{ .name = "core", .module = core_mod },
            },
        });
        switch (target.result.os.tag) {
            .macos => {
                addAppleSdkPaths(b, media_mod, target);
                linkAvfShim(b, media_mod);
            },
            .windows => linkMfLibs(media_mod),
            .linux => linkGstLibs(media_mod),
            else => unreachable,
        }
        const media_run = b.addRunArtifact(b.addTest(.{ .root_module = media_mod }));
        const clips = FixtureInputs.init(media_mod, media_run);
        clips.addSurfaceClips();
        clips.add("h264_aac", "decode/h264-aac.mp4");
        clips.add("h264_silent", "decode/h264-silent.mp4");
        clips.add("multitrack", "decode/h264-multitrack.mp4");
        clips.add("surround", "stress/surround51.mp4");
        clips.add("timecode", "stress/timecode.mov");
        clips.add("combined", "stress/combined_stress.mov");
        clips.add("marker", "stress/marker_bframes.mp4");
        if (target.result.os.tag != .windows) clips.add("hevc_pq", "decode/hevc-main10-pq.mp4");
        const linux = target.result.os.tag == .linux;
        const test_vp9 = b.option(bool, "test-vp9", "Require native VP9 MP4 decode in test-media (always on for Linux)") orelse false;
        const test_av1 = b.option(bool, "test-av1", "Require native AV1 MP4 decode in test-media (always on for Linux)") orelse false;
        clips.paths.addOption(bool, "expect_vp9", linux or test_vp9);
        clips.paths.addOption(bool, "expect_av1", linux or test_av1);
        if (linux or test_vp9) {
            clips.add("vp9_8_mp4", "decode/vp9-8.mp4");
            clips.add("vp9_10_mp4", "decode/vp9-10.mp4");
        }
        if (linux or test_av1) {
            clips.add("av1_8_mp4", "decode/av1-8.mp4");
            clips.add("av1_10_mp4", "decode/av1-10.mp4");
        }
        if (linux) {
            clips.add("multitrack_mkv", "decode/h264-multitrack.mkv");
            clips.add("vp9_8_webm", "decode/vp9-8.webm");
            clips.add("vp9_10_webm", "decode/vp9-10.webm");
            clips.add("av1_8_webm", "decode/av1-8.webm");
            clips.add("av1_10_webm", "decode/av1-10.webm");
        }
        b.step("test-media", "Decode the checked-in fixtures with the native backend").dependOn(&media_run.step);
    }

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
            .imports = &.{.{ .name = "core", .module = core_mod }},
        });
        const media_paths = b.addOptions();
        media_paths.addOptionPath("synthetic_clip", b.path("project/synthetic.mp4"));
        smoke_mod.addOptions("media_paths", media_paths);
        addAppleSdkPaths(b, smoke_mod, target);
        linkAvfShim(b, smoke_mod);
        const smoke_exe = b.addExecutable(.{ .name = "decode-smoke", .root_module = smoke_mod });
        const smoke_run = b.addRunArtifact(smoke_exe);
        smoke_run.addPassthruArgs();
        b.step("decode-smoke", "Pump the AVF backend without Godot (optionally pass -- <path>)").dependOn(&smoke_run.step);

        const abi = b.addTest(.{ .root_module = smoke_mod });
        test_step.dependOn(&b.addRunArtifact(abi).step);
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

    const smoke = b.addRunArtifact(validation_exe);
    const codec_smoke = b.addRunArtifact(validation_exe);
    inline for (.{ smoke, codec_smoke }, .{ "smoke.log", "smoke-codecs.log" }) |check, log| {
        check.addArg("--godot");
        check.addFileArg(gdzig_dep.namedLazyPath("godot"));
        check.addArg("--project");
        check.addDirectoryArg(b.path("project"));
        check.addArgs(&.{ "--driver", switch (b.graph.host.result.os.tag) {
            .windows => "d3d12",
            .linux => "vulkan",
            else => "default",
        }, "--log" });
        check.addDirectoryArg2(b.graph.path(.install_prefix, log), .{});
        check.step.dependOn(&install.step);
    }
    smoke.addArg("--");
    smoke.addPassthruArgs();
    smoke.addArgs(&.{ "--", "--smoke" });
    b.step("smoke", "Run the rendered Godot smoke with a deadline and log checks").dependOn(&smoke.step);

    codec_smoke.addArgs(&.{ "--marker", "CODEC_SMOKE_PASS", "--", "--script", "res://codec_smoke.gd", "--" });
    codec_smoke.addPassthruArgs();
    b.step("smoke-codecs", "Render and seek VP9 MP4 (also AV1 WebM on Linux) through the Godot loader").dependOn(&codec_smoke.step);
}

const FixtureInputs = struct {
    run: *Build.Step.Run,
    paths: *Build.Step.Options,

    fn init(mod: *Build.Module, run: *Build.Step.Run) FixtureInputs {
        const paths = run.step.owner.addOptions();
        mod.addOptions("fixtures", paths);
        return .{ .run = run, .paths = paths };
    }

    fn add(inputs: FixtureInputs, name: []const u8, relative_path: []const u8) void {
        const b = inputs.run.step.owner;
        const file = b.path("tests/fixtures").path(b, relative_path);
        // Clip contents affect the run, not compilation of the path string.
        inputs.paths.addOptionPathUntracked(name, file);
        inputs.run.addFileInput(file);
    }

    fn addSurfaceClips(inputs: FixtureInputs) void {
        inputs.add("bframes", "stress/bframes.mp4");
        inputs.add("nonmod16", "stress/nonmod16_854x480.mp4");
    }
};

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
        // Windows import libraries need no pkg-config; avoid broken host wrappers.
        mod.linkSystemLibrary(lib, .{ .use_pkg_config = .no });
    }
}

/// Compile the AVFoundation ObjC shim into `mod` and link the frameworks it
/// needs. Shared by the extension and the decode-smoke harness so the shim
/// path and framework list live in exactly one place. Metal is not included
/// here — only the presenting extension needs it.
fn linkAvfShim(b: *Build, mod: *Build.Module) void {
    mod.addCSourceFile(.{ .file = b.path("src/avf/avf_shim.m"), .flags = &.{"-fobjc-arc"} });
    if (mod.resolved_target.?.result.os.tag == .macos) mod.linkFramework("VideoToolbox", .{});
    for ([_][]const u8{ "Foundation", "AVFoundation", "CoreMedia", "CoreVideo" }) |fw| {
        mod.linkFramework(fw, .{});
    }
}

/// Add framework/library/include paths from xcrun's active macOS or iOS device
/// SDK. Zig 0.16 skips SDK autodetection for explicit `-Dtarget=...macos`/`...ios`;
/// these paths are then required to resolve frameworks and libobjc. Query xcrun
/// rather than hardcoding paths that vary by Xcode/Command Line Tools install.
fn addAppleSdkPaths(b: *Build, mod: *Build.Module, target: Build.ResolvedTarget) void {
    const sdk = switch (target.result.os.tag) {
        .ios => std.mem.trim(u8, b.run(&.{ "xcrun", "--sdk", "iphoneos", "--show-sdk-path" }), " \n"),
        else => std.mem.trim(u8, b.run(&.{ "xcrun", "--show-sdk-path" }), " \n"),
    };
    mod.addSystemFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "System/Library/Frameworks" }) });
    mod.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/lib" }) });
    mod.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/include" }) });
}
