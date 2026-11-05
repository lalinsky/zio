const std = @import("std");
const builtin = @import("builtin");
const Queue = @import("queue.zig").Queue;
const Completion = @import("completion.zig").Completion;
const Work = @import("completion.zig").Work;
const os = @import("../os/root.zig");
const Timeout = @import("../time.zig").Timeout;
const runtime = @import("../runtime.zig");

const log = @import("../common.zig").log;

pub const ThreadPool = struct {
    queue: Queue(Completion) = .{},
    queue_mutex: os.Mutex = .init(),
    queue_not_empty: os.Condition = .init(),
    /// Signaled when `running_threads` drops to zero, for `stop()`.
    all_done: os.Condition = .init(),
    queue_size: usize = 0,
    shutdown: bool = false,

    min_threads: usize,
    max_threads: usize,

    idle_timeout_ns: u64,

    /// Workers alive or being spawned, including those in `starting`. Workers
    /// are detached, so this count is the only record of them: a worker drops
    /// it as the very last thing it does with the pool, and `stop()` waits for
    /// it to reach zero. Only changed under `queue_mutex`; atomic so it can be
    /// observed without it.
    running_threads: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    /// Workers parked waiting for work. Only changed under `queue_mutex`; atomic
    /// so it can be observed without it.
    idle_threads: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    /// Workers counted in `running_threads` that have not yet taken
    /// `queue_mutex` for the first time. Each will take a queued job, so they
    /// count as available capacity. Guarded by `queue_mutex`.
    starting: usize = 0,

    /// Reserved jobs (see `Work.reserve_thread`) currently sitting in the queue,
    /// each still needing a worker to pick it up. Guarded by `queue_mutex`.
    reserved_pending: usize = 0,

    /// Reserved jobs currently occupying a worker (picked up, not yet finished).
    /// `max_threads` is the budget for *regular* work; reserved work is additive,
    /// so the effective ceiling for spawning is `max_threads + reserved_running`.
    /// Without this, reserved jobs would eat the regular budget and starve
    /// regular work once they occupy all `max_threads` workers. Atomic because it
    /// is decremented off the queue lock, on the running worker at completion.
    reserved_running: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    pub const Options = struct {
        min_threads: usize = 0,
        max_threads: ?usize = null,
        idle_timeout_ms: u64 = 60_000,
    };

    /// Default `max_threads`. Workers spend most of their time blocked in
    /// syscalls, so this is a guard against runaway thread creation, not a
    /// parallelism limit.
    pub const default_max_threads = 512;

    pub fn init(self: *ThreadPool, options: Options) !void {
        // A max_threads of 0 (explicit, or implied by a single-threaded build)
        // disables the pool: work is executed inline in submit().
        const max_threads = if (builtin.single_threaded)
            0
        else
            options.max_threads orelse default_max_threads;

        const min_threads = @min(options.min_threads, max_threads);

        self.* = .{
            .min_threads = min_threads,
            .max_threads = max_threads,
            .idle_timeout_ns = options.idle_timeout_ms * std.time.ns_per_ms,
        };
        errdefer self.deinit();

        // Install the process-global SIGURG handler used to interrupt cancelable
        // blocking syscalls. Refcounted; paired with deinit's uninstall.
        os.syscall_cancel.installHandler();

        for (0..min_threads) |_| {
            self.queue_mutex.lock();
            self.reserveSpawn();
            self.queue_mutex.unlock();
            self.spawnThread() catch |err| {
                self.cancelSpawn();
                return err;
            };
        }
    }

    /// Whether the jobs in the queue need another worker. Every queued job must
    /// have a worker to run it, either a parked one or one already starting, so
    /// none waits behind workers that may stay blocked indefinitely. A
    /// regular job only gets a new worker within the cap; reserved jobs are
    /// taken first and get one regardless. Called under `queue_mutex`.
    fn needsSpawn(self: *ThreadPool) bool {
        const available = self.idle_threads.load(.monotonic) + self.starting;
        if (available < self.reserved_pending) return true;
        // Ceiling is max_threads + reserved_running: reserved work is additive to
        // the regular budget, so regular work can still scale to max_threads even
        // when reserved jobs occupy workers.
        const ceiling = self.max_threads + self.reserved_running.load(.monotonic);
        return available < self.queue_size and self.running_threads.load(.monotonic) < ceiling;
    }

    /// Count a worker about to be spawned, so later spawn decisions see it.
    /// Called under `queue_mutex`.
    fn reserveSpawn(self: *ThreadPool) void {
        _ = self.running_threads.fetchAdd(1, .monotonic);
        self.starting += 1;
    }

    /// Undo `reserveSpawn` when the thread could not be spawned. A job left
    /// without a worker is retried by the next submit's spawn decision.
    fn cancelSpawn(self: *ThreadPool) void {
        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();
        self.starting -= 1;
        self.releaseThread();
    }

    /// Drop one worker from `running_threads`, waking `stop()` when it was the
    /// last. Called under `queue_mutex`.
    fn releaseThread(self: *ThreadPool) void {
        if (self.running_threads.fetchSub(1, .monotonic) == 1) {
            self.all_done.broadcast();
        }
    }

    /// Spawn a detached worker thread, already counted by `reserveSpawn`. Must
    /// not touch the pool after the spawn: once the worker runs, it can exit and
    /// let `stop()` return before this function does.
    fn spawnThread(self: *ThreadPool) !void {
        const thread = try std.Thread.spawn(.{}, run, .{self});
        thread.detach();
    }

    pub fn deinit(self: *ThreadPool) void {
        // stop() has already waited for all workers to be done with the pool (it
        // is idempotent, so calling it again here is safe if the caller did not
        // stop() first).
        self.stop();

        // Pair with the install in init (refcounted; restores on the last pool).
        os.syscall_cancel.uninstallHandler();
    }

    /// Stop the pool: drop any queued work, refuse new submissions, and wait
    /// until all workers are done with the pool. Their OS threads may still be
    /// finishing their exit, but none of them touches the pool anymore, so no
    /// completion callback can run (callbacks wake the owning event loop, so
    /// the loop must outlive the pool's workers). The pool object stays valid
    /// until deinit(); submit() called after stop() drops the work. Every
    /// caller waits, including concurrent and repeated ones.
    pub fn stop(self: *ThreadPool) void {
        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();
        if (!self.shutdown) {
            self.shutdown = true;
            // Drop any queued (not-yet-started) work so it can't be removed and
            // completed later (e.g. by cancel()), which would invoke its
            // completion_fn after shutdown and wake a loop being torn down.
            while (self.queue.pop()) |_| {}
            self.queue_size = 0;
            self.reserved_pending = 0;
            self.queue_not_empty.broadcast();
        }

        // A spawn reserved before `shutdown` was set is counted here too: its
        // worker sees `shutdown` and exits, or `cancelSpawn` drops the count.
        while (self.running_threads.load(.monotonic) > 0) {
            self.all_done.wait(&self.queue_mutex);
        }
    }

    pub fn submit(self: *ThreadPool, work: *Work) void {
        if (builtin.single_threaded or self.max_threads == 0) {
            if (work.state.cmpxchgStrong(.pending, .running, .acq_rel, .acquire)) |state| {
                std.debug.assert(state == .canceled);
                work.c.setError(error.Canceled);
            } else {
                if (work.cancel_token) |token| token.enter();
                work.func(work);
                if (work.cancel_token) |token| token.exit();
                work.c.setResult(.work, {});
                work.state.store(.completed, .release);
            }
            if (work.completion_fn) |completion_fn| {
                completion_fn(work.completion_context, work);
            }
            return;
        }

        self.queue_mutex.lock();
        if (self.shutdown) {
            // Pool is shutting down: drop the work without running it or
            // signaling completion. The owning loop may already be tearing down.
            self.queue_mutex.unlock();
            return;
        }
        // Reserved work goes to the front: the worker spawned for it, or the
        // idle one counted for it, must take this job and not an older regular
        // one, which may be the very job waiting on it. Reserved jobs are LIFO
        // among themselves, which only shows once a spawn has failed.
        if (work.reserve_thread) self.queue.pushFront(&work.c) else self.queue.push(&work.c);
        self.queue_size += 1;
        if (work.reserve_thread) self.reserved_pending += 1;

        // Decided under queue_mutex, so the counts are consistent: a parked
        // worker can't wake and claim work until we release the lock.
        const spawn = self.needsSpawn();
        if (spawn) self.reserveSpawn();

        self.queue_mutex.unlock();
        self.queue_not_empty.signal();

        if (spawn) {
            // On failure the job stays queued and runs once a worker frees up,
            // or gets a worker from the next submit's spawn decision.
            self.spawnThread() catch |err| {
                log.err("Failed to spawn thread: {}", .{err});
                self.cancelSpawn();
            };
        }
    }

    pub fn cancel(self: *ThreadPool, work: *Work) void {
        // Token-bearing work is never dropped from the queue: its `func` always
        // runs, so any caller-owned result (e.g. blockInPlace's stack result, or
        // a delegated op's completion) is always produced. Cancellation is
        // delivered through the token — a still-queued syscall aborts at
        // `begin()`, a running one is interrupted via SIGURG (the loop drives
        // resend until the worker acknowledges).
        if (work.cancel_token) |token| {
            if (token.cancel()) _ = token.signal();
            return;
        }

        // Untokened work has no way to abort in-flight, so cancellation must drop
        // it. Try to transition from pending to canceled atomically.
        if (work.state.cmpxchgStrong(.pending, .canceled, .acq_rel, .acquire)) |_| {
            // Already running or completed - worker will call completion_fn.
            return;
        }

        // Successfully marked as canceled, try to remove from queue
        self.queue_mutex.lock();
        const removed = self.queue.remove(&work.c);
        if (removed) {
            self.queue_size -= 1;
            // A reserved job leaving the queue without being picked up no longer
            // needs a worker; drop its pending count under the same lock.
            if (work.reserve_thread) self.reserved_pending -= 1;
        }
        self.queue_mutex.unlock();

        // Only call completion_fn if we removed from queue.
        // If not removed, worker already dequeued it and will call completion_fn
        // (seeing state == .canceled).
        if (removed) {
            work.c.setError(error.Canceled);
            if (work.completion_fn) |completion_fn| {
                completion_fn(work.completion_context, work);
            }
        }
    }

    fn run(self: *ThreadPool) void {
        // A worker is runtime machinery for its whole life. That includes the
        // `spawnBlocking` user code it also runs: such code can block on the
        // stderr lock, and the task holding that lock may be parked on this very
        // pool, so waiting would starve the worker needed to release it. See
        // `runtime.ThreadRole`.
        runtime.setThreadRole(.machinery);
        os.syscall_cancel.bindThread();

        self.queue_mutex.lock();
        self.runTasks();
        os.syscall_cancel.unbindThread();

        // The worker is detached, and this is its last access to the pool:
        // once the count is released and the mutex unlocked, `stop()` can
        // return and the pool can be freed. Nothing may follow these two lines.
        self.releaseThread();
        self.queue_mutex.unlock();
    }

    /// Run queued jobs until shutdown, or until the worker has been idle for
    /// `idle_timeout_ns` and the pool has more than `min_threads` workers.
    /// Called and returns with `queue_mutex` held.
    fn runTasks(self: *ThreadPool) void {
        self.starting -= 1;

        var timed_out = false;
        while (!self.shutdown) {
            const c = self.queue.pop() orelse {
                // Retire only with the queue seen empty under the lock: a job
                // pushed as the wait timed out counted this worker as idle.
                // The caller releases this worker's count while still holding
                // the lock, so the next spawn decision already sees it gone.
                if (timed_out and self.running_threads.load(.monotonic) > self.min_threads) {
                    return;
                }

                _ = self.idle_threads.fetchAdd(1, .monotonic);
                defer _ = self.idle_threads.fetchSub(1, .monotonic);

                if (self.running_threads.load(.monotonic) > self.min_threads) {
                    const timeout: Timeout = .{ .duration = .fromNanoseconds(self.idle_timeout_ns) };
                    self.queue_not_empty.timedWait(&self.queue_mutex, timeout) catch {
                        timed_out = true;
                    };
                } else {
                    self.queue_not_empty.wait(&self.queue_mutex);
                }
                continue;
            };
            timed_out = false;
            self.queue_size -= 1;

            const work = c.cast(Work);
            // Snapshot before running: the completion callback below may free
            // `work`, so we can't read `reserve_thread` off it afterwards.
            const is_reserved = work.reserve_thread;
            if (is_reserved) {
                // This worker now owns the reserved job: drop its pending count
                // (no longer queued) and count it as occupying a worker, which
                // lifts the regular ceiling by one. Both under the queue lock.
                self.reserved_pending -= 1;
                _ = self.reserved_running.fetchAdd(1, .monotonic);
            }

            self.queue_mutex.unlock();
            defer self.queue_mutex.lock();

            // Try to claim the work by transitioning from pending to running
            if (work.state.cmpxchgStrong(.pending, .running, .acq_rel, .acquire)) |state| {
                // Work was canceled before we could start it
                std.debug.assert(state == .canceled);
                work.c.setError(error.Canceled);
            } else {
                // We successfully claimed it, execute the work
                if (work.cancel_token) |token| token.enter();
                work.func(work);
                if (work.cancel_token) |token| token.exit();
                work.c.setResult(.work, {});
                work.state.store(.completed, .release);
            }

            // Reserved job no longer occupies a worker; drop the ceiling before
            // the completion callback, which may free `work`.
            if (is_reserved) _ = self.reserved_running.fetchSub(1, .monotonic);

            // Notify via completion callback
            if (work.completion_fn) |completion_fn| {
                completion_fn(work.completion_context, work);
            }
        }
    }
};
