#pragma once

// -----------------------------------------------------------------------
// cf_raii.h — move-only RAII wrappers for Core Foundation / Core Video
// reference-counted handles (CVPixelBufferRef, generic CFTypeRef).
//
// These own a +1 retain on the underlying handle. Copy is deleted; move
// transfers ownership and leaves the source empty. This is the explicit
// acceptance criterion: the Backend hands out native surface handles whose
// lifetime is bound to a wrapper, so a surface is released exactly once.
//
// The header is pure C++ (no Objective-C), so it can be included from .cpp
// as well as .mm translation units. It forward-declares the Core Video /
// Core Foundation opaque types and links against the C ABI functions, which
// keeps it Godot-independent and framework-light.
// -----------------------------------------------------------------------

#include <CoreVideo/CVPixelBuffer.h>

#include <utility>

namespace avf {

// -----------------------------------------------------------------------
// CFRef<T> — move-only owner of a retained CoreFoundation-style handle.
//
// T is the pointer type (e.g. CVPixelBufferRef, which is itself a typedef
// for a pointer to an opaque struct). Retain/Release are supplied as
// function pointers so one template serves every CF/CV ref type without
// dragging in the toolbox-style polymorphism.
// -----------------------------------------------------------------------
template <typename T, void (*ReleaseFn)(T), T (*RetainFn)(T)>
class CFRef {
public:
	CFRef() noexcept = default;

	// Adopt an existing +1 reference WITHOUT adding another retain.
	// Use this for handles you already own (e.g. the result of a Copy/Create
	// call, which by CoreFoundation convention returns a +1 reference).
	struct AdoptTag {};
	CFRef(AdoptTag, T handle) noexcept :
			handle_(handle) {}

	// Retain an existing handle (adds +1). Use for borrowed handles you want
	// to keep alive beyond the borrow.
	static CFRef retain(T handle) {
		if (handle) {
			RetainFn(handle);
		}
		return CFRef(AdoptTag{}, handle);
	}

	// Adopt a handle that already carries a +1 reference (no extra retain).
	static CFRef adopt(T handle) {
		return CFRef(AdoptTag{}, handle);
	}

	~CFRef() {
		reset();
	}

	// Move-only: copying a sole-ownership handle would risk a double release.
	CFRef(const CFRef &) = delete;
	CFRef &operator=(const CFRef &) = delete;

	CFRef(CFRef &&other) noexcept :
			handle_(other.handle_) {
		other.handle_ = nullptr;
	}

	CFRef &operator=(CFRef &&other) noexcept {
		if (this != &other) {
			reset();
			handle_ = other.handle_;
			other.handle_ = nullptr;
		}
		return *this;
	}

	// Release the owned handle (if any) and become empty.
	void reset() noexcept {
		if (handle_) {
			ReleaseFn(handle_);
			handle_ = nullptr;
		}
	}

	// Relinquish ownership: return the handle and stop tracking it. The
	// caller becomes responsible for the release.
	[[nodiscard]] T release() noexcept {
		T h = handle_;
		handle_ = nullptr;
		return h;
	}

	T get() const noexcept { return handle_; }
	explicit operator bool() const noexcept { return handle_ != nullptr; }

private:
	T handle_ = nullptr;
};

// -----------------------------------------------------------------------
// Concrete instantiation for CVPixelBufferRef. CVPixelBufferRetain returns
// the buffer; we adapt it to the (T)->void release signature with a wrapper
// so the template's ReleaseFn type matches.
// -----------------------------------------------------------------------
inline void cvpb_release(CVPixelBufferRef pb) noexcept {
	CVPixelBufferRelease(pb);
}
inline CVPixelBufferRef cvpb_retain(CVPixelBufferRef pb) noexcept {
	return CVPixelBufferRetain(pb);
}

using PixelBufferRef = CFRef<CVPixelBufferRef, cvpb_release, cvpb_retain>;

} // namespace avf
