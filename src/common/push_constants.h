// -----------------------------------------------------------------------
// push_constants.h — byte-packing for the NV12-to-RGB compute shader's
// push-constant block.
//
// The GLSL shader declares a std430 push-constant block with seven uint32
// and one float (32 bytes total). This header provides the C++ side of that
// contract: a single pack function that writes the correct bytes so the
// shader reads them back in the expected layout.
//
// Layout (std430, little-endian assumed — x86-64 and ARM64 both are):
//   offset 0: out_width       (uint32)
//   offset 4: out_height      (uint32)
//   offset 8: matrix_select   (uint32) — core::ColorMatrix
//   offset 12: range_select   (uint32) — core::ColorRange
//   offset 16: bit_depth      (uint32) — 8 or 10
//   offset 20: transfer_select (uint32) — core::TransferFunction
//   offset 24: primaries_select (uint32) — core::ColorPrimaries
//   offset 28: sample_scale   (float)
//   Total: kPushConstantSize (32) bytes
//
// A 16-byte multiple is required because pre-4.7 Godot rounds the required
// push-constant size up to 32 and 4.7+ validates the exact declared size of
// 32 bytes — this layout satisfies both.
// -----------------------------------------------------------------------

#pragma once

#include <cstdint>
#include <cstring>

#include "../core/backend.h"

namespace platform_media {

// Size in bytes of the packed push-constant block (see layout above).
inline constexpr uint32_t kPushConstantSize = 32;

// Pack the frame's colorimetry and output dimensions into the
// kPushConstantSize-byte buffer `dst`. `dst` must point to at least
// kPushConstantSize bytes of writable memory. The encoding matches the
// GLSL std430 layout declared in nv12_to_rgb.glsl.
//
// This is a pure function: no side effects on anything outside `dst`,
// no heap allocation, no Godot API calls.
inline void pack_push_constants(
		uint8_t *dst,
		uint32_t width,
		uint32_t height,
		const core::Colorimetry &color,
		float sample_scale) noexcept {
	std::memset(dst, 0, kPushConstantSize);
	const uint32_t matrix_select = static_cast<uint32_t>(color.matrix);
	const uint32_t range_select = static_cast<uint32_t>(color.range);
	const uint32_t bit_depth = static_cast<uint32_t>(color.bit_depth);
	const uint32_t transfer_select = static_cast<uint32_t>(color.transfer);
	const uint32_t primaries_select = static_cast<uint32_t>(color.primaries);
	std::memcpy(dst + 0, &width, sizeof(uint32_t));
	std::memcpy(dst + 4, &height, sizeof(uint32_t));
	std::memcpy(dst + 8, &matrix_select, sizeof(uint32_t));
	std::memcpy(dst + 12, &range_select, sizeof(uint32_t));
	std::memcpy(dst + 16, &bit_depth, sizeof(uint32_t));
	std::memcpy(dst + 20, &transfer_select, sizeof(uint32_t));
	std::memcpy(dst + 24, &primaries_select, sizeof(uint32_t));
	std::memcpy(dst + 28, &sample_scale, sizeof(float));
}

} // namespace platform_media
