# Pure oracle negatives: godot --headless --path project --script res://linux_transport_oracles_test.gd
extends SceneTree

const Oracle = preload("res://linux_transport_oracles.gd")
var failures := 0


func _check(ok: bool, reason: String) -> void:
	if not ok:
		failures += 1
		push_error(reason)


func _marked_image(frame: int, black: float = 0.05, white: float = 0.8) -> Image:
	var image := Image.create(320, 240, false, Image.FORMAT_RGBF)
	image.fill(Color(0.4, 0.2, 0.1))
	for cell in range(9):
		var high := cell == 1 or (cell >= 2 and (frame & (1 << (cell - 2))) != 0)
		var level := white if high else black
		image.fill_rect(Rect2i(16 + cell * 32, 16, 32, 32), Color(level, level, level))
	return image


func _initialize() -> void:
	# Include exact, fractional and near-boundary targets for both durations.
	for pair in [[0.6, 18], [1.35, 41], [0.2, 6], [0.45, 14], [1.0, 30], [1.007, 30], [1.009, 31]]:
		_check(Oracle.expected_seek_frame(pair[0]) == pair[1], "wrong seek frame rounding")
	for frame in range(90):
		for levels in [[0.0, 1.0], [0.08, 0.65], [0.02, 0.95]]:
			_check(Oracle.marker_frame(_marked_image(frame, levels[0], levels[1])) == frame, "marker conversion tolerance failed")
	var preceding := _marked_image(18)
	var wrong_nonstale := _marked_image(77) # earlier 0.85 request in the burst
	_check(hash(preceding.get_data()) != hash(wrong_nonstale.get_data()), "negative must defeat the old hash oracle")
	_check(not Oracle.matches_seek(wrong_nonstale, 1.35), "wrong nonstale burst frame passed")
	_check(not Oracle.matches_seek(_marked_image(40), 1.35), "floor frame passed ceil seek contract")
	_check(Oracle.matches_seek(_marked_image(41), 1.35), "correct target rejected")
	_check(not Oracle.matches_seek(_marked_image(0, 0.3, 0.31), 0.0), "low contrast marker passed")
	var ambiguous := _marked_image(41)
	ambiguous.fill_rect(Rect2i(80, 16, 32, 32), Color(0.4, 0.4, 0.4))
	_check(Oracle.marker_frame(ambiguous) == -1, "ambiguous bit passed")

	var tone := PackedVector2Array()
	var silence := PackedVector2Array()
	for i in range(8000):
		var sample := sin(float(i) * TAU * 440.0 / 48000.0) * 0.08
		tone.append(Vector2(sample, sample))
		silence.append(Vector2.ZERO)
	# 4096 fresh frames are healthy but incomplete, not an immediate failure.
	# A delayed second mixer block must satisfy the unchanged 4800 minimum.
	var delayed := Oracle.AudioWindow.new()
	delayed.consume(tone.slice(0, 4096))
	_check(not delayed.valid(true, 4800), "short first mixer block certified sufficient evidence")
	delayed.consume(PackedVector2Array())
	_check(delayed.frames == 4096, "empty delivery invented mixer frames")
	delayed.consume(tone.slice(0, 4096))
	_check(delayed.valid(true, 4800), "delayed healthy second mixer block rejected")
	var delayed_silence := Oracle.AudioWindow.new()
	delayed_silence.consume(silence.slice(0, 4096))
	_check(not delayed_silence.valid(false, 4800), "short silent block certified sufficient evidence")
	delayed_silence.consume(silence.slice(0, 4096))
	_check(delayed_silence.valid(false, 4800), "delayed silent mixer frames rejected")
	_check(not delayed_silence.valid(true, 4800), "delayed silence certified post-first-loop audio")
	var crossed_wrap := Oracle.AudioWindow.new()
	crossed_wrap.observe_position(2.8, 3.0)
	crossed_wrap.consume(tone)
	crossed_wrap.observe_position(0.1, 3.0)
	_check(crossed_wrap.phase_wraps == 1 and not crossed_wrap.valid(true, 4800), "cross-loop audio certified the preceding iteration")
	var same_iteration := Oracle.AudioWindow.new()
	same_iteration.observe_position(0.05, 1.0)
	same_iteration.observe_position(0.25, 1.0)
	same_iteration.consume(silence)
	_check(same_iteration.valid(false, 4800), "short silent clip's same-iteration evidence rejected")
	var first_iteration := Oracle.AudioWindow.new()
	first_iteration.consume(tone)
	_check(first_iteration.valid(true, 4800), "initial tone rejected")
	for iteration in range(3):
		var loop_window := Oracle.AudioWindow.new()
		loop_window.consume(silence)
		_check(not loop_window.valid(true, 4800), "audio stopping after first iteration passed loop %d" % iteration)
		_check(loop_window.valid(false, 4800), "silent fixture rejected")
	var empty := Oracle.AudioWindow.new()
	_check(not empty.valid(false, 4800), "absent mix samples certified silence")
	var transient := Oracle.AudioWindow.new()
	silence[0] = Vector2(1.0, 1.0)
	transient.consume(silence)
	_check(not transient.valid(true, 4800), "single stale transient certified audio")
	print("LINUX_TRANSPORT_ORACLES_", "PASS" if failures == 0 else "FAIL", " failures=", failures)
	quit(0 if failures == 0 else 1)
