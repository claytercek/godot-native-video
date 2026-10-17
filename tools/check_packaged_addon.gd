# Linux CI probe, run in the clean smoke project before playback. Reading
# /proc/self/maps checks the actual dynamic loader result, not a reimplementation
# of Godot's manifest feature matching. Never fake release via custom features.
extends Node

const ADDON := "res://addons/native_video/"


func _ready() -> void:
	var mode := OS.get_environment("NATIVE_VIDEO_PACKAGE_MODE")
	if mode not in ["debug", "release"]:
		_fail("expected NATIVE_VIDEO_PACKAGE_MODE=debug or release")
		return
	var other := "release" if mode == "debug" else "debug"
	if not OS.has_feature("linux") or not OS.has_feature("x86_64"):
		_fail("expected Linux x86_64 runtime")
		return
	if not OS.has_feature(mode) or OS.has_feature(other):
		_fail("runtime must have only the %s feature, not %s" % [mode, other])
		return
	if mode == "release" and not OS.has_feature("template_release"):
		_fail("release selection requires a real release template")
		return
	if not GDExtensionManager.is_extension_loaded(ADDON + "native_video.gdextension"):
		_fail("shipped GDExtension manifest was not loaded")
		return
	if not ClassDB.class_exists("NativeVideoStream"):
		_fail("NativeVideoStream was not registered")
		return
	var manifest := ConfigFile.new()
	if manifest.load(ADDON + "native_video.gdextension") != OK:
		_fail("could not read shipped manifest")
		return
	var selected: String = manifest.get_value("libraries", "linux.%s.x86_64" % mode, "")
	if selected.is_empty():
		_fail("missing library for linux.%s.x86_64" % mode)
		return
	var expected := ProjectSettings.globalize_path(ADDON + selected)
	# procfs reports a zero file length; read sequentially, not get_as_text().
	var maps := FileAccess.open("/proc/self/maps", FileAccess.READ)
	if maps == null:
		_fail("could not read /proc/self/maps")
		return
	var found := false
	while not maps.eof_reached():
		var line := maps.get_line()
		if ProjectSettings.globalize_path(ADDON) not in line:
			continue
		if not line.ends_with(" " + expected):
			_fail("unexpected native-video library mapping: " + line)
			return
		found = true
	if not found:
		_fail("packaged library was not mapped: " + expected)
		return
	print("PACKAGE_SELECTION_PASS %s %s" % [mode, expected])
	if OS.get_cmdline_user_args().has("--smoke"):
		# Run the existing playback smoke unchanged, after checking selection in
		# this same process. No --script/--scene overrides needed by templates.
		add_child.call_deferred(load("res://main.tscn").instantiate())
	else:
		get_tree().quit(0)


func _fail(message: String) -> void:
	push_error("PACKAGE_SELECTION_FAIL: " + message)
	get_tree().quit(1)
