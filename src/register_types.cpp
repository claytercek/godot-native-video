// -----------------------------------------------------------------------
// register_types.cpp — GDExtension entry point. Registers the Binding classes
// and the ResourceFormatLoader so a stock VideoStreamPlayer can load + play a
// native clip.
// -----------------------------------------------------------------------

#include "register_types.h"

#include "common/platform_media_resource_format_loader.h"
#include "common/platform_video_stream.h"
#include "common/platform_video_stream_playback.h"

#include <gdextension_interface.h>
#include <godot_cpp/classes/resource_loader.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>

using namespace godot;

static Ref<PlatformMediaResourceFormatLoader> s_loader;

void initialize_platform_media_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}

	ClassDB::register_class<PlatformVideoStreamPlayback>();
	ClassDB::register_class<PlatformVideoStream>();
	ClassDB::register_class<PlatformMediaResourceFormatLoader>();

	s_loader.instantiate();
	ResourceLoader::get_singleton()->add_resource_format_loader(s_loader);
}

void uninitialize_platform_media_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}

	if (s_loader.is_valid()) {
		ResourceLoader::get_singleton()->remove_resource_format_loader(s_loader);
		s_loader.unref();
	}
}

extern "C" {
GDExtensionBool GDE_EXPORT platform_media_streams_init(
		GDExtensionInterfaceGetProcAddress p_get_proc_address,
		const GDExtensionClassLibraryPtr p_library,
		GDExtensionInitialization *r_initialization) {
	GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library, r_initialization);

	init_obj.register_initializer(initialize_platform_media_module);
	init_obj.register_terminator(uninitialize_platform_media_module);
	init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);

	return init_obj.init();
}
}
