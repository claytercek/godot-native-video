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
//! (The DecodeStream and its Backend are owned by the injected
//! DecodeScheduler, which uses its own allocator; see decode_scheduler.zig.)

const std = @import("std");

const log = std.log.scoped(.playback_controller);

const backend_mod = @import("backend.zig");
const clock_mod = @import("clock.zig");
const audio_ring_mod = @import("audio_ring.zig");
const audio_telemetry_mod = @import("audio_telemetry.zig");
const scrubber_mod = @import("scrubber.zig");
const wall_clock_mod = @import("wall_clock.zig");
const decode_scheduler = @import("decode_scheduler.zig");
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
const AudioTelemetry = audio_telemetry_mod.AudioTelemetry;
const Scrubber = scrubber_mod.Scrubber;
const ScrubResolve = scrubber_mod.ScrubResolve;
const ResolveMode = scrubber_mod.ResolveMode;
const WallClockMs = wall_clock_mod.WallClockMs;
const DecodeScheduler = decode_scheduler.DecodeScheduler;
const StreamHandle = decode_scheduler.StreamHandle;

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
// AudioTrackSwitch — the clock-mastership half of a mid-stream audio-track
// switch, as an explicit little state machine.
//
// A switch runs idle -> handing-off -> live (with a recovering-on-failure
// edge back to live). The transitions that used to be smeared across load(),
// stop(), reconcileAudioTrack() and the audio-decode inner loop live here.
//
// This struct owns exactly ONE piece of state: `in_progress` — true from the
// moment a live reselect puts the ClockBridge into monotonic-master (so video
// keeps advancing while the new track is still silent) until the first chunk
// of the NEW track flows and re-anchors the clock back to audio-master. The
// caller keeps `desired_track`/`live_track` (which track is wanted vs. live)
// as its own caller-readable state; every clock handoff/re-anchor tied to a
// switch runs through the methods below so the mastership timing is defined in
// one place, not four.
// -----------------------------------------------------------------------
const AudioTrackSwitch = struct {
    in_progress: bool = false,

    /// A live reselect is starting: hand the clock to monotonic-master so
    /// video keeps advancing through the coming audio silence, and mark the
    /// switch in progress. handoffToMonotonic() is a no-op if already
    /// monotonic (e.g. a second request arrives mid-handoff).
    fn begin(self: *AudioTrackSwitch, clock: *ClockBridge) void {
        clock.handoffToMonotonic();
        self.in_progress = true;
    }

    /// The completing edge, called from the audio-decode loop for every chunk.
    /// reconcile cleared the ring before handing off, so the FIRST chunk to
    /// reach the decode loop (genuinely decoded, not merely attempted) is from
    /// the new track: re-anchor the audio clock to the current monotonic
    /// position so mediaTime() stays continuous, and end the handoff. A no-op
    /// once the switch has completed — the common per-chunk case.
    fn onFirstChunk(self: *AudioTrackSwitch, clock: *ClockBridge) void {
        if (!self.in_progress) return;
        clock.reanchorToAudio();
        self.in_progress = false;
    }

    /// The reselect failed: the Backend leaves the audio decode path undefined,
    /// so end the handoff and re-anchor to audio. The caller rolls its own
    /// desired track back to what is still live and seeks to recover.
    fn rollback(self: *AudioTrackSwitch, clock: *ClockBridge) void {
        self.in_progress = false;
        clock.reanchorToAudio();
    }

    /// Cancel a possibly half-complete switch (stop): end the handoff and make
    /// sure the bridge is audio-master again so it does not stay
    /// monotonic-master forever with no fillAudio() left to re-anchor it.
    /// `clock` is optional (unloaded controller) and reanchorToAudio() is
    /// itself a no-op on a silent clip's null audio clock, so this is safe to
    /// call unconditionally.
    fn cancel(self: *AudioTrackSwitch, clock: ?*ClockBridge) void {
        self.in_progress = false;
        if (clock) |c| c.reanchorToAudio();
    }
};

// -----------------------------------------------------------------------
// PlaybackController — Godot-free per-stream playback state machine.
// -----------------------------------------------------------------------
pub const PlaybackController = struct {
    allocator: std.mem.Allocator = undefined,

    // The decode pool this controller registers its stream with. Injected at
    // load(); valid whenever `stream` is non-null.
    sched: *DecodeScheduler = undefined,
    stream: ?StreamHandle = null,
    scrubber: Scrubber = .{},
    clock: ?ClockBridge = null,
    audio_ring: ?AudioRing = null,
    audio_telemetry: AudioTelemetry = .{},
    // Wall-clock timestamp of the most recent tick(), cached so stop()/
    // shutdown() (which don't take `now`) can still fire a final telemetry
    // report with a real wall-time reading.
    last_tick_wall_ms: WallClockMs = .{},

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

    // The clock-mastership half of a switch (the monotonic-master handoff
    // window and its re-anchor timing). Owns `in_progress`; the controller
    // drives it via begin/onFirstChunk/rollback/cancel rather than poking a
    // bare bool from four different methods.
    track_switch: AudioTrackSwitch = .{},

    // Per-track audio metadata cached at load time for sample-rate validation
    // during mid-stream track switches.
    track_infos: std.ArrayList(AudioTrackInfo) = .empty,

    // One-shot: whether the first-consumed-chunk-vs-canonical divergence
    // check (see checkAudioChunkDivergence) has run for the current load().
    // Diagnostic only; reset in load() so a reopen checks again.
    checked_first_audio_chunk: bool = false,

    warnings: std.ArrayList([]const u8) = .empty,

    pub fn init() PlaybackController {
        return .{};
    }

    /// Frees the controller's owned resources. Runs shutdown() first so no
    /// in-flight decode slice touches state being freed. Safe to call once
    /// after any (or no) load().
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
        // Safety net: reportFinal() is idempotent, so this is a no-op when
        // stop() or an EOS tick already reported (the common case) and only
        // fires for real on a close/unload that skipped both.
        self.audio_telemetry.reportFinal(self.last_tick_wall_ms, self.mediaTime());
        if (self.stream) |s| {
            self.sched.unregisterStream(s);
            self.stream = null;
        }
    }

    /// Takes ownership of an already-open()'d backend, derives the Canonical Mix
    /// Format, builds the master clock, and registers with the given
    /// DecodeScheduler. A pre-load requestAudioTrack() selection is validated and
    /// applied here.
    pub fn load(
        self: *PlaybackController,
        allocator: std.mem.Allocator,
        sched: *DecodeScheduler,
        backend: Backend,
        audio_output_latency_seconds: f64,
    ) !void {
        self.allocator = allocator;
        self.sched = sched;

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

        // Hand the Backend to the shared decode pool. From here a pool worker
        // decodes video ahead into stream's queue; this object never touches
        // the Backend directly except via the scheduler (nextFrame /
        // withBackend).
        self.stream = try sched.registerStream(backend);

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
        self.track_switch = .{};
        self.checked_first_audio_chunk = false;
        self.audio_telemetry.reset();

        // A pre-load requestAudioTrack() selection must survive, not be
        // clobbered; validate it now that audio_track_count is known.
        self.desired_track = self.clampTrackIndex(self.desired_track);
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
        self.audio_telemetry.reportFinal(self.last_tick_wall_ms, self.mediaTime());
        self.playing = false;
        self.paused = false;
        self.audio_eos = false;
        self.position = 0.0;
        if (self.master()) |c| c.setTime(0.0);
        if (self.audio_ring) |*r| r.clear();
        // Flush + reseek to start (serialized against the worker).
        if (self.stream) |s| self.sched.requestSeek(s, 0.0);
        self.scrubber = Scrubber.init(self.scrubber.config); // no stale velocity/settle
        // Track selection persists across stop (desired_/live_track are NOT
        // reset here). Cancel any half-complete switch: end the handoff and
        // re-anchor so the bridge does not stay monotonic-master forever with no
        // fillAudio() left to re-anchor it.
        self.track_switch.cancel(self.master());
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
        const idx = self.clampTrackIndex(idx_in);
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
        self.last_tick_wall_ms = now; // cached for stop()/shutdown()'s final telemetry report

        // Settle check runs regardless of play/pause: scrubbing commonly happens
        // while paused (dragging a timeline).
        self.settleScrub(now);

        // Reconcile any pending track switch. Runs even while paused so a switch
        // requested mid-pause (or during a scrub) is picked up promptly.
        self.reconcileAudioTrack();

        if (!self.playing or self.paused) return null;
        const sched = self.sched;

        const media_now = self.advanceClock(delta_seconds, now, sink, c);
        self.audio_telemetry.maybeReportPeriodic(now, media_now);
        const chosen = self.selectPresentFrame(sched, media_now);
        self.checkEndOfPlayback(sched, now, media_now);

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
    fn advanceClock(self: *PlaybackController, delta_seconds: f64, now: WallClockMs, sink: MixSink, c: *ClockBridge) f64 {
        if (c.isAudioMaster()) {
            self.fillAudio();
            const advanced_from_audio = self.driveAudio(now, sink);
            if (!advanced_from_audio and self.audioExhausted()) {
                c.setTime(c.mediaTime() + delta_seconds);
            }
        } else {
            c.advance(delta_seconds);
            if (self.has_audio) {
                self.fillAudio();
                _ = self.driveAudio(now, sink);
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
        // A deliberately fixed 30fps-nominal seconds-per-frame. The core tracks
        // no fps, and this value is never used AS a frame rate: the present
        // selector consumes it only as a half-interval "due" epsilon
        // (eps = frame_interval * 0.5). 30fps is the loosest common cadence, so
        // higher-fps content simply gets a slightly more generous tolerance —
        // acceptable, and cheaper than plumbing real fps down here.
        const frame_interval = 1.0 / 30.0;
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
    fn checkEndOfPlayback(self: *PlaybackController, sched: *DecodeScheduler, now: WallClockMs, media_now: f64) void {
        if (sched.atEnd(self.stream.?) and self.audioExhausted()) {
            // This branch runs exactly once per load() on the tick that observes
            // both conditions true (tick() no-ops on every subsequent call once
            // self.playing is false), so reportFinal's own idempotency guard is
            // a belt-and-suspenders, not load-bearing here.
            self.audio_telemetry.reportFinal(now, media_now);
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
        self.sched.withBackend(self.stream.?, self, fillAudioClosure);
    }

    // Diagnostic, one-shot per load(): compare the first AudioChunk actually
    // consumed against the Canonical Mix Format (canonical_mix_format.zig),
    // which is derived from the backend's DECLARED track metadata at load
    // time, not from what decode actually delivers. canonical_sample_rate
    // drives the AudioMasterClock, the ring's sizing, and Godot's
    // _getMixRate(); a mismatch here means audio plays at the wrong speed
    // regardless of which backend (or which layer within it) introduced the
    // divergence. Diagnostic only -- no behavior change.
    fn checkAudioChunkDivergence(self: *PlaybackController, chunk: backend_mod.AudioChunk) void {
        self.checked_first_audio_chunk = true;
        if (chunk.sample_rate != self.canonical_sample_rate or chunk.channel_count != self.canonical_channels) {
            log.warn(
                "first audio chunk diverges from canonical mix format -- canonical {d} Hz/{d} ch, chunk {d} Hz/{d} ch",
                .{ self.canonical_sample_rate, self.canonical_channels, chunk.sample_rate, chunk.channel_count },
            );
        }
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
            if (!self.checked_first_audio_chunk) self.checkAudioChunkDivergence(chunk);
            self.audio_telemetry.recordChunk(chunk.frame_count);
            if (chunk.samples.len == 0 or chunk.frame_count <= 0) continue;
            // Mid-stream track switch: the FSM re-anchors the clock the first
            // time a genuinely-new-track chunk reaches this point (a no-op on
            // every other chunk). The "why the first chunk is genuinely new"
            // reasoning lives in AudioTrackSwitch.onFirstChunk, not here.
            self.track_switch.onFirstChunk(&self.clock.?);
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

    fn driveAudio(self: *PlaybackController, now: WallClockMs, sink: MixSink) bool {
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
        self.audio_telemetry.recordMix(now, self.clock.?.mediaTime(), available, request, accepted);
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
        const sched = self.sched;

        if (resolve.mode == .exact) {
            // Settle/resume wants the precise frame: seek and decode forward
            // to the target synchronously on this thread (serialized against
            // the workers inside the scheduler). Precision over latency —
            // this never runs on the hot per-frame path.
            const eps = 1.0 / 120.0; // ~half a frame at 60fps tolerance
            sched.seekExact(self.stream.?, target, eps);
        } else {
            // Keyframe scrub: flush and reseek to the preceding keyframe;
            // whatever the backend yields first is the fast approximate frame.
            sched.requestSeek(self.stream.?, target);
        }

        c.setTime(target); // re-anchor the master clock to the resolved target
        self.position = target;
        self.audio_eos = false;

        // Reconcile any pending track switch at the resolved position (position
        // == target here) so a new selection is primed at the correct spot.
        self.reconcileAudioTrack();
    }

    // Range-check a requested audio-track index against the clip's track count,
    // warning and falling back to the default track (0) when out of range.
    // Shared by load() (validating a pre-load selection) and requestAudioTrack().
    fn clampTrackIndex(self: *PlaybackController, idx: i32) i32 {
        if (self.audio_track_count > 0 and (idx < 0 or idx >= self.audio_track_count)) {
            self.warnFmt(
                "Audio track index {d} is out of range. Clip has {d} track(s). Falling back to default (0).",
                .{ idx, self.audio_track_count },
            );
            return 0;
        }
        return idx;
    }

    fn reconcileAudioTrack(self: *PlaybackController) void {
        if (self.desired_track == self.live_track or self.stream == null) return;
        const sched = self.sched;

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
        const c = self.master().?;

        self.track_switch.begin(c); // handoff to monotonic-master + in-progress

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
            self.track_switch.rollback(c);
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
