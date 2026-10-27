//! GPU-only NV12/P010 import from MF's D3D11 decoder textures into Godot's
//! D3D12 RenderingDevice as R8/R16 luma and RG8/RG16 chroma textures.
//!
//! All D3D11 work uses the decoder texture's device, obtained through GetDevice
//! on first import. D3D11 resources are per-device: even a separate device with
//! the same adapter LUID cannot copy from the decoder texture. Shared textures
//! and a fence are opened on Godot's ID3D12Device. Cross-adapter OpenSharedHandle
//! failure reports `capability_unavailable`, selecting the CPU-copy fallback.
//!
//! initialize() binds Godot's D3D12 device. The first import builds the D3D11
//! compute pipeline and a persistent D3D11.4 SHARED fence, exported through an
//! NT handle and opened as an ID3D12Fence. Its signal value advances per frame.
//!
//! Each import GPU-blits the decoder slice into a cached NV12/P010 intermediate,
//! creates PlaneSlice SRVs, and dispatches a plane-split pass into fresh,
//! NT-shareable output textures. P010 samples are scaled by 1/64 in UNORM space
//! to convert code << 6 into the present shader's right-justified 10-bit layout.
//! Output textures bind RENDER_TARGET alongside SHADER_RESOURCE/UNORDERED_ACCESS
//! because Godot assumes an imported texture starts in RENDER_TARGET state
//! (godot#117115). RD import uses SAMPLING | COLOR_ATTACHMENT for the same reason;
//! neither plane is rendered to.
//!
//! After dispatch, import signals and flushes the shared fence, then CPU-waits
//! on its D3D12 side before exporting or wrapping the planes. Neither success
//! nor failure paths may sample or destroy a plane while D3D11 is writing it.
//! Each output is exported as an NT handle, opened as an ID3D12Resource, and
//! passed to texture_create_from_extension. The retire ring later destroys it.
//! Outputs are single-use, so no keyed mutex or release-sync is needed to return
//! access to D3D11.

const std = @import("std");

const core = @import("core");

const godot = @import("godot");
const RenderingDevice = godot.class.RenderingDevice;
const Rid = godot.builtin.Rid;

const win = @import("mf").win;
const com = win.com;
const dxgi = win.dxgi;
const d3d11 = win.d3d11;
const d3d12 = win.d3d12;
const d3dcompiler = win.d3dcompiler;

const si = @import("surface_importer.zig");
const PlaneTextures = si.PlaneTextures;

const wic = @import("windows_import_common.zig");
const CachedTex2D = wic.CachedTex2D;

const log = std.log.scoped(.native_video_d3d12_import);

const BootstrapResult = enum {
    ready,
    transient_failure,
    capability_unavailable,
};

const SharedOpenResult = enum {
    success,
    transient_failure,
    capability_unavailable,
};

const e_outofmemory: com.HRESULT = @bitCast(@as(u32, 0x8007000E));
const dxgi_error_device_removed: com.HRESULT = @bitCast(@as(u32, 0x887A0005));
const dxgi_error_device_hung: com.HRESULT = @bitCast(@as(u32, 0x887A0006));
const dxgi_error_device_reset: com.HRESULT = @bitCast(@as(u32, 0x887A0007));

// Plane-split shader: copy each display-aperture crop from the intermediate's
// PlaneSlice SRV into a display-sized output, excluding macroblock padding
// (core.backend.CropRect). luma_offset_x/y and chroma_offset_x/y locate the
// crop in the source; destination indices start at zero. Dispatch uses luma
// resolution, with a bounds check for half-resolution chroma writes.
//
// sample_scale is 1.0 for NV12 and 1/64 for P010, converting left-justified
// words (code << 6) to the present shader's low-10-bit layout in UNORM space.
const plane_split_hlsl =
    \\Texture2D<float>    SrcLuma    : register(t0);
    \\Texture2D<float2>   SrcChroma  : register(t1);
    \\RWTexture2D<float>   DstLuma   : register(u0);
    \\RWTexture2D<float2>  DstChroma : register(u1);
    \\
    \\cbuffer Params : register(b0) {
    \\    uint luma_width;
    \\    uint luma_height;
    \\    uint chroma_width;
    \\    uint chroma_height;
    \\    uint luma_offset_x;
    \\    uint luma_offset_y;
    \\    uint chroma_offset_x;
    \\    uint chroma_offset_y;
    \\    float sample_scale;
    \\};
    \\
    \\[numthreads(8, 8, 1)]
    \\void CSMain(uint3 tid : SV_DispatchThreadID) {
    \\    if (tid.x < luma_width && tid.y < luma_height) {
    \\        DstLuma[tid.xy] = SrcLuma.Load(int3(tid.x + luma_offset_x, tid.y + luma_offset_y, 0)) * sample_scale;
    \\    }
    \\    if (tid.x < chroma_width && tid.y < chroma_height) {
    \\        DstChroma[tid.xy] = SrcChroma.Load(int3(tid.x + chroma_offset_x, tid.y + chroma_offset_y, 0)) * sample_scale;
    \\    }
    \\}
;

/// Plane-split cbuffer: pad 36 payload bytes to a 16-byte multiple (48 bytes).
const PlaneSplitParams = extern struct {
    luma_width: u32,
    luma_height: u32,
    chroma_width: u32,
    chroma_height: u32,
    luma_offset_x: u32,
    luma_offset_y: u32,
    chroma_offset_x: u32,
    chroma_offset_y: u32,
    sample_scale: f32,
    pad: [3]u32 = .{ 0, 0, 0 },
};

comptime {
    std.debug.assert(@sizeOf(PlaneSplitParams) == 48);
}

/// Per-frame release payload: free the RD RIDs, then release the D3D12
/// resources holding the shared allocation alive. The D3D11-side transients are
/// released at the end of import(); the shared memory survives via these.
const ReleaseValue = struct {
    rd: *RenderingDevice,
    luma: Rid,
    chroma: Rid,
    d3d12_luma: *d3d12.ID3D12Resource,
    d3d12_chroma: *d3d12.ID3D12Resource,
};

fn releaseTeardown(v: *ReleaseValue) void {
    si.freePlaneRids(v.rd, v.luma, v.chroma);
    // @alignCast: ID3D12Resource is an opaque (align-1) handle, but a live COM
    // pointer is vtable-aligned, so the upcast to *IUnknown is sound.
    com.release(@as(*com.IUnknown, @ptrCast(@alignCast(v.d3d12_luma))));
    com.release(@as(*com.IUnknown, @ptrCast(@alignCast(v.d3d12_chroma))));
}

fn waitForSignal(fence: *d3d12.ID3D12Fence, event: com.HANDLE, signal_value: u64) bool {
    if (fence.GetCompletedValue() >= signal_value) return true;
    if (com.FAILED(fence.SetEventOnCompletion(signal_value, event))) {
        log.err("shared-fence SetEventOnCompletion failed.", .{});
        return false;
    }
    // Resource destruction without this handoff is a use-after-submit. A GPU
    // hang must therefore fail at the process watchdog boundary, not continue
    // by freeing or sampling allocations whose producer may still own them.
    return com.WaitForSingleObject(event, com.INFINITE) == com.WAIT_OBJECT_0;
}

pub const D3D12SurfaceImporter = struct {
    allocator: std.mem.Allocator,
    rd: ?*RenderingDevice = null,

    // Godot's D3D12 device (borrowed but COM-retained while we hold it).
    d3d12_device: ?*d3d12.ID3D12Device = null,

    // Decoder texture's D3D11 device and immediate context, bound on first
    // import via GetDevice. All D3D11 work must stay on this device.
    device: ?*d3d11.ID3D11Device = null,
    context: ?*d3d11.ID3D11DeviceContext = null,

    // Intermediate NV12/P010 texture the decoder slice is blitted into, cached
    // and reused (recreated only on size/format change).
    intermediate: CachedTex2D = .{},

    // Shared D3D11.4/D3D12 fence: one persistent object; import() increments
    // next_fence_value and signals after the plane-split pass.
    d3d11_fence: ?*d3d11.ID3D11Fence = null,
    d3d12_fence: ?*d3d12.ID3D12Fence = null,
    fence_event: com.HANDLE = null,
    next_fence_value: u64 = 0,

    // Persistent plane-split compute pipeline state.
    plane_split_cs: ?*d3d11.ID3D11ComputeShader = null,
    params_cb: ?*d3d11.ID3D11Buffer = null,

    // Extended interfaces queried once and reused every frame.
    device3: ?*d3d11.ID3D11Device3 = null,
    context4: ?*d3d11.ID3D11DeviceContext4 = null,

    // True once initialize() bound Godot's D3D12 device.
    initialized: bool = false,
    // True once the first import() built the D3D11 pipeline on the decoder's
    // own device (fence, extended interfaces, compute state).
    pipeline_ready: bool = false,
    // After one successful import, per-frame failures are retryable. Before
    // that, deterministic D3D12 open/wrap failures authorize CPU fallback.
    imported_once: bool = false,

    pub fn init(allocator: std.mem.Allocator) D3D12SurfaceImporter {
        return .{ .allocator = allocator };
    }

    /// Bind RD's D3D12 device; return false for a non-D3D12 RD. ensurePipeline
    /// builds the D3D11 side on first import, using the decoder texture's device.
    pub fn initialize(self: *D3D12SurfaceImporter, rd: *RenderingDevice) bool {
        if (self.initialized) return true;
        self.rd = rd;

        // Pull Godot's D3D12 device out of RD. On a non-D3D12 RD this is null.
        const dev_handle = rd.getDriverResource(.driver_resource_logical_device, si.rid_invalid, 0);
        if (dev_handle == 0) {
            log.err("init: RD did not yield a D3D12 device (non-D3D12 RD driver?).", .{});
            return false;
        }
        const d3d12_device: *d3d12.ID3D12Device = @ptrFromInt(@as(usize, @intCast(dev_handle)));
        _ = @as(*com.IUnknown, @ptrCast(d3d12_device)).AddRef();
        self.d3d12_device = d3d12_device;

        self.initialized = true;
        return true;
    }

    /// Lazily build the shared fence, extended interfaces, and compute state on
    /// `decoded`'s device (GetDevice). Permanent interface/interop failures
    /// authorize CPU fallback; allocation/bootstrap failures clear partial state
    /// for retry on a later frame.
    fn ensurePipeline(self: *D3D12SurfaceImporter, decoded: *d3d11.ID3D11Texture2D) BootstrapResult {
        if (self.pipeline_ready) return .ready;

        // A retry after a transient bootstrap failure must start from a clean
        // decoder-side pipeline rather than leaking or mixing partial COM state.
        self.resetDecoderPipeline();

        // Use the decoder's device. GetDevice/GetImmediateContext AddRef;
        // teardown() releases both.
        const bound = wic.bindDecoderDevice(decoded) orelse {
            log.err("init: ID3D11Texture2D.GetDevice failed.", .{});
            return .transient_failure;
        };
        self.device = bound.device;
        self.context = bound.context;
        const dev11 = bound.device;

        const d3d12_device = self.d3d12_device.?;

        // --- Shared fence bootstrap. ---
        const device5 = com.queryInterface(d3d11.ID3D11Device5, dev11) orelse {
            log.err("init: ID3D11Device5 not available (needs Windows 10 1809+).", .{});
            self.resetDecoderPipeline();
            return .capability_unavailable;
        };
        defer com.release(device5);

        var fence_out: ?*anyopaque = null;
        if (com.FAILED(device5.CreateFence(0, d3d11.D3D11_FENCE_FLAG_SHARED, &d3d11.ID3D11Fence.IID, &fence_out))) {
            log.err("init: ID3D11Device5.CreateFence failed.", .{});
            self.resetDecoderPipeline();
            return .transient_failure;
        }
        self.d3d11_fence = @ptrCast(@alignCast(fence_out.?));

        var fence_handle: com.HANDLE = null;
        if (com.FAILED(self.d3d11_fence.?.CreateSharedHandle(null, com.GENERIC_ALL, null, &fence_handle)) or fence_handle == null) {
            if (fence_handle != null) _ = com.CloseHandle(fence_handle);
            log.err("init: ID3D11Fence.CreateSharedHandle failed.", .{});
            self.resetDecoderPipeline();
            return .transient_failure;
        }
        var d3d12_fence_out: ?*anyopaque = null;
        const open_fence_hr = d3d12_device.OpenSharedHandle(fence_handle, &d3d12.ID3D12Fence.IID, &d3d12_fence_out);
        _ = com.CloseHandle(fence_handle);
        if (com.FAILED(open_fence_hr)) {
            log.err("init: ID3D12Device.OpenSharedHandle (fence) failed (cross-adapter setup?).", .{});
            self.resetDecoderPipeline();
            return .capability_unavailable;
        }
        self.d3d12_fence = @ptrCast(@alignCast(d3d12_fence_out.?));

        self.fence_event = com.CreateEventW(null, com.FALSE, com.FALSE, null);
        if (self.fence_event == null) {
            log.err("init: CreateEventW failed.", .{});
            self.resetDecoderPipeline();
            return .transient_failure;
        }

        // --- Extended device/context interfaces used every frame. ---
        self.device3 = com.queryInterface(d3d11.ID3D11Device3, dev11) orelse {
            log.err("init: ID3D11Device3 not available.", .{});
            self.resetDecoderPipeline();
            return .capability_unavailable;
        };
        self.context4 = com.queryInterface(d3d11.ID3D11DeviceContext4, self.context.?) orelse {
            log.err("init: ID3D11DeviceContext4 not available (needs Windows 10 1809+).", .{});
            self.resetDecoderPipeline();
            return .capability_unavailable;
        };

        // --- Plane-split compute shader bootstrap. ---
        var bytecode: ?*d3dcompiler.ID3DBlob = null;
        var compile_errors: ?*d3dcompiler.ID3DBlob = null;
        const compile_hr = d3dcompiler.D3DCompile(
            plane_split_hlsl,
            plane_split_hlsl.len,
            "plane_split_cs",
            null,
            null,
            "CSMain",
            "cs_5_0",
            d3dcompiler.D3DCOMPILE_OPTIMIZATION_LEVEL3,
            0,
            &bytecode,
            &compile_errors,
        );
        defer if (compile_errors) |e| {
            com.release(e);
        };
        if (com.FAILED(compile_hr) or bytecode == null) {
            log.err("init: plane-split shader compile failed.", .{});
            self.resetDecoderPipeline();
            return .capability_unavailable;
        }
        defer com.release(bytecode.?);

        var cs_out: ?*d3d11.ID3D11ComputeShader = null;
        if (com.FAILED(dev11.CreateComputeShader(bytecode.?.GetBufferPointer().?, bytecode.?.GetBufferSize(), null, &cs_out))) {
            log.err("init: CreateComputeShader (plane-split) failed.", .{});
            self.resetDecoderPipeline();
            return .transient_failure;
        }
        self.plane_split_cs = cs_out;

        var cb_desc = std.mem.zeroes(d3d11.D3D11_BUFFER_DESC);
        cb_desc.ByteWidth = @sizeOf(PlaneSplitParams);
        cb_desc.Usage = d3d11.D3D11_USAGE_DEFAULT;
        cb_desc.BindFlags = d3d11.D3D11_BIND_CONSTANT_BUFFER;
        var cb_out: ?*d3d11.ID3D11Buffer = null;
        if (com.FAILED(dev11.CreateBuffer(&cb_desc, null, &cb_out))) {
            log.err("init: CreateBuffer (plane-split params) failed.", .{});
            self.resetDecoderPipeline();
            return .transient_failure;
        }
        self.params_cb = cb_out;

        self.pipeline_ready = true;
        return .ready;
    }

    pub fn isInitialized(self: *const D3D12SurfaceImporter) bool {
        return self.initialized;
    }

    /// Import an NV12/P010 ID3D11Texture2D into two RD planes using only GPU
    /// copies, cropped to frame_info.crop (core.backend.CropRect). Borrows the
    /// decoder texture.
    pub fn import(self: *D3D12SurfaceImporter, frame_info: core.backend.VideoFrame, submission: u64) si.ImportResult {
        var out: PlaneTextures = .{};
        if (!self.initialized) return .transient_failure;
        const handle = frame_info.native_handle orelse return .bad_frame;
        const decoded: *d3d11.ID3D11Texture2D = @ptrCast(@alignCast(handle));

        // Bootstrap on the decoder's device. Only capability_unavailable
        // permits CPU fallback; transient bootstrap failures remain retryable.
        switch (self.ensurePipeline(decoded)) {
            .ready => {},
            .transient_failure => return .transient_failure,
            .capability_unavailable => return .capability_unavailable,
        }

        const rd = self.rd.?;
        const device = self.device.?;
        const context = self.context.?;

        var src_desc: d3d11.D3D11_TEXTURE2D_DESC = undefined;
        decoded.GetDesc(&src_desc);
        const is_10bit = wic.detectBitDepth(src_desc.Format) orelse {
            log.err("decoder texture is not NV12 or P010.", .{});
            return .bad_frame;
        };
        const width: com.UINT = src_desc.Width;
        const height: com.UINT = src_desc.Height;
        const rc = wic.resolveCrop(frame_info.crop, width, height);

        const luma_format = dxgiPlaneFormat(is_10bit, false);
        const chroma_format = dxgiPlaneFormat(is_10bit, true);

        // --- 1. GPU-blit the decoder slice into the cached intermediate. ---
        if (!self.intermediate.ensure(device, width, height, src_desc.Format, d3d11.D3D11_USAGE_DEFAULT, d3d11.D3D11_BIND_SHADER_RESOURCE, 0)) {
            log.err("intermediate texture create failed.", .{});
            return .transient_failure;
        }
        const intermediate = self.intermediate.texture.?;
        context.CopySubresourceRegion(intermediate.asResource(), 0, 0, 0, 0, decoded.asResource(), @intCast(frame_info.plane_slice), null);

        // --- 2. PlaneSlice SRVs over the intermediate. ---
        var luma_srv = com.ComPtr(d3d11.ID3D11ShaderResourceView){};
        defer luma_srv.deinit();
        var chroma_srv = com.ComPtr(d3d11.ID3D11ShaderResourceView){};
        defer chroma_srv.deinit();
        {
            var luma_srv_desc = std.mem.zeroes(d3d11.D3D11_SHADER_RESOURCE_VIEW_DESC1);
            luma_srv_desc.Format = luma_format;
            luma_srv_desc.ViewDimension = d3d11.D3D11_SRV_DIMENSION_TEXTURE2D;
            luma_srv_desc.u.Texture2D.MostDetailedMip = 0;
            luma_srv_desc.u.Texture2D.MipLevels = 1;
            luma_srv_desc.u.Texture2D.PlaneSlice = 0;
            if (com.FAILED(self.device3.?.CreateShaderResourceView1(intermediate.asResource(), &luma_srv_desc, luma_srv.put()))) {
                log.err("luma PlaneSlice SRV create failed.", .{});
                return .transient_failure;
            }
            var chroma_srv_desc = luma_srv_desc;
            chroma_srv_desc.Format = chroma_format;
            chroma_srv_desc.u.Texture2D.PlaneSlice = 1;
            if (com.FAILED(self.device3.?.CreateShaderResourceView1(intermediate.asResource(), &chroma_srv_desc, chroma_srv.put()))) {
                log.err("chroma PlaneSlice SRV create failed.", .{});
                return .transient_failure;
            }
        }

        // --- 3. Standalone, independently shareable output textures + UAVs. ---
        var luma_out = com.ComPtr(d3d11.ID3D11Texture2D){};
        defer luma_out.deinit();
        var chroma_out = com.ComPtr(d3d11.ID3D11Texture2D){};
        defer chroma_out.deinit();
        if (!makeOutputTexture(device, luma_format, rc.luma_width, rc.luma_height, luma_out.put()) or
            !makeOutputTexture(device, chroma_format, rc.chroma_width, rc.chroma_height, chroma_out.put()))
        {
            log.err("plane-split output texture create failed.", .{});
            return .transient_failure;
        }

        var luma_uav = com.ComPtr(d3d11.ID3D11UnorderedAccessView){};
        defer luma_uav.deinit();
        var chroma_uav = com.ComPtr(d3d11.ID3D11UnorderedAccessView){};
        defer chroma_uav.deinit();
        {
            var luma_uav_desc = std.mem.zeroes(d3d11.D3D11_UNORDERED_ACCESS_VIEW_DESC);
            luma_uav_desc.Format = luma_format;
            luma_uav_desc.ViewDimension = d3d11.D3D11_UAV_DIMENSION_TEXTURE2D;
            if (com.FAILED(device.CreateUnorderedAccessView(luma_out.get().?.asResource(), &luma_uav_desc, luma_uav.put()))) {
                log.err("luma UAV create failed.", .{});
                return .transient_failure;
            }
            var chroma_uav_desc = std.mem.zeroes(d3d11.D3D11_UNORDERED_ACCESS_VIEW_DESC);
            chroma_uav_desc.Format = chroma_format;
            chroma_uav_desc.ViewDimension = d3d11.D3D11_UAV_DIMENSION_TEXTURE2D;
            if (com.FAILED(device.CreateUnorderedAccessView(chroma_out.get().?.asResource(), &chroma_uav_desc, chroma_uav.put()))) {
                log.err("chroma UAV create failed.", .{});
                return .transient_failure;
            }
        }

        // --- Dispatch the plane-split pass. ---
        const params = PlaneSplitParams{
            .luma_width = rc.luma_width,
            .luma_height = rc.luma_height,
            .chroma_width = rc.chroma_width,
            .chroma_height = rc.chroma_height,
            .luma_offset_x = rc.luma_x,
            .luma_offset_y = rc.luma_y,
            .chroma_offset_x = rc.chroma_x,
            .chroma_offset_y = rc.chroma_y,
            .sample_scale = if (is_10bit) 1.0 / 64.0 else 1.0,
        };
        context.UpdateSubresource(@ptrCast(self.params_cb.?), 0, null, &params, 0, 0);

        const srvs = [_]?*d3d11.ID3D11ShaderResourceView{ luma_srv.get(), chroma_srv.get() };
        const uavs = [_]?*d3d11.ID3D11UnorderedAccessView{ luma_uav.get(), chroma_uav.get() };
        const cbs = [_]?*d3d11.ID3D11Buffer{self.params_cb.?};
        context.CSSetShaderResources(0, 2, &srvs);
        context.CSSetUnorderedAccessViews(0, 2, &uavs, null);
        context.CSSetConstantBuffers(0, 1, &cbs);
        context.CSSetShader(self.plane_split_cs, null, 0);
        context.Dispatch((rc.luma_width + 7) / 8, (rc.luma_height + 7) / 8, 1);

        const null_srvs = [_]?*d3d11.ID3D11ShaderResourceView{ null, null };
        const null_uavs = [_]?*d3d11.ID3D11UnorderedAccessView{ null, null };
        context.CSSetShaderResources(0, 2, &null_srvs);
        context.CSSetUnorderedAccessViews(0, 2, &null_uavs, null);
        context.CSSetShader(null, null, 0);

        // --- 4. Signal the shared fence and flush. ---
        self.next_fence_value += 1;
        const signal_value = self.next_fence_value;
        if (com.FAILED(self.context4.?.Signal(self.d3d11_fence.?, signal_value))) {
            log.err("shared-fence Signal failed.", .{});
            return .transient_failure;
        }
        context.Flush();
        if (!waitForSignal(self.d3d12_fence.?, self.fence_event, signal_value)) {
            return .transient_failure;
        }

        // --- 5. Export both output textures and open them on D3D12. ---
        var d3d12_luma = com.ComPtr(d3d12.ID3D12Resource){};
        defer d3d12_luma.deinit();
        var d3d12_chroma = com.ComPtr(d3d12.ID3D12Resource){};
        defer d3d12_chroma.deinit();
        switch (self.exportAndOpen(luma_out.get().?, d3d12_luma.put())) {
            .success => {},
            .transient_failure => return .transient_failure,
            .capability_unavailable => return .capability_unavailable,
        }
        switch (self.exportAndOpen(chroma_out.get().?, d3d12_chroma.put())) {
            .success => {},
            .transient_failure => return .transient_failure,
            .capability_unavailable => return .capability_unavailable,
        }

        // --- 6. Hand each ID3D12Resource to Godot RD as a plane texture. ---
        const luma = createFromExtension(rd, is_10bit, false, d3d12_luma.get().?, rc.luma_width, rc.luma_height);
        const chroma = createFromExtension(rd, is_10bit, true, d3d12_chroma.get().?, rc.chroma_width, rc.chroma_height);
        if (!luma.isValid() or !chroma.isValid()) {
            si.freePlaneRids(rd, luma, chroma);
            log.err("texture_create_from_extension failed.", .{});
            return if (self.imported_once) .transient_failure else .capability_unavailable;
        }

        // Transfer D3D12 resources into the release box. They retain shared
        // memory after the defers release the D3D11 transients.
        const release = si.boxClosure(self.allocator, ReleaseValue{
            .rd = rd,
            .luma = luma,
            .chroma = chroma,
            .d3d12_luma = d3d12_luma.get().?,
            .d3d12_chroma = d3d12_chroma.get().?,
        }, releaseTeardown) catch {
            si.freePlaneRids(rd, luma, chroma);
            return .transient_failure;
        };

        _ = d3d12_luma.take(); // ownership handed to the release box
        _ = d3d12_chroma.take();

        out.luma = luma;
        out.chroma = chroma;
        out.width = @intCast(rc.luma_width);
        out.height = @intCast(rc.luma_height);
        out.metadata = si.PresentationMetadata.fromFrame(frame_info, submission);
        out.release = release;
        self.imported_once = true;
        return .{ .success = out };
    }

    /// QI the D3D11 texture to IDXGIResource1, export an NT shared handle, and
    /// open it as an ID3D12Resource on Godot's D3D12 device.
    fn exportAndOpen(self: *D3D12SurfaceImporter, tex: *d3d11.ID3D11Texture2D, out: *?*d3d12.ID3D12Resource) SharedOpenResult {
        var dxgi_out: ?*anyopaque = null;
        const unknown: *com.IUnknown = @ptrCast(@alignCast(tex));
        const qi_hr = unknown.lpVtbl.QueryInterface(unknown, &dxgi.IDXGIResource1.IID, &dxgi_out);
        if (com.FAILED(qi_hr) or dxgi_out == null) {
            log.err("IDXGIResource1 unavailable for plane texture.", .{});
            return self.classifyInteropFailure(qi_hr);
        }
        const dxgi_res: *dxgi.IDXGIResource1 = @ptrCast(@alignCast(dxgi_out.?));
        defer com.release(dxgi_res);
        var handle: com.HANDLE = null;
        const create_hr = dxgi_res.CreateSharedHandle(null, dxgi.DXGI_SHARED_RESOURCE_READ | dxgi.DXGI_SHARED_RESOURCE_WRITE, null, &handle);
        if (com.FAILED(create_hr) or handle == null) {
            if (handle != null) _ = com.CloseHandle(handle);
            log.err("IDXGIResource1.CreateSharedHandle failed.", .{});
            return self.classifyInteropFailure(create_hr);
        }
        var res_out: ?*anyopaque = null;
        const hr = self.d3d12_device.?.OpenSharedHandle(handle, &d3d12.IID_ID3D12Resource, &res_out);
        _ = com.CloseHandle(handle);
        if (com.FAILED(hr) or res_out == null) {
            log.err("OpenSharedHandle (plane texture) failed.", .{});
            return self.classifyInteropFailure(hr);
        }
        out.* = @ptrCast(@alignCast(res_out));
        return .success;
    }

    /// Before the first successful import, deterministic interop failures prove
    /// that zero-copy is unavailable on this device/driver pair. Resource
    /// pressure and device-loss HRESULTs remain retryable; after one successful
    /// import every per-frame failure is transient.
    fn classifyInteropFailure(self: *const D3D12SurfaceImporter, hr: com.HRESULT) SharedOpenResult {
        if (self.imported_once or hr == e_outofmemory or hr == dxgi_error_device_removed or
            hr == dxgi_error_device_hung or hr == dxgi_error_device_reset)
        {
            return .transient_failure;
        }
        return .capability_unavailable;
    }

    pub fn deinit(self: *D3D12SurfaceImporter) void {
        self.teardown();
    }

    /// Release every owned COM object / handle. Idempotent; used both by the
    /// initialize() failure paths and by deinit().
    fn teardown(self: *D3D12SurfaceImporter) void {
        self.resetDecoderPipeline();
        if (self.d3d12_device) |p| {
            com.release(p);
            self.d3d12_device = null;
        }
        self.imported_once = false;
        self.initialized = false;
    }

    /// Release decoder-side state but keep the RD binding for bootstrap retry.
    fn resetDecoderPipeline(self: *D3D12SurfaceImporter) void {
        if (self.params_cb) |p| {
            // @alignCast: ID3D11Buffer/ComputeShader are opaque (align-1)
            // handles; a live COM pointer is vtable-aligned, so the upcast is
            // sound.
            com.release(@as(*com.IUnknown, @ptrCast(@alignCast(p))));
            self.params_cb = null;
        }
        if (self.plane_split_cs) |p| {
            com.release(@as(*com.IUnknown, @ptrCast(@alignCast(p))));
            self.plane_split_cs = null;
        }
        if (self.context4) |p| {
            com.release(p);
            self.context4 = null;
        }
        if (self.device3) |p| {
            com.release(p);
            self.device3 = null;
        }
        self.intermediate.release();
        if (self.d3d12_fence) |p| {
            com.release(p);
            self.d3d12_fence = null;
        }
        if (self.d3d11_fence) |p| {
            com.release(p);
            self.d3d11_fence = null;
        }
        if (self.fence_event) |e| {
            _ = com.CloseHandle(e);
            self.fence_event = null;
        }
        if (self.context) |c| {
            com.release(c);
            self.context = null;
        }
        if (self.device) |d| {
            com.release(d);
            self.device = null;
        }
        self.pipeline_ready = false;
    }
};

/// Create an NT-shareable plane. RENDER_TARGET supplements
/// SHADER_RESOURCE/UNORDERED_ACCESS to match RD's assumed initial state;
/// the texture is never rendered to.
fn makeOutputTexture(device: *d3d11.ID3D11Device, format: dxgi.DXGI_FORMAT, w: com.UINT, h: com.UINT, out: *?*d3d11.ID3D11Texture2D) bool {
    var desc = std.mem.zeroes(d3d11.D3D11_TEXTURE2D_DESC);
    desc.Width = w;
    desc.Height = h;
    desc.MipLevels = 1;
    desc.ArraySize = 1;
    desc.Format = format;
    desc.SampleDesc.Count = 1;
    desc.Usage = d3d11.D3D11_USAGE_DEFAULT;
    desc.BindFlags = d3d11.D3D11_BIND_SHADER_RESOURCE | d3d11.D3D11_BIND_UNORDERED_ACCESS | d3d11.D3D11_BIND_RENDER_TARGET;
    // MISC_SHARED_NTHANDLE requires SHARED. SHARED_KEYEDMUTEX caused
    // CSSetUnorderedAccessViews to hang; this pass uses no Acquire/ReleaseSync.
    desc.MiscFlags = d3d11.D3D11_RESOURCE_MISC_SHARED_NTHANDLE | d3d11.D3D11_RESOURCE_MISC_SHARED;
    return com.SUCCEEDED(device.CreateTexture2D(&desc, null, out));
}

/// DXGI equivalent of si.planeFormat for D3D11 SRV/UAV views:
/// is_10bit and is_chroma select R8/R16/RG8/RG16.
fn dxgiPlaneFormat(is_10bit: bool, is_chroma: bool) dxgi.DXGI_FORMAT {
    return if (is_chroma)
        (if (is_10bit) dxgi.DXGI_FORMAT_R16G16_UNORM else dxgi.DXGI_FORMAT_R8G8_UNORM)
    else
        (if (is_10bit) dxgi.DXGI_FORMAT_R16_UNORM else dxgi.DXGI_FORMAT_R8_UNORM);
}

/// texture_create_from_extension for one plane. `is_chroma` picks the RG format;
/// COLOR_ATTACHMENT usage works around the D3D12 RD driver's RENDER_TARGET
/// initial-state tracking.
fn createFromExtension(rd: *RenderingDevice, is_10bit: bool, is_chroma: bool, resource: *d3d12.ID3D12Resource, w: com.UINT, h: com.UINT) Rid {
    const fmt = si.planeFormat(is_10bit, is_chroma);
    return rd.textureCreateFromExtension(
        .texture_type_2d,
        fmt,
        .texture_samples_1,
        .{ .texture_usage_sampling_bit = true, .texture_usage_color_attachment_bit = true },
        @intCast(@intFromPtr(resource)),
        @intCast(w),
        @intCast(h),
        1,
        1,
        .{},
    );
}
