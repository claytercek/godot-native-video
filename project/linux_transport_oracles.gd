# Fixture/test contracts shared by the rendered regression and headless negatives.
extends RefCounted

const FRAME_RATE := 30.0
const SEEK_EPSILON := 1.0 / 120.0


# H264 AV/silent clips have 90 frames (3s); HEVC PQ has 30 (1s), all at
# PTS n/30 starting at zero. These assertions use interior targets, not the EOS
# clamp. seekExact keeps the first PTS >= target - epsilon, not the containing
# frame (floor). The rounding allowance is far below the 1/30s frame spacing.
static func expected_seek_frame(target: float) -> int:
	return maxi(0, int(ceil((target - SEEK_EPSILON) * FRAME_RATE - 0.000001)))


# Nine 32px grayscale cells at (16,16): black/white references, then seven
# little-endian bits of the zero-based frame index. Sample interiors only.
# Normalize against references to tolerate YUV range, SDR/PQ conversion and
# compression; reject ambiguous bits rather than rounding arbitrary pixels.
static func marker_frame(image: Image) -> int:
	if image == null or image.is_empty() or image.get_size() != Vector2i(320, 240):
		return -1
	var levels: Array[float] = []
	for cell in range(9):
		var level := 0.0
		for y in [24, 32, 40]:
			for dx in [8, 16, 24]:
				var pixel := image.get_pixel(16 + cell * 32 + dx, y)
				if not is_finite(pixel.r) or not is_finite(pixel.g) or not is_finite(pixel.b):
					return -1
				level += pixel.get_luminance()
		levels.append(level / 9.0)
	var contrast := levels[1] - levels[0]
	if contrast < 0.1:
		return -1
	var frame := 0
	for bit in range(7):
		var value := (levels[bit + 2] - levels[0]) / contrast
		if absf(value) <= 0.2:
			continue
		if absf(value - 1.0) > 0.2:
			return -1
		frame |= 1 << bit
	return frame


static func matches_seek(image: Image, target: float) -> bool:
	return marker_frame(image) == expected_seek_frame(target)


class AudioWindow:
	extends RefCounted
	var frames := 0
	var active_frames := 0
	var energy := 0.0
	var peak := 0.0
	var nonfinite := false
	var previous_position := -1.0
	var phase_wraps := 0

	func observe_position(position: float, length: float) -> void:
		if previous_position > length * 0.65 and position < length * 0.35:
			phase_wraps += 1
		previous_position = position

	func consume(samples: PackedVector2Array) -> void:
		frames += samples.size()
		for sample in samples:
			if not is_finite(sample.x) or not is_finite(sample.y):
				nonfinite = true
				continue
			var amplitude := maxf(absf(sample.x), absf(sample.y))
			peak = maxf(peak, amplitude)
			energy += sample.x * sample.x + sample.y * sample.y
			if amplitude > 0.001:
				active_frames += 1

	func rms() -> float:
		return sqrt(energy / float(maxi(1, frames * 2)))

	func valid(expect_audio: bool, minimum_frames: int) -> bool:
		if nonfinite or phase_wraps != 0 or frames < minimum_frames:
			return false
		if expect_audio:
			return rms() > 0.005 and active_frames > frames / 2
		return peak < 0.000001
