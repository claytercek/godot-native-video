//! Dedicated COM multi-threaded apartment (MTA) for the MF backend.
//!
//! Godot's D3D12 main thread is an STA: CoInitializeEx(MTA) fails there with
//! RPC_E_CHANGED_MODE, and source-reader creation fails intermittently. This
//! executor creates its own thread, pairing CoInitializeEx(COINIT_MULTITHREADED)
//! and CoUninitialize on that thread. run() dispatches a job and blocks for it.
//!
//! The thread lives from open() to close(), anchoring the process MTA while
//! scheduler workers call ReadSample. A synchronous MF source reader created
//! in that MTA has no single-thread affinity.
//!
//! Callers must serialize start()/run()/stop(); only one job may be in flight.
//! MfBackend opens before scheduler registration and closes after all decode
//! slices finish.

const std = @import("std");

const com = @import("win.zig").com;
const sys_clock = @import("core").sys_clock;

const log = std.log.scoped(.mf_com);

pub const JobFn = *const fn (*anyopaque) void;

pub const ComExecutor = struct {
    thread: ?std.Thread = null,

    mu: sys_clock.Mutex = .{},
    ready_cv: sys_clock.Condition = .{}, // thread -> start(): apartment initialised
    job_cv: sys_clock.Condition = .{}, // run()/stop() -> thread: work posted
    done_cv: sys_clock.Condition = .{}, // thread -> run(): job finished

    // Handshake state, all guarded by mu.
    ready: bool = false, // thread reached the CoInitializeEx result
    init_ok: bool = false, // that result was success (apartment is MTA)
    stopping: bool = false, // stop() asked the thread to exit
    pending: ?JobFn = null, // a job the thread has not yet consumed
    ctx: *anyopaque = undefined,
    done: bool = false, // the consumed job has returned

    /// Spawn the thread and wait for MTA initialization. Return error.ComInit
    /// on spawn or initialization failure. No-op if already running.
    pub fn start(self: *ComExecutor) error{ComInit}!void {
        if (self.thread != null) return;
        self.ready = false;
        self.init_ok = false;
        self.stopping = false;
        self.pending = null;
        self.done = false;

        self.thread = std.Thread.spawn(.{}, threadMain, .{self}) catch |e| {
            log.err("ComExecutor: thread spawn failed: {s}", .{@errorName(e)});
            return error.ComInit;
        };

        self.mu.lock();
        while (!self.ready) self.ready_cv.wait(&self.mu);
        const ok = self.init_ok;
        self.mu.unlock();

        if (!ok) {
            // The thread returned without entering the MTA (and without an
            // apartment to uninitialise); reap it and report failure.
            self.thread.?.join();
            self.thread = null;
            return error.ComInit;
        }
    }

    /// Run `func(ctx)` on the apartment thread and block until it returns.
    /// Requires start() to have succeeded. Not for concurrent callers (see the
    /// module concurrency contract).
    pub fn run(self: *ComExecutor, func: JobFn, ctx: *anyopaque) void {
        std.debug.assert(self.thread != null);
        self.mu.lock();
        self.pending = func;
        self.ctx = ctx;
        self.done = false;
        self.job_cv.signal();
        while (!self.done) self.done_cv.wait(&self.mu);
        self.mu.unlock();
    }

    /// Ask the apartment thread to CoUninitialize and exit, then join it.
    /// Idempotent: a no-op when not running.
    pub fn stop(self: *ComExecutor) void {
        if (self.thread == null) return;
        self.mu.lock();
        self.stopping = true;
        self.job_cv.signal();
        self.mu.unlock();
        self.thread.?.join();
        self.thread = null;
    }

    pub fn isRunning(self: *const ComExecutor) bool {
        return self.thread != null;
    }

    fn threadMain(self: *ComExecutor) void {
        const hr = com.CoInitializeEx(null, com.COINIT_MULTITHREADED);
        const ok = com.SUCCEEDED(hr) or hr == com.S_FALSE;

        if (!ok) {
            // A freshly spawned thread has no prior apartment, so this should be
            // unreachable; kept for genuinely unexpected cases (e.g. a hostile
            // in-proc COM hook forcing STA). Do NOT pair with CoUninitialize.
            if (hr == com.RPC_E_CHANGED_MODE) {
                log.warn("ComExecutor: thread already in an incompatible COM apartment (RPC_E_CHANGED_MODE)", .{});
            } else {
                log.warn("ComExecutor: CoInitializeEx(MTA) failed: 0x{x:0>8}", .{@as(u32, @bitCast(hr))});
            }
        }

        self.mu.lock();
        self.init_ok = ok;
        self.ready = true;
        self.ready_cv.signal();
        if (!ok) {
            self.mu.unlock();
            return;
        }

        while (true) {
            while (self.pending == null and !self.stopping) self.job_cv.wait(&self.mu);
            if (self.pending) |f| {
                const c = self.ctx;
                self.pending = null; // consume before running so it never re-runs
                self.mu.unlock();
                f(c);
                self.mu.lock();
                self.done = true;
                self.done_cv.signal();
                continue;
            }
            // No pending job and stopping requested.
            break;
        }
        self.mu.unlock();

        com.CoUninitialize();
    }
};

// ---------------------------------------------------------------------------
// Tests. Pure COM-apartment checks — no GPU or media, so they run on CI too.
// ---------------------------------------------------------------------------
const testing = std.testing;
const builtin = @import("builtin");

test "ComExecutor runs jobs on a dedicated MTA thread" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var ex: ComExecutor = .{};
    try ex.start();
    defer ex.stop();

    const Probe = struct {
        caller_id: std.Thread.Id,
        job_id: std.Thread.Id = 0,
        apt: com.APTTYPE = com.APTTYPE_CURRENT,
        hr: com.HRESULT = 0,

        fn run(p: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(p));
            self.job_id = std.Thread.getCurrentId();
            var qualifier: com.APTTYPEQUALIFIER = 0;
            self.hr = com.CoGetApartmentType(&self.apt, &qualifier);
        }
    };

    var probe = Probe{ .caller_id = std.Thread.getCurrentId() };
    ex.run(Probe.run, &probe);

    // The job ran off the calling thread, in a Multi-Threaded Apartment.
    try testing.expect(probe.job_id != probe.caller_id);
    try testing.expect(com.SUCCEEDED(probe.hr));
    try testing.expectEqual(com.APTTYPE_MTA, probe.apt);
}

test "ComExecutor run marshals each job exactly once and in order" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var ex: ComExecutor = .{};
    try ex.start();
    defer ex.stop();

    const Counter = struct {
        n: u32 = 0,
        fn bump(p: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(p));
            self.n += 1;
        }
    };
    var counter = Counter{};
    var i: u32 = 0;
    while (i < 5) : (i += 1) ex.run(Counter.bump, &counter);
    try testing.expectEqual(@as(u32, 5), counter.n);
}
