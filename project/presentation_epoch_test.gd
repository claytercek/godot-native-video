# Focused rendered regression for preview->resume and retirement-only pumping.
# godot --path project --script res://presentation_epoch_test.gd -- --file=PATH
# Use an RD renderer, not --headless. Pure lifetime/retry tests cover exact
# release counts; this test covers weak callback wiring and synchronous resume.
extends SceneTree

var player: VideoStreamPlayer
var failed := false
var published_epoch := -1
var publication_count := 0


func _initialize() -> void:
	_run.call_deferred()


func _require(condition: bool, reason: String) -> bool:
	if condition:
		return true
	failed = true
	print("PRESENTATION_EPOCH_FAIL ", reason)
	if is_instance_valid(player):
		print("PRESENTATION_EPOCH_STATE position=", player.stream_position,
			" playing=", player.is_playing(), " paused=", player.paused,
			" processing=", player.is_processing_internal(),
			" process_frames=", Engine.get_process_frames(), " draws=", Engine.get_frames_drawn())
	quit(1)
	return false


func _pump() -> Callable:
	for connection in get_signal_connection_list("process_frame"):
		var callback: Callable = connection["callable"]
		if callback.get_method() == &"process_presentation":
			return callback
	return Callable()


func _wait_draws(count: int) -> void:
	var target := Engine.get_frames_drawn() + count
	var deadline := Time.get_ticks_msec() + 5000
	while Engine.get_frames_drawn() < target and Time.get_ticks_msec() < deadline:
		await process_frame
	_require(Engine.get_frames_drawn() >= target, "render epoch did not advance")


func _resume_from_changed() -> void:
	publication_count += 1
	published_epoch = Engine.get_frames_drawn()
	player.paused = false


func _run() -> void:
	if not _require(RenderingServer.get_rendering_device() != null, "RD renderer required"):
		return
	var path := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--file="):
			path = arg.substr(7)
	var stream := load(path) as VideoStream
	if not _require(stream != null and stream.get_class() == "NativeVideoStream", "native fixture required"):
		return
	player = VideoStreamPlayer.new()
	root.add_child(player)
	player.stream = stream
	player.play()
	# Godot's first update has delta 0; finish the cold first draw before timing
	# playback progress. The shell's outer timeout still bounds renderer startup.
	await RenderingServer.frame_post_draw
	var deadline := Time.get_ticks_msec() + 5000
	while player.stream_position < 0.1 and Time.get_ticks_msec() < deadline:
		await process_frame
	if not _require(player.stream_position >= 0.1, "initial playback did not advance"):
		return
	player.paused = true
	await _wait_draws(6)
	if failed or not _require(_pump().is_null(), "paused lifetime batches did not drain"):
		return
	var texture := player.get_video_texture()
	if not _require(texture != null and texture.get_image() != null, "no decoded texture"):
		return
	texture.changed.connect(_resume_from_changed, CONNECT_ONE_SHOT)
	player.stream_position = player.get_stream_length() * 0.5
	var epoch := Engine.get_frames_drawn()
	deadline = Time.get_ticks_msec() + 3000
	# Manually invoke the actual weak callback many times without allowing a
	# draw. The decoder worker can produce the source while this thread waits.
	while publication_count == 0 and Time.get_ticks_msec() < deadline:
		var callback := _pump()
		if not _require(not callback.is_null(), "preview lost its callback"):
			return
		callback.call()
		OS.delay_msec(2)
	if not _require(publication_count == 1 and published_epoch == epoch, "preview did not synchronously resume in the same epoch"):
		return
	# Preview has returned; force normal player updates in the SAME epoch.
	# This is the path that used to advance the lifetime ring per submission.
	var resumed_position := player.stream_position
	for i in range(8):
		OS.delay_msec(20)
		player.notification(Node.NOTIFICATION_INTERNAL_PROCESS)
	if not _require(Engine.get_frames_drawn() == epoch and not _pump().is_null(), "same-epoch updates disconnected live retirement"):
		return
	if not _require(player.stream_position > resumed_position + 0.05, "forced normal updates did not actually advance playback"):
		return
	player.stop()
	if not _require(not _pump().is_null(), "stop abandoned live retirement batches"):
		return
	await _wait_draws(5)
	if failed or not _require(_pump().is_null(), "retirement-only callback stayed connected"):
		return
	player.play()
	await _wait_draws(3)
	# Drop the sole owner while a callback may still be connected. Its callable
	# is ObjectID-bound, not an owning ref or a dangling raw closure pointer.
	player.free()
	player = null
	await _wait_draws(5)
	if failed or not _require(_pump().is_null(), "destruction left a weak callback connected"):
		return
	print("PRESENTATION_EPOCH_PASS repeated_epoch=", epoch, " preview_resume=1 retirement_drained=1")
	quit(0)
