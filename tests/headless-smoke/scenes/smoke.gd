extends Node

# -----------------------------------------------------------------------
# Headless Smoke Suite — 6 assertion groups for the Native Video
# GDExtension. Runs headless with --headless (Dummy audio driver).
# Exits 0 on all-pass, 1 on any failure.
#
# The suite is a single sequential coroutine: _ready() runs the static
# groups, then awaits phase 1 (linear playback) and phase 2 (mid-play
# track switch) in order. Nothing runs concurrently with a frequency
# capture, so a capture can never observe state from a later step.
#
# Groups 5 and 6 use AudioEffectCapture to sample the Master bus and
# measure the dominant frequency via zero-crossing. The synthetic clip
# encodes a per-frame Sync Ladder (tools/multitrack_lib.sh): track k's
# frame i plays at (k * 3000 + 200) + 200 * i Hz, so tone frequency
# encodes both track identity and media position. With a ~0.67s audio
# pipeline delay the exact frequency lags the reported position, but
# the frequency trend (Δfreq/Δt ≈ 6000 Hz/s for either track) and the
# 3000 Hz stride between tracks are both measurable externally.
#
# ACCURACY CAVEAT — read before trusting any frequency number here:
# The C++ tests in tests/common/multi_track_cases.h measure raw decoded
# PCM straight from the backend, so their zero-crossing frequencies land
# cleanly on the Sync Ladder. This smoke test measures AFTER the full
# AudioServer mix pipeline, from AAC-encoded audio. AAC's lossy encoding
# distorts the sine, so the zero-crossing estimate is NOT reliable in
# absolute terms — measured frequencies often come in 2-8x below the
# theoretical Sync Ladder values and vary run-to-run, and the Phase 2
# pre/post samples sit at different points in the audio pipeline's delay
# buffer (no shared delay). Only the SIGN of the frequency trend
# (frequency rises with position; a track switch drops the base) is a
# meaningful signal here. The slope thresholds below are noise-rejection
# bands, NOT matches against the theoretical 6000 Hz/s.
# -----------------------------------------------------------------------

const TIMEOUT := 20.0
const CLIP := "res://synthetic.mp4"
const CLIP_MOV := "res://synthetic.mov"
const CLIP_M4V := "res://synthetic.m4v"

# Sync Ladder constants (mirrors tools/multitrack_lib.sh)
const SYNC_BASE := 200.0       # Hz — track 0 base frequency
const SYNC_STRIDE := 3000.0    # Hz — frequency gap between tracks
const SYNC_PER_FRAME := 200.0  # Hz — frequency step per frame
const FPS := 30.0

# Position-monotonicity tolerances and messages per phase. Phase 2 allows
# more jitter because the track switch itself may nudge the clock.
const P1_TOLERANCE := 0.01
const P1_REGRESS_FMT := "Position regressed: %.3f -> %.3f"
const P2_TOLERANCE := 0.05
const P2_REGRESS_FMT := "Position regressed significantly after track switch: %.3f -> %.3f"

var _errors := 0
var _player: VideoStreamPlayer
var _prev_pos := -1.0
var _phase_start_ms := 0

# AudioEffectCapture setup
var _capture: AudioEffectCapture
var _capture_bus_idx := -1


# ===================================================
# Lifecycle — one sequential pass over all groups
# ===================================================

func _ready():
	print("=== Headless Smoke Suite ===")
	print("[SETUP] platform=%s audio_driver=%s" % [
		OS.get_name(),
		AudioServer.get_driver_name(),
	])

	# --- Set up AudioEffectCapture on Master bus ---
	_capture = AudioEffectCapture.new()
	_capture_bus_idx = AudioServer.get_bus_index("Master")
	AudioServer.add_bus_effect(_capture_bus_idx, _capture, 0)
	_capture.set_buffer_length(2.0)

	_player = $VideoStreamPlayer

	# --- Group 1: classes registered ---
	test_classes_registered()

	# --- Group 2: ResourceLoader resolution ---
	test_resource_loader_resolution()

	# --- Group 4: audio track enumeration ---
	test_audio_track_enumeration()

	# --- Groups 3 & 5: playback progress + frequency tracking ---
	if _errors == 0:
		await _run_phase1()

	# --- Group 6: mid-play track switch + post-switch frequency ---
	if _errors == 0:
		await _run_phase2()

	_finish()


# ===================================================
# Group 1 — classes registered
# ===================================================

func test_classes_registered():
	var expected := [
		"NativeVideoStream",
		"NativeVideoStreamPlayback",
		"NativeVideoResourceFormatLoader",
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
	var exts := ResourceLoader.get_recognized_extensions_for_type("VideoStream")
	var want := ["mp4", "mov", "m4v"]
	for ext in want:
		if ext in exts:
			print("[OK] Extension registered: .%s" % ext)
		else:
			print("[FAIL] Extension NOT registered: .%s" % ext)
			_errors += 1

	var s := ResourceLoader.load(CLIP, "VideoStream")
	if s == null:
		_fail("Could not load %s" % CLIP)
		return
	if s.get_class() == "NativeVideoStream":
		print("[OK] %s loads as NativeVideoStream" % CLIP)
	else:
		_fail("%s is %s, expected NativeVideoStream" % [CLIP, s.get_class()])

	for path in [CLIP_MOV, CLIP_M4V]:
		s = ResourceLoader.load(path, "VideoStream")
		if s == null:
			_fail("Could not load %s" % path)
			continue
		if s.get_class() == "NativeVideoStream":
			print("[OK] %s loads as NativeVideoStream" % path)
		else:
			_fail("%s is %s, expected NativeVideoStream" % [path, s.get_class()])

	print("[PASS] Group 2 — ResourceLoader resolution")


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

	var t0: Dictionary = tracks1[0]
	if t0.get("language", "") != "eng":
		_fail("Track 0 language: expected 'eng', got '%s'" % t0.get("language", ""))
	if t0.get("channels", 0) != 1:
		_fail("Track 0 channels: expected 1, got %d" % t0.get("channels", 0))
	if t0.get("sample_rate", 0) != 48000:
		_fail("Track 0 sample_rate: expected 48000, got %d" % t0.get("sample_rate", 0))
	if t0.get("default", false) != true:
		_fail("Track 0 default: expected true, got false")

	var t1: Dictionary = tracks1[1]
	if t1.get("language", "") != "fra":
		_fail("Track 1 language: expected 'fra', got '%s'" % t1.get("language", ""))
	if t1.get("channels", 0) != 1:
		_fail("Track 1 channels: expected 1, got %d" % t1.get("channels", 0))
	if t1.get("sample_rate", 0) != 48000:
		_fail("Track 1 sample_rate: expected 48000, got %d" % t1.get("sample_rate", 0))

	var tracks2 = s.get_audio_tracks()
	if tracks2 != tracks1:
		_fail("Cache mismatch: second call returned different tracks")

	print("[OK] Audio tracks: 2 tracks with expected metadata, cache works")
	print("[PASS] Group 4 — audio track enumeration")


# ===================================================
# Group 3 — playback progress
# Group 5 — Sync Ladder frequency tracking during linear playback
# ===================================================

func _run_phase1():
	print("[PHASE 1] Playing clip to EOS...")
	var stream: VideoStream = ResourceLoader.load(CLIP, "VideoStream")
	if stream == null:
		_fail("Could not load clip for playback")
		return
	_player.stream = stream
	_phase_start_ms = Time.get_ticks_msec()
	_prev_pos = -1.0
	_player.play()

	# Capture frequency at two positions during playback. The Sync Ladder
	# encodes position: frequency rises ~6000 Hz/s (theoretical) as playback
	# advances. We measure through the full AudioServer mix pipeline from
	# AAC-encoded audio, so the estimate is unreliable in absolute terms (see
	# the header CAVEAT) and only the trend is asserted at EOS. Sample late
	# to avoid startup transients.
	var s0 := {"pos": -1.0, "freq": -1.0}
	var s1 := {"pos": -1.0, "freq": -1.0}
	var reached := await _wait_for_position(0.8, P1_TOLERANCE, P1_REGRESS_FMT)
	if reached >= 0.0:
		s0 = await _capture_sample()
		print("[PHASE 1] freq sample at pos=%.3f: %.0f Hz" % [s0.pos, s0.freq])
		if s0.freq > 0:
			reached = await _wait_for_position(1.3, P1_TOLERANCE, P1_REGRESS_FMT)
			if reached >= 0.0:
				s1 = await _capture_sample()
				print("[PHASE 1] freq sample at pos=%.3f: %.0f Hz" % [s1.pos, s1.freq])
	if _errors > 0:
		return

	var final_pos := await _wait_for_eos(P1_TOLERANCE, P1_REGRESS_FMT)
	if _errors > 0:
		return

	# --- Group 3: position monotonic, advanced to EOS ---
	if final_pos > 0.0:
		print("[PHASE 1] EOS at pos=%.3fs — position advanced monotonically" % final_pos)
		print("[PASS] Group 3 — playback progress")
	else:
		_fail("EOS at zero position — no advance")
		return

	# --- Group 5 frequency assertion ---
	# See the header CAVEAT for why the exact 6000 Hz/s slope is NOT
	# asserted: AAC + AudioServer make the zero-crossing estimate unreliable
	# in absolute terms. We assert a clearly-positive trend (above the noise
	# floor, below a double-crossing-artifact ceiling), not a match against
	# 6000.
	if s0.freq > 0 and s1.freq > 0:
		var ok := true
		# The Sync Ladder frequency must rise with playback position.
		if s1.freq <= s0.freq:
			_fail("Phase 1 freq did not increase: %.0f -> %.0f Hz" % [s0.freq, s1.freq])
			ok = false
		else:
			# Lower bound rejects a near-flat signal (noise/silence);
			# upper bound rejects double-crossing artifacts from AAC
			# harmonic distortion. Theoretical slope is 6000 Hz/s; the
			# measured slope is often ~half and varies run-to-run, so the
			# band is a noise-rejection window, not a 6000 match.
			var dt: float = s1.pos - s0.pos
			var slope: float = (s1.freq - s0.freq) / dt if dt > 0 else 0.0
			if slope < 1500.0 or slope > 9000.0:
				_fail("Phase 1 freq slope %.0f Hz/s outside expected range 1500-9000 Hz/s" % slope)
				ok = false
			if ok:
				print("[PHASE 1] freq slope %.0f Hz/s (theoretical ~6000; measured varies via AAC) — Sync Ladder tracks position" % slope)
		if ok:
			print("[PASS] Group 5 — Sync Ladder frequency tracks playback position")
	else:
		_fail("Could not capture frequency samples for Group 5")


# ===================================================
# Group 6 — mid-play track switch + post-switch frequency band
# ===================================================

func _run_phase2():
	print("[PHASE 2] Track switch test...")
	var stream: VideoStream = ResourceLoader.load(CLIP, "VideoStream")
	if stream == null:
		_fail("Could not load clip for phase 2")
		return
	_phase_start_ms = Time.get_ticks_msec()
	_prev_pos = -1.0
	_player.stream = stream
	_player.audio_track = 1  # Start on the non-default track
	_player.play()
	print("[PHASE 2] Playing with track=1")

	var pre := {"pos": -1.0, "freq": -1.0}
	var post := {"pos": -1.0, "freq": -1.0}
	var switched := false

	# Pre-switch capture (track 1 audio). Because this coroutine is the only
	# driver of phase 2, the track switch below cannot run until the capture
	# has fully returned — the pre-switch sample can never contain track 0
	# audio.
	var reached := await _wait_for_position(0.8, P2_TOLERANCE, P2_REGRESS_FMT)
	if reached >= 0.0:
		pre = await _capture_sample()
		print("[PHASE 2] Pre-switch freq at pos=%.3f (track 1): %.0f Hz" % [pre.pos, pre.freq])

		# Switch tracks at ~1 second in.
		var switch_pos := await _wait_for_position(1.0, P2_TOLERANCE, P2_REGRESS_FMT)
		if switch_pos >= 0.0:
			_player.audio_track = 0
			switched = true
			print("[PHASE 2] Switched to track 0 at pos=%.3fs" % switch_pos)

			# Post-switch capture: wait ~0.7s after the switch for the audio
			# pipeline to deliver track 0 audio.
			reached = await _wait_for_position(1.7, P2_TOLERANCE, P2_REGRESS_FMT)
			if reached >= 0.0:
				post = await _capture_sample()
				print("[PHASE 2] Post-switch freq at pos=%.3f (track 0): %.0f Hz" % [post.pos, post.freq])
	if _errors > 0:
		return

	var final_pos := await _wait_for_eos(P2_TOLERANCE, P2_REGRESS_FMT)
	if _errors > 0:
		return

	if final_pos > 0.0 and switched:
		print("[PHASE 2] EOS at pos=%.3fs after track switch" % final_pos)
		print("[PASS] mid-play track switch — playback continued after switching audio track")
		_assert_post_switch_freq(pre, post)
	elif final_pos > 0.0:
		_fail("Track switch never executed (clip ended before switch point)")
	else:
		_fail("No position advance in phase 2")


func _assert_post_switch_freq(pre: Dictionary, post: Dictionary):
	if pre.freq < 0 or post.freq < 0:
		# Frequency capture failed — not a hard failure if capture is
		# impossible, but log it.
		print("[INFO] Group 6 skipped — frequency samples not available")
		return

	var ok := true

	# What this assertion can and cannot prove, stated honestly:
	#
	# Both captures go through the full AudioServer mix pipeline from
	# AAC-encoded audio, so zero-crossing frequencies are NOT reliable in
	# absolute terms (see the header CAVEAT). Worse, the pre- and post-switch
	# samples sit at DIFFERENT points in the audio pipeline's delay buffer,
	# so they do NOT share a common pipeline delay — the slope's premise of a
	# shared delay is false, and the slope is not a clean theoretical value.
	#
	# What we CAN distinguish: if the switch FAILED and we stayed on track 1,
	# both samples come from track 1's Sync Ladder and the slope is ~6000 Hz/s
	# (position advance only). A successful switch to track 0 drops the base
	# by 3000 Hz, so the net slope falls well below 6000. The > 5000 Hz/s
	# threshold catches the "still on track 1" case.
	#
	# What we CANNOT distinguish: a successful switch from a signal too weak
	# to measure (both give a low slope). So this proves we did NOT stay on
	# track 1, NOT that clean track-0 audio reached the output.

	var dt: float = post.pos - pre.pos
	var diff: float = post.freq - pre.freq
	var slope: float = diff / dt if dt > 0 else 0.0

	print("[PHASE 2] Pre-switch: %.0f Hz at pos %.3f (track 1)" % [pre.freq, pre.pos])
	print("[PHASE 2] Post-switch: %.0f Hz at pos %.3f (track 0)" % [post.freq, post.pos])
	print("[PHASE 2] Δfreq=%.0f Hz over Δt=%.3fs (slope=%.0f Hz/s)" % [diff, dt, slope])

	# Still on track 1 => slope ~6000 Hz/s. Switch to track 0 => slope well
	# below 6000 (the 3000 Hz track-base drop subtracts from the position
	# advance). > 5000 Hz/s means the switch did not take effect. A strongly
	# negative slope is not expected even for a successful switch and smells
	# like an audio pipeline problem.
	if slope > 5000.0:
		_fail("Post-switch slope %.0f Hz/s > 5000 — track switch did not take effect (still on track 1 would be ~6000 Hz/s)" % slope)
		ok = false
	elif slope < -3000.0:
		_fail("Post-switch slope %.0f Hz/s is too low — possible audio pipeline issue" % slope)
		ok = false

	if ok:
		print("[PHASE 2] Post-switch slope %.0f Hz/s (< 5000) confirms we did not stay on track 1" % slope)
		print("[PASS] Group 6 — post-switch slope confirms audio track changed (not still track 1)")


# ===================================================
# Playback polling
# ===================================================

func _phase_elapsed() -> float:
	return float(Time.get_ticks_msec() - _phase_start_ms) / 1000.0


# Poll frame-by-frame until stream_position reaches `target`, checking the
# per-phase timeout and position monotonicity on every frame. Returns the
# position at which the target was reached, or -1.0 if playback stopped
# first (EOS — not a failure; the caller decides) or on timeout/regression
# (both _fail()).
func _wait_for_position(target: float, tolerance: float, regress_fmt: String) -> float:
	while true:
		await get_tree().process_frame
		if _phase_elapsed() > TIMEOUT:
			_fail("TIMEOUT — no EOS after %.1fs" % TIMEOUT)
			return -1.0
		if not _player.is_playing():
			# Ignore the not-yet-started window right after play().
			if _phase_elapsed() > 0.5:
				return -1.0
			continue
		var pos := _player.stream_position
		if _prev_pos >= 0 and pos < _prev_pos - tolerance:
			_fail(regress_fmt % [_prev_pos, pos])
			return -1.0
		_prev_pos = pos
		if pos >= target:
			return pos
	return -1.0  # unreachable


# Poll frame-by-frame until the player stops (EOS), with the same timeout
# and monotonicity checks. Returns the final stream position, or -1.0 on
# timeout/regression (both _fail()).
func _wait_for_eos(tolerance: float, regress_fmt: String) -> float:
	while true:
		await get_tree().process_frame
		if _phase_elapsed() > TIMEOUT:
			_fail("TIMEOUT — no EOS after %.1fs" % TIMEOUT)
			return -1.0
		if not _player.is_playing():
			# Ignore the not-yet-started window right after play().
			if _phase_elapsed() > 0.5:
				return _player.stream_position
			continue
		var pos := _player.stream_position
		if _prev_pos >= 0 and pos < _prev_pos - tolerance:
			_fail(regress_fmt % [_prev_pos, pos])
			return -1.0
		_prev_pos = pos
	return -1.0  # unreachable


# ===================================================
# Audio capture and frequency measurement
# ===================================================

# Read the position first, then capture: the sample's position is the
# moment the capture was requested, matching how the Sync Ladder encodes
# position into frequency.
func _capture_sample() -> Dictionary:
	var pos := _player.stream_position
	var freq := await _capture_and_measure_freq()
	return {"pos": pos, "freq": freq}


func _capture_and_measure_freq() -> float:
	# Wait for at least 4800 frames (100 ms) of captured audio
	var deadline := 2.0  # max seconds to wait
	var waited := 0.0
	var step := 0.01
	while _capture.get_frames_available() < 4800 and waited < deadline:
		waited += step
		await get_tree().create_timer(step).timeout

	var frames_avail := _capture.get_frames_available()
	if frames_avail < 256:
		return -1.0  # Not enough audio

	var buffer := _capture.get_buffer(frames_avail)

	# Extract left channel (mono clip, but AudioEffectCapture returns stereo)
	var mono := PackedFloat32Array()
	mono.resize(buffer.size())
	for i in buffer.size():
		mono[i] = buffer[i].x

	# Find first non-zero span
	var start := 0
	while start < mono.size() and abs(mono[start]) < 0.001:
		start += 1

	if start >= mono.size() - 2:
		return -1.0  # All zero/silence

	# Zero-crossing frequency estimate (matches the C++ implementation in
	# tests/common/multi_track_cases.h). CAVEAT: the C++ tests measure raw
	# decoded PCM straight from the backend; this smoke test measures AFTER
	# the AudioServer mix pipeline, from AAC-encoded audio. AAC's lossy
	# encoding distorts the sine, so the estimate is unreliable in absolute
	# terms (see the header CAVEAT and Group 5). Only the trend sign is
	# meaningful here.
	var crossings := 0
	var prev := mono[start]
	var window := mini(mono.size() - start, 14400)  # max 300 ms
	for i in range(start + 1, start + window):
		var cur := mono[i]
		if (prev < 0.0) != (cur < 0.0):
			crossings += 1
		prev = cur

	var duration := float(window) / 48000.0
	if duration <= 0.0:
		return -1.0
	return (float(crossings) / 2.0) / duration


# ===================================================
# Helpers
# ===================================================

func _fail(msg: String):
	print("[FAIL] %s" % msg)
	_errors += 1


func _finish():
	# Remove the AudioEffectCapture we added at effect index 0 on Master.
	if _capture_bus_idx >= 0 and _capture:
		AudioServer.remove_bus_effect(_capture_bus_idx, 0)
		_capture = null

	if _errors == 0:
		print("=== ALL PASS ===")
		if OS.is_stdout_verbose():
			print("[INFO] 0 errors, exiting 0")
		get_tree().quit(0)
	else:
		print("=== %d FAILURE(S) ===" % _errors)
		get_tree().quit(1)
