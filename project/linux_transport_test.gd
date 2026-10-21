# Public VideoStreamPlayer integration regression; requires a rendered RD.
# godot --path project --script res://linux_transport_test.gd -- \
#   --file=/tmp/fixtures/h264-aac.mp4 --expect-audio=1
# The shell runner supplies an outer timeout and rejects engine/load errors.
extends SceneTree

const Oracle = preload("res://linux_transport_oracles.gd")

var player: VideoStreamPlayer
var capture: AudioEffectCapture
var bus_index := -1
var finished_count := 0
var audio_window: Oracle.AudioWindow
var pcm_nonfinite := false
var pcm_nonzero := false # Negative-only evidence for silent fixtures, never audio success.
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
			if audio_window != null:
				audio_window.consume(samples)
			for sample in samples:
				if not is_finite(sample.x) or not is_finite(sample.y):
					pcm_nonfinite = true
				if maxf(absf(sample.x), absf(sample.y)) >= 0.000001:
					pcm_nonzero = true
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
	if is_instance_valid(player):
		print("LINUX_TRANSPORT_STATE position=", player.stream_position,
			" playing=", player.is_playing(), " paused=", player.paused,
			" processing=", player.is_processing_internal(),
			" process_frames=", Engine.get_process_frames(), " draws=", Engine.get_frames_drawn())
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


# Always drain capture in _process, including the discard interval. Give the
# player's default 500ms audio buffer plus a mixer block time to retire, then
# clear anything captured before this phase. No startup/cumulative evidence is
# carried into the next window. Dummy still exercises the engine mixer.
# Collection ends on sample count, not a wall window: Dummy/physical drivers
# can deliver 4096-frame blocks unevenly relative to process_frame. The 750ms
# deadline bounds missing capture; it never substitutes elapsed time for PCM.
func _check_audio_phase(expect_audio: bool, phase: String) -> bool:
	audio_window = null
	var window := Oracle.AudioWindow.new()
	var source_id := player.get_instance_id()
	var length := player.get_stream_length()
	var minimum_frames := int(AudioServer.get_mix_rate() * 0.1)
	# Silent fixtures have no queued PCM to retire. Still require the same
	# number of actual mixer frames, including for the one-second HEVC clip.
	var discard_until := Time.get_ticks_msec() + (600 if expect_audio else 40)
	var deadline := discard_until + 750
	var collecting := false
	while not failed:
		if not is_instance_valid(player) or player.get_instance_id() != source_id or not player.is_playing() or player.paused:
			audio_window = null
			return _require(false, "audio phase ended before fresh evidence: " + phase)
		window.observe_position(player.stream_position, length)
		if window.phase_wraps != 0:
			audio_window = null
			return _require(false, "audio evidence crossed into another loop iteration: " + phase)
		var now := Time.get_ticks_msec()
		if not collecting and now >= discard_until:
			capture.clear_buffer()
			audio_window = window
			collecting = true
		if window.frames >= minimum_frames or now >= deadline:
			break
		await process_frame
	audio_window = null
	print("LINUX_TRANSPORT_AUDIO phase=", phase, " frames=", window.frames,
		" minimum_frames=", minimum_frames, " rms=", window.rms(),
		" active_frames=", window.active_frames, " phase_wraps=", window.phase_wraps)
	return _require(not failed and window.valid(expect_audio, minimum_frames),
		"fresh audio window failed or capture deadline expired after " + phase)


# Detect the backward transition independently of its destination: requiring
# position < 35% here would hide the regression that restarts at the old scrub
# target (45%). Neither this helper nor the caller seeks/stops/reloads at EOS.
func _check_loops(expect_audio: bool, phase: String) -> bool:
	var length := player.get_stream_length()
	var wraps := 0
	var previous := player.stream_position
	var deadline := Time.get_ticks_msec() + int((length * 4.0 + 4.0) * 1000.0)
	while not failed and wraps < 3 and Time.get_ticks_msec() < deadline:
		await process_frame
		var position := player.stream_position
		if previous > length * 0.65 and position < previous - length * 0.2:
			wraps += 1
			var iteration := "%s-%d" % [phase, wraps]
			print("LINUX_TRANSPORT_LOOP phase=", iteration, " previous=", previous, " restart=", position)
			if not _require(position >= 0.0 and position < 0.1, iteration + " did not restart at zero"):
				return false
			# Presentation can trail the reset clock by a rendered epoch. Require
			# an actual early-frame marker before leaving the first 200ms, not
			# just a reset clock over stale EOS/scrub pixels. Do not pause/seek
			# to obtain the image: that would repair the behavior under test.
			var marker := Oracle.marker_frame(_image())
			var marker_deadline := Time.get_ticks_msec() + 1000
			while (marker < 0 or marker > 6) and player.stream_position < 0.2 and Time.get_ticks_msec() < marker_deadline:
				await process_frame
				marker = Oracle.marker_frame(_image())
			print("LINUX_TRANSPORT_MARKER phase=", iteration, " actual=", marker, " expected=0..6")
			if not _require(marker >= 0 and marker <= 6, iteration + " did not render the beginning of the clip"):
				return false
			if not await _check_audio_phase(expect_audio, iteration):
				return false
		previous = player.stream_position
	if not _require(wraps == 3 and player.is_playing(), phase + " did not complete three loop transitions"):
		return false
	print("LINUX_TRANSPORT_CHECK phase=", phase, " loops=", wraps, " (restart clock, frame markers, independent audio windows)")
	return true


func _require_seek_image(image: Image, target: float, phase: String) -> bool:
	print("LINUX_TRANSPORT_MARKER phase=", phase, " actual=", Oracle.marker_frame(image),
		" expected=", Oracle.expected_seek_frame(target), " target=", target)
	return _require(Oracle.matches_seek(image, target), phase + " rendered the wrong temporal frame")


# Signal introspection is public in both supported stock Godot versions. Count
# only the shared extension presentation/retirement pump, not this test's
# coroutine frame subscriptions. A connected pump alone is not pending seek
# evidence while playing; paused cases drain old retirements before scheduling.
func _presentation_callbacks() -> int:
	var count := 0
	for connection in get_signal_connection_list("process_frame"):
		var callback: Callable = connection["callable"]
		if callback.get_method() == &"process_presentation":
			count += 1
	return count


# A paused/stopped pump may remain connected for three actual rendered epochs
# to retire GPU work. Poll the observable connection, not a guessed sleep.
# Preview resolution gets a larger bounded epoch budget; settled retirement
# gets three epochs plus scheduling slack. The wall deadline catches no-draw
# stalls without treating process_frame ticks as completed GPU render epochs.
func _drain_presentation(phase: String, max_render_epochs: int = 6) -> bool:
	var first_epoch := Engine.get_frames_drawn()
	var deadline := Time.get_ticks_msec() + 3000
	while not failed and _presentation_callbacks() > 0:
		if not _require(_presentation_callbacks() == 1, phase + " duplicated the presentation pump"):
			return false
		if Engine.get_frames_drawn() - first_epoch > max_render_epochs or Time.get_ticks_msec() >= deadline:
			return _require(false, phase + " presentation pump did not drain within its render-epoch budget")
		await process_frame
	return not failed


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
	if not _require(player.paused and _presentation_callbacks() == 1, "changed mutation did not run inside a paused preview"):
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
	if not await _drain_presentation("changed-lifecycle pause"):
		return false
	var texture := player.get_video_texture()
	if not _require(texture != null and _presentation_callbacks() == 0, "changed lifecycle has no settled source texture"):
		return false
	var victim_id := player.get_instance_id()
	var before := changed_mutations
	texture.changed.connect(_on_preview_changed.bind(free_player, stream), CONNECT_ONE_SHOT)
	player.stream_position = player.get_stream_length() * 0.2
	if not _require(_presentation_callbacks() == 1, "changed lifecycle did not schedule a preview"):
		return false
	var deadline := Time.get_ticks_msec() + 3000
	while not failed and changed_mutations == before and Time.get_ticks_msec() < deadline:
		await process_frame
	# Allow the synchronous publisher's stack to unwind before inspecting its
	# connection. Completion is event-based; no assumed number of render ticks.
	await process_frame
	if not _require(not failed and changed_mutations == before + 1, "paused preview did not invoke its synchronous changed handler exactly once"):
		return false
	if not _require(_presentation_callbacks() == 0, "changed mutation left the old preview callback connected"):
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
	if not _require(_presentation_callbacks() == 0 and changed_mutations == before + 1, "changed mutation left stale callbacks or repeated publication"):
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
	if not _require(_presentation_callbacks() == 0, "free left a paused-preview callback connected"):
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
	# Godot's first update has delta 0; finish the cold first draw before timing
	# playback progress. The shell's outer timeout still bounds renderer startup.
	await RenderingServer.frame_post_draw
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
	if not await _check_audio_phase(expect_audio, "initial-play"):
		return

	player.paused = true
	if not await _drain_presentation("initial pause"):
		return
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
	if not await _check_audio_phase(expect_audio, "resume"):
		return
	print("LINUX_TRANSPORT_CHECK pause-resume")

	# Exercise a playing seek early enough to collect independent audio evidence
	# even in the one-second fixture. Settle on actual clock progress, not an
	# extra wall-clock sleep that consumes the short clip's remaining duration.
	var target := length * 0.25
	player.stream_position = target
	if not _require(await _advance_from(target, 1.0 / Oracle.FRAME_RATE), "playing seek did not advance from target"):
		return
	if not _require(player.stream_position >= target - 0.15 and player.stream_position <= target + 0.4, "playing seek did not settle near target"):
		return
	if not await _check_audio_phase(expect_audio, "playing-seek"):
		return
	player.paused = true
	if not await _drain_presentation("pause before target seek"):
		return
	target = length * 0.2
	player.stream_position = target
	if not _require(_presentation_callbacks() == 1, "paused seek did not install exactly one preview callback"):
		return
	if not await _drain_presentation("paused-seek completion", 120):
		return
	if not _require(absf(player.stream_position - target) < 0.12, "paused seek did not settle at target"):
		return
	image = _image()
	if not _require_seek_image(image, target, "paused-seek"):
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
	for fraction in [0.75, 0.25, 0.65, 0.15, 0.85, 0.45]:
		player.stream_position = length * fraction
	target = length * 0.45
	if not _require(_presentation_callbacks() == 1, "rapid paused seeks duplicated or lost the preview callback"):
		return
	if not await _drain_presentation("rapid-paused-seek completion", 120):
		return
	if not _require(player.paused and absf(player.stream_position - target) < 0.06, "rapid paused seek did not settle at final exact target"):
		return
	image = _image()
	if not _require_seek_image(image, target, "rapid-paused-seek"):
		return
	var burst_settled_hash := hash(image.get_data())
	settled_position = player.stream_position
	await _wait(0.2)
	image = _image()
	if not _require(image != null and hash(image.get_data()) == burst_settled_hash and absf(player.stream_position - settled_position) < 0.01, "rapid paused seek kept advancing after its preview"):
		return
	print("LINUX_TRANSPORT_CHECK rapid-paused-settle target=", target, " position=", player.stream_position)

	# Resume in the same frame as a paused seek: the normal update path must
	# take over immediately. Its pump may remain for GPU retirement, but must
	# not replay a captured preview target or duplicate its connection.
	player.stream_position = length * 0.3
	if not _require(_presentation_callbacks() == 1, "seek/resume case did not start with a pending preview"):
		return
	player.paused = false
	if not _require(_presentation_callbacks() <= 1, "resume duplicated the presentation pump"):
		return
	if not _require(await _advance_from(length * 0.3, 0.15), "seek/resume cancellation prevented clock progress"):
		return
	if not await _check_audio_phase(expect_audio, "seek-resume"):
		return
	print("LINUX_TRANSPORT_CHECK seek-resume-cancel")

	# Stop must cancel an outstanding preview, not merely an already-settled one.
	player.paused = true
	if not await _drain_presentation("pause before pending stop"):
		return
	player.stream_position = length * 0.8
	if not _require(_presentation_callbacks() == 1, "stop case did not start with a pending preview"):
		return
	player.stop()
	if not await _drain_presentation("pending-preview stop"):
		return
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
	if not _require(_presentation_callbacks() == 1, "reload case did not start with a pending preview"):
		return
	player.stream = null
	if not _require(_presentation_callbacks() == 0, "stream unload left a pending preview callback connected"):
		return
	player.stream = stream
	await _wait(0.2)
	if not _require(_presentation_callbacks() == 0 and not player.is_playing() and absf(player.stream_position) < 0.01, "stale preview affected reloaded playback"):
		return
	print("LINUX_TRANSPORT_CHECK pending-stop-reload-cancel")
	player.paused = false
	if not _require(not player.is_playing() and absf(player.stream_position) < 0.08, "stop did not reset playback"):
		return
	player.play()
	if not _require(await _advance_from(0.0, 0.15), "replay after stop did not advance"):
		return
	if not await _check_audio_phase(expect_audio, "stop-replay"):
		return
	var eos_deadline := Time.get_ticks_msec() + int((length + 4.0) * 1000.0)
	while player.is_playing() and Time.get_ticks_msec() < eos_deadline:
		await process_frame
	if not _require(not player.is_playing() and finished_count > 0, "EOS did not stop and emit finished"):
		return
	print("LINUX_TRANSPORT_CHECK stop-replay-eos")

	player.loop = true
	player.play()
	if not await _check_audio_phase(expect_audio, "loop-start"):
		return
	# Preserve the no-scrub control on the clean playback created above.
	if not await _check_loops(expect_audio, "loop"):
		return

	# Keep the same playback and its nonzero scrub history through natural EOS.
	# A stop, stream replacement or explicit seek(0) here masks stale resume
	# targets when Godot implements looping by calling play() directly.
	player.paused = true
	if not await _drain_presentation("pause before loop scrub"):
		return
	target = length * 0.45
	player.stream_position = target
	if not await _drain_presentation("loop scrub completion", 120):
		return
	if not _require(player.paused and absf(player.stream_position - target) < 0.06, "loop scrub did not settle at nonzero target"):
		return
	if not _require_seek_image(_image(), target, "loop-paused-scrub"):
		return
	player.paused = false
	if not _require(await _advance_from(target, 1.0 / Oracle.FRAME_RATE), "loop scrub resume did not advance"):
		return
	if not await _check_loops(expect_audio, "loop-after-scrub"):
		return
	if not _require(not pcm_nonfinite, "engine audio mix contained nonfinite PCM"):
		return
	if not expect_audio and not _require(not pcm_nonzero, "silent source produced nonzero audio outside its windows"):
		return
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
	if not await _drain_presentation("pause before pending free"):
		return
	for fraction in [0.75, 0.25, 0.65, 0.15, 0.85, 0.45]:
		player.stream_position = length * fraction
	if not _require(_presentation_callbacks() == 1, "free case did not start with a pending preview"):
		return
	if not _dispose(true):
		return
	await _wait(0.2)
	print("LINUX_TRANSPORT_PASS file=", path, " audio=", expect_audio,
		" (mix capture only; no audible/A-V-sync/HDR-display assertion)")
	quit(0)
