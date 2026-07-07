// -----------------------------------------------------------------------
// register_types.cpp — GDExtension entry point. Registers the Binding classes
// and the ResourceFormatLoader so a stock VideoStreamPlayer can load + play a
// native clip.
// -----------------------------------------------------------------------

#include "register_types.h"

#include "common/native_video_resource_format_loader.h"
#include "common/native_video_stream.h"
#include "common/native_video_stream_playback.h"

#include <gdextension_interface.h>
#include <godot_cpp/classes/resource_loader.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>

using namespace godot;

static Ref<NativeVideoResourceFormatLoader> s_loader;

void initialize_native_video_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}

	ClassDB::register_class<NativeVideoStreamPlayback>();
	ClassDB::register_class<NativeVideoStream>();
	ClassDB::register_class<NativeVideoResourceFormatLoader>();

	s_loader.instantiate();
	ResourceLoader::get_singleton()->add_resource_format_loader(s_loader);
}

void uninitialize_native_video_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}

	if (s_loader.is_valid()) {
		ResourceLoader::get_singleton()->remove_resource_format_loader(s_loader);
		s_loader.unref();
	}
}

extern "C" {
GDExtensionBool GDE_EXPORT native_video_init(
		GDExtensionInterfaceGetProcAddress p_get_proc_address,
		const GDExtensionClassLibraryPtr p_library,
		GDExtensionInitialization *r_initialization) {
	GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library, r_initialization);

	init_obj.register_initializer(initialize_native_video_module);
	init_obj.register_terminator(uninitialize_native_video_module);
	init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);

	return init_obj.init();
}
}
