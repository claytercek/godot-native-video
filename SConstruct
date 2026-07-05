#!/usr/bin/env python
import os
import sys


libname = "platform-media-streams"
projectdir = "demo"

localEnv = Environment(tools=["default"], PLATFORM="")

# Build profiles can be used to decrease compile times.
# You can either specify "disabled_classes", OR
# explicitly specify "enabled_classes" which disables all other classes.
# Modify the example file as needed and uncomment the line below or
# manually specify the build_profile parameter when running SCons.

# NOTE: an `enabled_classes` build profile would have to enumerate the full
# transitive closure of every godot-cpp class the present pipeline touches
# (RenderingDevice, RenderingServer, Texture2DRD, the RD* descriptor classes,
# their bases, ...). That is brittle and easy to under-specify, so we build the
# full bindings. Re-introduce a curated profile only once the API surface is
# stable and the closure is verified.
# localEnv["build_profile"] = "build_profile.json"

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
    core_env.Append(CPPPATH=["#src/core", "#tests/core/vendor"])
    core_sources = [
        "tests/core/main.cpp",
        "tests/core/test_frame_queue.cpp",
        "tests/core/test_clock.cpp",
        "tests/core/test_retire_ring.cpp",
        "tests/core/test_present_selector.cpp",
        "tests/core/test_audio_ring.cpp",
        "tests/core/test_av_drift.cpp",
        "tests/core/test_decode_scheduler.cpp",
        "tests/core/test_scrubber.cpp",
        "src/core/decode_scheduler.cpp",
    ]
    # The force-synchronous lifetime-debug mode is gated behind PLATFORM_MEDIA_DEBUG.
    # Define it for the headless core tests so the force-sync test compiles/runs.
    core_env.Append(CPPDEFINES=["PLATFORM_MEDIA_DEBUG"])
    # The scheduler spins up worker threads. MSVC's std::thread needs no extra
    # library; everywhere else link pthread.
    if sys.platform != "win32":
        core_env.Append(LIBS=["pthread"])
    # Allow an ASan build of the core tests to prove the retire-ring is
    # use-after-free clean:  scons target=core_tests asan=yes
    # (MSVC supports /fsanitize=address; GCC/Clang use -fsanitize=address.)
    if ARGUMENTS.get("asan", "") in ("1", "yes", "true"):
        if sys.platform == "win32":
            core_env.Append(CXXFLAGS=["/fsanitize=address", "/Zi"])
        else:
            core_env.Append(CXXFLAGS=["-fsanitize=address", "-fno-omit-frame-pointer", "-g"])
            core_env.Append(LINKFLAGS=["-fsanitize=address"])
    core_tests = core_env.Program("bin/core_tests", core_sources)
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

# Add source files
env.Append(CPPPATH=["src/"])
sources = ["build/src/register_types.cpp"]

# Engine Core C++ sources that are not platform backends (no godot-cpp / RD deps).
# The shared decode-worker pool lives in src/core and MUST be linked into the
# library — the binding references DecodeScheduler::instance(). Without this the
# macOS dylib links under -undefined,dynamic_lookup with the scheduler symbols
# unresolved and crashes at runtime the moment a video plays.
env.VariantDir("build/src/core", "src/core", duplicate=0)
sources.extend(Glob("build/src/core/*.cpp"))

# Force-synchronous lifetime-debug mode is gated behind PLATFORM_MEDIA_DEBUG; it
# is compiled in for debug builds only and stays out of template_release so the
# synchronous decode path can never run in a shipped binary.
if env["target"] == "template_debug" or env["target"] == "editor":
    env.Append(CPPDEFINES=["PLATFORM_MEDIA_DEBUG"])

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

    # The DXGI->Vulkan importer needs the Vulkan headers (vulkan/vulkan.h) and
    # the loader import library (vulkan-1.lib). Neither ships with MSVC, so we
    # pull them from the Vulkan SDK via the VULKAN_SDK env var the SDK installer
    # sets. (Any directory with Include/vulkan/*.h + Lib/vulkan-1.lib works —
    # e.g. the Khronos Vulkan-Headers repo plus an import lib generated from
    # the system vulkan-1.dll.)
    vulkan_sdk = os.environ.get("VULKAN_SDK", "")
    if vulkan_sdk:
        env.Append(CPPPATH=[os.path.join(vulkan_sdk, "Include")])
        env.Append(LIBPATH=[os.path.join(vulkan_sdk, "Lib")])
    else:
        print("WARNING: VULKAN_SDK is not set — vulkan/vulkan.h and vulkan-1.lib "
              "will only resolve if provided some other way. Install the LunarG "
              "Vulkan SDK if the build fails to find them.")

    # Libraries:
    #   mfplat/mf/mfreadwrite/mfuuid : Media Foundation source reader + decode.
    #   d3d11/dxgi                   : D3D11 device + DXGI shared-handle interop.
    #   d3d12                        : D3D12SurfaceImporter's OpenSharedHandle path.
    #   d3dcompiler                  : runtime HLSL compile for the D3D11 plane-split
    #                                  compute shader (D3D12SurfaceImporter).
    #   ole32/propsys/shlwapi        : COM init + PROPVARIANT helpers + path utils.
    # The Vulkan loader (vulkan-1) is needed by the DXGI->Vulkan importer; it is
    # provided by the Vulkan SDK. If godot-cpp already links the loader this is
    # redundant but harmless.
    env.Append(LIBS=[
        "mfplat", "mf", "mfreadwrite", "mfuuid",
        "d3d11", "dxgi", "d3d12", "d3dcompiler", "ole32", "shlwapi", "propsys",
        "vulkan-1",
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

copy = env.Install("{}/bin/{}/".format(projectdir, env["platform"]), library)

default_args = [library, copy]
Default(*default_args)