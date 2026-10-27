//! Shared D3D11/DXGI helpers for the Windows CPU-copy and D3D12 importers:
//! decoder-device binding, cached textures, NV12/P010 detection, and crop
//! resolution. No RenderingDevice or Godot types.

const std = @import("std");

const win = @import("mf").win;
const com = win.com;
const dxgi = win.dxgi;
const d3d11 = win.d3d11;

const core = @import("core");

/// Decoder device and immediate context, AddRef'd by GetDevice and
/// GetImmediateContext. The caller must com.release both.
pub const DecoderDevice = struct {
    device: *d3d11.ID3D11Device,
    context: *d3d11.ID3D11DeviceContext,
};

/// Bind to decoded's device. D3D11 resources are per-device: copies, views,
/// and all other operations on decoded must use this device, never a separate
/// one. Returns null if device/context lookup fails; the caller logs.
pub fn bindDecoderDevice(decoded: *d3d11.ID3D11Texture2D) ?DecoderDevice {
    var dev: ?*d3d11.ID3D11Device = null;
    decoded.GetDevice(&dev);
    const device = dev orelse return null;
    var ctx: ?*d3d11.ID3D11DeviceContext = null;
    device.GetImmediateContext(&ctx);
    const context = ctx orelse return null;
    return .{ .device = device, .context = context };
}

/// True for P010 (10-bit), false for NV12 (8-bit), null for unsupported formats.
pub fn detectBitDepth(format: dxgi.DXGI_FORMAT) ?bool {
    return switch (format) {
        dxgi.DXGI_FORMAT_P010 => true,
        dxgi.DXGI_FORMAT_NV12 => false,
        else => null,
    };
}

/// Owned D3D11Texture2D, reused until size or format changes. Used for CPU
/// readback slots and the D3D12 blit intermediate. release() or a mismatched
/// ensure() frees the previous texture.
pub const CachedTex2D = struct {
    texture: ?*d3d11.ID3D11Texture2D = null,
    width: com.UINT = 0,
    height: com.UINT = 0,
    format: dxgi.DXGI_FORMAT = dxgi.DXGI_FORMAT_UNKNOWN,

    /// Reuse a matching width/height/format; otherwise release and recreate
    /// with the supplied usage/bind/CPU-access flags. Returns false with a null
    /// texture if CreateTexture2D fails; the caller logs.
    pub fn ensure(
        self: *CachedTex2D,
        device: *d3d11.ID3D11Device,
        width: com.UINT,
        height: com.UINT,
        format: dxgi.DXGI_FORMAT,
        usage: d3d11.D3D11_USAGE,
        bind_flags: com.UINT,
        cpu_access_flags: com.UINT,
    ) bool {
        if (self.texture != null and self.width == width and self.height == height and self.format == format) {
            return true;
        }
        self.release();
        var desc = std.mem.zeroes(d3d11.D3D11_TEXTURE2D_DESC);
        desc.Width = width;
        desc.Height = height;
        desc.MipLevels = 1;
        desc.ArraySize = 1;
        desc.Format = format;
        desc.SampleDesc.Count = 1;
        desc.Usage = usage;
        desc.BindFlags = bind_flags;
        desc.CPUAccessFlags = cpu_access_flags;
        var tex: ?*d3d11.ID3D11Texture2D = null;
        if (com.FAILED(device.CreateTexture2D(&desc, null, &tex))) {
            self.width = 0;
            self.height = 0;
            self.format = dxgi.DXGI_FORMAT_UNKNOWN;
            return false;
        }
        self.texture = tex;
        self.width = width;
        self.height = height;
        self.format = format;
        return true;
    }

    pub fn release(self: *CachedTex2D) void {
        if (self.texture) |t| {
            com.release(t);
            self.texture = null;
        }
    }
};

/// VideoFrame.crop resolved against the decoder's macroblock-aligned luma
/// dimensions, with a derived chroma crop. Both Windows importers use these
/// bounds to exclude padding from the planes sampled by the present shader.
pub const ResolvedCrop = struct {
    luma_x: com.UINT,
    luma_y: com.UINT,
    luma_width: com.UINT,
    luma_height: com.UINT,
    chroma_x: com.UINT,
    chroma_y: com.UINT,
    chroma_width: com.UINT,
    chroma_height: com.UINT,
};

/// Resolve the display aperture against the decoder's actual luma size.
/// Zero or oversized extents fall back to the corresponding aligned dimension;
/// offsets are clamped to keep the crop inside the texture. Zero width is
/// core.backend.CropRect's no-metadata sentinel. Chroma fields use floor
/// division by 2, following CropRect's half-pixel policy for 4:2:0.
pub fn resolveCrop(crop: core.backend.CropRect, aligned_width: com.UINT, aligned_height: com.UINT) ResolvedCrop {
    const luma_width = if (crop.width > 0 and crop.width <= aligned_width) crop.width else aligned_width;
    const luma_height = if (crop.height > 0 and crop.height <= aligned_height) crop.height else aligned_height;
    const luma_x = @min(crop.x, aligned_width - luma_width);
    const luma_y = @min(crop.y, aligned_height - luma_height);
    return .{
        .luma_x = luma_x,
        .luma_y = luma_y,
        .luma_width = luma_width,
        .luma_height = luma_height,
        .chroma_x = luma_x / 2,
        .chroma_y = luma_y / 2,
        .chroma_width = luma_width / 2,
        .chroma_height = luma_height / 2,
    };
}
