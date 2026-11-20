extends SceneTree

const Oracle = preload("res://linux_transport_oracles.gd")
const SEEK_SECONDS := 1.4


func _initialize() -> void:
	_run.call_deferred()


func _wait_marker(player: VideoStreamPlayer, first: int, last: int) -> bool:
	var deadline := Time.get_ticks_msec() + 5000
	var marker := -1
	while Time.get_ticks_msec() < deadline:
		await RenderingServer.frame_post_draw
		var texture := player.get_video_texture()
		if texture != null and texture.get_width() > 0:
			marker = Oracle.marker_frame(texture.get_image())
			if marker >= first and marker <= last:
				print("CODEC_SMOKE_MARKER ", player.stream.file, " frame=", marker)
				return true
	printerr("CODEC_SMOKE_FAIL ", player.stream.file, " expected frame ", first, "..", last, " got ", marker)
	return false


func _run() -> void:
	var paths := OS.get_cmdline_user_args()
	if paths.is_empty():
		paths.append("tests/fixtures/decode/vp9-8.mp4")
		if OS.get_name() == "Linux":
			paths.append("tests/fixtures/decode/av1-8.webm")
	if RenderingServer.get_rendering_device() == null:
		printerr("CODEC_SMOKE_FAIL rendered device required")
		quit(1)
		return
	var player := VideoStreamPlayer.new()
	root.add_child(player)
	for arg in paths:
		var path := arg.trim_prefix("--file=")
		if path.is_relative_path():
			path = ProjectSettings.globalize_path("res://../").path_join(path).simplify_path()
		var stream := load(path) as VideoStream
		if stream == null or stream.get_class() != "NativeVideoStream":
			printerr("CODEC_SMOKE_FAIL native loader did not handle ", path)
			quit(1)
			return
		player.stream = stream
		player.play()
		if not await _wait_marker(player, 1, 30):
			quit(1)
			return
		player.paused = true
		player.stream_position = SEEK_SECONDS
		var expected := Oracle.expected_seek_frame(SEEK_SECONDS)
		if not await _wait_marker(player, expected, expected):
			quit(1)
			return
		player.stop()
		player.stream = null
		player.paused = false
	player.free()
	print("CODEC_SMOKE_PASS")
	quit(0)
