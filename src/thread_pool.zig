const std = @import("std");
const Queue = @import("queue.zig").Queue;
const Completion = @import("completion.zig").Completion;
const Work = @import("completion.zig").Work;

pub const ThreadPool = struct {
    allocator: std.mem.Allocator,

    workers: std.ArrayList(Worker) = .empty,
    workers_mutex: std.Thread.Mutex = .{},
    next_worker_id: u64 = 0,

    queue: Queue(Completion) = .{},
    queue_mutex: std.Thread.Mutex = .{},
    queue_not_empty: std.Thread.Condition = .{},
    queue_size: usize = 0,
    shutdown: bool = false,

    min_threads: usize,
    max_threads: usize,

    idle_timeout_ns: u64,
    scale_threshold: usize,

    running_threads: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    idle_threads: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

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
        const cpu_count = try std.Thread.getCpuCount();
        const max_threads = options.max_threads orelse (cpu_count * 2);
        const min_threads = options.min_threads;

        self.* = .{
            .allocator = allocator,
            .min_threads = min_threads,
            .max_threads = max_threads,
            .idle_timeout_ns = options.idle_timeout_ms * std.time.ns_per_ms,
            .scale_threshold = options.scale_threshold,
        };
        errdefer self.deinit();

        try self.workers.ensureTotalCapacity(allocator, max_threads);

        for (0..min_threads) |_| {
            try self.spawnThread();
        }
    }

    fn spawnThread(self: *ThreadPool) !void {
        self.workers_mutex.lock();
        defer self.workers_mutex.unlock();

        if (self.workers.items.len >= self.max_threads) return;

        _ = self.running_threads.fetchAdd(1, .monotonic);
        errdefer _ = self.running_threads.fetchSub(1, .monotonic);

        const worker_id = self.next_worker_id;
        self.next_worker_id +%= 1;

        std.log.debug("Spawning thread {}", .{worker_id});

        const worker = self.workers.addOneAssumeCapacity();
        worker.worker_id = worker_id;
        worker.thread = try std.Thread.spawn(.{}, run, .{ self, worker_id });
    }

    fn removeThread(self: *ThreadPool, worker_id: u64, after_shutdown: bool) bool {
        self.workers_mutex.lock();
        defer self.workers_mutex.unlock();

        const allow_removal = after_shutdown or self.workers.items.len > self.min_threads;
        if (!allow_removal) return false;

        std.log.debug("Removing thread {}", .{worker_id});

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
        self.stop();

        // Join all threads - they will remove themselves from the list
        // We need to keep joining until all workers are gone
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

        self.workers.deinit(self.allocator);
    }

    pub fn stop(self: *ThreadPool) void {
        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();
        self.shutdown = true;
        self.queue_not_empty.broadcast();
    }

    pub fn submit(self: *ThreadPool, work: *Work) void {
        self.queue_mutex.lock();
        self.queue.push(&work.c);
        self.queue_size += 1;
        const queued = self.queue_size;
        self.queue_not_empty.signal();
        self.queue_mutex.unlock();

        const running = self.running_threads.load(.monotonic);
        const idle = self.idle_threads.load(.monotonic);
        const should_spawn = running < self.min_threads or (idle == 0 and queued >= running * self.scale_threshold and running < self.max_threads);
        if (should_spawn) {
            self.spawnThread() catch |err| {
                std.log.err("Failed to spawn thread: {}", .{err});
            };
        }
    }

    pub fn cancel(self: *ThreadPool, work: *Work) bool {
        // Try to transition from pending to canceled atomically
        if (work.state.cmpxchgStrong(.pending, .canceled, .acq_rel, .acquire)) |_| {
            // Already in different state (running or completed)
            return false;
        }

        // Successfully marked as canceled, now safe to remove from queue
        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();
        return self.queue.remove(&work.c);
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
                    self.queue_not_empty.timedWait(&self.queue_mutex, self.idle_timeout_ns) catch return false;
                } else {
                    self.queue_not_empty.wait(&self.queue_mutex);
                }
                continue;
            };
            self.queue_size -= 1;

            self.queue_mutex.unlock();
            defer self.queue_mutex.lock();

            const work = c.cast(Work);
            const loop = work.loop orelse unreachable;

            // Try to claim the work by transitioning from pending to running
            if (work.state.cmpxchgStrong(.pending, .running, .acq_rel, .acquire)) |state| {
                // Work was canceled before we could start it
                std.debug.assert(state == .canceled);
                work.result = error.Canceled;
            } else {
                // We successfully claimed it, execute the work
                work.func(loop, work);
                work.result = {};
                work.state.store(.completed, .release);
            }

            // Notify the event loop
            loop.state.work_completions.push(c);
            loop.wake();
        }
        return true;
    }
};
