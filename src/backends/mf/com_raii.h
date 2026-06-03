#pragma once

// -----------------------------------------------------------------------
// com_raii.h — move-only RAII wrapper for COM reference-counted interfaces.
//
// The Windows analog of cf_raii.h. COM objects (IMFSourceReader,
// ID3D11Texture2D, IMFDXGIDeviceManager, ...) are reference-counted via
// IUnknown::AddRef / IUnknown::Release. ComPtr<T> owns exactly one reference;
// copy is deleted, move transfers ownership and leaves the source empty, and
// the destructor calls Release() exactly once. This guarantees the acceptance
// criterion that every COM object / D3D11 texture handed out by the Backend is
// released exactly once.
//
// We deliberately roll our own minimal ComPtr instead of using
// Microsoft::WRL::ComPtr so the Engine Core / Backend stays free of WRL headers
// (which only exist in the Windows SDK and aren't needed for the small surface
// of AddRef/Release/== we use). The semantics mirror WRL::ComPtr closely, so a
// Windows dev can swap in WRL if preferred with minimal churn.
//
// NOTE: this header is Windows-only — it includes <Unknwn.h> for IUnknown. It is
// guarded so that, if ever pulled into a non-Windows TU by accident, it compiles
// to nothing rather than erroring. The MF backend that uses it is itself only
// compiled on Windows.
// -----------------------------------------------------------------------

#if defined(_WIN32)

#include <Unknwn.h> // IUnknown
#include <utility>

namespace mf {

// -----------------------------------------------------------------------
// ComPtr<T> — move-only owner of one AddRef'd COM interface pointer.
//
// T must derive from IUnknown. Mirrors avf::CFRef: adopt() takes an existing
// +1 reference without adding another (use for the result of a Create*/Query*
// call, which by COM convention returns +1); attach via the address-of-pointer
// helper put() is provided for the common out-parameter pattern.
// -----------------------------------------------------------------------
template <typename T>
class ComPtr {
public:
	ComPtr() noexcept = default;
	ComPtr(std::nullptr_t) noexcept {}

	// Retain an existing (borrowed) pointer, adding +1. Use when you want to keep
	// a pointer you do not own alive beyond the borrow.
	static ComPtr retain(T *p) noexcept {
		if (p) {
			p->AddRef();
		}
		return ComPtr(p);
	}

	// Adopt a pointer that already carries a +1 reference (no extra AddRef). Use
	// for the result of Create*/QueryInterface, which return +1 by convention.
	static ComPtr adopt(T *p) noexcept {
		return ComPtr(p);
	}

	~ComPtr() {
		reset();
	}

	// Move-only: copying a sole-ownership pointer would risk a double Release.
	ComPtr(const ComPtr &) = delete;
	ComPtr &operator=(const ComPtr &) = delete;

	ComPtr(ComPtr &&other) noexcept :
			ptr_(other.ptr_) {
		other.ptr_ = nullptr;
	}

	ComPtr &operator=(ComPtr &&other) noexcept {
		if (this != &other) {
			reset();
			ptr_ = other.ptr_;
			other.ptr_ = nullptr;
		}
		return *this;
	}

	// Release the owned pointer (if any) and become empty.
	void reset() noexcept {
		if (ptr_) {
			ptr_->Release();
			ptr_ = nullptr;
		}
	}

	// Relinquish ownership: return the raw pointer and stop tracking it. The
	// caller becomes responsible for the Release().
	[[nodiscard]] T *detach() noexcept {
		T *p = ptr_;
		ptr_ = nullptr;
		return p;
	}

	// Address-of-pointer for the out-parameter pattern: pass &p.put() to a
	// Create*/QueryInterface call that writes a +1 pointer. Resets first so we
	// never leak a previously-held pointer.
	T **put() noexcept {
		reset();
		return &ptr_;
	}

	// Address-of-pointer typed as void** for IUnknown::QueryInterface /
	// CoCreateInstance out-params (IID_PPV_ARGS-style call sites).
	void **put_void() noexcept {
		reset();
		return reinterpret_cast<void **>(&ptr_);
	}

	T *get() const noexcept { return ptr_; }
	T *operator->() const noexcept { return ptr_; }
	explicit operator bool() const noexcept { return ptr_ != nullptr; }

private:
	explicit ComPtr(T *p) noexcept :
			ptr_(p) {}

	T *ptr_ = nullptr;
};

} // namespace mf

#endif // _WIN32
