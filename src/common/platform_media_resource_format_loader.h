#pragma once

// -----------------------------------------------------------------------
// platform_media_resource_format_loader.h — loads a clip path into a
// PlatformVideoStream resource so VideoStreamPlayer can play it.
//
// Registered with ResourceLoader for the video container extensions the OS
// decodes (mp4/mov/m4v). It does NOT decode anything here — it just produces a
// VideoStream pointing at the file; decoding happens lazily in the playback.
// -----------------------------------------------------------------------

#include <godot_cpp/classes/resource_format_loader.hpp>

namespace godot {

class PlatformMediaResourceFormatLoader : public ResourceFormatLoader {
	GDCLASS(PlatformMediaResourceFormatLoader, ResourceFormatLoader)

public:
	PackedStringArray _get_recognized_extensions() const override;
	bool _handles_type(const StringName &type) const override;
	String _get_resource_type(const String &path) const override;
	Variant _load(const String &path, const String &original_path,
			bool use_sub_threads, int32_t cache_mode) const override;

protected:
	static void _bind_methods();
};

} // namespace godot
