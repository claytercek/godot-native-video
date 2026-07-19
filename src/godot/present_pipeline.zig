//! present_pipeline.zig — the zero-copy NV12->RGB present pipeline.
//!
//! Port of src/common/present_pipeline.h/.cpp. Owns, on Godot's
//! RenderingDevice:
//!   - the NV12->RGB compute shader + pipeline + sampler,
//!   - an N-buffered ring of engine-owned RGBA storage textures (rgba8 in SDR
//!     mode, rgba16f in HDR mode), exposed through ONE stable Texture2DRD that
//!     Godot samples (see getTexture()),
//!   - a SurfaceImporter (Metal on macOS) that turns a decoder surface into two
//!     RD plane textures — zero-copy,
//!   - a RetireRing(N) that holds each frame's transient surfaces for N
//!     rendered frames so the GPU never reads a freed surface.
//!
//! HDR output mode: the ring textures become RGBA16F and the compute shader
//! emits scene-linear values scaled so 1.0 = 203-nit Reference White (BT.2408).
//!
//! present(frame) runs ONE compute dispatch (NV12->RGB) into the next ring slot
//! and re-points the stable Texture2DRD at it.

const std = @import("std");

const godot = @import("godot");
const RenderingServer = godot.class.RenderingServer;
const RenderingDevice = godot.class.RenderingDevice;
const RdShaderSource = godot.class.RdShaderSource;
const RdSamplerState = godot.class.RdSamplerState;
const RdTextureFormat = godot.class.RdTextureFormat;
const RdTextureView = godot.class.RdTextureView;
const RdUniform = godot.class.RdUniform;
const Texture2drd = godot.class.Texture2drd;
const Rid = godot.builtin.Rid;
const Array = godot.builtin.Array;
const Variant = godot.builtin.Variant;
const String = godot.builtin.String;
const PackedByteArray = godot.builtin.PackedByteArray;

const log = std.log.scoped(.native_video_present);

// Core types come through the "core" named module (build.zig-wired) so they
// match the module instance the PlaybackController hands us. A module's root
// restricts @import to its own subtree, so path imports into ../core are not
// an option.
const core = @import("core");
const backend = core.backend;
const VideoFrame = backend.VideoFrame;
const push_constants = core.push_constants;
const retire_ring = core.retire_ring;
const shaders = core.shaders;

const si = @import("surface_importer.zig");
const SurfaceImporter = si.SurfaceImporter;
const PlaneTextures = si.PlaneTextures;

/// Present-pipeline output format.
pub const OutputMode = enum(u8) {
    sdr = 0, // RGBA8, non-linear (tone-mapped / clamped), Godot's standard 2D
    hdr = 1, // RGBA16F, scene-linear, 1.0 = 203-nit Reference White (BT.2408)
};

/// Number of rendered frames a decoder surface is held before retirement, and
/// the depth of the engine-owned RGBA output ring. Godot's render pipeline is
/// at most a few frames deep; 3 is a safe, cheap bound.
pub const frame_latency: usize = 3;
pub const ring_depth: usize = frame_latency;

const RingSlot = struct {
    rgba_rid: Rid = si.rid_invalid, // RD storage texture (rgba8 or rgba16f)
};

/// The pipeline's RD-resource lifecycle.
const State = enum(u8) {
    unbuilt, // resources not built (initial, or after free/dimension change)
    ready, // resources built and usable
    disabled, // no RenderingServer/RenderingDevice — terminal, never leaves
};

// -----------------------------------------------------------------------
// The retire-ring payload: freeing one presented frame's transient surfaces.
// C++ captured this in a std::function lambda; Zig needs an explicit heap ctx
// carrying the uniform set RID + the plane-release + frame-release closures.
// The ctx is freed after its release closure runs.
// -----------------------------------------------------------------------
const RetirePayload = struct {
    allocator: std.mem.Allocator,
    rd: *RenderingDevice,
    uniform_set: Rid,
    plane_release: si.Closure,
    frame: VideoFrame,

    fn run(ctx: ?*anyopaque) void {
        const self: *RetirePayload = @ptrCast(@alignCast(ctx.?));
        if (self.uniform_set.isValid()) self.rd.freeRid(self.uniform_set);
        self.plane_release.call();
        self.frame.release();
        self.allocator.destroy(self);
    }
};

pub const PresentPipeline = struct {
    allocator: std.mem.Allocator,

    rd: ?*RenderingDevice = null, // borrowed: the global RD
    importer: ?SurfaceImporter = null, // per-platform, chosen at first build

    shader: Rid = si.rid_invalid,
    pipeline: Rid = si.rid_invalid,
    sampler: Rid = si.rid_invalid,

    ring: [ring_depth]RingSlot = @splat(.{}),
    ring_index: usize = 0,

    // Lazily created in getTexture(); identity stable for the pipeline's
    // lifetime. VideoStreamPlayer caches this ref once and draws it forever.
    current_texture: ?*Texture2drd = null,

    retire: retire_ring.RetireRing(frame_latency) = .{},

    width: i32 = 0,
    height: i32 = 0,
    state: State = .unbuilt,
    output_mode: OutputMode = .sdr,

    cpu_copy_count: u64 = 0, // invariant: 0 on the zero-copy Import Paths

    pub fn init(allocator: std.mem.Allocator) PresentPipeline {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *PresentPipeline) void {
        self.shutdown();
    }

    pub fn isReady(self: *const PresentPipeline) bool {
        return self.state == .ready;
    }

    pub fn outputMode(self: *const PresentPipeline) OutputMode {
        return self.output_mode;
    }

    pub fn cpuCopyCount(self: *const PresentPipeline) u64 {
        return self.cpu_copy_count;
    }

    /// Set the output mode (SDR or HDR). Triggers a resource rebuild on the
    /// next ensureReady() call — the ring texture format changes (rgba8 vs
    /// rgba16f), so buildResources() rebuilds everything, shader included.
    /// No-op if Disabled: there is nothing to rebuild.
    pub fn setOutputMode(self: *PresentPipeline, mode: OutputMode) void {
        if (mode != self.output_mode) {
            self.output_mode = mode;
            if (self.state == .ready) {
                self.state = .unbuilt; // force rebuild on next ensureReady
            }
        }
    }

    /// The engine-owned RGBA Texture2DRD holding the latest frame. Returned
    /// from VideoStreamPlayback._getTexture(). Identity is stable: we hand out
    /// one lazily-created Texture2DRD and re-point its RD RID each present.
    pub fn getTexture(self: *PresentPipeline) *Texture2drd {
        if (self.current_texture == null) {
            const tex = Texture2drd.init();
            self.current_texture = tex;
        }
        return self.current_texture.?;
    }

    /// Lazily build the RD resources for a width x height frame. Safe to call
    /// every frame; rebuilds only when dimensions/mode change or on first use.
    /// Returns false if RD is unavailable or the importer fails.
    pub fn ensureReady(self: *PresentPipeline, width: i32, height: i32) bool {
        if (width <= 0 or height <= 0) return false;
        // Disabled (e.g. headless) is terminal — don't retry build every frame.
        if (self.state == .disabled) return false;
        if (self.state == .ready and width == self.width and height == self.height) {
            return true;
        }
        // Dimensions or output mode changed (or first use): rebuild. Drain held
        // surfaces first so we don't leak the old ring's transient textures.
        if (self.state == .ready) {
            self.retire.drain();
            self.freeResources();
        }
        return self.buildResources(width, height);
    }

    fn buildResources(self: *PresentPipeline, width: i32, height: i32) bool {
        // Use the global RenderingDevice — the present output must live on the
        // same device Godot samples from when compositing the player.
        const rd = RenderingServer.getRenderingDevice() orelse {
            // No RenderingDevice (headless). Degrade gracefully: decode, audio,
            // clock, and the playback state machine keep running; only texture
            // output is disabled. Latch Disabled and print once.
            self.state = .disabled;
            log.info("No RenderingDevice — presentation disabled (headless mode). " ++
                "Decode and audio continue normally.", .{});
            return false;
        };
        self.rd = rd;

        // Build the per-platform surface importer lazily, then bind it to RD.
        if (self.importer == null) {
            self.importer = si.makeSurfaceImporter(self.allocator);
        }
        const importer = self.importer orelse {
            log.err("Surface importer construction failed.", .{});
            return false;
        };
        if (!importer.initialize(rd)) {
            log.err("Surface importer init failed (RD backend not supported by importer?).", .{});
            return false;
        }

        // --- Compile the shader variant for the active output mode. ---
        const want_hdr = self.output_mode == .hdr;
        const label = if (want_hdr) "nv12_to_rgb_hdr" else "nv12_to_rgb";
        self.shader = compileShader(rd, want_hdr);
        if (!self.shader.isValid()) return false;

        self.pipeline = rd.computePipelineCreate(self.shader, .{});
        if (!self.pipeline.isValid()) {
            log.err("{s} compute_pipeline_create failed.", .{label});
            return false;
        }

        // Bilinear sampler so the half-res chroma plane upsamples smoothly.
        const ss = RdSamplerState.init();
        defer if (ss.unreference()) ss.destroy();
        ss.setMagFilter(.sampler_filter_linear);
        ss.setMinFilter(.sampler_filter_linear);
        self.sampler = rd.samplerCreate(ss);
        if (!self.sampler.isValid()) {
            log.err("sampler_create failed.", .{});
            return false;
        }

        // --- N engine-owned storage textures. RGBA16F for HDR, RGBA8 for SDR. ---
        const tex_fmt: RenderingDevice.DataFormat = if (want_hdr)
            .data_format_r16g16b16a16_sfloat
        else
            .data_format_r8g8b8a8_unorm;
        if (!self.buildRingTextures(rd, tex_fmt, width, height)) return false;

        self.width = width;
        self.height = height;
        self.ring_index = 0;
        // Point the stable output texture at slot 0. This fires `changed`, so
        // the player's cached texture picks up the real dimensions.
        self.getTexture().setTextureRdRid(self.ring[0].rgba_rid);
        self.state = .ready;
        return true;
    }

    /// Compile the NV12->RGB compute shader for the requested output mode and
    /// create the RD shader object. Returns si.rid_invalid on any compile or
    /// creation failure (logged).
    fn compileShader(rd: *RenderingDevice, want_hdr: bool) Rid {
        const label = if (want_hdr) "nv12_to_rgb_hdr" else "nv12_to_rgb";
        const source_text = if (want_hdr) shaders.nv12_to_rgb_hdr_compute else shaders.nv12_to_rgb_compute;

        const src = RdShaderSource.init();
        defer if (src.unreference()) src.destroy();
        src.setLanguage(.shader_language_glsl);
        var source_str = String.fromLatin1(source_text);
        defer source_str.deinit();
        src.setStageSource(.shader_stage_compute, source_str);

        const spirv = rd.shaderCompileSpirvFromSource(src, .{}) orelse {
            log.err("{s} shader compile returned null.", .{label});
            return si.rid_invalid;
        };
        defer if (spirv.unreference()) spirv.destroy();
        var compile_err = spirv.getStageCompileError(.shader_stage_compute);
        defer compile_err.deinit();
        if (compile_err.length() != 0) {
            log.err("{s} shader compile error.", .{label});
            return si.rid_invalid;
        }

        var label_str = String.fromLatin1(label);
        defer label_str.deinit();
        const shader = rd.shaderCreateFromSpirv(spirv, .{ .name = label_str });
        if (!shader.isValid()) {
            log.err("{s} shader_create_from_spirv failed.", .{label});
            return si.rid_invalid;
        }
        return shader;
    }

    /// Build the N engine-owned RGBA output storage textures (rgba16f for
    /// HDR, rgba8 for SDR) into self.ring. Returns false on any failure
    /// (logged); self.ring holds whatever slots were created so far.
    fn buildRingTextures(self: *PresentPipeline, rd: *RenderingDevice, tex_fmt: RenderingDevice.DataFormat, width: i32, height: i32) bool {
        for (0..ring_depth) |i| {
            const tf = RdTextureFormat.init();
            defer if (tf.unreference()) tf.destroy();
            tf.setFormat(tex_fmt);
            tf.setWidth(@intCast(width));
            tf.setHeight(@intCast(height));
            tf.setDepth(1);
            tf.setArrayLayers(1);
            tf.setMipmaps(1);
            tf.setTextureType(.texture_type_2d);
            tf.setUsageBits(.{
                .texture_usage_sampling_bit = true,
                .texture_usage_storage_bit = true,
                .texture_usage_can_copy_from_bit = true,
            });

            const view = RdTextureView.init();
            defer if (view.unreference()) view.destroy();

            const rgba = rd.textureCreate(tf, view, .{});
            if (!rgba.isValid()) {
                log.err("RGBA output texture_create failed.", .{});
                return false;
            }
            self.ring[i].rgba_rid = rgba;
        }
        return true;
    }

    /// Present one decoded frame: import its NV12 planes zero-copy, run the
    /// NV12->RGB compute pass into the next RGBA ring slot, and retire surfaces
    /// that have aged out. The frame's own release() is parked in the ring.
    /// Returns true if a GPU pass ran.
    pub fn present(self: *PresentPipeline, frame: VideoFrame) bool {
        if (!self.ensureReady(frame.width, frame.height)) {
            // Couldn't build the pipeline; still run the frame's own release so
            // the decoder pool can recycle the surface. Retire immediately.
            frame.release();
            return false;
        }
        const rd = self.rd.?;
        const importer = self.importer.?;

        // Age the retire-ring by one rendered frame BEFORE parking this frame's
        // surfaces. advance() releases whatever was parked frame_latency ago.
        self.retire.advance();

        // Import the decoder surface zero-copy into two RD plane textures.
        var planes = importer.import(frame.native_handle, frame.plane_slice);
        if (!planes.valid()) {
            frame.release();
            return false;
        }

        // Advance the output ring slot.
        self.ring_index = (self.ring_index + 1) % ring_depth;
        const slot = self.ring[self.ring_index];

        const uniform_set = self.buildUniformSet(rd, planes, slot);
        if (!uniform_set.isValid()) {
            planes.release.call();
            frame.release();
            return false;
        }

        // Push constant: output dimensions + colorimetry + bit depth + the
        // importer's 10-bit sample scale (std430, push_constant_size bytes).
        var pc = self.buildPushConstants(frame, planes.sample_scale);
        defer pc.deinit();

        // Cross-API sync hooks (no-op on macOS: acquire/release are empty).
        planes.acquire.call();

        // --- ONE compute dispatch: NV12 -> RGBA into the engine-owned slot. ---
        const gx: u32 = @intCast(@divTrunc(self.width + 7, 8));
        const gy: u32 = @intCast(@divTrunc(self.height + 7, 8));

        const cl = rd.computeListBegin();
        rd.computeListBindComputePipeline(cl, self.pipeline);
        rd.computeListBindUniformSet(cl, uniform_set, 0);
        rd.computeListSetPushConstant(cl, pc, push_constants.push_constant_size);
        rd.computeListDispatch(cl, gx, gy, 1);
        rd.computeListEnd();

        // Release the keyed mutex back to the decoder (no-op on macOS).
        planes.release_sync.call();

        // Re-point the stable output texture at the slot the dispatch wrote.
        self.getTexture().setTextureRdRid(slot.rgba_rid);

        // Count this frame if the CPU-Copy Import Path produced the planes.
        if (!importer.isZeroCopy()) {
            self.cpu_copy_count += 1;
        }

        // Park this frame's surfaces (plane textures + uniform set + the
        // decoder VideoFrame's own release) for frame_latency frames. They are
        // freed together once the GPU is guaranteed done (N frames later).
        const payload = self.allocator.create(RetirePayload) catch {
            // Out of memory: free everything now rather than leaking.
            if (uniform_set.isValid()) rd.freeRid(uniform_set);
            planes.release.call();
            frame.release();
            return true;
        };
        payload.* = .{
            .allocator = self.allocator,
            .rd = rd,
            .uniform_set = uniform_set,
            .plane_release = planes.release,
            .frame = frame,
        };
        self.retire.retain(.{ .ctx = payload, .func = RetirePayload.run });
        return true;
    }

    /// Build the uniform set binding the decoded planes and the output ring
    /// slot to the compute shader: luma(0), chroma(1), rgba_out(2). Returns
    /// whatever rd.uniformSetCreate() returns (si.rid_invalid on failure);
    /// the caller is responsible for releasing `planes`/`frame` on failure.
    fn buildUniformSet(self: *PresentPipeline, rd: *RenderingDevice, planes: PlaneTextures, slot: RingSlot) Rid {
        const u_luma = RdUniform.init();
        defer if (u_luma.unreference()) u_luma.destroy();
        u_luma.setUniformType(.uniform_type_sampler_with_texture);
        u_luma.setBinding(0);
        u_luma.addId(self.sampler);
        u_luma.addId(planes.luma);

        const u_chroma = RdUniform.init();
        defer if (u_chroma.unreference()) u_chroma.destroy();
        u_chroma.setUniformType(.uniform_type_sampler_with_texture);
        u_chroma.setBinding(1);
        u_chroma.addId(self.sampler);
        u_chroma.addId(planes.chroma);

        const u_out = RdUniform.init();
        defer if (u_out.unreference()) u_out.destroy();
        u_out.setUniformType(.uniform_type_image);
        u_out.setBinding(2);
        u_out.addId(slot.rgba_rid);

        var uniforms = Array.init();
        defer uniforms.deinit();
        // Boxing a RefCounted into a Variant takes a ref; deinit the local
        // Variant after append (which takes its own) or the uniform leaks.
        inline for (.{ u_luma, u_chroma, u_out }) |u| {
            var v = Variant.init(*RdUniform, u);
            uniforms.append(v);
            v.deinit();
        }

        return rd.uniformSetCreate(uniforms, self.shader, 0);
    }

    /// Pack the compute shader's push constants (output dimensions +
    /// colorimetry + bit depth + the importer's 10-bit sample scale) into a
    /// PackedByteArray ready for rd.computeListSetPushConstant(). The caller
    /// owns the returned array and must deinit() it.
    fn buildPushConstants(self: *PresentPipeline, frame: VideoFrame, sample_scale: f32) PackedByteArray {
        var pc = PackedByteArray.init();
        _ = pc.resize(@intCast(push_constants.push_constant_size));
        // pack into a stack buffer, then copy into the PackedByteArray.
        var buf: [push_constants.push_constant_size]u8 = undefined;
        push_constants.packPushConstants(
            &buf,
            @intCast(self.width),
            @intCast(self.height),
            frame.color,
            sample_scale,
        );
        for (buf, 0..) |b, i| pc.set(@intCast(i), @intCast(b));
        return pc;
    }

    fn freeResources(self: *PresentPipeline) void {
        const rd = self.rd orelse return;
        // Detach the stable output texture BEFORE freeing the ring textures so
        // it never dangles. Keep the object alive: the player holds a cached
        // ref; a rebuild re-points it.
        if (self.current_texture) |t| t.setTextureRdRid(si.rid_invalid);
        for (0..ring_depth) |i| {
            if (self.ring[i].rgba_rid.isValid()) {
                rd.freeRid(self.ring[i].rgba_rid);
                self.ring[i].rgba_rid = si.rid_invalid;
            }
        }
        if (self.pipeline.isValid()) {
            rd.freeRid(self.pipeline);
            self.pipeline = si.rid_invalid;
        }
        if (self.sampler.isValid()) {
            rd.freeRid(self.sampler);
            self.sampler = si.rid_invalid;
        }
        if (self.shader.isValid()) {
            rd.freeRid(self.shader);
            self.shader = si.rid_invalid;
        }
        // Disabled is terminal — only downgrade Ready to Unbuilt.
        if (self.state == .ready) self.state = .unbuilt;
        self.width = 0;
        self.height = 0;
    }

    /// Tear down all RD resources and drain the retire-ring.
    pub fn shutdown(self: *PresentPipeline) void {
        // Release any surfaces still parked before tearing down RD resources.
        self.retire.drain();
        self.freeResources();
        if (self.importer) |imp| {
            imp.deinit();
            self.importer = null;
        }
        if (self.current_texture) |t| {
            if (t.unreference()) t.destroy();
            self.current_texture = null;
        }
        self.rd = null;
    }
};
