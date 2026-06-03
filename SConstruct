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
    core_env.Append(CXXFLAGS=["-std=c++20", "-Wall", "-Wextra"])
    core_env.Append(CPPPATH=["#src/core", "#tests/core/vendor"])
    core_sources = [
        "tests/core/main.cpp",
        "tests/core/test_frame_queue.cpp",
        "tests/core/test_clock.cpp",
        "tests/core/test_retire_ring.cpp",
    ]
    # Allow an ASan build of the core tests to prove the retire-ring is
    # use-after-free clean:  scons target=core_tests asan=yes
    if ARGUMENTS.get("asan", "") in ("1", "yes", "true"):
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
    # the vendored "vendor/doctest.h" include).
    avf_env.Append(CPPPATH=["#src/core", "#src/backends/avf", "#tests/core"])
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
        "src/backends/avf/avf_backend.mm",
    ]
    avf_tests = avf_env.Program("bin/avf_tests", avf_sources)
    Default(avf_tests)
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
    # Add Windows Media Foundation source files
    sources.extend(Glob("build/src/platform/wmf/*.cpp"))
    
    # Add necessary libraries for Windows Media Foundation
    env.Append(LIBS=["mfplat", "mf", "mfreadwrite", "mfuuid", "d3d11", "ole32", "shlwapi"])
    
    # Enable Unicode for Windows API
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