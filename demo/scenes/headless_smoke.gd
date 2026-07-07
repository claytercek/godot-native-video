extends Node

# Headless smoke test. Auto-plays the clip, advances to EOS, then quits cleanly.
# Exits 0 on success, 1 on failure.

const TIMEOUT := 20.0
var _player: VideoStreamPlayer
var _started := false
var _elapsed := 0.0


func _ready():
	_player = $VideoStreamPlayer
	_player.stream = ResourceLoader.load("res://synthetic.mp4", "VideoStream")
	if not _player.stream:
		print("[HEADLESS] FAIL: could not load clip")
		get_tree().quit(1)
		return
	await get_tree().process_frame
	_player.play()
	print("[HEADLESS] Playing clip...")
	_started = true


func _process(delta):
	if not _started:
		return
	_elapsed += delta
	if _elapsed > TIMEOUT:
		print("[HEADLESS] FAIL: timed out (%.1fs)" % _elapsed)
		get_tree().quit(1)
	if not _player.is_playing() and _elapsed > 2.0:
		var pos = _player.stream_position
		print("[HEADLESS] EOS at pos=%.3fs" % pos)
		if pos > 0.0:
			print("[HEADLESS] PASS")
			get_tree().quit(0)
		else:
			print("[HEADLESS] FAIL: no advance")
			get_tree().quit(1)