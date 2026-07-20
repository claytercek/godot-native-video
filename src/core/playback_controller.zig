//! playback_controller.zig — port of src/core/playback_controller.h/.cpp.
//!
//! Godot-free per-stream playback state machine.
//!
//! The Binding (NativeVideoStreamPlayback) owns exactly one of these per
//! playback and translates its inputs/outputs to Godot types. No Godot
//! includes, no RenderingDevice, no AudioServer — the controller talks to the
//! mixer via the MixSink seam, to the decoder via the shared DecodeScheduler,
//! and surfaces warnings via takeWarnings(). tick() returns the frame to
//! present BY VALUE; the caller owns the GPU present and the frame's release().
//!
//! ALLOCATOR: load() takes and stores a std.mem.Allocator. It owns the
//! controller's audio ring buffer, mix/drive scratch buffers, the per-track
//! metadata cache, and the warning strings. deinit() frees all of them.
//! (The DecodeStream and its Backend are owned by the process-wide
//! DecodeScheduler, which uses its own allocator; see decode_scheduler.zig.)

const std = @import("std");

const backend_mod = @import("backend.zig");
const clock_mod = @import("clock.zig");
const audio_ring_mod = @import("audio_ring.zig");
const scrubber_mod = @import("scrubber.zig");
const wall_clock_mod = @import("wall_clock.zig");
const decode_scheduler = @import("decode_scheduler.zig");
const sys_clock = @import("sys_clock.zig");
const canonical_mix_format = @import("canonical_mix_format.zig");
const channel_mixer = @import("channel_mixer.zig");
const present_selector = @import("present_selector.zig");

const Backend = backend_mod.Backend;
const VideoFrame = backend_mod.VideoFrame;
const Colorimetry = backend_mod.Colorimetry;
const AudioTrackInfo = backend_mod.AudioTrackInfo;
const ClockBridge = clock_mod.ClockBridge;
const AudioMasterClock = clock_mod.AudioMasterClock;
const MonotonicClock = clock_mod.MonotonicClock;
const AudioRing = audio_ring_mod.AudioRing;
const Scrubber = scrubber_mod.Scrubber;
const ScrubResolve = scrubber_mod.ScrubResolve;
const ResolveMode = scrubber_mod.ResolveMode;
const WallClockMs = wall_clock_mod.WallClockMs;
const DecodeScheduler = decode_scheduler.DecodeScheduler;
const StreamHandle = decode_scheduler.StreamHandle;

// Bounded backoff for the Exact-resolve forward-decode spin in
// applyScrubResolve(). The spin waits for the decode pool worker to top the
// queue up to the exact scrub target. A pure yield loop can hot-loop on a
// loaded machine; instead we yield a bounded number of times (cheap, sub-ms
// latency), then sleep in small increments (bounded CPU), then give up and let
// the present step converge on the next ticks. Total wall-clock ceiling is
// roughly kScrubMaxYieldSpins yields + kScrubMaxSleepSpins * kScrubSpinSleep.
pub const kScrubMaxYieldSpins: i32 = 100;
pub const kScrubMaxSleepSpins: i32 = 1000;
// 0.1 ms per sleep iteration — responsive without burning a core.
pub const kScrubSpinSleepMs: f64 = 0.1;

// -----------------------------------------------------------------------
// MixSink — the one Godot-touching seam the controller calls through.
//
// Returns the frames it actually ACCEPTED; that count is the back-pressure
// signal the controller's clock-advance accounting keys on (it advances by
// min(accepted, real_frames) so neither underrun silence nor a full downstream
// buffer inflates media time). The Binding wraps mix_audio().
//
// A ptr + vtable interface (Zig has no capturing closures). `interleaved`
// holds whole frames of `channel_count` contiguous float32 samples; the
// frame count is interleaved.len / channel_count.
// -----------------------------------------------------------------------
pub const MixSink = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        mix: *const fn (*anyopaque, interleaved: []const f32, channel_count: i32) i32,
    };

    /// Mix `channel_count`-channel interleaved PCM into the downstream
    /// buffer. `interleaved.len` must be an exact multiple of
    /// `channel_count`. Returns the number of frames actually accepted.
    pub fn mix(self: MixSink, interleaved: []const f32, channel_count: i32) i32 {
        std.debug.assert(channel_count > 0);
        std.debug.assert(interleaved.len % @as(usize, @intCast(channel_count)) == 0);
        return self.vtable.mix(self.ptr, interleaved, channel_count);
    }
};

// -----------------------------------------------------------------------
// PlaybackController — Godot-free per-stream playback state machine.
// -----------------------------------------------------------------------
pub const PlaybackController = struct {
    allocator: std.mem.Allocator = undefined,

    stream: ?StreamHandle = null,
    scrubber: Scrubber = .{},
    clock: ?ClockBridge = null,
    audio_ring: ?AudioRing = null,

    // Scratch buffers kept as members to avoid per-call allocations on the
    // decode/mix path (resized only when a larger buffer is needed).
    mix_scratch: std.ArrayList(f32) = .empty, // fill_audio()'s channel-mix scratch
    drive_scratch: std.ArrayList(f32) = .empty, // drive_audio()'s ring-read scratch

    loaded: bool = false,
    playing: bool = false,
    paused: bool = false,
    // Video EOS is tracked by the shared scheduler (atEnd()), so this only
    // tracks audio EOS for the end-of-playback condition.
    audio_eos: bool = false,
    has_audio: bool = false, // clip carries an audio track -> audio is master
    audio_track_count: i32 = 0, // cached from the backend at load time
    length: f64 = 0.0,
    position: f64 = 0.0, // PTS of the most recently presented frame

    width: i32 = 0,
    height: i32 = 0,
    color: Colorimetry = .{},

    // See canonical_mix_format. canonical_sample_rate is the FIRST
    // audio-bearing track's rate, NOT shared across tracks.
    canonical_channels: i32 = 0,
    canonical_sample_rate: i32 = 0,

    // --- Audio track reconcile state ---
    //
    // desired_track and live_track converge by construction via
    // reconcileAudioTrack(): desired_track is what the caller asked for (via
    // requestAudioTrack()), live_track is what the backend is actually
    // decoding. They can disagree only between a request and the next
    // reconcile; a failed reselect rolls desired_track back to live_track
    // instead of leaving the two permanently out of sync.
    desired_track: i32 = 0,
    live_track: i32 = 0,

    // True between a mid-stream reselect and the first audio chunk from the new
    // track. During this window the ClockBridge is in monotonic-master mode so
    // video keeps advancing while audio is silent.
    switch_in_progress: bool = false,

    // Per-track audio metadata cached at load time for sample-rate validation
    // during mid-stream track switches.
    track_infos: std.ArrayList(AudioTrackInfo) = .empty,

    warnings: std.ArrayList([]const u8) = .empty,

    pub fn init() PlaybackController {
        return .{};
    }

    /// Frees the controller's owned resources. Runs shutdown() first (matching
    /// the C++ destructor). Safe to call once after any (or no) load().
    pub fn deinit(self: *PlaybackController) void {
        self.shutdown();
        if (self.audio_ring) |*r| r.deinit();
        self.audio_ring = null;
        self.mix_scratch.deinit(self.allocator);
        self.drive_scratch.deinit(self.allocator);
        self.track_infos.deinit(self.allocator);
        for (self.warnings.items) |w| self.allocator.free(w);
        self.warnings.deinit(self.allocator);
    }

    fn warn(self: *PlaybackController, message: []const u8) void {
        // Takes ownership of the allocated `message`.
        self.warnings.append(self.allocator, message) catch self.allocator.free(message);
    }

    fn warnFmt(self: *PlaybackController, comptime fmt: []const u8, args: anytype) void {
        const message = std.fmt.allocPrint(self.allocator, fmt, args) catch return;
        self.warn(message);
    }

    /// Drains warnings queued since the last call, transferring ownership of the
    /// strings to the caller. The caller must free each string and deinit() the
    /// returned list with the same allocator load() was given.
    pub fn takeWarnings(self: *PlaybackController) std.ArrayList([]const u8) {
        const out = self.warnings;
        self.warnings = .empty;
        return out;
    }

    /// Unregisters from the scheduler, blocking until any in-flight decode slice
    /// completes (no use-after-free). Safe to call multiple times.
    pub fn shutdown(self: *PlaybackController) void {
        if (self.stream) |s| {
            DecodeScheduler.instance().unregisterStream(s);
            self.stream = null;
        }
    }

    /// Takes ownership of an already-open()'d backend, derives the Canonical Mix
    /// Format, builds the master clock, and registers with the shared
    /// DecodeScheduler. A pre-load requestAudioTrack() selection is validated and
    /// applied here.
    pub fn load(
        self: *PlaybackController,
        allocator: std.mem.Allocator,
        backend: Backend,
        audio_output_latency_seconds: f64,
    ) !void {
        self.allocator = allocator;

        // Cached at open time from the track's format descriptions; per-frame CV
        // attachments may carry more accurate metadata at decode time.
        self.color = backend.colorimetry();
        self.length = backend.durationSeconds();
        self.width = backend.videoWidth();
        self.height = backend.videoHeight();
        self.audio_track_count = backend.audioTrackCount();

        // --- Canonical Mix Format ---
        // Derived pure from the backend's audio tracks (no scheduler, no clock).
        // Done before the backend moves into the scheduler, which takes
        // ownership.
        var fmt = try canonical_mix_format.deriveCanonicalMixFormat(allocator, backend);
        self.canonical_channels = fmt.channels;
        self.canonical_sample_rate = fmt.sample_rate;
        self.has_audio = fmt.has_audio;
        // Move the per-track metadata and warning strings out of `fmt`.
        self.track_infos.deinit(allocator);
        self.track_infos = fmt.track_infos;
        fmt.track_infos = .empty;
        for (fmt.warnings.items) |w| self.warn(w);
        fmt.warnings.deinit(allocator); // strings transferred; free the outer array only

        // Hand the Backend to the process-wide shared decode pool. From here a
        // pool worker decodes video ahead into stream's queue; this object
        // never touches the Backend directly except via the scheduler
        // (nextFrame / withBackend).
        self.stream = try DecodeScheduler.instance().registerStream(backend);

        if (self.has_audio) {
            // Audio-master: latency-compensated so mediaTime() reflects what the
            // speaker is emitting, not what was just queued.
            const audio = AudioMasterClock.init(self.canonical_sample_rate, audio_output_latency_seconds);
            const mono = MonotonicClock.init(0.0);
            self.clock = ClockBridge.init(audio, mono, true);
            const ring_frames: usize = @as(usize, @intCast(self.canonical_sample_rate)) / 2; // ~0.5 s
            self.audio_ring = try AudioRing.init(allocator, self.canonical_channels, ring_frames);
        } else {
            // Silent clip: a null audio clock makes the bridge permanently
            // monotonic-master, so every audio-facing ClockBridge method is a
            // safe no-op.
            const mono = MonotonicClock.init(0.0);
            self.clock = ClockBridge.init(null, mono, false);
        }

        self.loaded = true;
        self.position = 0.0;
        self.audio_eos = false;
        self.switch_in_progress = false;

        // A pre-load requestAudioTrack() selection must survive, not be
        // clobbered; validate it now that audio_track_count is known.
        if (self.audio_track_count > 0 and
            (self.desired_track < 0 or self.desired_track >= self.audio_track_count))
        {
            self.warnFmt(
                "Audio track index {d} is out of range. Clip has {d} track(s). Falling back to default (0).",
                .{ self.desired_track, self.audio_track_count },
            );
            self.desired_track = 0;
        }
        self.live_track = 0;
        // Cheap-applies any pre-load selection (we are not yet playing).
        self.reconcileAudioTrack();
    }

    // No getter boilerplate: loaded/length/width/height/color and the
    // canonical mix format fields are read directly. All state fields are
    // caller-readable; mutate only through the methods below.

    // --- Transport ---

    pub fn play(self: *PlaybackController, now: WallClockMs) void {
        if (!self.loaded) return;
        const was_playing = self.playing;
        self.playing = true;
        self.paused = false;
        if (self.master()) |c| c.setPaused(false);
        // Resuming after a scrub: force an exact resolve at the last scrub target
        // so play starts from the precise frame, not an approximate keyframe one.
        if (!was_playing and self.stream != null) {
            self.applyScrubResolve(self.scrubber.onResume(now));
        }
    }

    pub fn stop(self: *PlaybackController) void {
        self.playing = false;
        self.paused = false;
        self.audio_eos = false;
        self.position = 0.0;
        if (self.master()) |c| c.setTime(0.0);
        if (self.audio_ring) |*r| r.clear();
        // Flush + reseek to start (serialized against the worker).
        if (self.stream) |s| DecodeScheduler.instance().requestSeek(s, 0.0);
        self.scrubber = Scrubber.init(self.scrubber.config); // no stale velocity/settle
        self.switch_in_progress = false;
        // Track selection persists across stop (desired_/live_track are NOT
        // reset here). If the caller stopped mid-switch, re-anchor so the bridge
        // does not stay monotonic-master forever with no fill_audio() to
        // re-anchor it.
        if (self.has_audio) {
            if (self.clock) |*c| c.reanchorToAudio();
        }
    }

    pub fn setPaused(self: *PlaybackController, paused: bool) void {
        self.paused = paused;
        if (self.master()) |c| c.setPaused(paused);
    }

    // Master-clock media time — the clock the present-selector compares frames
    // against. Distinct from position() (the PTS of the most recently PRESENTED
    // video frame).
    pub fn mediaTime(self: *PlaybackController) f64 {
        if (self.master()) |c| return c.mediaTime();
        return 0.0;
    }

    // Feeds the scrubber and applies the resulting resolve (keyframe or exact).
    pub fn seek(self: *PlaybackController, time_seconds: f64, now: WallClockMs) void {
        if (self.stream == null or self.master() == null) return;
        const resolve = self.scrubber.onSeek(@max(time_seconds, 0.0), now);
        self.applyScrubResolve(resolve);
    }

    // Refuses a mid-stream switch to a track whose sample rate differs from the
    // canonical rate (the mix format is fixed for the lifetime); applies
    // immediately when stopped/pre-load, otherwise defers to the next tick().
    pub fn requestAudioTrack(self: *PlaybackController, idx_in: i32) void {
        var idx = idx_in;
        if (self.audio_track_count > 0 and (idx < 0 or idx >= self.audio_track_count)) {
            self.warnFmt(
                "Audio track index {d} is out of range. Clip has {d} track(s). Falling back to default (0).",
                .{ idx, self.audio_track_count },
            );
            idx = 0;
        }

        if (idx == self.desired_track) return;

        // The canonical mix format and AudioMasterClock are fixed to the clip's
        // canonical rate and cannot change mid-stream, so a mid-stream switch to
        // a differing-rate track is refused outright (stopped/pre-play has no
        // live audio path yet, so it is allowed).
        if (self.playing and self.has_audio and idx >= 0 and
            @as(usize, @intCast(idx)) < self.track_infos.items.len and
            self.track_infos.items[@intCast(idx)].sample_rate != self.canonical_sample_rate)
        {
            self.warnFmt(
                "Cannot switch to audio track {d}: sample rate {d} Hz differs from the canonical rate {d} Hz. Rejecting switch.",
                .{ idx, self.track_infos.items[@intCast(idx)].sample_rate, self.canonical_sample_rate },
            );
            return;
        }

        self.desired_track = idx;

        // Stopped/pre-play applies immediately; playing/paused defers to the next
        // tick() (which runs while paused).
        if (!self.playing) self.reconcileAudioTrack();
    }

    // Returns the frame to present this tick (BY VALUE), or null when not loaded
    // / not playing / paused. The caller owns the GPU present and the frame's
    // release().
    pub fn tick(self: *PlaybackController, delta_seconds: f64, now: WallClockMs, sink: MixSink) ?VideoFrame {
        const clock = self.master();
        if (!self.loaded or clock == null or self.stream == null) return null;
        const c = clock.?;

        // Settle check runs regardless of play/pause: scrubbing commonly happens
        // while paused (dragging a timeline).
        self.settleScrub(now);

        // Reconcile any pending track switch. Runs even while paused so a switch
        // requested mid-pause (or during a scrub) is picked up promptly.
        self.reconcileAudioTrack();

        if (!self.playing or self.paused) return null;
        const sched = DecodeScheduler.instance();

        const media_now = self.advanceClock(delta_seconds, sink, c);
        const chosen = self.selectPresentFrame(sched, media_now);
        self.checkEndOfPlayback(sched);

        return chosen;
    }

    // Settle check runs regardless of play/pause: scrubbing commonly happens
    // while paused (dragging a timeline). Once a fast drag has gone quiet for
    // the debounce window, upgrade the approximate keyframe frame to the
    // exact target frame.
    fn settleScrub(self: *PlaybackController, now: WallClockMs) void {
        if (self.scrubber.poll(now)) |settle| {
            self.applyScrubResolve(settle);
        }
    }

    // Advance the master clock for this tick and return the resulting media
    // time. One-clock rule: each tick advances media time from exactly one
    // source. Audio-master ticks advance from real mixed audio frames; when
    // audio is exhausted (a shorter audio track fully drained — legitimate in
    // real-world files) and did not advance the clock, the render delta
    // substitutes so video keeps moving. Monotonic-master ticks (silent clip,
    // or the handoff window during a track switch) advance by the render
    // delta; audio is still pumped so a mid-switch track re-anchors as soon
    // as its samples flow.
    fn advanceClock(self: *PlaybackController, delta_seconds: f64, sink: MixSink, c: *ClockBridge) f64 {
        if (c.isAudioMaster()) {
            self.fillAudio();
            const advanced_from_audio = self.driveAudio(sink);
            if (!advanced_from_audio and self.audioExhausted()) {
                c.setTime(c.mediaTime() + delta_seconds);
            }
        } else {
            c.advance(delta_seconds);
            if (self.has_audio) {
                self.fillAudio();
                _ = self.driveAudio(sink);
            }
        }
        return c.mediaTime();
    }

    // Present step: drop-late / hold-early, via the Godot-free selector. Peek
    // head/next PTS non-destructively (frame order is never disturbed):
    //   * Drop  — head stale: pop+release, loop.
    //   * Show  — head is the due frame for `media_now`: pop and present it.
    //   * Hold  — head in the future: present nothing new.
    // Updates self.position when a frame is chosen.
    fn selectPresentFrame(self: *PlaybackController, sched: *DecodeScheduler, media_now: f64) ?VideoFrame {
        const frame_interval = 1.0 / 30.0; // nominal; refined when fps is known
        var chosen: ?VideoFrame = null;

        while (true) {
            const head_pts = sched.peekHeadPts(self.stream.?);
            if (head_pts == null) break; // queue empty -> hold the current frame
            const next_pts = sched.peekNextPts(self.stream.?);

            const action = present_selector.selectPresentAction(head_pts, next_pts, media_now, frame_interval);

            if (action == .drop) {
                if (sched.nextFrame(self.stream.?)) |stale| stale.release();
                continue;
            }

            if (action == .show) {
                chosen = sched.nextFrame(self.stream.?);
            }

            // Show or Hold both end the present scan for this tick.
            break;
        }

        if (chosen) |ch| self.position = ch.pts_seconds;
        return chosen;
    }

    // End-of-playback: video EOS (atEnd() is worker-reported) and audio drained.
    fn checkEndOfPlayback(self: *PlaybackController, sched: *DecodeScheduler) void {
        if (sched.atEnd(self.stream.?) and self.audioExhausted()) {
            self.playing = false;
        }
    }

    // ------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------

    fn master(self: *PlaybackController) ?*ClockBridge {
        if (self.clock) |*c| return c;
        return null;
    }

    fn audioExhausted(self: *PlaybackController) bool {
        // True when no real audio samples will ever advance the clock again:
        // silent clips, and a shorter audio track once it has fully drained.
        if (!self.has_audio) return true;
        if (self.audio_eos) {
            if (self.audio_ring) |*r| return r.empty();
        }
        return false;
    }

    fn fillAudio(self: *PlaybackController) void {
        if (self.stream == null or self.audio_ring == null or self.audio_eos) return;
        // Pump under the scheduler's per-stream exclusion so we never race the
        // worker decoding video ahead on the same Backend.
        DecodeScheduler.instance().withBackend(self.stream.?, self, fillAudioClosure);
    }

    fn fillAudioClosure(self: *PlaybackController, backend: *Backend) void {
        var ring = &self.audio_ring.?;
        // Half-fill: cushion against decode jitter without buffering unbounded
        // audio.
        while (ring.freeFrames() > ring.availableFrames()) {
            const chunk = backend.nextAudioChunk() orelse {
                // EOS. If a switch is still in progress, we simply never
                // re-anchor: the bridge stays monotonic-master and tick()'s
                // clock->advance() keeps video moving through what is now a
                // permanent gap.
                self.audio_eos = true;
                break;
            };
            if (chunk.samples.len == 0 or chunk.frame_count <= 0) continue;
            // --- Mid-stream track switch: re-anchor clock when new audio flows.
            // During a switch the clock is in monotonic-master mode so video keeps
            // advancing through the audio silence. reconcileAudioTrack() cleared
            // the ring before this call, so the first chunk to reach this point
            // (decoded, not merely attempted) is genuinely from the new track: the
            // audio clock is repositioned to the current monotonic position so
            // mediaTime() remains continuous.
            if (self.switch_in_progress) {
                self.clock.?.reanchorToAudio();
                self.switch_in_progress = false;
            }
            // Mix native layout -> canonical (no-op memcpy when counts match).
            const nf = chunk.frame_count;
            const sc = chunk.channel_count;
            const dc = self.canonical_channels;
            const needed: usize = @as(usize, @intCast(nf)) * @as(usize, @intCast(dc));
            if (!self.ensureScratchCapacity(&self.mix_scratch, needed)) return;
            channel_mixer.mixChannels(chunk.samples, sc, self.mix_scratch.items[0..needed], dc, nf);
            _ = ring.write(self.mix_scratch.items[0..needed], @intCast(nf));
        }
    }

    fn driveAudio(self: *PlaybackController, sink: MixSink) bool {
        if (self.audio_ring == null or self.clock == null or self.canonical_channels <= 0) return false;

        const kMaxMixFramesPerTick: i32 = 4096; // ~85 ms @ 48k

        const ch = self.canonical_channels;
        var ring = &self.audio_ring.?;
        const available = ring.availableFrames();
        // On underrun, offer a small block of silence so the sink keeps its
        // buffer fed; the clock is NOT advanced for silence (readFrames reports 0
        // real frames).
        const request_base: usize = if (available > 0) available else 256;
        const request: i32 = @intCast(@min(request_base, @as(usize, @intCast(kMaxMixFramesPerTick))));

        const needed: usize = @as(usize, @intCast(request)) * @as(usize, @intCast(ch));
        if (!self.ensureScratchCapacity(&self.drive_scratch, needed)) return false;

        // Drain decoded PCM (or silence on underrun) into the staging buffer.
        const real_frames = ring.readFrames(self.drive_scratch.items[0..needed], @intCast(request));

        // Advance the clock ONLY by frames both real (non-silence) AND consumed —
        // neither underrun silence nor a full downstream buffer inflates media
        // time. If the sink accepts fewer than `real_frames` (near-full
        // downstream buffer), the surplus is dropped: the clock stays honest at
        // the cost of a little lost audio. Tolerable for linear playback.
        const accepted = sink.mix(self.drive_scratch.items[0..needed], ch);
        const advance = @min(accepted, @as(i32, @intCast(real_frames)));
        if (advance > 0) self.clock.?.onAudioMixed(advance);
        return advance > 0;
    }

    // Grow `scratch` to at least `needed` elements if it isn't already — the
    // "grow scratch buffer" idiom shared by fillAudioClosure() and
    // driveAudio(). Returns false (buffer left as-is) on allocation failure.
    fn ensureScratchCapacity(self: *PlaybackController, scratch: *std.ArrayList(f32), needed: usize) bool {
        if (scratch.items.len < needed) {
            scratch.resize(self.allocator, needed) catch return false;
        }
        return true;
    }

    fn applyScrubResolve(self: *PlaybackController, resolve: ScrubResolve) void {
        const c = self.master() orelse return;
        if (self.stream == null) return;
        const target = @max(resolve.target_seconds, 0.0);

        if (self.audio_ring) |*r| r.clear(); // stale audio must not play after a (re)seek
        const sched = DecodeScheduler.instance();

        // Both modes start by flushing the decode-ahead queue and reseeking the
        // Backend to the preceding keyframe through the scheduler (serialized
        // against the worker; no race / no UAF).
        sched.requestSeek(self.stream.?, target);

        if (resolve.mode == .exact) {
            // Decode forward past the keyframe to the exact target, dropping
            // earlier frames; bounded by the clip (stops at EOS). Runs on the
            // caller's thread only on settle/resume (not the hot per-frame path),
            // so a brief wait for the worker is acceptable. The wait uses bounded
            // backoff (kScrubMaxYieldSpins / kScrubMaxSleepSpins): a pure yield
            // loop could hot-loop on a loaded machine.
            const eps = 1.0 / 120.0; // ~half a frame at 60fps tolerance
            var yield_spins: i32 = 0;
            var sleep_spins: i32 = 0;
            const sleep_ns: u64 = @intFromFloat(kScrubSpinSleepMs * 1000.0 * 1000.0);
            while (true) {
                const head = sched.peekHeadPts(self.stream.?);
                if (head == null) {
                    if (sched.atEnd(self.stream.?)) break; // EOS before the target — clamp.
                    if (yield_spins < kScrubMaxYieldSpins) {
                        std.Thread.yield() catch {};
                        yield_spins += 1;
                    } else if (sleep_spins < kScrubMaxSleepSpins) {
                        sys_clock.sleep(sleep_ns);
                        sleep_spins += 1;
                    } else {
                        break; // worker stalled — give up, let present step converge.
                    }
                    continue;
                }
                yield_spins = 0;
                sleep_spins = 0;
                if (head.? + eps >= target) break; // head is at/after the target
                // Head is before the target: drop it and keep decoding forward.
                if (sched.nextFrame(self.stream.?)) |stale| stale.release();
            }
        }

        c.setTime(target); // re-anchor the master clock to the resolved target
        self.position = target;
        self.audio_eos = false;

        // Reconcile any pending track switch at the resolved position (position
        // == target here) so a new selection is primed at the correct spot.
        self.reconcileAudioTrack();
    }

    fn reconcileAudioTrack(self: *PlaybackController) void {
        if (self.desired_track == self.live_track or self.stream == null) return;
        const sched = DecodeScheduler.instance();

        if (!self.playing) {
            // Stopped / pre-play: cheap apply. Deferred in the backend until its
            // next seek — which play()'s scrub-resume resolve always issues first.
            sched.withBackend(self.stream.?, self, applyDesiredTrack);
            self.live_track = self.desired_track;
            return;
        }

        // Playing (or paused — reselecting now primes the new reader at position
        // so resume is instant).
        if (self.clock == null or self.audio_ring == null) return;

        self.clock.?.handoffToMonotonic(); // no-op if already monotonic
        self.switch_in_progress = true;

        const target = self.desired_track;
        const prime_seconds = self.position;

        // Reselect under the scheduler's per-stream exclusion. Tears down and
        // rebuilds ONLY the audio decode path; the FrameQueue still has buffered
        // frames so presenting is uninterrupted.
        var ctx = ReselectCtx{ .target = target, .prime = prime_seconds };
        sched.withBackend(self.stream.?, &ctx, ReselectCtx.run);

        if (!ctx.ok) {
            // The Backend contract leaves the audio decode path undefined on
            // failure, so the old track is not safely playable. Roll desired back
            // to what is still live and force a seek to recover.
            self.desired_track = self.live_track;
            self.switch_in_progress = false;
            self.clock.?.reanchorToAudio();
            self.warnFmt("Audio track switch to {d} failed; recovering via seek.", .{target});
            sched.requestSeek(self.stream.?, self.position);
            return;
        }

        // Clear stale samples; fillAudio() re-anchors when the new track flows.
        self.live_track = self.desired_track;
        self.audio_ring.?.clear();
        self.audio_eos = false;
    }

    fn applyDesiredTrack(self: *PlaybackController, backend: *Backend) void {
        backend.selectAudioTrack(self.desired_track);
    }

    const ReselectCtx = struct {
        target: i32,
        prime: f64,
        ok: bool = false,
        fn run(ctx: *ReselectCtx, backend: *Backend) void {
            ctx.ok = backend.reselectAudioTrack(ctx.target, ctx.prime);
        }
    };
};

test {
    _ = @import("playback_controller_test.zig");
}
