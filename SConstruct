#!/usr/bin/env python
import os
import sys


libname = "native-video"
projectdir = "demo"

localEnv = Environment(tools=["default"], PLATFORM="")

# Build profiles can be used to decrease compile times.
# You can either specify "disabled_classes", OR
# explicitly specify "enabled_classes" which disables all other classes.
# Modify the example file as needed and uncomment the line below or
# manually specify the build_profile parameter when running SCons.

# NOTE: godot-cpp expands base classes automatically, but it PRUNES any binding
# method whose signature references a class missing from `enabled_classes` — so
# the profile must name every engine class our code calls into or passes around,
# including types that appear only in signatures (e.g. compute_pipeline_create
# needs RDPipelineSpecializationConstant). godot-cpp's own sources additionally
# require OS. When adding a new engine-class usage, add it to build_profile.json
# or the corresponding binding method silently vanishes and the build fails on
# that call site.
localEnv["build_profile"] = "build_profile.json"

customs = ["custom.py"]
customs = [os.path.abspath(path) for path in customs]

opts = Variables(customs, ARGUMENTS)
opts.Update(localEnv)

Help(opts.GenerateHelpText(localEnv))

env = localEnv.Clone()

# -----------------------------------------------------------------------
# core_tests target — Engine Core unit tests with NO godot-cpp dependency.
# Build:  scons target=core_tests
# Run:    ./bin/core_tests
# -----------------------------------------------------------------------
if ARGUMENTS.get("target", "") == "core_tests":
    core_env = Environment(tools=["default"])
    if sys.platform == "win32":
        core_env.Append(CXXFLAGS=["/std:c++20", "/EHsc", "/W4"])
    else:
        core_env.Append(CXXFLAGS=["-std=c++20", "-Wall", "-Wextra"])
    core_env.Append(CPPPATH=["#src/core", "#src/common", "#tests/core/vendor"])
    # Embed the NV12->RGB compute shader source into a test-only header so
    # test_color_matrix.cpp can regression-test the actual shader SOURCE TEXT
    # (not just a hand-reimplemented C++ reference) against the ITU-derived
    # coefficients. Only the SDR variant is embedded — the SDR and HDR headers
    # both come from this same nv12_to_rgb.glsl source (differing only in the
    # injected HDR_OUTPUT define), so the matrix-selection code under test is
    # identical between them.
    python_exe = '"%s"' % sys.executable
    shader_header_dir = "build/gen_tests/src/common"
    shader_header = shader_header_dir + "/nv12_to_rgb_shader.h"
    shader_header_target = core_env.Command(
        target=shader_header,
        source="src/common/nv12_to_rgb.glsl",
        action=python_exe + " tools/embed_shader.py $SOURCE $TARGET",
    )
    core_env.Depends(shader_header, "src/common/hdr_color_math.glsl")
    core_env.Append(CPPPATH=[shader_header_dir])
    core_sources = [
        "tests/core/main.cpp",
        "tests/core/test_frame_queue.cpp",
        "tests/core/test_clock.cpp",
        "tests/core/test_retire_ring.cpp",
        "tests/core/test_present_selector.cpp",
        "tests/core/test_audio_ring.cpp",
        "tests/core/test_channel_mixer.cpp",
        "tests/core/test_marker_clip.cpp",
        "tests/core/test_av_drift.cpp",
        "tests/core/test_audio_eos_fallback.cpp",
        "tests/core/test_decode_scheduler.cpp",
        "tests/core/test_scrubber.cpp",
        "tests/core/test_color_matrix.cpp",
        "tests/core/test_hdr_color_math.cpp",
        "tests/core/test_colorimetry.cpp",
        "tests/core/test_push_constant.cpp",
        "tests/core/test_surface_importer_factory.cpp",
        "tests/core/test_playback_controller.cpp",
        "src/core/decode_scheduler.cpp",
        "src/core/backend.cpp",
        "src/core/playback_controller.cpp",
        "src/core/canonical_mix_format.cpp",
    ]
    # The force-synchronous lifetime-debug mode is gated behind NATIVE_VIDEO_DEBUG.
    # Define it for the headless core tests so the force-sync test compiles/runs.
    core_env.Append(CPPDEFINES=["NATIVE_VIDEO_DEBUG"])
    # The scheduler spins up worker threads. MSVC's std::thread needs no extra
    # library; everywhere else link pthread.
    if sys.platform != "win32":
        core_env.Append(LIBS=["pthread"])
    # Sanitizer flavors of the core tests (mutually exclusive):
    #   scons target=core_tests asan=yes   — ASan + UBSan (MSVC: ASan only);
    #                                        proves e.g. the retire-ring is
    #                                        use-after-free clean.
    #   scons target=core_tests tsan=yes   — TSan (GCC/Clang only); the
    #                                        scheduler/frame-queue tests spin
    #                                        real threads, so races surface.
    want_asan = ARGUMENTS.get("asan", "") in ("1", "yes", "true")
    want_tsan = ARGUMENTS.get("tsan", "") in ("1", "yes", "true")
    if want_asan and want_tsan:
        print("asan=yes and tsan=yes are mutually exclusive — pick one.")
        Exit(1)
    if want_asan:
        if sys.platform == "win32":
            core_env.Append(CXXFLAGS=["/fsanitize=address", "/Zi"])
        else:
            # -fno-sanitize-recover makes UBSan findings fatal (non-zero exit)
            # instead of printed-and-continued, so CI actually fails.
            san = ["-fsanitize=address,undefined", "-fno-sanitize-recover=all"]
            core_env.Append(CXXFLAGS=san + ["-fno-omit-frame-pointer", "-g"])
            core_env.Append(LINKFLAGS=san)
    if want_tsan:
        if sys.platform == "win32":
            print("tsan=yes is not supported by MSVC; use a GCC/Clang host.")
            Exit(1)
        core_env.Append(CXXFLAGS=["-fsanitize=thread", "-fno-omit-frame-pointer", "-g"])
        core_env.Append(LINKFLAGS=["-fsanitize=thread"])
    core_tests = core_env.Program("bin/core_tests", core_sources)
    # Belt-and-suspenders: make sure the generated shader header exists before
    # anything in core_tests compiles. The implicit CPPPATH include scanner
    # normally finds this on its own once the Command node is in the graph,
    # but an explicit Depends is cheap insurance for a clean build.
    core_env.Depends(core_tests, shader_header_target)
    Default(core_tests)
    # Skip the rest — godot-cpp is not needed.
    Return()

# -----------------------------------------------------------------------
# avf_tests target — AVFoundation Backend headless integration test.
# Pure C++/ObjC++ + macOS frameworks; NO godot-cpp, NO RenderingDevice.
# Build:  scons target=avf_tests
# Run:    ./bin/avf_tests
# -----------------------------------------------------------------------
if ARGUMENTS.get("target", "") == "avf_tests":
    avf_env = Environment(tools=["default"])
    avf_env.Append(CXXFLAGS=["-std=c++20", "-Wall", "-Wextra", "-fobjc-arc"])
    # Backend sources (#src/core for backend.h), test sources (#tests/core for
    # the vendored "vendor/doctest.h" include; #tests for "common/clip_matrix.h").
    avf_env.Append(CPPPATH=["#src/core", "#src/backends/avf", "#tests/core", "#tests"])
    avf_env.Append(FRAMEWORKS=[
        "Foundation",
        "AVFoundation",
        "CoreMedia",
        "CoreVideo",
        "CoreFoundation",
    ])
    avf_sources = [
        "tests/avf/main.mm",
        "tests/avf/test_avf_backend.mm",
        "tests/avf/test_avf_clip_matrix.mm",
        "src/backends/avf/avf_backend.mm",
        "src/core/backend.cpp",
    ]
    avf_tests = avf_env.Program("bin/avf_tests", avf_sources)
    Default(avf_tests)
    # Skip the rest — godot-cpp is not needed.
    Return()

# -----------------------------------------------------------------------
# mf_tests target — Media Foundation Backend headless integration test.
# WINDOWS ONLY. Pure C++ + MF/D3D11; NO godot-cpp, NO RenderingDevice — the
# decode-to-NV12-D3D11 + PCM contract mirror of avf_tests.
# Build (on Windows):  scons target=mf_tests platform=windows
# Run:                 bin\mf_tests.exe
#
# Guarded so an accidental invocation on a non-Windows host fails loudly with a
# clear message instead of producing a broken binary.
# -----------------------------------------------------------------------
if ARGUMENTS.get("target", "") == "mf_tests":
    if sys.platform != "win32":
        print("mf_tests is Windows-only (Media Foundation + D3D11). "
              "Run it on a Windows host / CI; it cannot be built on this platform.")
        sys.exit(1)
    mf_env = Environment(tools=["default"])
    mf_env.Append(CXXFLAGS=["/std:c++20", "/EHsc"])
    # Backend sources (#src/core for backend.h), test sources (#tests/core for
    # the vendored "vendor/doctest.h" include; #tests for "common/clip_matrix.h").
    mf_env.Append(CPPPATH=["#src/core", "#src/backends/mf", "#tests/core", "#tests"])
    mf_env.Append(CPPDEFINES=["UNICODE", "_UNICODE"])
    mf_env.Append(LIBS=[
        "mfplat", "mf", "mfreadwrite", "mfuuid",
        "d3d11", "dxgi", "ole32", "shlwapi", "propsys",
    ])
    mf_sources = [
        "tests/mf/main.cpp",
        "tests/mf/test_mf_backend.cpp",
        "tests/mf/test_mf_clip_matrix.cpp",
        "src/backends/mf/mf_backend.cpp",
        "src/backends/mf/mf_audio.cpp",
        "src/core/backend.cpp",
    ]
    mf_tests = mf_env.Program("bin/mf_tests", mf_sources)
    Default(mf_tests)
    # Skip the rest — godot-cpp is not needed.
    Return()

if not (os.path.isdir("godot-cpp") and os.listdir("godot-cpp")):
    print("""godot-cpp is not available within this folder, as Git submodules haven't been initialized.
Run the following command to download godot-cpp:

    git submodule update --init --recursive""")
    sys.exit(1)

env = SConscript("godot-cpp/SConstruct", {"env": env, "customs": customs}, variant_dir="build/godot-cpp")

env.VariantDir("build/src", "src", duplicate=0)

# -----------------------------------------------------------------------
# Embed the authored NV12->RGB compute shader into C++ headers at build
# time so the .glsl file is the single source of truth. The SDR and HDR
# headers are both generated from the SAME nv12_to_rgb.glsl source, embedded
# twice with different preprocessor defines to select the output variant.
# -----------------------------------------------------------------------
# Run the embed script with the same interpreter that runs SCons — `python3`
# is not on PATH on stock Windows (the Store stub shadows it).
python_exe = '"%s"' % sys.executable
shader_header = "build/gen/src/common/nv12_to_rgb_shader.h"
env.Command(
    target=shader_header,
    source="src/common/nv12_to_rgb.glsl",
    action=python_exe + " tools/embed_shader.py $SOURCE $TARGET",
)
# Track the included hdr_color_math.glsl as a dependency so the shader
# header is regenerated when it changes.
env.Depends(shader_header, "src/common/hdr_color_math.glsl")

# HDR variant: the same nv12_to_rgb.glsl source, embedded with HDR_OUTPUT=1
# injected after the #version line, selecting the RGBA16F/scene-linear
# (no tone-map) code paths instead of the SDR rgba8 tone-mapped ones.
shader_hdr_header = "build/gen/src/common/nv12_to_rgb_hdr_shader.h"
env.Command(
    target=shader_hdr_header,
    source="src/common/nv12_to_rgb.glsl",
    action=python_exe + " tools/embed_shader.py $SOURCE $TARGET kNv12ToRgbHdrCompute -D HDR_OUTPUT=1",
)
env.Depends(shader_hdr_header, "src/common/hdr_color_math.glsl")

# Add source files
env.Append(CPPPATH=["src/", "build/gen/src"])
sources = ["build/src/register_types.cpp"]

# Engine Core C++ sources that are not platform backends (no godot-cpp / RD deps).
# The shared decode-worker pool lives in src/core and MUST be linked into the
# library — the binding references DecodeScheduler::instance(). Without this the
# macOS dylib links under -undefined,dynamic_lookup with the scheduler symbols
# unresolved and crashes at runtime the moment a video plays.
env.VariantDir("build/src/core", "src/core", duplicate=0)
sources.extend(Glob("build/src/core/*.cpp"))

# Force-synchronous lifetime-debug mode is gated behind NATIVE_VIDEO_DEBUG; it
# is compiled in for debug builds only and stays out of template_release so the
# synchronous decode path can never run in a shipped binary.
if env["target"] == "template_debug" or env["target"] == "editor":
    env.Append(CPPDEFINES=["NATIVE_VIDEO_DEBUG"])

# Add Binding source files (src/common — the Godot adapter layer). Both plain
# C++ (.cpp) and Objective-C++ (.mm, e.g. the Metal surface importer) live here.
sources.extend(Glob("build/src/common/*.cpp"))
sources.extend(Glob("build/src/common/**/*.cpp"))

# Platform-specific configurations
if env["platform"] == "macos" or env["platform"] == "ios":
    # Add the Engine Core AVFoundation Backend (src/backends/avf) and any
    # Objective-C++ Binding sources (src/common, e.g. the Metal importer).
    sources.extend(Glob("build/src/backends/avf/*.mm"))
    sources.extend(Glob("build/src/common/*.mm"))

    # CPPPATH so the binding can include the core + backend headers by relative
    # path and godot-cpp headers resolve as usual.
    env.Append(CPPPATH=["src/core", "src/backends/avf"])

    # Frameworks: AVFoundation/CoreMedia for decode; CoreVideo for the
    # CVPixelBuffer/CVMetalTextureCache zero-copy import; Metal/QuartzCore for the
    # MTLDevice/MTLTexture present path; CoreFoundation for CF retain/release.
    env.Append(FRAMEWORKS=[
        "AVFoundation", "CoreMedia", "CoreVideo", "MediaToolbox",
        "Metal", "QuartzCore", "CoreFoundation", "Foundation",
    ])

    # Use dynamic symbol lookup
    env.Append(LINKFLAGS=["-Wl,-undefined,dynamic_lookup"])

    # Enable Objective-C++ ARC.
    env.Append(CXXFLAGS=["-fobjc-arc"])
elif env["platform"] == "windows":
    # Add the Engine Core Media Foundation Backend (src/backends/mf). The Binding
    # sources (src/common/*.cpp) — including the DXGI->Vulkan surface importer and
    # the Windows backend factory — are already globbed above; their bodies are
    # guarded by #if _WIN32 so they only emit code on Windows.
    sources.extend(Glob("build/src/backends/mf/*.cpp"))

    # CPPPATH so the binding can include the core + MF backend headers by relative
    # path (mirrors the macOS block).
    env.Append(CPPPATH=["src/core", "src/backends/mf"])

    # The DXGI->Vulkan importer needs vulkan/vulkan.h, vendored as the
    # thirdparty/vulkan-headers submodule. Headers only — the importer loads
    # vulkan-1.dll at runtime (VK_NO_PROTOTYPES), so no Vulkan SDK and no
    # vulkan-1.lib are needed to build.
    if not os.path.isfile("thirdparty/vulkan-headers/include/vulkan/vulkan.h"):
        print("""thirdparty/vulkan-headers is missing. Run:

    git submodule update --init --recursive""")
        sys.exit(1)
    env.Append(CPPPATH=["#thirdparty/vulkan-headers/include"])

    # Libraries:
    #   mfplat/mf/mfreadwrite/mfuuid : Media Foundation source reader + decode.
    #   d3d11/dxgi                   : D3D11 device + DXGI shared-handle interop.
    #   d3d12                        : D3D12SurfaceImporter's OpenSharedHandle path.
    #   d3dcompiler                  : runtime HLSL compile for the D3D11 plane-split
    #                                  compute shader (D3D12SurfaceImporter).
    #   ole32/propsys/shlwapi        : COM init + PROPVARIANT helpers + path utils.
    # No Vulkan loader here: the DXGI->Vulkan importer resolves vulkan-1.dll
    # at runtime.
    env.Append(LIBS=[
        "mfplat", "mf", "mfreadwrite", "mfuuid",
        "d3d11", "dxgi", "d3d12", "d3dcompiler", "ole32", "shlwapi", "propsys",
    ])

    # Enable Unicode for Windows API.
    env.Append(CPPDEFINES=["UNICODE", "_UNICODE"])

if env["target"] in ["editor", "template_debug"]:
    try:
        doc_data = env.GodotCPPDocData("build/src/gen/doc_data.gen.cpp", source=Glob("doc_classes/*.xml"))
        sources.append(doc_data)
    except AttributeError:
        print("Not including class reference as we're targeting a pre-4.3 baseline.")

# .dev doesn't inhibit compatibility, so we don't need to key it.
# .universal just means "compatible with all relevant arches" so we don't need to key it.
suffix = env['suffix'].replace(".dev", "").replace(".universal", "")

lib_filename = "{}{}{}{}".format(env.subst('$SHLIBPREFIX'), libname, suffix, env.subst('$SHLIBSUFFIX'))

library = env.SharedLibrary(
    "bin/{}/{}".format(env['platform'], lib_filename),
    source=sources,
)

copy = env.Install("{}/addons/native-video/{}/".format(projectdir, env["platform"]), library)
smoke_copy = env.Install("tests/headless-smoke/addons/native-video/{}/".format(env["platform"]), library)

default_args = [library, copy, smoke_copy]
Default(*default_args)