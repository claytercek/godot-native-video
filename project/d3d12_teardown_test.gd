# Run with --rendering-driver d3d12 --script res://d3d12_teardown_test.gd.
extends SceneTree

const CYCLES := 40


func _initialize() -> void:
	_run.call_deferred()


func _fail(reason: String) -> void:
	printerr("D3D12_TEARDOWN_FAIL ", reason)
	quit(1)


func _using_zero_copy() -> bool:
	for connection in get_signal_connection_list("process_frame"):
		var callback: Callable = connection["callable"]
		if callback.get_method() == &"process_presentation":
			var playback := callback.get_object()
			return playback != null and playback.get_cpu_copy_count() == 0
	return false


func _run() -> void:
	if RenderingServer.get_current_rendering_driver_name() != "d3d12":
		_fail("D3D12 renderer required")
		return
	var stream := load("res://synthetic.mp4") as VideoStream
	if stream == null or stream.get_class() != "NativeVideoStream":
		_fail("native fixture required")
		return
	var player := VideoStreamPlayer.new()
	var exit_image := TextureRect.new()
	root.add_child(player)
	root.add_child(exit_image)
	for cycle in range(CYCLES):
		player.stream = stream
		player.play()
		player.set_process_internal(false)
		var deadline := Time.get_ticks_msec() + 5000
		var texture: Texture2D
		while Time.get_ticks_msec() < deadline:
			await process_frame
			player.notification(Node.NOTIFICATION_INTERNAL_PROCESS)
			texture = player.get_video_texture()
			if texture != null and texture.get_width() > 0:
				break
		if texture == null or texture.get_width() <= 0:
			_fail("no decoded texture on cycle %d" % cycle)
			return
		if not _using_zero_copy():
			_fail("D3D12 zero-copy required on cycle %d" % cycle)
			return
		# Clear the stream before Godot submits this draw. Keep its texture
		# assigned to another canvas item, as an exit animation might do.
		exit_image.texture = texture
		player.stop()
		player.stream = null
		if cycle < CYCLES - 1:
			await RenderingServer.frame_post_draw
	print("D3D12_TEARDOWN_PASS cycles=", CYCLES)
	quit(0)
