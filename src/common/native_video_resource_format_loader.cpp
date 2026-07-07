// -----------------------------------------------------------------------
// native_video_resource_format_loader.cpp — see header.
// -----------------------------------------------------------------------

#include "native_video_resource_format_loader.h"
#include "native_video_stream.h"

#include <godot_cpp/core/class_db.hpp>

using namespace godot;

void NativeVideoResourceFormatLoader::_bind_methods() {}

PackedStringArray NativeVideoResourceFormatLoader::_get_recognized_extensions() const {
	PackedStringArray exts;
	// Containers AVFoundation decodes on macOS. v1 contract is 8-bit SDR
	// H.264/HEVC in MP4/MOV (v1 format scope).
	exts.push_back("mp4");
	exts.push_back("mov");
	exts.push_back("m4v");
	return exts;
}

bool NativeVideoResourceFormatLoader::_handles_type(const StringName &type) const {
	const String t = String(type);
	return t == String("VideoStream") || t == String("NativeVideoStream");
}

String NativeVideoResourceFormatLoader::_get_resource_type(const String &path) const {
	const String ext = path.get_extension().to_lower();
	if (ext == "mp4" || ext == "mov" || ext == "m4v") {
		return String("NativeVideoStream");
	}
	return String();
}

Variant NativeVideoResourceFormatLoader::_load(const String &path,
		const String & /*original_path*/, bool /*use_sub_threads*/,
		int32_t /*cache_mode*/) const {
	Ref<NativeVideoStream> stream;
	stream.instantiate();
	// Record the path; the playback opens the backend lazily on instantiate.
	stream->set_file(path);
	return stream;
}
