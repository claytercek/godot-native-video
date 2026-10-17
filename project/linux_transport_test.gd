# Public VideoStreamPlayer integration regression; requires a rendered RD.
# godot --path project --script res://linux_transport_test.gd -- \
#   --file=/tmp/fixtures/h264-aac.mp4 --expect-audio=1
# The shell runner supplies an outer timeout and rejects engine/load errors.
extends SceneTree

var player: VideoStreamPlayer
var capture: AudioEffectCapture
var bus_index := -1
var finished_count := 0
var pcm_frames := 0
var pcm_peak := 0.0
var pcm_nonfinite := false
var failed := false
var started_ms := 0
var changed_mutations := 0


func _initialize() -> void:
	started_ms = Time.get_ticks_msec()
	_run.call_deferred()


func _process(_delta: float) -> bool:
	if capture != null:
		var available := capture.get_frames_available()
		if available > 0:
			var samples := capture.get_buffer(available)
			pcm_frames += samples.size()
			for sample in samples:
				if not is_finite(sample.x) or not is_finite(sample.y):
					pcm_nonfinite = true
				pcm_peak = maxf(pcm_peak, maxf(absf(sample.x), absf(sample.y)))
	if not failed and Time.get_ticks_msec() - started_ms > 60_000:
		_require(false, "global transport deadline exceeded")
	return false


func _arg(name: String, fallback: String = "") -> String:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with(name + "="):
			return arg.substr(name.length() + 1)
	return fallback


func _require(condition: bool, reason: String) -> bool:
	if condition:
		return true
	failed = true
	print("LINUX_TRANSPORT_FAIL ", reason)
	quit(1)
	return false


func _wait(seconds: float) -> void:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	while not failed and Time.get_ticks_msec() < deadline:
		await process_frame


func _advance_from(position: float, amount: float, timeout_seconds: float = 3.0) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout_seconds * 1000.0)
	while not failed and Time.get_ticks_msec() < deadline:
		if player.stream_position >= position + amount:
			return true
		await process_frame
	return false


# Signal introspection is public in both supported stock Godot versions. Count
# only the extension callback, not this test's coroutine frame subscriptions.
func _preview_callbacks() -> int:
	var count := 0
	for connection in get_signal_connection_list("process_frame"):
		var callback: Callable = connection["callable"]
		if callback.get_method() == &"process_paused_preview":
			count += 1
	return count


func _image() -> Image:
	var texture := player.get_video_texture()
	if texture == null or texture.get_size() != Vector2(320, 240):
		return null
	return texture.get_image()


func _pixels_valid(image: Image) -> bool:
	if image == null or image.is_empty() or image.get_size() != Vector2i(320, 240):
		return false
	var total := 0.0
	var squared := 0.0
	var count := 0
	for y in range(0, 240, 8):
		for x in range(0, 320, 8):
			var pixel := image.get_pixel(x, y)
			if not is_finite(pixel.r) or not is_finite(pixel.g) or not is_finite(pixel.b):
				return false
			var luminance := pixel.get_luminance()
			total += luminance
			squared += luminance * luminance
			count += 1
	var mean := total / float(count)
	var variance := squared / float(count) - mean * mean
	print("LINUX_TRANSPORT_PIXELS mean=", mean, " variance=", variance)
	return mean > 0.01 and mean < 0.95 and variance > 0.0002


# Intentionally synchronous: no deferred connection, queue_free, or helper
# unpause. This drops the player's playback ownership from inside present().
func _on_preview_changed(free_player: bool, stream: VideoStream) -> void:
	changed_mutations += 1
	if not _require(player.paused and _preview_callbacks() == 1, "changed mutation did not run inside a paused preview"):
		return
	if free_player:
		root.remove_child(player)
		player.free()
		player = null
	else:
		player.stream = null
		player.stream = stream


func _changed_lifecycle(stream: VideoStream, free_player: bool) -> bool:
	player.paused = true
	var texture := player.get_video_texture()
	if not _require(texture != null and _preview_callbacks() == 0, "changed lifecycle has no settled source texture"):
		return false
	var victim_id := player.get_instance_id()
	var before := changed_mutations
	texture.changed.connect(_on_preview_changed.bind(free_player, stream), CONNECT_ONE_SHOT)
	player.stream_position = player.get_stream_length() * 0.2
	if not _require(_preview_callbacks() == 1, "changed lifecycle did not schedule a preview"):
		return false
	var deadline := Time.get_ticks_msec() + 3000
	while not failed and changed_mutations == before and Time.get_ticks_msec() < deadline:
		await process_frame
	# Allow the synchronous publisher's stack to unwind before inspecting its
	# connection. Completion is event-based; no assumed number of render ticks.
	await process_frame
	if not _require(not failed and changed_mutations == before + 1, "paused preview did not invoke its synchronous changed handler exactly once"):
		return false
	if not _require(_preview_callbacks() == 0, "changed mutation left the old preview callback connected"):
		return false
	if free_player:
		if not _require(player == null and not is_instance_id_valid(victim_id), "changed handler did not synchronously free its player"):
			return false
	else:
		if not _require(player.paused and not player.is_playing() and absf(player.stream_position) < 0.01, "old preview changed the replacement playback"):
			return false
		if not _require(player.get_video_texture() != texture, "stream replacement retained the old playback texture"):
			return false
	await _wait(0.2)
	if not _require(_preview_callbacks() == 0 and changed_mutations == before + 1, "changed mutation left stale callbacks or repeated publication"):
		return false
	if not free_player:
		if not _require(not player.is_playing() and absf(player.stream_position) < 0.01, "stale preview advanced replacement playback"):
			return false
		# Only start the replacement after proving the old preview was canceled.
		player.paused = false
		player.play()
		if not _require(await _advance_from(0.0, 0.2), "playback after synchronous stream replacement did not advance"):
			return false
		if not _require(_pixels_valid(_image()), "replacement playback did not publish valid decoded pixels"):
			return false
	print("LINUX_TRANSPORT_CHECK synchronous-changed-", "free" if free_player else "reload")
	return true


func _dispose(free_pending_preview: bool = false) -> bool:
	var before := Time.get_ticks_msec()
	if is_instance_valid(player):
		if not free_pending_preview:
			player.stop()
			player.stream = null
		root.remove_child(player)
		player.free()
		player = null
	if bus_index >= 0:
		AudioServer.remove_bus(bus_index)
		bus_index = -1
	capture = null
	if not _require(_preview_callbacks() == 0, "free left a paused-preview callback connected"):
		return false
	var elapsed := Time.get_ticks_msec() - before
	print("LINUX_TRANSPORT_CLOSE milliseconds=", elapsed, " free_pending_preview=", free_pending_preview)
	return _require(elapsed < 2000, "stop/unregister/free exceeded two-second budget")


func _run() -> void:
	if not _require(RenderingServer.get_rendering_device() != null, "headless/Compatibility cannot validate RD presentation"):
		return
	if not _require(ClassDB.class_exists("NativeVideoStream"), "native extension did not register"):
		return
	var path := _arg("--file")
	var expect_audio := _arg("--expect-audio", "1") == "1"
	var stream := load(path) as VideoStream
	if not _require(stream != null and stream.get_class() == "NativeVideoStream", "fixture did not load as NativeVideoStream"):
		return
	var tracks: Array = stream.call("get_audio_tracks")
	if not _require(tracks.size() == (1 if expect_audio else 0), "audio-track metadata does not match fixture"):
		return

	bus_index = AudioServer.bus_count
	AudioServer.add_bus()
	var bus_name := "LinuxValidationCapture"
	AudioServer.set_bus_name(bus_index, bus_name)
	capture = AudioEffectCapture.new()
	capture.buffer_length = 0.5
	AudioServer.add_bus_effect(bus_index, capture)
	# Capture happens before bus volume; avoid presenting this as audible testing.
	AudioServer.set_bus_volume_db(bus_index, -80.0)
	player = VideoStreamPlayer.new()
	player.bus = bus_name
	root.add_child(player)
	player.stream = stream
	player.finished.connect(func() -> void: finished_count += 1)
	var length := player.get_stream_length()
	if not _require(length > 0.5 and length < 4.0, "unexpected fixture duration"):
		return
	player.play()
	if not _require(await _advance_from(0.0, minf(0.2, length * 0.15)), "initial playback clock did not advance"):
		return
	var texture_deadline := Time.get_ticks_msec() + 4000
	var image := _image()
	while image == null and Time.get_ticks_msec() < texture_deadline:
		await process_frame
		image = _image()
	if not _require(_pixels_valid(image), "decoded texture is absent, uniform, nonfinite or incorrectly sized"):
		return
	print("LINUX_TRANSPORT_CHECK initial-video")

	player.paused = true
	await _wait(0.15)
	var pause_position := player.stream_position
	var paused_image := _image()
	if not _require(paused_image != null, "texture disappeared while paused"):
		return
	var pause_hash := hash(paused_image.get_data())
	await _wait(0.3)
	image = _image()
	if not _require(absf(player.stream_position - pause_position) < 0.08, "position advanced while paused"):
		return
	if not _require(image != null and hash(image.get_data()) == pause_hash, "presented frame changed while paused"):
		return
	player.paused = false
	if not _require(await _advance_from(pause_position, minf(0.15, length * 0.1)), "resume did not advance"):
		return
	print("LINUX_TRANSPORT_CHECK pause-resume")

	var target := length * 0.6
	player.stream_position = target
	await _wait(0.12)
	if not _require(player.stream_position >= target - 0.15 and player.stream_position <= target + 0.4, "playing seek did not settle near target"):
		return
	player.paused = true
	await _wait(0.15)
	var paused_seek_source := _image()
	if not _require(paused_seek_source != null, "texture disappeared before paused seek"):
		return
	# Compare against the frame actually visible immediately before this seek,
	# not the unrelated pause/resume baseline captured earlier in the test.
	var paused_seek_source_hash := hash(paused_seek_source.get_data())
	var paused_seek_source_position := player.stream_position
	target = length * 0.2
	player.stream_position = target
	if not _require(_preview_callbacks() == 1, "paused seek did not install exactly one preview callback"):
		return
	await _wait(0.4)
	if not _require(_preview_callbacks() == 0, "completed paused seek left its callback connected"):
		return
	if not _require(absf(player.stream_position - target) < 0.12, "paused seek did not settle at target"):
		return
	image = _image()
	var paused_seek_destination_hash := hash(image.get_data()) if image != null else 0
	print("LINUX_TRANSPORT_CHECK paused-seek source_position=", paused_seek_source_position,
		" destination_position=", player.stream_position, " source_hash=", paused_seek_source_hash,
		" destination_hash=", paused_seek_destination_hash)
	if not _require(image != null and paused_seek_destination_hash != paused_seek_source_hash, "paused seek left the immediately preceding decoded frame"):
		return
	var settled_position := player.stream_position
	await _wait(0.2)
	if not _require(absf(player.stream_position - settled_position) < 0.08, "paused seek restarted the clock"):
		return
	print("LINUX_TRANSPORT_CHECK seek-paused-seek")

	# Same-frame bursts exercise supersession without allowing a stale callback
	# to consume an earlier target between seek requests.
	image = _image()
	if not _require(image != null, "rapid paused seek has no immediately preceding image"):
		return
	var burst_source_hash := hash(image.get_data())
	for fraction in [0.75, 0.25, 0.65, 0.15, 0.85, 0.45]:
		player.stream_position = length * fraction
	target = length * 0.45
	if not _require(_preview_callbacks() == 1, "rapid paused seeks duplicated or lost the preview callback"):
		return
	await _wait(0.45)
	if not _require(_preview_callbacks() == 0, "exact scrub settling left a preview callback connected"):
		return
	if not _require(player.paused and absf(player.stream_position - target) < 0.06, "rapid paused seek did not settle at final exact target"):
		return
	image = _image()
	if not _require(image != null and hash(image.get_data()) != burst_source_hash, "rapid paused seek retained its preceding texture"):
		return
	var burst_settled_hash := hash(image.get_data())
	settled_position = player.stream_position
	await _wait(0.2)
	image = _image()
	if not _require(image != null and hash(image.get_data()) == burst_settled_hash and absf(player.stream_position - settled_position) < 0.01, "rapid paused seek kept advancing after its preview"):
		return
	print("LINUX_TRANSPORT_CHECK rapid-paused-settle target=", target, " position=", player.stream_position)

	# Resume in the same frame as a paused seek: the normal update path must
	# take over immediately, with no outstanding preview callback/captured target.
	player.stream_position = length * 0.3
	if not _require(_preview_callbacks() == 1, "seek/resume case did not start with a pending preview"):
		return
	player.paused = false
	if not _require(_preview_callbacks() == 0, "resume did not cancel the pending preview callback"):
		return
	if not _require(await _advance_from(length * 0.3, 0.15), "seek/resume cancellation prevented clock progress"):
		return
	print("LINUX_TRANSPORT_CHECK seek-resume-cancel")

	# Stop must cancel an outstanding preview, not merely an already-settled one.
	player.paused = true
	player.stream_position = length * 0.8
	if not _require(_preview_callbacks() == 1, "stop case did not start with a pending preview"):
		return
	player.stop()
	if not _require(_preview_callbacks() == 0, "stop left a pending preview callback connected"):
		return
	await _wait(0.2)
	if not _require(not player.is_playing() and absf(player.stream_position) < 0.01, "stale preview changed the stopped playback"):
		return

	# Replacing the stream must destroy/cancel the old playback before its next
	# process_frame. Keep the new one paused to expose any stale old callback.
	# stop resets playback's pause state; reset the player's persistent property
	# before starting this separate case so setting true is a real transition.
	player.paused = false
	player.play()
	player.paused = true
	player.stream_position = length * 0.7
	if not _require(_preview_callbacks() == 1, "reload case did not start with a pending preview"):
		return
	player.stream = null
	if not _require(_preview_callbacks() == 0, "stream unload left a pending preview callback connected"):
		return
	player.stream = stream
	await _wait(0.2)
	if not _require(_preview_callbacks() == 0 and not player.is_playing() and absf(player.stream_position) < 0.01, "stale preview affected reloaded playback"):
		return
	print("LINUX_TRANSPORT_CHECK pending-stop-reload-cancel")
	player.paused = false
	if not _require(not player.is_playing() and absf(player.stream_position) < 0.08, "stop did not reset playback"):
		return
	player.play()
	if not _require(await _advance_from(0.0, 0.15), "replay after stop did not advance"):
		return
	var eos_deadline := Time.get_ticks_msec() + int((length + 4.0) * 1000.0)
	while player.is_playing() and Time.get_ticks_msec() < eos_deadline:
		await process_frame
	if not _require(not player.is_playing() and finished_count > 0, "EOS did not stop and emit finished"):
		return
	print("LINUX_TRANSPORT_CHECK stop-replay-eos")

	player.loop = true
	player.play()
	var wraps := 0
	var previous := player.stream_position
	var loop_deadline := Time.get_ticks_msec() + int((length * 4.0 + 4.0) * 1000.0)
	while wraps < 3 and Time.get_ticks_msec() < loop_deadline:
		await process_frame
		var position := player.stream_position
		if previous > length * 0.65 and position < length * 0.35:
			wraps += 1
		previous = position
	if not _require(wraps >= 3 and player.is_playing(), "three loop transitions did not complete"):
		return
	if not _require(not pcm_nonfinite, "engine audio mix contained nonfinite PCM"):
		return
	if expect_audio:
		if not _require(pcm_frames > 0 and pcm_peak > 0.001, "decoded PCM did not reach Godot's audio mix bus"):
			return
	elif not _require(pcm_peak < 0.000001, "silent source produced nonzero audio"):
		return
	print("LINUX_TRANSPORT_CHECK loops=", wraps, " captured_frames=", pcm_frames, " peak=", pcm_peak)
	# Exercise reentrant destruction while the preview is actively publishing,
	# not only teardown before the callback starts. Keep the public texture ref
	# alive in the helper; it does not own the playback or its present pipeline.
	if not await _changed_lifecycle(stream, false):
		return
	if not await _changed_lifecycle(stream, true):
		return

	# Use a fresh player for the separate pre-callback destruction case.
	player = VideoStreamPlayer.new()
	player.bus = bus_name
	root.add_child(player)
	player.stream = stream
	player.play()
	if not _require(await _advance_from(0.0, 0.2), "fresh player before pending free did not advance"):
		return
	# Free directly, with neither stop nor stream=null, before the next process
	# frame can consume this burst. A weak callback must not touch the old object.
	player.paused = true
	for fraction in [0.75, 0.25, 0.65, 0.15, 0.85, 0.45]:
		player.stream_position = length * fraction
	if not _require(_preview_callbacks() == 1, "free case did not start with a pending preview"):
		return
	if not _dispose(true):
		return
	await _wait(0.2)
	print("LINUX_TRANSPORT_PASS file=", path, " audio=", expect_audio,
		" (mix capture only; no audible/A-V-sync/HDR-display assertion)")
	quit(0)
