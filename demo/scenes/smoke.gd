extends Control

# Demo driver for the Native Video GDExtension.
#
# Loads a clip (by default the synthetic fixture from tools/gen_test_media.sh)
# into a stock VideoStreamPlayer and plays it. The VideoStreamPlayer pulls a
# NativeVideoStreamPlayback, which decodes NV12 via the platform backend
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
#   The mode is driven through the NativeVideoStream resource
#   (player.stream.set_output_mode), which forwards to the live playback.
#   Stock Godot 4.4/4.5 has no VideoStreamPlayer.get_stream_playback(), so the
#   playback object is only used opportunistically for richer color info.
#
# Additionally enumerates audio tracks from the stream resource and displays
# their metadata (language, name, channel count, sample rate, default flag).
# The user may select an audio track before pressing Play; the selection is
# honoured on the first decode.

@onready var player: VideoStreamPlayer = $VideoStreamPlayer
@onready var status: Label = $Status
@onready var output_mode_btn: Button = $OutputModeButton
@onready var track_list: Label = $TrackList
@onready var track_selector: OptionButton = $TrackSelector
@onready var play_btn: Button = $PlayButton

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
var _stream = null


func _ready() -> void:
	output_mode_btn.pressed.connect(_on_toggle_output_mode)
	output_mode_btn.text = "Output Mode: SDR"
	output_mode_btn.disabled = true

	_stream = ResourceLoader.load(clip_path)
	if _stream == null:
		_set_status("FAILED to load: %s\n(generate it with tools/gen_test_media.sh and copy synthetic.mp4 into demo/)" % clip_path)
		return
	player.stream = _stream

	# The Output Mode toggle drives the stream resource, which forwards to the
	# live playback — no get_stream_playback() needed (absent in Godot 4.4/4.5).
	output_mode_supported = _stream.has_method("set_output_mode")
	output_mode_btn.disabled = not output_mode_supported

	_set_status("Loaded %s. Select a track and press Play." % clip_path)

	# Wire up UI signals.
	play_btn.pressed.connect(_on_play_pressed)
	track_selector.item_selected.connect(_on_track_selector_item_selected)

	# Query audio track list and populate the selector.
	display_tracks(_stream)

	# `godot -- --autoplay` starts playback immediately — used by the
	# non-headless regression test, where nobody can click Play.
	if OS.get_cmdline_user_args().has("--autoplay"):
		_on_play_pressed.call_deferred()


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
		var msg := "Playing  pos=%.2fs  tex=%s  track=%d%s  (switch live using dropdown)" % [
			player.stream_position,
			tex_ok,
			player.audio_track,
			info,
		]
		if not output_mode_supported:
			msg += "\n" + _toggle_unavailable_msg()
		_set_status(msg)


func _toggle_unavailable_msg() -> String:
	return "Output Mode toggle unavailable: stream is %s, which does not expose set_output_mode" % player.stream.get_class()


func display_tracks(stream) -> void:
	var tracks = stream.get_audio_tracks()
	track_selector.clear()
	if tracks == null or tracks.is_empty():
		if track_list != null:
			track_list.text = "No audio tracks"
		track_selector.add_item("0 (no audio)")
		track_selector.disabled = true
		return

	var lines: PackedStringArray = []
	lines.append("Audio tracks (%d):" % tracks.size())
	for i in tracks.size():
		var t: Dictionary = tracks[i]
		var lang = t.get("language", "")
		var name = t.get("name", "")
		var ch = t.get("channels", 0)
		var rate = t.get("sample_rate", 0)
		var is_def = t.get("default", false)
		var label = "[%d] %s" % [i, lang if lang != "" else "??"]
		if name != "":
			label += " %s" % name
		label += "  %dch %dHz" % [ch, rate]
		if is_def:
			label += "  DEFAULT"
		track_selector.add_item(label, i)
		lines.append("  " + label)
	if track_list != null:
		track_list.text = "\n".join(lines)
	track_selector.disabled = false
	track_selector.selected = 0


func _on_play_pressed() -> void:
	if _stream == null:
		return
	# Honour the user's track selection before play.
	player.audio_track = track_selector.get_selected_id()
	player.play()
	# Opportunistically grab the playback object for richer color info.
	# VideoStreamPlayer.get_stream_playback() only exists in newer Godot
	# builds; the mode display does not depend on it.
	if player.has_method("get_stream_playback"):
		playback = player.get_stream_playback()
	_set_status("Playing %s  track=%d" % [clip_path, player.audio_track])
	play_btn.disabled = true


func _on_track_selector_item_selected(_index: int) -> void:
	# Update the player's selection. If currently playing, this triggers a
	# mid-stream track switch (the backend reselects the audio track without
	# interrupting video).
	player.audio_track = track_selector.get_selected_id()
	var msg = "Track %d selected." % player.audio_track
	if player.is_playing():
		msg += " Switching live..."
	else:
		msg += " Press Play."
	_set_status(msg)


func _set_status(msg: String) -> void:
	if status != null:
		status.text = msg
	print(msg)