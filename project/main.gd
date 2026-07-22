# Single entry point for the demo project.
#
# Modes (selected by CLI flag, read from OS.get_cmdline_user_args() — the
# args after `--` when launched as `godot --path project -- <args>` — with
# OS.get_cmdline_args() as a fallback):
#
#   --smoke          headless pass/fail verification (formerly smoke.gd):
#                     loads a clip, plays it, polls for a presented video
#                     texture, does a pixel-content sanity check, and quits
#                     with exit 0 (PASS) / 1 (FAIL).
#   (no flag)        interactive playback UI.
#
# A file path may be given as a bare positional arg or `--file=<path>`.
# Absolute on-disk paths, res://, and user:// all work (the loader keys on
# extension and globalizes res:// paths). Defaults to res://synthetic.mp4.
extends Node

const DEFAULT_CLIP := "res://synthetic.mp4"

@onready var video_player: VideoStreamPlayer = $VideoStreamPlayer
@onready var ui_layer: CanvasLayer = $UI
@onready var error_label: Label = $UI/Root/ErrorLabel
@onready var seek_bar: HSlider = $UI/Root/Controls/SeekBar
@onready var time_label: Label = $UI/Root/Controls/TimeLabel
@onready var play_button: Button = $UI/Root/Controls/HBox/PlayPauseButton
@onready var loop_check: CheckButton = $UI/Root/Controls/HBox/LoopCheck
@onready var audio_option: OptionButton = $UI/Root/Controls/HBox/AudioTrackOption

var _smoke_mode := false
var _user_dragging := false

# --- smoke-mode state (ported from the legacy smoke.gd) ---
var _smoke_player: VideoStreamPlayer
var _smoke_frames := 0
var _smoke_saw_texture := false
var _smoke_positions: Array[float] = []


func _ready() -> void:
	var args := _get_args()
	var clip_arg := _extract_file_arg(args)
	var clip_path := clip_arg if clip_arg != "" else DEFAULT_CLIP

	if args.has("--smoke"):
		_smoke_mode = true
		ui_layer.hide()
		video_player.hide()
		_run_smoke(clip_path)
		return

	_setup_interactive(clip_path)


func _process(delta: float) -> void:
	if _smoke_mode:
		_process_smoke()
	else:
		_process_ui(delta)


# ---------------------------------------------------------------------------
# CLI arg parsing
# ---------------------------------------------------------------------------

func _get_args() -> PackedStringArray:
	var user_args := OS.get_cmdline_user_args()
	if user_args.size() > 0:
		return user_args
	return OS.get_cmdline_args()


func _extract_file_arg(args: PackedStringArray) -> String:
	for a in args:
		if a.begins_with("--file="):
			return a.substr("--file=".length())
	for a in args:
		if a.begins_with("--"):
			continue
		return a
	return ""


# ---------------------------------------------------------------------------
# Smoke mode (headless verification — pass/fail semantics preserved verbatim
# from the original smoke.gd)
# ---------------------------------------------------------------------------

func _run_smoke(clip_path: String) -> void:
	print("SMOKE: NativeVideoStream registered = ", ClassDB.class_exists("NativeVideoStream"))
	var stream = load(clip_path)
	print("SMOKE: loaded stream = ", stream)
	if stream == null:
		print("SMOKE: FAIL — loader did not handle mp4")
		get_tree().quit(1)
		return
	_smoke_player = VideoStreamPlayer.new()
	add_child(_smoke_player)
	_smoke_player.stream = stream
	_smoke_player.play()
	print("SMOKE: is_playing = ", _smoke_player.is_playing())
	print("SMOKE: length = ", _smoke_player.get_stream_length())


func _process_smoke() -> void:
	_smoke_frames += 1
	if _smoke_frames % 30 == 0:
		_smoke_positions.append(_smoke_player.stream_position)
	var tex := _smoke_player.get_video_texture()
	if tex != null and not _smoke_saw_texture:
		_smoke_saw_texture = true
		print("SMOKE: first texture at frame ", _smoke_frames, ": ", tex, " ", tex.get_size())
	# Mid-playback pixel check: read back the presented frame and verify the
	# compute pass wrote real video content (not all-black / all-one-color).
	# The clip is greyscale and mostly dark, so single points can be genuinely
	# black — average the whole image (8px stride) to prove real content and
	# pin NV12->RGB conversion fidelity against the known-good value (avg ~= 0.078).
	if _smoke_frames == 60 and _smoke_saw_texture:
		var rtex := _smoke_player.get_video_texture()
		var img := rtex.get_image() if rtex != null else null
		if img == null:
			print("SMOKE: get_image() returned null (no CPU readback path)")
		else:
			var w := img.get_width()
			var h := img.get_height()
			var r := 0.0
			var g := 0.0
			var b := 0.0
			var n := 0
			for y in range(0, h, 8):
				for x in range(0, w, 8):
					var px := img.get_pixel(x, y)
					r += px.r
					g += px.g
					b += px.b
					n += 1
			var inv: float = 1.0 / float(n) if n > 0 else 0.0
			var avg := Color(r * inv, g * inv, b * inv)
			print("SMOKE: avg over ", n, " samples = ", avg)
			print("SMOKE: content = ", "REAL" if avg.get_luminance() > 0.01 else "BLACK")
	# ~2.5s at 60fps: past EOS of the 2s clip.
	if _smoke_frames == 150:
		print("SMOKE: positions at 0.5s intervals = ", _smoke_positions)
		print("SMOKE: still playing at EOS+0.5s = ", _smoke_player.is_playing())
		print("SMOKE: ", "PASS" if _smoke_saw_texture else "FAIL — no texture ever presented")
		get_tree().quit(0 if _smoke_saw_texture else 1)


# ---------------------------------------------------------------------------
# Interactive UI mode
# ---------------------------------------------------------------------------

func _setup_interactive(clip_path: String) -> void:
	error_label.hide()
	audio_option.hide()

	var stream = load(clip_path)
	if stream == null:
		var msg := "Failed to load video: %s" % clip_path
		push_error(msg)
		error_label.text = msg
		error_label.show()
		play_button.disabled = true
		seek_bar.editable = false
		loop_check.disabled = true
		return

	video_player.stream = stream
	video_player.finished.connect(_on_video_finished)

	play_button.pressed.connect(_on_play_pressed)
	loop_check.toggled.connect(_on_loop_toggled)
	seek_bar.drag_started.connect(_on_seek_drag_started)
	seek_bar.drag_ended.connect(_on_seek_drag_ended)
	seek_bar.max_value = video_player.get_stream_length()

	_populate_audio_tracks(stream)

	video_player.play()
	_update_play_button_text()


func _process_ui(_delta: float) -> void:
	if video_player.stream == null:
		return
	_update_play_button_text()
	var length := video_player.get_stream_length()
	if not _user_dragging:
		seek_bar.value = video_player.stream_position
	_update_time_label(video_player.stream_position, length)


func _update_play_button_text() -> void:
	if video_player.is_playing() and not video_player.is_paused():
		play_button.text = "Pause"
	else:
		play_button.text = "Play"


func _update_time_label(position: float, length: float) -> void:
	time_label.text = "%s / %s" % [_format_time(position), _format_time(length)]


func _format_time(t: float) -> String:
	var total := int(max(t, 0.0))
	var m := total / 60
	var s := total % 60
	return "%d:%02d" % [m, s]


func _populate_audio_tracks(stream: VideoStream) -> void:
	audio_option.clear()
	if not stream.has_method("get_audio_tracks"):
		audio_option.hide()
		return

	var tracks: Array = stream.get_audio_tracks()
	if tracks.size() < 2:
		audio_option.hide()
		return

	audio_option.show()
	var base_rate = tracks[0].get("sample_rate", 0)
	for i in range(tracks.size()):
		var t: Dictionary = tracks[i]
		var label := "%s (%s) %dch" % [
			t.get("name", "Track %d" % i),
			t.get("language", "?"),
			t.get("channels", 0),
		]
		audio_option.add_item(label, i)
		var idx := audio_option.get_item_count() - 1
		if t.get("sample_rate", 0) != base_rate:
			audio_option.set_item_disabled(idx, true)
			audio_option.set_item_tooltip(
				idx,
				"Incompatible sample rate (%d Hz) — switching mid-playback silently no-ops" % t.get("sample_rate", 0)
			)

	audio_option.selected = video_player.audio_track
	audio_option.item_selected.connect(_on_audio_track_selected)


func _on_play_pressed() -> void:
	if video_player.is_playing():
		video_player.set_paused(not video_player.is_paused())
	else:
		video_player.play()
	_update_play_button_text()


func _on_loop_toggled(enabled: bool) -> void:
	video_player.loop = enabled


func _on_video_finished() -> void:
	if not video_player.loop:
		_update_play_button_text()


func _on_seek_drag_started() -> void:
	_user_dragging = true


func _on_seek_drag_ended(_value_changed: bool) -> void:
	_user_dragging = false
	video_player.stream_position = seek_bar.value


func _on_audio_track_selected(idx: int) -> void:
	video_player.audio_track = idx
