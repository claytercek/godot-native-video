# Platform Media Streams for Godot

A high-performance GDExtension that provides native media playback for Godot Engine using platform-specific system APIs. Instead of relying on software decoders or cross-platform abstractions, this extension uses each platform's native media frameworks like AVFoundation (macOS/iOS) and Windows Media Foundation (Windows).

## Features

- **Native system integration** using platform-specific media APIs
- **Wide format support** - play any format your OS can handle, not just Theora/OGV
- **Better performance** compared to software decoders like FFmpeg or built-in Theora
- **Optimal battery life** on mobile devices through system-level optimizations
- **Modern codec support** including H.264, HEVC, VP9, and platform-specific formats (dependent on platform)
- **Seamless integration** with Godot's existing VideoStreamPlayer workflow

## Why Choose Platform Media Streams?

**vs. Built-in Theora VideoStream:**
- Support for modern formats (MP4, MOV, etc.) instead of just OGV/Theora
- Better performance and battery life through native system decoders
- Wider codec support (H.264, HEVC, etc.)

**vs. FFmpeg-based solutions:**
- No large FFmpeg dependency to bundle with your game
- Leverages optimized system decoders that are already present on the target platform
- Better integration with platform-specific features and optimizations
- Smaller final binary size

## Platform Support

### ✅ Currently Supported
- **macOS** - AVFoundation implementation
- **iOS** - AVFoundation implementation

### 🚧 Planned Support
- **Windows** - Windows Media Foundation implementation (in development)
- **Linux** - GStreamer implementation (planned)
- **Android** - MediaPlayer/ExoPlayer implementation (planned)

## Requirements

- **Godot 4.4+** - This extension requires Godot Engine version 4.4 or later
- **Platform-specific dependencies** are automatically linked (AVFoundation, etc.)

## Installation

TODO

## Supported Formats

Supported media formats depend on the target platform's native capabilities:

- **macOS/iOS**: MP4, MOV, M4V, 3GP, and all other formats supported by AVFoundation
- **Windows**: MP4, AVI, WMV, and all other formats supported by Windows Media Foundation

---

## Development & Contributing

### Building from Source

1. **Initialize submodules**:
   ```bash
   git submodule update --init --recursive
   ```

2. **Build for your platform**:
   ```bash
   scons target=template_debug platform=[macos|ios|windows]
   ```

3. **Test your changes**:
   ```bash
   godot --path project/
   ```

### Repository Structure

- `src/` - Source code
  - `common/` - Platform-agnostic code and interfaces
  - `platforms/avf/` - AVFoundation implementation (macOS/iOS)
  - `platforms/wmf/` - Windows Media Foundation implementation (planned)
- `demo/` - Test Godot project
- `godot-cpp/` - Godot C++ bindings (submodule)
