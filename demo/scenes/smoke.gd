extends Control

# Demo driver for the native media streams GDExtension.
#
# Loads a clip (by default the synthetic fixture from tools/gen_test_media.sh)
# into a stock VideoStreamPlayer and plays it. The VideoStreamPlayer pulls a
# PlatformVideoStreamPlayback, which decodes NV12 via the platform backend
# (AVFoundation on macOS, Media Foundation on Windows) and presents zero-copy
# through the NV12->RGB compute pipeline. If the frames appear and advance, the
# present path is working.
#
# HDR output mode:
#   The Output Mode toggle switches between SDR (RGBA8, default) and HDR
#   (RGBA16F scene-linear, 1.0 = 203-nit Reference White). In HDR mode the
#   viewport's use_hdr_2d is enabled so Godot's compositor applies the correct
#   display transfer function. An HDR clip with supra-white highlights shows
#   the extended range; an SDR clip in HDR mode is linearized onto the same
#   scale so both render correctly in the same HDR viewport.
#
#   The mode is driven through the PlatformVideoStream resource
#   (player.stream.set_output_mode), which forwards to the live playback.
#   Stock Godot 4.4/4.5 has no VideoStreamPlayer.get_stream_playback(), so the
#   playback object is only used opportunistically for richer color info.

@onready var player: VideoStreamPlayer = $VideoStreamPlayer
@onready var status: Label = $Status
@onready var output_mode_btn: Button = $OutputModeButton

# Point this at any .mp4/.mov/.m4v the OS can decode. The default is the
# synthetic fixture; copy it into the demo project's res:// to use res://.
@export var clip_path: String = "res://synthetic.mp4"

# Optional HDR clip (e.g., an HDR10 PQ .mp4 with real highlights).
# When set, the HDR toggle will switch between SDR and HDR clips.
@export var hdr_clip_path: String = ""

var hdr_mode: bool = false
var playback = null
# Whether the loaded stream exposes set_output_mode (probed once per load).
var output_mode_supported: bool = false


func _ready() -> void:
	output_mode_btn.pressed.connect(_on_toggle_output_mode)
	output_mode_btn.text = "Output Mode: SDR"
	output_mode_btn.disabled = true

	_load_clip(clip_path)


func _on_toggle_output_mode() -> void:
	hdr_mode = not hdr_mode
	output_mode_btn.text = "Output Mode: HDR" if hdr_mode else "Output Mode: SDR"

	# Toggle use_hdr_2d on the viewport so Godot's compositor applies the
	# correct display transfer function for the HDR output.
	get_viewport().use_hdr_2d = hdr_mode

	if output_mode_supported:
		player.stream.set_output_mode(int(hdr_mode))

	_set_status("Output mode: %s  use_hdr_2d: %s" % [
		"HDR" if hdr_mode else "SDR",
		get_viewport().use_hdr_2d,
	])


func _load_clip(path: String) -> void:
	var stream := ResourceLoader.load(path)
	if stream == null:
		_set_status("FAILED to load: %s\n(generate it with tools/gen_test_media.sh and copy synthetic.mp4 into demo/)" % path)
		return
	player.stream = stream
	player.play()

	# The Output Mode toggle drives the stream resource, which forwards to the
	# live playback — no get_stream_playback() needed (absent in Godot 4.4/4.5).
	output_mode_supported = stream.has_method("set_output_mode")
	output_mode_btn.disabled = not output_mode_supported
	if not output_mode_supported:
		_set_status("Playing %s\n%s" % [path, _toggle_unavailable_msg()])
		return
	_set_status("Playing %s" % path)

	# Opportunistically grab the playback object for richer color info.
	# VideoStreamPlayer.get_stream_playback() only exists in newer Godot
	# builds; the mode display below does not depend on it.
	if player.has_method("get_stream_playback"):
		playback = player.get_stream_playback()


func _process(_delta: float) -> void:
	if player.stream != null and player.is_playing():
		var tex_ok = "ok" if player.get_video_texture() != null else "null"
		var info = ""
		if playback != null and playback.has_method("get_color_info"):
			# Richer color info when a playback object is reachable.
			info = "  mode=%s" % playback.get_color_info().get("output_mode", "?")
		elif player.stream.has_method("get_output_mode"):
			# No playback object (Godot 4.4/4.5) — read the mode off the stream.
			info = "  mode=%s" % player.stream.get_output_mode()
		var msg := "Playing  pos=%.2fs  tex=%s%s" % [
			player.stream_position,
			tex_ok,
			info,
		]
		if not output_mode_supported:
			msg += "\n" + _toggle_unavailable_msg()
		_set_status(msg)


func _toggle_unavailable_msg() -> String:
	return "Output Mode toggle unavailable: stream is %s, which does not expose set_output_mode" % player.stream.get_class()


func _set_status(msg: String) -> void:
	if status != null:
		status.text = msg
	print(msg)