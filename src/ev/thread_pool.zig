const std = @import("std");
const builtin = @import("builtin");
const Queue = @import("queue.zig").Queue;
const Completion = @import("completion.zig").Completion;
const Work = @import("completion.zig").Work;
const os = @import("../os/root.zig");
const Timeout = @import("../time.zig").Timeout;

const log = @import("../common.zig").log;

pub const ThreadPool = struct {
    allocator: std.mem.Allocator,

    workers: std.ArrayList(Worker) = .empty,
    workers_mutex: os.Mutex = .init(),
    next_worker_id: u64 = 0,

    queue: Queue(Completion) = .{},
    queue_mutex: os.Mutex = .init(),
    queue_not_empty: os.Condition = .init(),
    queue_size: usize = 0,
    shutdown: bool = false,

    min_threads: usize,
    max_threads: usize,

    idle_timeout_ns: u64,
    scale_threshold: usize,

    running_threads: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    idle_threads: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    /// Reserved jobs (see `Work.reserve_thread`) currently sitting in the queue,
    /// each still needing a worker to pick it up. Guarded by `queue_mutex`, so it
    /// is consistent with `idle_threads` and the queue when the spawn decision is
    /// made. A reservation spawns a worker only when there aren't enough idle
    /// workers to cover every pending reserved job — otherwise a parked worker
    /// takes it, no new thread needed.
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
        scale_threshold: usize = 2,
    };

    const Worker = struct {
        worker_id: u64,
        thread: std.Thread,
    };

    pub fn init(self: *ThreadPool, allocator: std.mem.Allocator, options: Options) !void {
        // A max_threads of 0 (explicit, or implied by a single-threaded build)
        // disables the pool: work is executed inline in submit().
        const max_threads = if (builtin.single_threaded)
            0
        else
            options.max_threads orelse (try std.Thread.getCpuCount()) * 2;

        const min_threads = @min(options.min_threads, max_threads);

        self.* = .{
            .allocator = allocator,
            .min_threads = min_threads,
            .max_threads = max_threads,
            .idle_timeout_ns = options.idle_timeout_ms * std.time.ns_per_ms,
            .scale_threshold = options.scale_threshold,
        };
        errdefer self.deinit();

        // Install the process-global SIGURG handler used to interrupt cancelable
        // blocking syscalls. Refcounted; paired with deinit's uninstall.
        os.syscall_cancel.installHandler();

        try self.workers.ensureTotalCapacity(allocator, max_threads);

        for (0..min_threads) |_| {
            try self.spawnThread(false);
        }
    }

    /// Spawn a worker thread. `forced` bypasses the `max_threads` cap, used for a
    /// reservation that must add capacity beyond the configured maximum (the
    /// extra worker is reaped back toward `min_threads` once idle, like any
    /// other). Non-forced spawns (init, scale-up) respect the cap.
    fn spawnThread(self: *ThreadPool, forced: bool) !void {
        self.workers_mutex.lock();
        defer self.workers_mutex.unlock();

        if (!forced and self.workers.items.len >= self.max_threads + self.reserved_running.load(.monotonic)) return;

        _ = self.running_threads.fetchAdd(1, .monotonic);
        errdefer _ = self.running_threads.fetchSub(1, .monotonic);

        const worker_id = self.next_worker_id;
        self.next_worker_id +%= 1;

        log.debug("Spawning thread {}", .{worker_id});

        // Reservations can push the worker count past the init-time capacity, so
        // this must allocate on demand rather than assume capacity.
        const worker = try self.workers.addOne(self.allocator);
        errdefer _ = self.workers.pop();
        worker.worker_id = worker_id;
        worker.thread = try std.Thread.spawn(.{}, run, .{ self, worker_id });
    }

    fn removeThread(self: *ThreadPool, worker_id: u64, after_shutdown: bool) bool {
        self.workers_mutex.lock();
        defer self.workers_mutex.unlock();

        const allow_removal = after_shutdown or self.workers.items.len > self.min_threads;
        if (!allow_removal) return false;

        log.debug("Removing thread {}", .{worker_id});

        for (self.workers.items, 0..) |*worker, i| {
            if (worker.worker_id == worker_id) {
                _ = self.workers.swapRemove(i);
                _ = self.running_threads.fetchSub(1, .monotonic);
                return true;
            }
        }
        unreachable;
    }

    pub fn deinit(self: *ThreadPool) void {
        // stop() has already joined all worker threads (it is idempotent, so
        // calling it again here is safe if the caller did not stop() first).
        self.stop();
        self.workers.deinit(self.allocator);

        // Pair with the install in init (refcounted; restores on the last pool).
        os.syscall_cancel.uninstallHandler();
    }

    /// Stop the pool: drop any queued work, refuse new submissions, and join all
    /// worker threads. After this returns, no worker thread exists, so no
    /// completion callback can run anymore (callbacks wake the owning event
    /// loop, so the loop must outlive the pool's threads). The pool object stays
    /// valid until deinit(); submit() called after stop() drops the work.
    pub fn stop(self: *ThreadPool) void {
        {
            self.queue_mutex.lock();
            defer self.queue_mutex.unlock();
            if (self.shutdown) return; // already stopped, threads already joined
            self.shutdown = true;
            // Drop any queued (not-yet-started) work so it can't be removed and
            // completed later (e.g. by cancel()), which would invoke its
            // completion_fn after shutdown and wake a loop being torn down.
            while (self.queue.pop()) |_| {}
            self.queue_size = 0;
            self.reserved_pending = 0;
            self.queue_not_empty.broadcast();
        }

        // Join all threads - they will remove themselves from the list.
        // We need to keep joining until all workers are gone.
        while (true) {
            self.workers_mutex.lock();
            const thread = if (self.workers.items.len > 0) self.workers.items[0].thread else null;
            self.workers_mutex.unlock();

            if (thread) |t| {
                t.join();
            } else {
                break;
            }
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
        self.queue.push(&work.c);
        self.queue_size += 1;
        const queued = self.queue_size;

        // Decide, under queue_mutex, whether a reserved job needs a fresh worker.
        // Both idle_threads and reserved_pending are only mutated while holding
        // this lock, so the snapshot is race-free: a parked worker can't wake and
        // claim work until we release the lock. Spawn only when the idle workers
        // can't cover every pending reserved job; otherwise a parked worker takes
        // it. This is the guarantee's headroom accounting — one spare (idle or
        // freshly spawned) worker per outstanding reserved job.
        var reservation_needs_spawn = false;
        if (work.reserve_thread) {
            self.reserved_pending += 1;
            reservation_needs_spawn = self.idle_threads.load(.monotonic) < self.reserved_pending;
        }

        self.queue_not_empty.signal();
        self.queue_mutex.unlock();

        if (reservation_needs_spawn) {
            // Forced: a reserved job may need capacity beyond max_threads. On
            // failure the job stays queued (reserved_pending is dropped when a
            // worker eventually picks it up) and runs once a worker frees up —
            // the hard guarantee degrades, but nothing is lost.
            self.spawnThread(true) catch |err| {
                log.err("Failed to spawn reserved thread: {}", .{err});
            };
            return;
        }

        const running = self.running_threads.load(.monotonic);
        const idle = self.idle_threads.load(.monotonic);
        // Ceiling is max_threads + reserved_running: reserved work is additive to
        // the regular budget, so regular work can still scale to max_threads even
        // when reserved jobs occupy workers.
        const ceiling = self.max_threads + self.reserved_running.load(.monotonic);
        const should_spawn = running < self.min_threads or (idle == 0 and queued >= running * self.scale_threshold and running < ceiling);
        if (should_spawn) {
            self.spawnThread(false) catch |err| {
                log.err("Failed to spawn thread: {}", .{err});
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

    fn run(self: *ThreadPool, worker_id: u64) void {
        while (true) {
            const shutdown = self.runTasks();
            if (self.removeThread(worker_id, shutdown)) return;
        }
        unreachable;
    }

    fn runTasks(self: *ThreadPool) bool {
        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();

        while (!self.shutdown) {
            const c = self.queue.pop() orelse {
                _ = self.idle_threads.fetchAdd(1, .monotonic);
                defer _ = self.idle_threads.fetchSub(1, .monotonic);

                if (self.running_threads.load(.monotonic) >= self.min_threads) {
                    const timeout: Timeout = .{ .duration = .fromNanoseconds(self.idle_timeout_ns) };
                    self.queue_not_empty.timedWait(&self.queue_mutex, timeout) catch return false;
                } else {
                    self.queue_not_empty.wait(&self.queue_mutex);
                }
                continue;
            };
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
        return true;
    }
};
