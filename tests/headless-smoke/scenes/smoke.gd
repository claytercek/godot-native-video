extends Node

# -----------------------------------------------------------------------
# Headless Smoke Suite — 5 assertion groups for the native media streams
# GDExtension. Runs headless with --headless (Dummy audio driver).
# Exits 0 on all-pass, 1 on any failure.
# -----------------------------------------------------------------------

const TIMEOUT := 20.0
const CLIP := "res://synthetic.mp4"
const CLIP_MOV := "res://synthetic.mov"
const CLIP_M4V := "res://synthetic.m4v"

var _elapsed := 0.0
var _errors := 0
var _player: VideoStreamPlayer
var _prev_pos := -1.0

# Phase: 0=static-tests, 1=play-to-eos, 2=track-switch, 3=done
var _phase := 0
var _switch_done := false
var _stream: VideoStream


# ===================================================
# Lifecycle
# ===================================================

func _ready():
	print("=== Headless Smoke Suite ===")
	print("[SETUP] platform=%s audio_driver=%s" % [
		OS.get_name(),
		AudioServer.get_driver_name(),
	])

	# --- Group 1: classes registered ---
	test_classes_registered()

	# --- Group 2: ResourceLoader resolution ---
	test_resource_loader_resolution()

	# --- Group 4: audio track enumeration ---
	# Run before phase 1 so the probe-once cache is exercised live.
	test_audio_track_enumeration()

	# --- Group 3 (async): playback progress ---
	if _errors > 0:
		_finish()
		return

	var ok := _start_phase1()
	if ok:
		_phase = 1
	else:
		_finish()


func _process(delta):
	if _phase == 0 or _phase == 3:
		return

	_elapsed += delta
	if _elapsed > TIMEOUT:
		_fail("TIMEOUT — no EOS after %.1fs" % TIMEOUT)
		_finish()
		return

	if _phase == 1:
		_phase1_process()
	elif _phase == 2:
		_phase2_process()


# ===================================================
# Group 1 — classes registered
# ===================================================

func test_classes_registered():
	var expected := [
		"PlatformVideoStream",
		"PlatformVideoStreamPlayback",
		"PlatformMediaResourceFormatLoader",
	]
	var all_ok := true
	for cls in expected:
		if ClassDB.class_exists(cls):
			print("[OK] Class registered: %s" % cls)
		else:
			print("[FAIL] Class NOT registered: %s" % cls)
			_errors += 1
			all_ok = false
	if all_ok:
		print("[PASS] Group 1 — all classes registered")


# ===================================================
# Group 2 — ResourceLoader resolves .mp4/.mov/.m4v
# ===================================================

func test_resource_loader_resolution():
	# Check that the format loader registered the three extensions.
	var exts := ResourceLoader.get_recognized_extensions_for_type("VideoStream")
	var want := ["mp4", "mov", "m4v"]
	for ext in want:
		if ext in exts:
			print("[OK] Extension registered: .%s" % ext)
		else:
			print("[FAIL] Extension NOT registered: .%s" % ext)
			_errors += 1

	# Actually load a .mp4 and verify it is a PlatformVideoStream.
	var s := ResourceLoader.load(CLIP, "VideoStream")
	if s == null:
		_fail("Could not load %s" % CLIP)
		return
	if s.get_class() == "PlatformVideoStream":
		print("[OK] %s loads as PlatformVideoStream" % CLIP)
	else:
		_fail("%s is %s, expected PlatformVideoStream" % [CLIP, s.get_class()])

	# Verify .mov and .m4v files also load (the loader handles all three).
	for path in [CLIP_MOV, CLIP_M4V]:
		s = ResourceLoader.load(path, "VideoStream")
		if s == null:
			_fail("Could not load %s" % path)
			continue
		if s.get_class() == "PlatformVideoStream":
			print("[OK] %s loads as PlatformVideoStream" % path)
		else:
			_fail("%s is %s, expected PlatformVideoStream" % [path, s.get_class()])

	print("[PASS] Group 2 — ResourceLoader resolution")


# ===================================================
# Group 3 — playback progress (phase 1)
# ===================================================

func _start_phase1() -> bool:
	print("[PHASE 1] Playing clip to EOS...")
	_player = $VideoStreamPlayer
	_stream = ResourceLoader.load(CLIP, "VideoStream")
	if _stream == null:
		_fail("Could not load clip for playback")
		return false
	_player.stream = _stream
	_elapsed = 0.0
	_prev_pos = -1.0
	_player.play()
	return true


func _phase1_process():
	if _player.is_playing():
		var pos := _player.stream_position
		if _prev_pos >= 0 and pos < _prev_pos - 0.01:
			_fail("Position regressed: %.3f -> %.3f" % [_prev_pos, pos])
			_finish()
			return
		_prev_pos = pos
	elif _elapsed > 0.5:
		# EOS reached
		var pos := _player.stream_position
		if pos > 0.0:
			print("[PHASE 1] EOS at pos=%.3fs — position advanced monotonically" % pos)
			print("[PASS] Group 3 — playback progress")
		else:
			_fail("EOS at zero position — no advance")
			_finish()
			return
		_start_phase2()


# ===================================================
# Group 4 — audio track enumeration
# ===================================================

func test_audio_track_enumeration():
	var s := ResourceLoader.load(CLIP, "VideoStream")
	if s == null:
		_fail("Cannot test audio tracks: clip not loaded")
		return

	var tracks1 = s.get_audio_tracks()
	if tracks1.size() != 2:
		_fail("Expected 2 audio tracks, got %d" % tracks1.size())
		return

	# Track 0: eng, 1ch, 48kHz, default
	var t0: Dictionary = tracks1[0]
	if t0.get("language", "") != "eng":
		_fail("Track 0 language: expected 'eng', got '%s'" % t0.get("language", ""))
	if t0.get("channels", 0) != 1:
		_fail("Track 0 channels: expected 1, got %d" % t0.get("channels", 0))
	if t0.get("sample_rate", 0) != 48000:
		_fail("Track 0 sample_rate: expected 48000, got %d" % t0.get("sample_rate", 0))
	if t0.get("default", false) != true:
		_fail("Track 0 default: expected true, got false")

	# Track 1: fra, 1ch, 48kHz
	var t1: Dictionary = tracks1[1]
	if t1.get("language", "") != "fra":
		_fail("Track 1 language: expected 'fra', got '%s'" % t1.get("language", ""))
	if t1.get("channels", 0) != 1:
		_fail("Track 1 channels: expected 1, got %d" % t1.get("channels", 0))
	if t1.get("sample_rate", 0) != 48000:
		_fail("Track 1 sample_rate: expected 48000, got %d" % t1.get("sample_rate", 0))

	# Cache check: second call returns equivalent data
	var tracks2 = s.get_audio_tracks()
	if tracks2 != tracks1:
		_fail("Cache mismatch: second call returned different tracks")

	print("[OK] Audio tracks: 2 tracks with expected metadata, cache works")
	print("[PASS] Group 4 — audio track enumeration")


# ===================================================
# Group 5 — mid-play track switch (phase 2)
# ===================================================

func _start_phase2():
	print("[PHASE 2] Track switch test...")

	_stream = ResourceLoader.load(CLIP, "VideoStream")
	if _stream == null:
		_fail("Could not load clip for phase 2")
		_finish()
		return

	_phase = 2
	_elapsed = 0.0
	_prev_pos = -1.0
	_switch_done = false

	_player.stream = _stream
	_player.audio_track = 1  # Start on the non-default track
	_player.play()
	print("[PHASE 2] Playing with track=1")


func _phase2_process():
	if not _player.is_playing():
		if _elapsed > 0.5:
			var pos := _player.stream_position
			if pos > 0.0 and _switch_done:
				print("[PHASE 2] EOS at pos=%.3fs after track switch" % pos)
				print("[PASS] Group 5 — mid-play track switch")
			elif pos > 0.0:
				_fail("Track switch never executed (clip ended before switch point)")
			else:
				_fail("No position advance in phase 2")
			_finish()
		return

	var pos := _player.stream_position

	# Switch tracks at ~1 second in
	if not _switch_done and pos > 1.0:
		_player.audio_track = 0
		print("[PHASE 2] Switched to track 0 at pos=%.3fs" % pos)
		_prev_pos = pos
		_switch_done = true
		return

	# Verify monotonic position after switch.
	# A small regression (~1 frame) is normal during audio re-sync.
	if _prev_pos >= 0 and pos < _prev_pos - 0.05:
		_fail("Position regressed significantly after track switch: %.3f -> %.3f" % [_prev_pos, pos])
		_finish()
		return
	_prev_pos = pos


# ===================================================
# Helpers
# ===================================================

func _fail(msg: String):
	print("[FAIL] %s" % msg)
	_errors += 1


func _finish():
	_phase = 3
	if _errors == 0:
		print("=== ALL PASS ===")
		if OS.is_stdout_verbose():
			print("[INFO] 0 errors, exiting 0")
		get_tree().quit(0)
	else:
		print("=== %d FAILURE(S) ===" % _errors)
		get_tree().quit(1)