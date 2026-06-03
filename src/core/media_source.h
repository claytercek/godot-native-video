#pragma once

#include <cstddef>
#include <cstdint>
#include <string>

namespace core {

// Abstracts byte/file input so tests feed fixtures and the Binding feeds Godot
// FileAccess. No Godot types appear here — this header is Godot-independent.
class MediaSource {
public:
	virtual ~MediaSource() = default;

	// Returns the total byte length of the source, or 0 if unknown / streaming.
	virtual uint64_t size() const = 0;

	// Returns the current read position.
	virtual uint64_t tell() const = 0;

	// Seek to an absolute byte offset. Returns true on success.
	virtual bool seek(uint64_t offset) = 0;

	// Read up to `count` bytes into `buf`. Returns the number of bytes actually
	// read; returns 0 on EOF or error.
	virtual size_t read(void *buf, size_t count) = 0;

	// True when the source has no more data to deliver.
	virtual bool eof() const = 0;

	// Optional: human-readable name/path for diagnostics, may be empty.
	virtual std::string name() const { return {}; }
};

} // namespace core
