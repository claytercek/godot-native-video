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
var _smoke_started_msec := 0
var _smoke_next_probe_msec := 0
var _smoke_content_valid := false

const SMOKE_DEADLINE_MSEC := 10_000
const SMOKE_PROBE_INTERVAL_MSEC := 250
const SMOKE_EXPECTED_SIZE := Vector2i(320, 240)
const SMOKE_LUMINANCE_MIN := 0.04
const SMOKE_LUMINANCE_MAX := 0.14
const SMOKE_VARIANCE_MIN := 0.0005
const SMOKE_CHANNEL_DELTA_MAX := 0.02


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
# Smoke mode (integration verification against the checked-in synthetic clip)
# ---------------------------------------------------------------------------

func _run_smoke(clip_path: String) -> void:
	var registered := ClassDB.class_exists("NativeVideoStream")
	print("SMOKE: NativeVideoStream registered = ", registered)
	if not registered:
		_fail_smoke("NativeVideoStream was not registered")
		return
	var stream = load(clip_path)
	print("SMOKE: loaded stream = ", stream)
	if stream == null:
		_fail_smoke("loader did not handle mp4")
		return
	if not stream is NativeVideoStream:
		_fail_smoke("loader returned %s instead of NativeVideoStream" % stream.get_class())
		return
	_smoke_player = VideoStreamPlayer.new()
	add_child(_smoke_player)
	_smoke_player.stream = stream
	_smoke_started_msec = Time.get_ticks_msec()
	_smoke_next_probe_msec = _smoke_started_msec
	_smoke_player.play()
	print("SMOKE: is_playing = ", _smoke_player.is_playing())
	print("SMOKE: length = ", _smoke_player.get_stream_length())
	if not _smoke_player.is_playing():
		_fail_smoke("playback did not start")
		return
	if _smoke_player.get_stream_length() <= 0.0:
		_fail_smoke("stream reported no duration")
		return


func _process_smoke() -> void:
	_smoke_frames += 1
	var now := Time.get_ticks_msec()
	var probe_due := false
	if now >= _smoke_next_probe_msec:
		probe_due = true
		_smoke_next_probe_msec = now + SMOKE_PROBE_INTERVAL_MSEC
		_smoke_positions.append(_smoke_player.stream_position)
	var tex := _smoke_player.get_video_texture()
	if tex != null and not _smoke_saw_texture:
		var texture_size := Vector2i(tex.get_size())
		if texture_size != Vector2i.ZERO and texture_size != SMOKE_EXPECTED_SIZE:
			_fail_smoke("texture dimensions were %s, expected %s" % [texture_size, SMOKE_EXPECTED_SIZE])
			return
		if texture_size == SMOKE_EXPECTED_SIZE:
			_smoke_saw_texture = true
			print("SMOKE: first populated texture at frame ", _smoke_frames, ": ", tex, " ", texture_size)
	# Mid-playback pixel check: read back the presented frame and verify the
	# compute pass wrote real video content (not all-black / all-one-color).
	# The clip is greyscale and mostly dark, so single points can be genuinely
	# black — average the whole image (8px stride) to prove real content and
	# pin NV12->RGB conversion fidelity against the known-good value (avg ~= 0.078).
	if _smoke_saw_texture and not _smoke_content_valid and probe_due:
		var rtex := _smoke_player.get_video_texture()
		var img := rtex.get_image() if rtex != null else null
		if img != null:
			var w := img.get_width()
			var h := img.get_height()
			var r := 0.0
			var g := 0.0
			var b := 0.0
			var luminance_sum := 0.0
			var luminance_squared_sum := 0.0
			var max_channel_delta := 0.0
			var n := 0
			for y in range(0, h, 8):
				for x in range(0, w, 8):
					var px := img.get_pixel(x, y)
					r += px.r
					g += px.g
					b += px.b
					var luminance := px.get_luminance()
					luminance_sum += luminance
					luminance_squared_sum += luminance * luminance
					max_channel_delta = max(
						max_channel_delta,
						max(abs(px.r - px.g), max(abs(px.g - px.b), abs(px.b - px.r)))
					)
					n += 1
			var inv: float = 1.0 / float(n) if n > 0 else 0.0
			var avg := Color(r * inv, g * inv, b * inv)
			var avg_luminance: float = luminance_sum * inv
			var variance: float = max(0.0, luminance_squared_sum * inv - avg_luminance * avg_luminance)
			_smoke_content_valid = (
				n > 0
				and avg_luminance >= SMOKE_LUMINANCE_MIN
				and avg_luminance <= SMOKE_LUMINANCE_MAX
				and variance >= SMOKE_VARIANCE_MIN
				and max_channel_delta <= SMOKE_CHANNEL_DELTA_MAX
			)
			print(
				"SMOKE: samples = ", n,
				", avg = ", avg,
				", luminance = ", avg_luminance,
				", variance = ", variance,
				", max channel delta = ", max_channel_delta
			)
			print("SMOKE: content = ", "EXPECTED SYNTHETIC FRAME" if _smoke_content_valid else "INVALID")
	if (
		_smoke_content_valid
		and _smoke_positions.size() >= 3
		and _smoke_player.stream_position >= _smoke_player.get_stream_length() - 0.1
	):
		_finish_smoke(_positions_are_monotonic(_smoke_positions))
		return
	if now - _smoke_started_msec >= SMOKE_DEADLINE_MSEC:
		var monotonic := _positions_are_monotonic(_smoke_positions)
		_finish_smoke(_smoke_saw_texture and _smoke_content_valid and monotonic)


func _finish_smoke(passed: bool) -> void:
	print("SMOKE: sampled positions = ", _smoke_positions)
	print("SMOKE: monotonic positions = ", _positions_are_monotonic(_smoke_positions))
	print("SMOKE: ", "PASS" if passed else "FAIL — missing/black output or non-monotonic clock")
	_smoke_player.stop()
	_smoke_player.stream = null
	remove_child(_smoke_player)
	_smoke_player.free()
	get_tree().quit(0 if passed else 1)


func _fail_smoke(reason: String) -> void:
	print("SMOKE: FAIL — ", reason)
	if is_instance_valid(_smoke_player):
		_smoke_player.stop()
		_smoke_player.stream = null
		if _smoke_player.get_parent() != null:
			_smoke_player.get_parent().remove_child(_smoke_player)
		_smoke_player.free()
	get_tree().quit(1)


func _positions_are_monotonic(positions: Array[float]) -> bool:
	if positions.size() < 3:
		return false
	var advanced := false
	for i in range(1, positions.size()):
		if positions[i] + 0.001 < positions[i - 1]:
			return false
		if positions[i] > positions[i - 1] + 0.001:
			advanced = true
	return advanced


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
