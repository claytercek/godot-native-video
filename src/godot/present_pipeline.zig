//! Y'CbCr-to-RGB presentation on Godot's RenderingDevice. Owns the compute
//! shader, pipeline, and sampler, a platform surface importer, an RGBA output
//! ring, and a retire ring for transient surfaces.
//!
//! Each presentation dispatches one conversion pass into an output slot and
//! points a stable Texture2DRD at it. SDR uses RGBA8; HDR uses scene-linear
//! RGBA16F with 1.0 = 203-nit reference white (BT.2408). Transient surfaces stay
//! alive for N rendered frames before retirement so GPU sampling finishes first.

const std = @import("std");
const builtin = @import("builtin");

const godot = @import("godot");
const RenderingServer = godot.class.RenderingServer;
const Engine = godot.class.Engine;
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

// Use build.zig's named module to share PlaybackController's type identity;
// Zig's module-root boundary prevents path imports into ../core.
const core = @import("core");
const backend = core.backend;
const VideoFrame = backend.VideoFrame;
const push_constants = core.push_constants;
const retire_ring = core.retire_ring;
const shaders = core.shaders;

const si = @import("surface_importer.zig");
const preview_policy = @import("preview_presentation.zig");
const PlaneTextures = si.PlaneTextures;

// Select the platform importer at comptime. Windows chooses D3D12 or CPU-copy
// at runtime; Linux uploads GStreamer CPU planes; Apple platforms use Metal.
// All expose the same value-held interface.
const SurfaceImporter = if (builtin.os.tag == .windows)
    @import("windows_surface_importer.zig").WindowsSurfaceImporter
else if (builtin.os.tag == .linux)
    @import("linux_surface_importer.zig").LinuxSurfaceImporter
else
    @import("metal_surface_importer.zig").MetalSurfaceImporter;

/// Present-pipeline output format.
pub const OutputMode = enum(u8) {
    sdr = 0, // RGBA8, non-linear (tone-mapped / clamped), Godot's standard 2D
    hdr = 1, // RGBA16F, scene-linear, 1.0 = 203-nit Reference White (BT.2408)

    /// Convert a Variant property integer to a mode. Return null for values
    /// outside the property's enum hint (0 or 1), so callers can ignore them.
    pub fn fromInt(v: i64) ?OutputMode {
        return switch (v) {
            0 => .sdr,
            1 => .hdr,
            else => null,
        };
    }
};

/// Decoder-surface retention and RGBA ring depth, measured in rendered frames.
/// Three frames cover Godot's render-pipeline latency.
pub const frame_latency: usize = 3;
pub const ring_depth: usize = frame_latency;

const RingSlot = struct {
    rgba_rid: Rid = si.rid_invalid, // RD storage texture (rgba8 or rgba16f)
};

const ResourceGeneration = struct {
    rd: *RenderingDevice,
    shader: Rid,
    pipeline: Rid,
    sampler: Rid,
    ring: [ring_depth]RingSlot,
};

fn resourceGenerationTeardown(generation: *ResourceGeneration) void {
    for (generation.ring) |slot| {
        if (slot.rgba_rid.isValid()) generation.rd.freeRid(slot.rgba_rid);
    }
    if (generation.pipeline.isValid()) generation.rd.freeRid(generation.pipeline);
    if (generation.sampler.isValid()) generation.rd.freeRid(generation.sampler);
    if (generation.shader.isValid()) generation.rd.freeRid(generation.shader);
}

/// The pipeline's RD-resource lifecycle.
const State = enum(u8) {
    unbuilt, // resources not built (initial, or after free/dimension change)
    ready, // resources built and usable
    rebuild_pending, // live resources must be retired before replacement
    disabled, // no RenderingServer/RenderingDevice — terminal, never leaves
};

// Heap-boxed retirement payload. After the GPU latency window, free the
// uniform set, imported planes, and decoder frame in that order.
const RetireValue = struct {
    rd: *RenderingDevice,
    uniform_set: Rid,
    plane_release: si.Closure,
    frame: VideoFrame,
};

fn retireTeardown(v: *RetireValue) void {
    if (v.uniform_set.isValid()) v.rd.freeRid(v.uniform_set);
    v.plane_release.call();
    v.frame.release();
}

pub const PresentPipeline = struct {
    allocator: std.mem.Allocator,

    rd: ?*RenderingDevice = null, // borrowed: the global RD
    importer: ?SurfaceImporter = null, // built at first buildResources
    last_submission: u64 = 0,

    shader: Rid = si.rid_invalid,
    pipeline: Rid = si.rid_invalid,
    sampler: Rid = si.rid_invalid,

    // Sized in buildResources and repacked in place, avoiding per-frame allocation.
    push_scratch: PackedByteArray,

    ring: [ring_depth]RingSlot = @splat(.{}),
    output_ring: retire_ring.EpochSlots(ring_depth) = .{},

    // Lazily created in getTexture(); identity stable for the pipeline's
    // lifetime. VideoStreamPlayer caches this ref once and draws it forever.
    current_texture: ?*Texture2drd = null,

    retire: retire_ring.RetireRing(frame_latency) = .{},

    width: i32 = 0,
    height: i32 = 0,
    state: State = .unbuilt,
    // Script request, changed only by setOutputMode(); build failure preserves it.
    requested_output_mode: OutputMode = .sdr,
    // Build target: follows the request unless ensureReady() falls back to SDR.
    active_output_mode: OutputMode = .sdr,
    // Live resource mode, set on .ready and cleared on release. Null before
    // build, in headless mode, or after build failure.
    built_output_mode: ?OutputMode = null,

    pub fn init(allocator: std.mem.Allocator) PresentPipeline {
        return .{ .allocator = allocator, .push_scratch = PackedByteArray.init() };
    }

    pub fn deinit(self: *PresentPipeline) void {
        self.shutdown();
    }

    pub fn isReady(self: *const PresentPipeline) bool {
        return self.state == .ready;
    }

    /// Last requested mode, preserved across build failure. It may differ from
    /// the built mode until the next present() or after SDR fallback.
    pub fn outputMode(self: *const PresentPipeline) OutputMode {
        return self.requested_output_mode;
    }

    /// Live resource mode, or null before first present(), in headless mode,
    /// or after build failure. May lag outputMode() while a request is pending;
    /// SDR fallback persists until the request changes again.
    pub fn builtOutputMode(self: *const PresentPipeline) ?OutputMode {
        return self.built_output_mode;
    }

    /// Successful CPU-copy imports this session. Zero on Metal; Windows counts
    /// initial CPU-copy selection and D3D12 fallback imports.
    pub fn cpuCopyCount(self: *const PresentPipeline) u64 {
        if (self.importer) |*importer| return importer.cpuCopyCount();
        return 0;
    }

    /// Request SDR or HDR for the next ensureReady()/present(). A mode change
    /// rebuilds resources, including ring format and shader. Build failure
    /// falls back to SDR without changing the request; builtOutputMode() reports
    /// the result. Repeating the request is a no-op, including after failure.
    pub fn setOutputMode(self: *PresentPipeline, mode: OutputMode) void {
        if (mode != self.requested_output_mode) {
            self.requested_output_mode = mode;
            self.active_output_mode = mode;
            if (self.state == .ready) {
                self.state = .rebuild_pending;
            }
        }
    }

    /// Stable, lazily created RGBA Texture2DRD returned by _getTexture().
    /// Each presentation updates its RD RID without replacing the object.
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
        // Disabled (e.g. headless) is terminal; do not retry each frame.
        if (self.state == .disabled) return false;
        if (!self.ensureImporter()) return false;
        if (self.state == .ready and width == self.width and height == self.height) {
            return true;
        }
        // Dimensions or output mode changed: move the whole live generation
        // into the same latency ring as its submitted frames. New resources
        // can be built immediately without freeing anything the GPU may use.
        if (self.state == .ready or self.state == .rebuild_pending) {
            if (!self.retireResourceGeneration()) return false;
        }
        if (self.buildResources(width, height)) return true;
        // Retry a failed HDR shader/pipeline/texture build once as SDR, keeping
        // the request intact. Always use SDR, not the previous mode, to avoid
        // retrying a failed SDR build as HDR. buildResources() frees partial
        // builds at entry; if SDR also fails, return without looping.
        if (self.active_output_mode != .sdr) {
            log.warn("{t} pipeline build failed — falling back to sdr output.", .{self.active_output_mode});
            self.active_output_mode = .sdr;
            return self.buildResources(width, height);
        }
        return false;
    }

    fn buildResources(self: *PresentPipeline, width: i32, height: i32) bool {
        // Reclaim partial builds. Validity checks make this a no-op when
        // ensureReady() already retired the previous generation.
        self.freeResources();

        const rd = self.rd.?;

        // Size the reusable push-constant staging buffer once. present()
        // repacks into its detached buffer instead of allocating per frame.
        _ = self.push_scratch.resize(@intCast(push_constants.push_constant_size));

        // --- Compile the shader variant for the active output mode. ---
        const want_hdr = self.active_output_mode == .hdr;
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
        self.output_ring = .{};
        // Point the stable output texture at slot 0. This fires `changed`, so
        // the player's cached texture picks up the real dimensions.
        self.getTexture().setTextureRdRid(self.ring[0].rgba_rid);
        self.state = .ready;
        self.built_output_mode = self.active_output_mode;
        return true;
    }

    fn ensureImporter(self: *PresentPipeline) bool {
        if (self.state == .disabled) return false;
        const rd = self.rd orelse RenderingServer.getRenderingDevice() orelse {
            // Headless: disable only texture output and log once. Decode,
            // audio, the clock, and playback state continue.
            self.state = .disabled;
            log.info("No RenderingDevice — presentation disabled (headless mode). " ++
                "Decode and audio continue normally.", .{});
            return false;
        };
        self.rd = rd;

        // Build the surface importer lazily, then bind it to RD.
        if (self.importer == null) {
            self.importer = SurfaceImporter.init(self.allocator);
        }
        const importer = &self.importer.?;
        if (!importer.initialize(rd)) {
            log.err("Surface importer init failed (RD backend not supported by importer?).", .{});
            return false;
        }
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

    /// Engine.getFramesDrawn advances after SceneTree processing when Godot
    /// draws (main/main.cpp). Previews, reentrant resume, and _update share an
    /// epoch; process ticks without rendering do not age GPU resources. The
    /// binding pumps epochs after playback/preview stops until all batches retire.
    pub fn advanceRenderEpoch(self: *PresentPipeline) void {
        self.retire.advance(@intCast(Engine.getFramesDrawn()));
    }

    pub fn hasRetirements(self: *const PresentPipeline) bool {
        return self.retire.liveCount() != 0;
    }

    /// Allocate a presentation identity independently of decoder timestamps.
    pub fn nextSubmission(self: *PresentPipeline) u64 {
        self.last_submission +%= 1;
        if (self.last_submission == 0) self.last_submission = 1;
        return self.last_submission;
    }

    /// Normal playback preserves delayed-import behavior and always consumes
    /// frame, either immediately on failure or via the GPU retire ring.
    pub fn present(self: *PresentPipeline, frame: VideoFrame) bool {
        const result = self.presentSubmission(frame, self.nextSubmission(), false);
        if (result != .presented) frame.release();
        return result == .presented;
    }

    /// Preview retries borrow frame until matching output is ready. Only
    /// .presented transfers ownership to the retire ring. Stale delayed output
    /// is discarded without dispatch, even when its PTS equals this request.
    pub fn presentPreview(self: *PresentPipeline, frame: VideoFrame, submission: u64) preview_policy.Result {
        return self.presentSubmission(frame, submission, true);
    }

    fn presentSubmission(self: *PresentPipeline, frame: VideoFrame, submission: u64, require_match: bool) preview_policy.Result {
        self.advanceRenderEpoch();
        if (!self.ensureImporter()) return .failed;
        const importer = &self.importer.?;
        const imported = importer.import(frame, submission);
        var planes = switch (imported) {
            .success => |value| value,
            else => return preview_policy.importFailure(std.meta.activeTag(imported)),
        };
        if (require_match and !preview_policy.matches(submission, planes.metadata.submission)) {
            planes.discard();
            return .pending;
        }
        if (!self.ensureReady(planes.width, planes.height)) {
            planes.discard();
            return .failed;
        }
        const rd = self.rd.?;

        // Select locally, commit only after fallible preparation succeeds.
        // Same-epoch dispatches write one texture in GPU command order.
        var output_ring = self.output_ring;
        const slot = self.ring[output_ring.select(self.retire.currentEpoch())];
        const uniform_set = self.buildUniformSet(rd, planes, slot);
        if (!uniform_set.isValid()) {
            planes.discard();
            return .failed;
        }
        self.packPushConstants(planes);

        // Retain resources and frame before dispatch or Texture2DRD.changed.
        // Synchronous handlers may replace the stream or free the player;
        // the binding keeps playback alive until this call returns.
        self.retire.retain(self.allocator, RetireValue{
            .rd = rd,
            .uniform_set = uniform_set,
            .plane_release = planes.release,
            .frame = frame,
        }, retireTeardown) catch {
            rd.freeRid(uniform_set);
            planes.discard();
            return .failed;
        };

        self.output_ring = output_ring;
        const gx: u32 = @intCast(@divTrunc(self.width + 7, 8));
        const gy: u32 = @intCast(@divTrunc(self.height + 7, 8));
        const cl = rd.computeListBegin();
        rd.computeListBindComputePipeline(cl, self.pipeline);
        rd.computeListBindUniformSet(cl, uniform_set, 0);
        rd.computeListSetPushConstant(cl, self.push_scratch, push_constants.push_constant_size);
        rd.computeListDispatch(cl, gx, gy, 1);
        rd.computeListEnd();

        // Last access to pipeline state: this emits a synchronous signal.
        self.getTexture().setTextureRdRid(slot.rgba_rid);
        return .presented;
    }

    /// Bind luma(0), chroma(1), and rgba_out(2). Returns an invalid RID on
    /// failure; the caller remains responsible for planes/frame ownership.
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

    /// Pack dimensions, colorimetry, and bit depth into pre-sized push_scratch
    /// for rd.computeListSetPushConstant(), without allocating.
    fn packPushConstants(self: *PresentPipeline, planes: PlaneTextures) void {
        // Pack into a stack buffer, then copy into push_scratch's own storage.
        var buf: [push_constants.push_constant_size]u8 = undefined;
        push_constants.packPushConstants(
            &buf,
            @intCast(self.width),
            @intCast(self.height),
            planes.metadata.color,
        );
        // index(0) detaches CoW storage and returns the unique writable buffer.
        const dst: [*]u8 = @ptrCast(self.push_scratch.index(0));
        @memcpy(dst[0..buf.len], buf[0..]);
    }

    fn freeResources(self: *PresentPipeline) void {
        const rd = self.rd orelse return;
        // Detach before freeing ring textures to avoid a dangling RID. Keep
        // the player's cached Texture2DRD alive for the next build.
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
        // Disabled is terminal; only change ready to unbuilt.
        if (self.state == .ready) self.state = .unbuilt;
        self.built_output_mode = null;
        self.width = 0;
        self.height = 0;
    }

    fn retireResourceGeneration(self: *PresentPipeline) bool {
        self.advanceRenderEpoch();
        const rd = self.rd orelse return false;
        // Generations are independent epoch-batched payloads. They retire
        // even if the replacement build/import fails or playback stays paused;
        // no later successful frame is needed to carry their release hook.
        self.retire.retain(self.allocator, ResourceGeneration{
            .rd = rd,
            .shader = self.shader,
            .pipeline = self.pipeline,
            .sampler = self.sampler,
            .ring = self.ring,
        }, resourceGenerationTeardown) catch {
            log.err("could not retain the current GPU resource generation for a safe rebuild.", .{});
            return false;
        };

        if (self.current_texture) |texture| texture.setTextureRdRid(si.rid_invalid);
        self.shader = si.rid_invalid;
        self.pipeline = si.rid_invalid;
        self.sampler = si.rid_invalid;
        self.ring = @splat(.{});
        self.width = 0;
        self.height = 0;
        self.state = .unbuilt;
        self.built_output_mode = null;
        return true;
    }

    /// Tear down all RD resources and drain the retire-ring.
    pub fn shutdown(self: *PresentPipeline) void {
        // Teardown is immediate. RD defers RID destruction, but drain is not
        // a GPU fence for native allocations, notably borrowed D3D12 resources.
        // Safe deferred destruction of those allocations remains unresolved.
        self.retire.drain();
        self.freeResources();
        if (self.importer) |*imp| {
            imp.deinit();
            self.importer = null;
        }
        if (self.current_texture) |t| {
            if (t.unreference()) t.destroy();
            self.current_texture = null;
        }
        self.push_scratch.deinit();
        self.rd = null;
    }
};
