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
// The C++ pure-virtual class becomes a ptr + vtable interface. `interleaved`
// points at frame_count * channel_count contiguous float32 samples.
// -----------------------------------------------------------------------
pub const MixSink = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        mix: *const fn (*anyopaque, interleaved: []const f32, frame_count: i32, channel_count: i32) i32,
    };

    /// Mix `frame_count` frames of `channel_count`-channel interleaved PCM into
    /// the downstream buffer. Returns the number of frames actually accepted.
    pub fn mix(self: MixSink, interleaved: []const f32, frame_count: i32, channel_count: i32) i32 {
        return self.vtable.mix(self.ptr, interleaved, frame_count, channel_count);
    }
};

// -----------------------------------------------------------------------
// PlaybackController — Godot-free per-stream playback state machine.
// -----------------------------------------------------------------------
pub const PlaybackController = struct {
    allocator: std.mem.Allocator = undefined,

    stream_: ?StreamHandle = null,
    scrubber_: Scrubber = .{},
    clock_: ?ClockBridge = null,
    audio_ring_: ?AudioRing = null,

    // Scratch buffers kept as members to avoid per-call allocations on the
    // decode/mix path (resized only when a larger buffer is needed).
    mix_scratch_: std.ArrayList(f32) = .empty, // fill_audio()'s channel-mix scratch
    drive_scratch_: std.ArrayList(f32) = .empty, // drive_audio()'s ring-read scratch

    loaded_: bool = false,
    playing_: bool = false,
    paused_: bool = false,
    // Video EOS is tracked by the shared scheduler (atEnd()), so this only
    // tracks audio EOS for the end-of-playback condition.
    audio_eos_: bool = false,
    has_audio_: bool = false, // clip carries an audio track -> audio is master
    audio_track_count_: i32 = 0, // cached from the backend at load time
    length_: f64 = 0.0,
    position_: f64 = 0.0, // PTS of the most recently presented frame

    width_: i32 = 0,
    height_: i32 = 0,
    color_: Colorimetry = .{},

    // See canonical_mix_format. canonical_sample_rate_ is the FIRST
    // audio-bearing track's rate, NOT shared across tracks.
    canonical_channels_: i32 = 0,
    canonical_sample_rate_: i32 = 0,

    // --- Audio track reconcile state ---
    //
    // desired_track_ and live_track_ converge by construction via
    // reconcileAudioTrack(): desired_track_ is what the caller asked for (via
    // requestAudioTrack()), live_track_ is what the backend is actually
    // decoding. They can disagree only between a request and the next
    // reconcile; a failed reselect rolls desired_track_ back to live_track_
    // instead of leaving the two permanently out of sync.
    desired_track_: i32 = 0,
    live_track_: i32 = 0,

    // True between a mid-stream reselect and the first audio chunk from the new
    // track. During this window the ClockBridge is in monotonic-master mode so
    // video keeps advancing while audio is silent.
    switch_in_progress_: bool = false,

    // Per-track audio metadata cached at load time for sample-rate validation
    // during mid-stream track switches.
    track_infos_: std.ArrayList(AudioTrackInfo) = .empty,

    warnings_: std.ArrayList([]const u8) = .empty,

    pub fn init() PlaybackController {
        return .{};
    }

    /// Frees the controller's owned resources. Runs shutdown() first (matching
    /// the C++ destructor). Safe to call once after any (or no) load().
    pub fn deinit(self: *PlaybackController) void {
        self.shutdown();
        if (self.audio_ring_) |*r| r.deinit();
        self.audio_ring_ = null;
        self.mix_scratch_.deinit(self.allocator);
        self.drive_scratch_.deinit(self.allocator);
        self.track_infos_.deinit(self.allocator);
        for (self.warnings_.items) |w| self.allocator.free(w);
        self.warnings_.deinit(self.allocator);
    }

    fn warn(self: *PlaybackController, message: []const u8) void {
        // Takes ownership of the allocated `message`.
        self.warnings_.append(self.allocator, message) catch self.allocator.free(message);
    }

    fn warnFmt(self: *PlaybackController, comptime fmt: []const u8, args: anytype) void {
        const message = std.fmt.allocPrint(self.allocator, fmt, args) catch return;
        self.warn(message);
    }

    /// Drains warnings queued since the last call, transferring ownership of the
    /// strings to the caller. The caller must free each string and deinit() the
    /// returned list with the same allocator load() was given.
    pub fn takeWarnings(self: *PlaybackController) std.ArrayList([]const u8) {
        const out = self.warnings_;
        self.warnings_ = .empty;
        return out;
    }

    /// Unregisters from the scheduler, blocking until any in-flight decode slice
    /// completes (no use-after-free). Safe to call multiple times.
    pub fn shutdown(self: *PlaybackController) void {
        if (self.stream_) |s| {
            DecodeScheduler.instance().unregisterStream(s);
            self.stream_ = null;
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
        self.color_ = backend.colorimetry();
        self.length_ = backend.durationSeconds();
        self.width_ = backend.videoWidth();
        self.height_ = backend.videoHeight();
        self.audio_track_count_ = backend.audioTrackCount();

        // --- Canonical Mix Format ---
        // Derived pure from the backend's audio tracks (no scheduler, no clock).
        // Done before the backend moves into the scheduler, which takes
        // ownership.
        var fmt = try canonical_mix_format.deriveCanonicalMixFormat(allocator, backend);
        self.canonical_channels_ = fmt.channels;
        self.canonical_sample_rate_ = fmt.sample_rate;
        self.has_audio_ = fmt.has_audio;
        // Move the per-track metadata and warning strings out of `fmt`.
        self.track_infos_.deinit(allocator);
        self.track_infos_ = fmt.track_infos;
        fmt.track_infos = .empty;
        for (fmt.warnings.items) |w| self.warn(w);
        fmt.warnings.deinit(allocator); // strings transferred; free the outer array only

        // Hand the Backend to the process-wide shared decode pool. From here a
        // pool worker decodes video ahead into stream_'s queue; this object
        // never touches the Backend directly except via the scheduler
        // (nextFrame / withBackend).
        self.stream_ = try DecodeScheduler.instance().registerStream(backend);

        if (self.has_audio_) {
            // Audio-master: latency-compensated so mediaTime() reflects what the
            // speaker is emitting, not what was just queued.
            const audio = AudioMasterClock.init(self.canonical_sample_rate_, audio_output_latency_seconds);
            const mono = MonotonicClock.init(0.0);
            self.clock_ = ClockBridge.init(audio, mono, true);
            const ring_frames: usize = @as(usize, @intCast(self.canonical_sample_rate_)) / 2; // ~0.5 s
            self.audio_ring_ = try AudioRing.init(allocator, self.canonical_channels_, ring_frames);
        } else {
            // Silent clip: a null audio clock makes the bridge permanently
            // monotonic-master, so every audio-facing ClockBridge method is a
            // safe no-op.
            const mono = MonotonicClock.init(0.0);
            self.clock_ = ClockBridge.init(null, mono, false);
        }

        self.loaded_ = true;
        self.position_ = 0.0;
        self.audio_eos_ = false;
        self.switch_in_progress_ = false;

        // A pre-load requestAudioTrack() selection must survive, not be
        // clobbered; validate it now that audio_track_count_ is known.
        if (self.audio_track_count_ > 0 and
            (self.desired_track_ < 0 or self.desired_track_ >= self.audio_track_count_))
        {
            self.warnFmt(
                "Audio track index {d} is out of range. Clip has {d} track(s). Falling back to default (0).",
                .{ self.desired_track_, self.audio_track_count_ },
            );
            self.desired_track_ = 0;
        }
        self.live_track_ = 0;
        // Cheap-applies any pre-load selection (we are not yet playing_).
        self.reconcileAudioTrack();
    }

    pub fn isLoaded(self: *const PlaybackController) bool {
        return self.loaded_;
    }
    pub fn length(self: *const PlaybackController) f64 {
        return self.length_;
    }
    pub fn width(self: *const PlaybackController) i32 {
        return self.width_;
    }
    pub fn height(self: *const PlaybackController) i32 {
        return self.height_;
    }
    pub fn colorimetry(self: *const PlaybackController) Colorimetry {
        return self.color_;
    }

    // Canonical Mix Format, stable for the playback's lifetime once load()
    // returns.
    pub fn canonicalChannels(self: *const PlaybackController) i32 {
        return self.canonical_channels_;
    }
    pub fn canonicalSampleRate(self: *const PlaybackController) i32 {
        return self.canonical_sample_rate_;
    }

    // --- Transport ---

    pub fn play(self: *PlaybackController, now: WallClockMs) void {
        if (!self.loaded_) return;
        const was_playing = self.playing_;
        self.playing_ = true;
        self.paused_ = false;
        if (self.master()) |c| c.setPaused(false);
        // Resuming after a scrub: force an exact resolve at the last scrub target
        // so play starts from the precise frame, not an approximate keyframe one.
        if (!was_playing and self.stream_ != null) {
            self.applyScrubResolve(self.scrubber_.onResume(now.ms));
        }
    }

    pub fn stop(self: *PlaybackController) void {
        self.playing_ = false;
        self.paused_ = false;
        self.audio_eos_ = false;
        self.position_ = 0.0;
        if (self.master()) |c| c.setTime(0.0);
        if (self.audio_ring_) |*r| r.clear();
        // Flush + reseek to start (serialized against the worker).
        if (self.stream_) |s| DecodeScheduler.instance().requestSeek(s, 0.0);
        self.scrubber_ = Scrubber.init(self.scrubber_.config); // no stale velocity/settle
        self.switch_in_progress_ = false;
        // Track selection persists across stop (desired_/live_track_ are NOT
        // reset here). If the caller stopped mid-switch, re-anchor so the bridge
        // does not stay monotonic-master forever with no fill_audio() to
        // re-anchor it.
        if (self.has_audio_) {
            if (self.clock_) |*c| c.reanchorToAudio();
        }
    }

    pub fn setPaused(self: *PlaybackController, paused: bool) void {
        self.paused_ = paused;
        if (self.master()) |c| c.setPaused(paused);
    }

    pub fn isPlaying(self: *const PlaybackController) bool {
        return self.playing_;
    }
    pub fn isPaused(self: *const PlaybackController) bool {
        return self.paused_;
    }
    pub fn position(self: *const PlaybackController) f64 {
        return self.position_;
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
        if (self.stream_ == null or self.master() == null) return;
        var t = time_seconds;
        if (t < 0.0) t = 0.0;
        const resolve = self.scrubber_.onSeek(t, now.ms);
        self.applyScrubResolve(resolve);
    }

    // Refuses a mid-stream switch to a track whose sample rate differs from the
    // canonical rate (the mix format is fixed for the lifetime); applies
    // immediately when stopped/pre-load, otherwise defers to the next tick().
    pub fn requestAudioTrack(self: *PlaybackController, idx_in: i32) void {
        var idx = idx_in;
        if (self.audio_track_count_ > 0 and (idx < 0 or idx >= self.audio_track_count_)) {
            self.warnFmt(
                "Audio track index {d} is out of range. Clip has {d} track(s). Falling back to default (0).",
                .{ idx, self.audio_track_count_ },
            );
            idx = 0;
        }

        if (idx == self.desired_track_) return;

        // The canonical mix format and AudioMasterClock are fixed to the clip's
        // canonical rate and cannot change mid-stream, so a mid-stream switch to
        // a differing-rate track is refused outright (stopped/pre-play has no
        // live audio path yet, so it is allowed).
        if (self.playing_ and self.has_audio_ and idx >= 0 and
            @as(usize, @intCast(idx)) < self.track_infos_.items.len and
            self.track_infos_.items[@intCast(idx)].sample_rate != self.canonical_sample_rate_)
        {
            self.warnFmt(
                "Cannot switch to audio track {d}: sample rate {d} Hz differs from the canonical rate {d} Hz. Rejecting switch.",
                .{ idx, self.track_infos_.items[@intCast(idx)].sample_rate, self.canonical_sample_rate_ },
            );
            return;
        }

        self.desired_track_ = idx;

        // Stopped/pre-play applies immediately; playing/paused defers to the next
        // tick() (which runs while paused).
        if (!self.playing_) self.reconcileAudioTrack();
    }

    pub fn desiredAudioTrack(self: *const PlaybackController) i32 {
        return self.desired_track_;
    }
    pub fn liveAudioTrack(self: *const PlaybackController) i32 {
        return self.live_track_;
    }

    // Returns the frame to present this tick (BY VALUE), or null when not loaded
    // / not playing / paused. The caller owns the GPU present and the frame's
    // release().
    pub fn tick(self: *PlaybackController, delta_seconds: f64, now: WallClockMs, sink: MixSink) ?VideoFrame {
        const clock = self.master();
        if (!self.loaded_ or clock == null or self.stream_ == null) return null;
        const c = clock.?;

        // Settle check runs regardless of play/pause: scrubbing commonly happens
        // while paused (dragging a timeline). Once a fast drag has gone quiet for
        // the debounce window, upgrade the approximate keyframe frame to the
        // exact target frame.
        if (self.scrubber_.poll(now.ms)) |settle| {
            self.applyScrubResolve(settle);
        }

        // Reconcile any pending track switch. Runs even while paused so a switch
        // requested mid-pause (or during a scrub) is picked up promptly.
        self.reconcileAudioTrack();

        if (!self.playing_ or self.paused_) return null;
        const sched = DecodeScheduler.instance();

        // No-op when audio-master; keeps video advancing through
        // monotonic-master silence (silent clip, or the handoff window during a
        // track switch).
        c.advance(delta_seconds);

        // One clock rule: advance from real audio samples when any exist; once no
        // more can ever come (a shorter audio track fully drained — legitimate in
        // real-world files), advance by the render delta instead. Extracted into
        // advanceMasterClock() so the rule is a single named concept a future
        // edit can't silently break by reordering the ifs.
        var advanced_from_audio = false;
        if (self.has_audio_) {
            self.fillAudio();
            advanced_from_audio = self.driveAudio(sink);
        }
        self.advanceMasterClock(delta_seconds, advanced_from_audio);
        const media_now = c.mediaTime();

        // --- Present step: drop-late / hold-early, via the Godot-free selector.
        // Peek head/next PTS non-destructively (frame order is never disturbed):
        //   * Drop  — head stale: pop+release, loop.
        //   * Show  — head is the due frame for `media_now`: pop and present it.
        //   * Hold  — head in the future: present nothing new.
        const frame_interval = 1.0 / 30.0; // nominal; refined when fps is known
        var chosen: ?VideoFrame = null;

        while (true) {
            const head_pts = sched.peekHeadPts(self.stream_.?);
            if (head_pts == null) break; // queue empty -> hold the current frame
            const next_pts = sched.peekNextPts(self.stream_.?);

            const action = present_selector.selectPresentAction(head_pts, next_pts, media_now, frame_interval);

            if (action == .drop) {
                if (sched.nextFrame(self.stream_.?)) |stale| stale.release();
                continue;
            }

            if (action == .show) {
                chosen = sched.nextFrame(self.stream_.?);
            }

            // Show or Hold both end the present scan for this tick.
            break;
        }

        if (chosen) |ch| self.position_ = ch.pts_seconds;

        // End-of-playback: video EOS (atEnd() is worker-reported) and audio drained.
        if (sched.atEnd(self.stream_.?) and self.audioExhausted()) {
            self.playing_ = false;
        }

        return chosen;
    }

    // ------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------

    fn master(self: *PlaybackController) ?*ClockBridge {
        if (self.clock_) |*c| return c;
        return null;
    }

    fn audioExhausted(self: *PlaybackController) bool {
        // True when no real audio samples will ever advance the clock again:
        // silent clips, and a shorter audio track once it has fully drained.
        if (!self.has_audio_) return true;
        if (self.audio_eos_) {
            if (self.audio_ring_) |*r| return r.empty();
        }
        return false;
    }

    // advanceMasterClock — the one-clock rule: advance the master clock by
    // exactly one source per tick, never two. When audio is present and drove
    // the clock (`advanced_from_audio`), that is the one advance. When audio is
    // master but exhausted (no more real samples will ever come — a shorter
    // audio track fully drained, a legitimate real-world case), fall back to the
    // render delta. The gates prevent double-advance: the `!advanced_from_audio`
    // gate keeps the last partial ring drain from stacking real frames + delta;
    // the `isAudioMaster()` gate keeps this from stacking on top of the bridge
    // advance() while in monotonic-master mode. Reordering these conditions would
    // silently break A/V sync — the three "one-clock rule" tests pin the
    // behavior.
    fn advanceMasterClock(self: *PlaybackController, delta_seconds: f64, advanced_from_audio: bool) void {
        const c = self.master() orelse return;
        if (!c.isAudioMaster() or advanced_from_audio) return;
        if (!self.audioExhausted()) return;
        c.setTime(c.mediaTime() + delta_seconds);
    }

    fn fillAudio(self: *PlaybackController) void {
        if (self.stream_ == null or self.audio_ring_ == null or self.audio_eos_) return;
        // Pump under the scheduler's per-stream exclusion so we never race the
        // worker decoding video ahead on the same Backend.
        DecodeScheduler.instance().withBackend(self.stream_.?, self, fillAudioClosure);
    }

    fn fillAudioClosure(p: *anyopaque, backend: *Backend) void {
        const self: *PlaybackController = @ptrCast(@alignCast(p));
        var ring = &self.audio_ring_.?;
        // Half-fill: cushion against decode jitter without buffering unbounded
        // audio.
        while (ring.freeFrames() > ring.availableFrames()) {
            const chunk = backend.nextAudioChunk() orelse {
                // EOS. If a switch is still in progress, we simply never
                // re-anchor: the bridge stays monotonic-master and tick()'s
                // clock->advance() keeps video moving through what is now a
                // permanent gap.
                self.audio_eos_ = true;
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
            if (self.switch_in_progress_) {
                self.clock_.?.reanchorToAudio();
                self.switch_in_progress_ = false;
            }
            // Mix native layout -> canonical (no-op memcpy when counts match).
            const nf = chunk.frame_count;
            const sc = chunk.channel_count;
            const dc = self.canonical_channels_;
            const needed: usize = @as(usize, @intCast(nf)) * @as(usize, @intCast(dc));
            if (self.mix_scratch_.items.len < needed) {
                self.mix_scratch_.resize(self.allocator, needed) catch return;
            }
            channel_mixer.mixChannels(chunk.samples, sc, self.mix_scratch_.items[0..needed], dc, nf);
            _ = ring.write(self.mix_scratch_.items[0..needed], @intCast(nf));
        }
    }

    fn driveAudio(self: *PlaybackController, sink: MixSink) bool {
        if (self.audio_ring_ == null or self.clock_ == null or self.canonical_channels_ <= 0) return false;

        const kMaxMixFramesPerTick: i32 = 4096; // ~85 ms @ 48k

        const ch = self.canonical_channels_;
        var ring = &self.audio_ring_.?;
        const available = ring.availableFrames();
        // On underrun, offer a small block of silence so the sink keeps its
        // buffer fed; the clock is NOT advanced for silence (readFrames reports 0
        // real frames).
        const request_base: usize = if (available > 0) available else 256;
        const request: i32 = @intCast(@min(request_base, @as(usize, @intCast(kMaxMixFramesPerTick))));

        const needed: usize = @as(usize, @intCast(request)) * @as(usize, @intCast(ch));
        if (self.drive_scratch_.items.len < needed) {
            self.drive_scratch_.resize(self.allocator, needed) catch return false;
        }

        // Drain decoded PCM (or silence on underrun) into the staging buffer.
        const real_frames = ring.readFrames(self.drive_scratch_.items[0..needed], @intCast(request));

        // Advance the clock ONLY by frames both real (non-silence) AND consumed —
        // neither underrun silence nor a full downstream buffer inflates media
        // time. If the sink accepts fewer than `real_frames` (near-full
        // downstream buffer), the surplus is dropped: the clock stays honest at
        // the cost of a little lost audio. Tolerable for linear playback.
        const accepted = sink.mix(self.drive_scratch_.items[0..needed], request, ch);
        const advance = @min(accepted, @as(i32, @intCast(real_frames)));
        if (advance > 0) self.clock_.?.onAudioMixed(advance);
        return advance > 0;
    }

    fn applyScrubResolve(self: *PlaybackController, resolve: ScrubResolve) void {
        const c = self.master() orelse return;
        if (self.stream_ == null) return;
        const target = if (resolve.target_seconds < 0.0) 0.0 else resolve.target_seconds;

        if (self.audio_ring_) |*r| r.clear(); // stale audio must not play after a (re)seek
        const sched = DecodeScheduler.instance();

        // Both modes start by flushing the decode-ahead queue and reseeking the
        // Backend to the preceding keyframe through the scheduler (serialized
        // against the worker; no race / no UAF).
        sched.requestSeek(self.stream_.?, target);

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
                const head = sched.peekHeadPts(self.stream_.?);
                if (head == null) {
                    if (sched.atEnd(self.stream_.?)) break; // EOS before the target — clamp.
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
                if (sched.nextFrame(self.stream_.?)) |stale| stale.release();
            }
        }

        c.setTime(target); // re-anchor the master clock to the resolved target
        self.position_ = target;
        self.audio_eos_ = false;

        // Reconcile any pending track switch at the resolved position (position_
        // == target here) so a new selection is primed at the correct spot.
        self.reconcileAudioTrack();
    }

    fn reconcileAudioTrack(self: *PlaybackController) void {
        if (self.desired_track_ == self.live_track_ or self.stream_ == null) return;
        const sched = DecodeScheduler.instance();

        if (!self.playing_) {
            // Stopped / pre-play: cheap apply. Deferred in the backend until its
            // next seek — which play()'s scrub-resume resolve always issues first.
            var ctx = SelectCtx{ .target = self.desired_track_ };
            sched.withBackend(self.stream_.?, &ctx, SelectCtx.run);
            self.live_track_ = self.desired_track_;
            return;
        }

        // Playing (or paused — reselecting now primes the new reader at position_
        // so resume is instant).
        if (self.clock_ == null or self.audio_ring_ == null) return;

        self.clock_.?.handoffToMonotonic(); // no-op if already monotonic
        self.switch_in_progress_ = true;

        const target = self.desired_track_;
        const prime_seconds = self.position_;

        // Reselect under the scheduler's per-stream exclusion. Tears down and
        // rebuilds ONLY the audio decode path; the FrameQueue still has buffered
        // frames so presenting is uninterrupted.
        var ctx = ReselectCtx{ .target = target, .prime = prime_seconds };
        sched.withBackend(self.stream_.?, &ctx, ReselectCtx.run);

        if (!ctx.ok) {
            // The Backend contract leaves the audio decode path undefined on
            // failure, so the old track is not safely playable. Roll desired back
            // to what is still live and force a seek to recover.
            self.desired_track_ = self.live_track_;
            self.switch_in_progress_ = false;
            self.clock_.?.reanchorToAudio();
            self.warnFmt("Audio track switch to {d} failed; recovering via seek.", .{target});
            sched.requestSeek(self.stream_.?, self.position_);
            return;
        }

        // Clear stale samples; fillAudio() re-anchors when the new track flows.
        self.live_track_ = self.desired_track_;
        self.audio_ring_.?.clear();
        self.audio_eos_ = false;
    }

    const SelectCtx = struct {
        target: i32,
        fn run(p: *anyopaque, backend: *Backend) void {
            const ctx: *SelectCtx = @ptrCast(@alignCast(p));
            backend.selectAudioTrack(ctx.target);
        }
    };

    const ReselectCtx = struct {
        target: i32,
        prime: f64,
        ok: bool = false,
        fn run(p: *anyopaque, backend: *Backend) void {
            const ctx: *ReselectCtx = @ptrCast(@alignCast(p));
            ctx.ok = backend.reselectAudioTrack(ctx.target, ctx.prime);
        }
    };
};

test {
    _ = @import("playback_controller_test.zig");
}
