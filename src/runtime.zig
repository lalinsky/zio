// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const assert = std.debug.assert;

const ev = @import("ev/root.zig");
const os = @import("os/root.zig");

const meta = @import("meta.zig");
const Cancelable = @import("common.zig").Cancelable;
const log = @import("common.zig").log;
const time = @import("time.zig");
const Duration = time.Duration;
const Timestamp = time.Timestamp;

const Coroutine = @import("coro/coroutines.zig").Coroutine;
const Context = @import("coro/coroutines.zig").Context;
const StackPool = @import("coro/stack_pool.zig").StackPool;
const StackPoolConfig = @import("coro/stack_pool.zig").Config;
const setupStackGrowth = @import("coro/stack.zig").setupStackGrowth;
const cleanupStackGrowth = @import("coro/stack.zig").cleanupStackGrowth;

const AnyTask = @import("task.zig").AnyTask;
const TaskPool = @import("task.zig").TaskPool;
const spawnTask = @import("task.zig").spawnTask;
const finishTask = @import("task.zig").finishTask;
const spawnBlockingTask = @import("blocking_task.zig").spawnBlockingTask;
const Group = @import("group.zig").Group;

const dns = @import("dns/root.zig");

const select = @import("select.zig");
const Waiter = @import("common.zig").Waiter;
const random_mod = @import("random.zig");

const mod = @This();

/// Number of executor threads to run (including main).
pub const ExecutorCount = enum(u8) {
    /// Auto-detect based on CPU count
    auto = 0,
    _,

    /// Create an exact executor count (1 = single-threaded, no worker threads)
    pub fn exact(n: u8) ExecutorCount {
        assert(n >= 1 and n <= Executor.max_executors);
        return @enumFromInt(n);
    }

    pub fn resolve(self: ExecutorCount) u8 {
        return switch (self) {
            .auto => @intCast(@min(Executor.max_executors, std.Thread.getCpuCount() catch 1)),
            _ => @intFromEnum(self),
        };
    }
};

// Runtime configuration options
pub const RuntimeOptions = struct {
    thread_pool: ev.ThreadPool.Options = .{},
    stack_pool: StackPoolConfig = .{
        .maximum_size = 8 * 1024 * 1024,
        .committed_size = 256 * 1024,
        .max_unused_stacks = 1000,
        .max_age = .fromSeconds(60),
    },
    /// Total number of executors to run.
    /// When enable_main_executor is true (default), this includes the main executor on the calling thread.
    /// When enable_main_executor is false, all executors run as background worker threads.
    executors: ExecutorCount = .exact(1),
    /// When true (default), the calling thread becomes the main executor (executor 0).
    /// Set to false when creating runtimes in background threads that should not block
    /// the creating thread in an event loop. Requires executors >= 1 to have any workers.
    enable_main_executor: bool = true,
    /// Allow tasks to migrate between executors when true.
    enable_task_migration: bool = true,
    /// DNS resolver configuration.
    dns: DnsOptions = .{},
};

pub const DnsOptions = struct {
    /// Use the built-in native DNS resolver instead of getaddrinfo.
    custom_resolver: bool = ev.backend == .io_uring,
};

const Awaitable = @import("awaitable.zig").Awaitable;

// Public handle for spawned tasks and futures
pub fn JoinHandle(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const Result = T;

        awaitable: ?*Awaitable,
        result: T,

        /// Helper to get result from awaitable and release it
        fn finishAwaitable(self: *Self, awaitable: *Awaitable) void {
            self.result = awaitable.getTypedResult(T);
            awaitable.release();
            self.awaitable = null;
        }

        /// Wait for the task to complete and return its result.
        ///
        /// If the current task is canceled while waiting, the spawned task will be canceled too.
        ///
        /// Example:
        /// ```zig
        /// var handle = try rt.spawn(myTask, .{});
        /// const result = handle.join();
        /// ```
        pub fn join(self: *Self) T {
            // If awaitable is null, result is already cached
            const awaitable = self.awaitable orelse return self.result;

            // Wait for completion
            _ = select.waitUntilComplete(awaitable);

            // Get result and release awaitable
            self.finishAwaitable(awaitable);
            return self.result;
        }

        /// Check if the task has completed and a result is available.
        pub fn hasResult(self: *const Self) bool {
            if (self.awaitable) |awaitable| {
                return awaitable.hasResult();
            }
            return true; // If awaitable is null, result is already cached
        }

        /// Get the result value of type T (preserving any error union).
        /// Asserts that the task has already completed.
        /// This is used internally by select() to preserve error union types.
        pub fn getResult(self: *Self) T {
            if (self.awaitable) |awaitable| {
                return awaitable.getTypedResult(T);
            }
            return self.result;
        }

        /// Registers a waiter to be notified when the task completes.
        /// This is part of the Future protocol for select().
        /// Returns false if the task is already complete (no wait needed), true if added to queue.
        pub fn asyncWait(self: Self, waiter: *Waiter) bool {
            if (self.awaitable) |awaitable| {
                return awaitable.asyncWait(waiter);
            }
            return false; // Already complete
        }

        /// Cancels a pending wait operation by removing the waiter.
        /// This is part of the Future protocol for select().
        /// Returns true if removed, false if already removed by completion (wake in-flight).
        pub fn asyncCancelWait(self: Self, waiter: *Waiter) bool {
            if (self.awaitable) |awaitable| {
                return awaitable.asyncCancelWait(waiter);
            }
            return true; // No awaitable means already completed, no wake in-flight
        }

        /// Request cancellation and wait for the task to complete.
        ///
        /// Safe to call after `join()` - typically used in defer for cleanup.
        ///
        /// Example:
        /// ```zig
        /// var handle = try rt.spawn(myTask, .{});
        /// defer handle.cancel();
        /// // Do some other work that could return early
        /// const result = handle.join();
        /// // cancel() in defer is a no-op since join() already completed
        /// ```
        pub fn cancel(self: *Self) void {
            // If awaitable is null, already completed/detached - no-op
            const awaitable = self.awaitable orelse return;

            // If already done, just clean up
            if (awaitable.hasResult()) {
                self.finishAwaitable(awaitable);
                return;
            }

            // Request cancellation
            awaitable.cancel();

            // Wait for completion
            _ = select.waitUntilComplete(awaitable);

            // Get result and release awaitable
            self.finishAwaitable(awaitable);
        }

        /// Detach the task, allowing it to run in the background.
        ///
        /// After detaching, the result is no longer retrievable.
        ///
        /// Example:
        /// ```zig
        /// var handle = try rt.spawn(backgroundTask, .{});
        /// handle.detach(); // Task runs independently
        /// ```
        pub fn detach(self: *Self) void {
            // If awaitable is null, already detached - no-op
            const awaitable = self.awaitable orelse return;

            awaitable.release();
            self.awaitable = null;
            self.result = undefined;
        }
    };
}

// Generic data structures (private)
const WaitNode = @import("utils/wait_queue.zig").WaitNode;
const ConcurrentStack = @import("utils/concurrent_stack.zig").ConcurrentStack;
const SimpleQueue = @import("utils/simple_queue.zig").SimpleQueue;

comptime {
    // WaitNode needs at least 4-byte alignment for 2 spare bits in pointers
    std.debug.assert(@alignOf(WaitNode) >= 4);
}

pub fn getNextExecutor(rt: *Runtime) error{RuntimeShutdown}!*Executor {
    if (rt.shutting_down.load(.acquire)) {
        return error.RuntimeShutdown;
    }

    const index = rt.next_executor_index.fetchAdd(1, .monotonic);
    return rt.executors.items[index % rt.executors.items.len];
}

// Executor - per-thread execution unit for running coroutines
pub const Executor = struct {
    pub const max_executors = 64;

    id: u6,
    loop: ev.Loop,

    /// Per-executor random state (non-secure CSPRNG; later the secure-path fd/handle).
    random_state: random_mod.RandomState,

    ready_queue: SimpleQueue(WaitNode) = .{},

    // Tracks tasks run since last event loop tick.
    // After EVENT_INTERVAL tasks, getNextTask() returns null to force I/O processing.
    tick_task_count: u8 = 0,

    // Monotonically increasing tick counter, incremented after each event loop tick.
    // Used with task.last_run_tick to prevent running the same task more than once per tick.
    // Starts at 1 so new tasks (last_run_tick=0) can run immediately.
    current_tick: u32 = 1,

    // Tracks tasks waiting in ready_queue + next_ready_queue.
    ready_count: u32 = 0,

    // Timestamp of last event loop tick, used for time-based yield decisions.
    last_tick_time: Timestamp = .zero,

    // Deferred cleanup for the task that just yielded away from this executor.
    // Processed by the next coroutine to run (at landing sites: startFn, yield resume, run loop).
    pending_cleanup: TaskCleanup = .none,

    // Remote task support - lock-free LIFO stack for cross-thread resumption
    next_ready_queue_remote: ConcurrentStack(WaitNode) = .{},

    // Back-reference to runtime for global coordination
    runtime: *Runtime,

    // Main task for non-coroutine contexts (e.g., main thread calling rt.sleep())
    // This allows the main thread to use the same yield/wake mechanisms as spawned tasks.
    // Note: main_task.coro is not a real coroutine - scheduleTask handles it specially
    // by setting state to .ready without queuing.
    main_task: AnyTask = undefined,

    // Shutdown event - keeps the event loop active and provides cross-thread shutdown.
    // When notified, it calls loop.stop() to exit the event loop.
    shutdown: ev.Async = ev.Async.init(),

    // Periodic timer for evicting idle stacks from the shared stack pool.
    stack_pool_eviction_timer: ev.Timer = ev.Timer.init(.{ .duration = .fromSeconds(60) }),

    // The task currently executing on this executor.
    // Updated before every context switch into a task and after every switch back.
    // Used by getCurrentTaskOrNull() instead of the TLS current_context chain.
    current_task: *AnyTask,

    // Executor dedicated to this thread. Written once on init, never updated.
    pub threadlocal var current_DO_NOT_ACCESS_DIRECTLY: ?*Executor = null;

    /// Get the Executor instance from any coroutine that belongs to it.
    /// Coroutines have parent_context_ptr pointing to main_task.coro.context,
    /// so we navigate: context -> coro -> main_task -> executor.
    /// Only valid on the executor thread that is currently running the coroutine.
    pub fn fromCoroutine(coro: *Coroutine) *Executor {
        const parent_context_ptr = @atomicLoad(*Context, &coro.parent_context_ptr, .acquire);
        const main_coro: *Coroutine = @fieldParentPtr("context", parent_context_ptr);
        const main_task: *AnyTask = @fieldParentPtr("coro", main_coro);
        return @alignCast(@fieldParentPtr("main_task", main_task));
    }

    pub fn init(self: *Executor, runtime: *Runtime, id: u6) !void {
        self.* = .{
            .id = id,
            .loop = undefined,
            .random_state = undefined,
            .current_task = undefined,
            .runtime = runtime,
            .shutdown = ev.Async.init(),
        };

        // Initialize main_task - this serves as both the scheduler context and
        // the task context for async operations called from main.
        // main_task.coro.context is where spawned tasks yield back to.
        self.main_task = .{
            .state = std.atomic.Value(AnyTask.State).init(.{ .tag = .ready }),
            .awaitable = .{
                .kind = .task,
                .wait_node = .{},
            },
            .coro = .{
                .context = std.mem.zeroes(Context),
                .parent_context_ptr = undefined,
            },
            .runtime = runtime,
            .closure = undefined, // main_task has no closure
        };
        @atomicStore(*Context, &self.main_task.coro.parent_context_ptr, &self.main_task.coro.context, .release);

        try setupStackGrowth();
        errdefer cleanupStackGrowth();

        // Initialize this executor's random state from OS entropy.
        try random_mod.setup(&self.random_state);

        try self.loop.init(.{
            .allocator = self.runtime.allocator,
            .thread_pool = &self.runtime.thread_pool,
            .loop_group = &self.runtime.loop_group,
            .defer_callbacks = false,
        });
        errdefer self.loop.deinit();

        // Register shutdown handle to keep loop active and enable cross-thread shutdown
        self.shutdown.c.callback = shutdownCallback;
        self.loop.add(&self.shutdown.c);

        // Register periodic stack pool eviction timer (skipped when max_age is zero)
        if (self.runtime.options.stack_pool.max_age.value > 0) {
            self.stack_pool_eviction_timer.c.callback = stackPoolEvictionCallback;
            self.loop.add(&self.stack_pool_eviction_timer.c);
        }

        self.main_task.coro.setCurrent();
        setCurrentExecutor(self);
        self.current_task = &self.main_task;
    }

    pub fn deinit(self: *Executor) void {
        setCurrentExecutor(null);
        Coroutine.clearCurrent();

        self.loop.deinit();

        cleanupStackGrowth();
    }

    fn shutdownCallback(loop: *ev.Loop, _: *ev.Completion) void {
        loop.stop();
    }

    fn stackPoolEvictionCallback(loop: *ev.Loop, c: *ev.Completion) void {
        const timer = c.cast(ev.Timer);
        const self: *Executor = @alignCast(@fieldParentPtr("stack_pool_eviction_timer", timer));
        self.runtime.stack_pool.cleanup(loop.now(), 16);
        if (self.runtime.options.stack_pool.max_age.value > 0) {
            loop.add(c);
        }
    }

    pub const YieldCancelMode = enum { allow_cancel, no_cancel };

    /// Yield to other tasks only if many are waiting, to balance fairness vs. context-switch overhead.
    const yield_ready_threshold = 13;

    pub fn maybeYield(self: *Executor, comptime mode: AnyTask.YieldMode, comptime cancel_mode: YieldCancelMode) if (cancel_mode == .allow_cancel) Cancelable!void else void {
        if (self.ready_count >= yield_ready_threshold) {
            return getCurrentTask().yield(mode, cancel_mode);
        }
    }

    pub const RunMode = enum {
        /// Run until main_task.state becomes .ready.
        /// Caller must set up the state before calling (e.g., .waiting for I/O).
        until_ready,
        /// Run until explicitly stopped via loop.stop().
        /// Used for worker executor threads.
        until_stopped,
    };

    /// Run the executor event loop.
    pub fn run(self: *Executor, mode: RunMode) !void {
        const check_ready = mode != .until_stopped;

        // Process deferred cleanup (e.g. main task's park/reschedule)
        self.processCleanup();

        while (true) {
            // Process ready coroutines
            while (self.getNextTask()) |next_task| {
                @atomicStore(*Context, &next_task.coro.parent_context_ptr, &self.main_task.coro.context, .release);
                self.current_task = next_task;
                next_task.coro.step();
                self.current_task = &self.main_task;
                self.processCleanup();
            }

            // Exit if loop is stopped
            if (self.loop.stopped()) {
                if (mode == .until_stopped) {
                    return;
                }
                @panic("event loop stopped while the main task was yielding");
            }

            // Drain remote ready queue (cross-thread tasks) after processing current queue
            var drained = self.next_ready_queue_remote.popAll();
            while (drained.pop()) |task| {
                self.ready_queue.push(task);
                self.ready_count += 1;
            }

            // Run event loop - non-blocking if there's work, otherwise wait for I/O
            const main_ready = check_ready and self.main_task.state.load(.acquire).tag == .ready;
            const has_work = self.ready_queue.head != null or main_ready;
            try self.loop.run(if (has_work) .no_wait else .once);

            // Reset task counter and update tick time after event loop tick
            self.tick_task_count = 0;
            self.current_tick +%= 1;
            self.last_tick_time = self.loop.now();

            // Check again after I/O
            if (check_ready and self.main_task.state.load(.acquire).tag == .ready) {
                return;
            }
        }
    }

    /// Get the next task to run from the ready queue.
    ///
    /// Returns null if no tasks are available, or if EVENT_INTERVAL tasks have
    /// been run since the last event loop tick (to ensure I/O responsiveness).
    fn getNextTask(self: *Executor) ?*AnyTask {
        // Maximum tasks to run before forcing an event loop tick (from Go's scheduler)
        const EVENT_INTERVAL = 61;

        // Force event loop tick after running EVENT_INTERVAL tasks
        if (self.tick_task_count >= EVENT_INTERVAL) {
            return null;
        }

        // Peek at head of ready_queue
        const node = self.ready_queue.head orelse return null;
        const task = AnyTask.fromWaitNode(node);

        // Task already ran this tick? Force event loop tick first.
        // This prevents a yielding task from running multiple times per tick.
        // We leave the task in the queue (don't pop) to preserve FIFO order.
        if (task.last_run_tick == self.current_tick) {
            return null;
        }

        // Actually remove from queue now that we're going to run it
        _ = self.ready_queue.pop();

        task.last_run_tick = self.current_tick;
        self.tick_task_count += 1;
        self.ready_count -= 1;
        return task;
    }

    /// Schedule a task to the current executor's local queue.
    /// This must only be called when we're on the correct executor thread.
    fn scheduleTaskLocal(self: *Executor, task: *AnyTask) void {
        // Main task is never queued — its readiness is driven by its state field,
        // which the run loop checks directly. processCleanup can reach here with the
        // main task on the pre-woken park / reschedule paths.
        if (task == &self.main_task) return;

        const wait_node = &task.awaitable.wait_node;
        self.ready_queue.push(wait_node);
        self.ready_count += 1;
    }

    /// Schedule a task to a remote executor (different executor or no current executor).
    /// Uses the thread-safe remote queue and notifies the executor.
    fn scheduleTaskRemote(self: *Executor, task: *AnyTask) void {
        std.debug.assert(task != &self.main_task);

        const wait_node = &task.awaitable.wait_node;
        self.next_ready_queue_remote.push(wait_node);
        self.loop.wake();
    }

    /// Schedule a task for execution.
    /// Atomically transitions task state to .ready and schedules it for execution.
    /// May migrate the task to the current executor for cache locality.
    pub fn scheduleTask(task: *AnyTask) void {
        var old = task.state.load(.acquire);
        while (true) {
            switch (old.tag) {
                // Task already finished (race between completion and cancel) - nothing to do
                .finished => return,
                // Task is in .ready state (running or about to park).
                // Set the awaken bit as a park token; processCleanup.park will consume it
                // and reschedule the task instead of transitioning to .waiting.
                .ready => {
                    if (old.awaken) return; // Token already set, nothing to do
                    const desired = AnyTask.State{ .tag = .ready, .awaken = true };
                    if (task.state.cmpxchgWeak(old, desired, .acq_rel, .acquire)) |actual| {
                        old = actual;
                        continue;
                    }
                    return; // Awaken token set; task will handle it before/during next park
                },
                // Valid states to transition to .ready
                .new, .waiting => {},
            }
            const desired = AnyTask.State{ .tag = .ready, .awaken = false };
            if (task.state.cmpxchgWeak(old, desired, .acq_rel, .acquire)) |actual| {
                old = actual;
                continue;
            }
            break;
        }

        const home_exec = Executor.fromCoroutine(&task.coro);

        if (task == &home_exec.main_task) {
            home_exec.loop.wake();
            return;
        }

        if (getCurrentExecutorOrNull()) |current_exec| {
            if (current_exec == home_exec) {
                // Schedule locally
                current_exec.scheduleTaskLocal(task);
                return;
            }
            // New tasks always go to their round-robin assigned home executor to
            // distribute load across executors. Only already-running tasks may
            // migrate to the current executor (for cache locality with the waker).
            // The .new check can be removed once we have work stealing to rebalance
            // load (see https://github.com/lalinsky/zio/issues/460).
            if (old.tag != .new and current_exec.runtime == home_exec.runtime and home_exec.runtime.options.enable_task_migration) {
                // Migrate to the current executor
                task.last_run_tick = 0;
                current_exec.scheduleTaskLocal(task);
                return;
            }
        }

        // Schedule on the home executor
        home_exec.scheduleTaskRemote(task);
    }

    const TaskCleanup = union(enum) {
        none,
        reschedule: *AnyTask,
        park: *AnyTask,
        finish: *AnyTask,
    };

    /// Process deferred cleanup for the task that just yielded away.
    /// Called at each landing site after a context switch:
    /// - startFn (new task entry)
    /// - yield resume (after yieldTo returns)
    /// - run loop (after step returns)
    pub fn processCleanup(self: *Executor) void {
        switch (self.pending_cleanup) {
            .none => {},
            .reschedule => |task| {
                self.pending_cleanup = .none;
                self.scheduleTaskLocal(task);
            },
            .park => |task| {
                self.pending_cleanup = .none;
                // Context is now saved — safe to make the task wakeable.
                // Atomically check the awaken bit and either:
                // - Transition (ready, awaken=false) → (waiting, awaken=false): normal park
                // - Consume (ready, awaken=true) → (ready, awaken=false): pre-woken, reschedule
                var old = task.state.load(.acquire);
                while (true) {
                    std.debug.assert(old.tag == .ready);
                    if (old.awaken) {
                        // Pre-woken: consume the token, keep .ready, and reschedule
                        const desired = AnyTask.State{ .tag = .ready, .awaken = false };
                        if (task.state.cmpxchgWeak(old, desired, .acq_rel, .acquire)) |actual| {
                            old = actual;
                            continue;
                        }
                        self.scheduleTaskLocal(task);
                        return;
                    }
                    // Normal: transition to .waiting
                    const desired = AnyTask.State{ .tag = .waiting, .awaken = false };
                    if (task.state.cmpxchgWeak(old, desired, .acq_rel, .acquire)) |actual| {
                        old = actual;
                        continue;
                    }
                    break; // Task is now .waiting
                }
            },
            .finish => |task| {
                self.pending_cleanup = .none;
                task.state.store(.{ .tag = .finished }, .release);
                if (task.coro.context.stack_info.allocation_len > 0) {
                    self.runtime.stack_pool.release(task.coro.context.stack_info, self.loop.now());
                    task.coro.context.stack_info.allocation_len = 0;
                }
                finishTask(self.runtime, &task.awaitable);
            },
        }
    }

    /// Yield the current coroutine to the next ready task or back to the run loop.
    /// Sets current_task for the target and performs the context switch.
    pub fn switchOut(self: *Executor, coro: *Coroutine) void {
        if (self.getNextTask()) |next_task| {
            @atomicStore(*Context, &next_task.coro.parent_context_ptr, &self.main_task.coro.context, .release);
            self.current_task = next_task;
            coro.yieldTo(&next_task.coro);
        } else {
            self.current_task = &self.main_task;
            coro.yield();
        }
    }
};

/// Get the current thread's executor, or null if not in executor context.
pub noinline fn getCurrentExecutorOrNull() ?*Executor {
    return Executor.current_DO_NOT_ACCESS_DIRECTLY;
}

noinline fn setCurrentExecutor(current: ?*Executor) void {
    Executor.current_DO_NOT_ACCESS_DIRECTLY = current;
}

/// Get the current thread's executor.
/// Panics if called from a thread without an active executor context.
pub fn getCurrentExecutor() *Executor {
    return getCurrentExecutorOrNull() orelse @panic("no current executor");
}

/// Get the currently executing task.
/// Panics if called from a thread without an active executor context.
pub fn getCurrentTask() *AnyTask {
    return getCurrentTaskOrNull() orelse @panic("no current task");
}

/// Get the currently executing task, or null if not in task context.
pub fn getCurrentTaskOrNull() ?*AnyTask {
    const exec = getCurrentExecutorOrNull() orelse return null;
    return exec.current_task;
}

/// Cooperatively yield control to allow other tasks to run.
/// The current task will be rescheduled and continue execution later.
/// Returns error.Canceled if the task was canceled.
/// No-op if called from a thread without an executor (returns without error).
pub fn yield() Cancelable!void {
    const task = getCurrentTaskOrNull() orelse {
        os.thread.yield();
        return;
    };
    return task.yield(.reschedule, .allow_cancel);
}

/// Cooperatively yield, but only if enough other tasks are waiting (a cheap
/// fairness check for long CPU-bound loops that would otherwise hog the
/// executor). Returns error.Canceled if the task was canceled. No-op if called
/// from a thread without an executor.
pub fn maybeYield() Cancelable!void {
    const exec = getCurrentExecutorOrNull() orelse return;
    return exec.maybeYield(.reschedule, .allow_cancel);
}

/// Spawn a task on the current runtime.
/// Panics if called outside of a task context.
pub fn spawn(func: anytype, args: std.meta.ArgsTuple(@TypeOf(func))) !JoinHandle(meta.ReturnType(func)) {
    const rt = getCurrentExecutor().runtime;
    return rt.spawn(func, args);
}

/// Spawn a blocking task on the current runtime.
/// Panics if called outside of a task context.
pub fn spawnBlocking(func: anytype, args: std.meta.ArgsTuple(@TypeOf(func))) !JoinHandle(meta.ReturnType(func)) {
    const rt = getCurrentExecutor().runtime;
    return rt.spawnBlocking(func, args);
}

/// Begin a cancellation shield to prevent being canceled during critical sections.
/// If not in a task context, this is a no-op.
pub fn beginShield() void {
    if (getCurrentTaskOrNull()) |task| {
        task.beginShield();
    }
}

/// End a cancellation shield.
/// If not in a task context, this is a no-op.
pub fn endShield() void {
    if (getCurrentTaskOrNull()) |task| {
        task.endShield();
    }
}

/// Check if the current task has been cancelled and return an error if so.
/// If not in a task context, this is a no-op.
pub fn checkCancel() Cancelable!void {
    if (getCurrentTaskOrNull()) |task| {
        try task.checkCancel();
    }
}

/// Get the current monotonic timestamp.
pub fn now() Timestamp {
    return .now(.monotonic);
}

/// Sleep for a specified duration.
pub fn sleep(duration: Duration) Cancelable!void {
    var waiter: Waiter = .init();
    try waiter.timedWait(1, .{ .duration = duration }, .allow_cancel);
}

// Runtime - orchestrator for one or more Executors
pub const Runtime = struct {
    thread_pool: ev.ThreadPool,
    stack_pool: StackPool,
    task_pool: TaskPool,
    allocator: Allocator,
    options: RuntimeOptions,

    executors: std.ArrayList(*Executor) = .empty,
    loop_group: ev.LoopGroup = .{},
    main_executor: Executor,
    next_executor_index: std.atomic.Value(usize) = .init(0),
    workers: std.ArrayList(Worker) = .empty,
    task_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0), // Active task counter
    shutting_down: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    own_self: bool = false,

    resolver: ?dns.Resolver = null,

    const Worker = struct {
        thread: std.Thread = undefined,
        ready: os.ResetEvent = .init(),
        err: ?anyerror = null,
        executor: Executor = undefined,
    };

    pub fn init(allocator: Allocator, options: RuntimeOptions) !*Runtime {
        const self = try allocator.create(Runtime);
        errdefer allocator.destroy(self);

        try self.initStatic(allocator, options);
        self.own_self = true;
        return self;
    }

    pub fn initStatic(self: *Runtime, allocator: Allocator, options: RuntimeOptions) !void {
        const num_executors = options.executors.resolve();
        const num_workers = if (options.enable_main_executor) num_executors - 1 else num_executors;

        self.* = .{
            .allocator = allocator,
            .options = options,
            .thread_pool = undefined,
            .main_executor = undefined,
            .stack_pool = .init(options.stack_pool),
            .task_pool = .init(allocator),
            .resolver = if (options.dns.custom_resolver) dns.Resolver.init(allocator) else null,
        };
        errdefer if (self.resolver) |*r| r.deinit();

        try self.thread_pool.init(allocator, options.thread_pool);
        errdefer self.thread_pool.deinit();

        try self.executors.ensureTotalCapacity(allocator, num_executors);
        errdefer self.executors.deinit(allocator);

        var main_executor_initialized = false;
        if (options.enable_main_executor) {
            try self.main_executor.init(self, 0);
            main_executor_initialized = true;
            self.executors.appendAssumeCapacity(&self.main_executor);
        }
        errdefer if (main_executor_initialized) self.main_executor.deinit();

        try self.workers.ensureTotalCapacity(allocator, num_workers);

        errdefer self.shutdownWorkers();

        if (!builtin.single_threaded) {
            const worker_id_start: u6 = if (options.enable_main_executor) 1 else 0;
            for (0..num_workers) |i| {
                log.debug("Spawning worker thread {}", .{i + worker_id_start});
                const worker = self.workers.addOneAssumeCapacity();
                errdefer _ = self.workers.pop();
                worker.* = .{};
                worker.thread = try std.Thread.spawn(.{}, runWorker, .{ self, worker, @as(u6, @intCast(i + worker_id_start)) });
            }

            for (self.workers.items, 0..) |*worker, i| {
                log.debug("Waiting for worker thread {}", .{i + worker_id_start});
                worker.ready.wait();
                if (worker.err) |e| {
                    return e;
                }
                self.executors.appendAssumeCapacity(&worker.executor);
            }
        }
    }

    /// Stop worker executors and join threads. Used by deinit() and init() error path.
    fn shutdownWorkers(self: *Runtime) void {
        // Wait for all workers to finish initialization, then stop their event loops.
        // Workers that failed to initialize (err != null) don't have valid executors.
        for (self.workers.items) |*worker| {
            worker.ready.wait();
            if (worker.err == null) {
                worker.executor.shutdown.notify();
            }
        }

        // Join worker threads
        for (self.workers.items) |*worker| {
            worker.thread.join();
        }
        self.workers.deinit(self.allocator);
    }

    pub fn deinit(self: *Runtime) void {
        const allocator = self.allocator;

        // Set shutting_down flag to prevent new spawns
        self.shutting_down.store(true, .release);

        // Stop and join the thread pool first, while all executor loops are
        // still alive. Thread-pool completion callbacks wake the owning loop
        // (writing its eventfd), so the pool's worker threads must be fully
        // joined before any loop is torn down. stop() leaves the pool object
        // valid (in shutdown mode), so any late submissions from executors being
        // shut down are safely dropped.
        self.thread_pool.stop();

        // Stop worker executors and join threads (deinits their loops)
        self.shutdownWorkers();

        // All tasks should be complete before deinit
        std.debug.assert(self.task_count.load(.acquire) == 0);

        // Clean up ThreadPool (worker threads already joined by stop()).
        self.thread_pool.deinit();

        // Worker executors clean themselves up via defer in runWorker.
        // We only need to deinit the main executor here (if it was created).
        if (self.options.enable_main_executor) {
            self.main_executor.deinit();
        }

        self.executors.deinit(allocator);

        // Clean up stack pool
        self.stack_pool.deinit();

        // Clean up task pool
        self.task_pool.deinit();

        if (self.resolver) |*r| r.deinit();

        // Free the Runtime allocation
        if (self.own_self) {
            allocator.destroy(self);
        }
    }

    // High-level public API
    pub fn spawn(self: *Runtime, func: anytype, args: std.meta.ArgsTuple(@TypeOf(func))) !JoinHandle(meta.ReturnType(func)) {
        const Result = meta.ReturnType(func);
        const Args = @TypeOf(args);

        const Wrapper = struct {
            fn start(ctx: *const anyopaque, result: *anyopaque) void {
                const a: *const Args = @ptrCast(@alignCast(ctx));
                const r: *Result = @ptrCast(@alignCast(result));
                r.* = @call(.auto, func, a.*);
            }
        };

        const task = try spawnTask(
            self,
            @sizeOf(Result),
            .fromByteUnits(@alignOf(Result)),
            std.mem.asBytes(&args),
            .fromByteUnits(@alignOf(Args)),
            .{ .regular = &Wrapper.start },
            null,
        );

        return JoinHandle(Result){
            .awaitable = &task.awaitable,
            .result = undefined,
        };
    }

    pub fn spawnBlocking(self: *Runtime, func: anytype, args: std.meta.ArgsTuple(@TypeOf(func))) !JoinHandle(meta.ReturnType(func)) {
        const Result = meta.ReturnType(func);
        const Args = @TypeOf(args);

        const Wrapper = struct {
            fn start(ctx: *const anyopaque, result: *anyopaque) void {
                const a: *const Args = @ptrCast(@alignCast(ctx));
                const r: *Result = @ptrCast(@alignCast(result));
                r.* = @call(.always_inline, func, a.*);
            }
        };

        const task = try spawnBlockingTask(
            self,
            @sizeOf(Result),
            .fromByteUnits(@alignOf(Result)),
            std.mem.asBytes(&args),
            .fromByteUnits(@alignOf(Args)),
            .{ .regular = &Wrapper.start },
            null,
        );

        return JoinHandle(Result){
            .awaitable = &task.awaitable,
            .result = undefined,
        };
    }

    /// Worker thread entry point. Initializes executor and runs until stopped.
    /// Signals worker.ready after initialization (success or failure).
    fn runWorker(self: *Runtime, worker: *Worker, id: u6) void {
        worker.executor.init(self, id) catch |e| {
            worker.err = e;
            worker.ready.set();
            return;
        };
        defer worker.executor.deinit();

        worker.ready.set();

        var backoff = Duration.fromMilliseconds(10);
        const max_backoff = Duration.fromMilliseconds(1000);

        while (true) {
            worker.executor.run(.until_stopped) catch |e| {
                if (self.shutting_down.load(.acquire)) break;
                log.err("Worker executor error: {}, retrying in {f}", .{ e, backoff });
                os.time.sleep(backoff);
                backoff = .{ .value = @min(backoff.value *| 2, max_backoff.value) };
                continue;
            };
            break;
        }
    }

    // Convenience methods that operate on the current coroutine context
    // These delegate to the current executor automatically
    // Most are no-op if not called from within a coroutine

    /// Cooperatively yield control to allow other tasks to run.
    /// The current task will be rescheduled and continue execution later.
    /// Can be called from the main thread or from within a coroutine.
    /// If called from a thread without an executor, yields the OS thread.
    /// Deprecated: use zio.yield() instead.
    pub fn yield(_: *Runtime) Cancelable!void {
        return mod.yield();
    }

    /// Sleep for the specified number of milliseconds.
    /// Returns error.Canceled if the task was canceled during sleep.
    /// Deprecated: use zio.sleep() instead.
    pub fn sleep(_: *Runtime, duration: Duration) Cancelable!void {
        return mod.sleep(duration);
    }

    /// Begin a cancellation shield to prevent being canceled during critical sections.
    /// Deprecated: use zio.beginShield() instead.
    pub fn beginShield(_: *Runtime) void {
        mod.beginShield();
    }

    /// End a cancellation shield.
    /// Deprecated: use zio.endShield() instead.
    pub fn endShield(_: *Runtime) void {
        mod.endShield();
    }

    /// Check if cancellation has been requested and return error.Canceled if so.
    /// This consumes the cancellation flag.
    /// Use this after endShield() to detect cancellation that occurred during the shielded section.
    /// Deprecated: use zio.checkCancel() instead.
    pub fn checkCancel(_: *Runtime) Cancelable!void {
        return mod.checkCancel();
    }

    /// Get the current monotonic timestamp.
    /// This uses the event loop's cached time for efficiency.
    /// Deprecated: use zio.now() instead.
    pub fn now(_: *Runtime) Timestamp {
        return mod.now();
    }

    /// Construct a `std.Io` instance backed by this runtime.
    pub fn io(self: *Runtime) std.Io {
        return @import("io.zig").fromRuntime(self);
    }

    /// Recover the `*Runtime` from a `std.Io` produced by `Runtime.io()`.
    pub fn fromIo(value: std.Io) *Runtime {
        return @import("io.zig").toRuntime(value);
    }
};

test "runtime: spawnBlocking smoke test" {
    const runtime = try Runtime.init(std.testing.allocator, .{
        .thread_pool = .{},
    });
    defer runtime.deinit();

    const blockingWork = struct {
        fn call(x: i32) i32 {
            return x * 2;
        }
    }.call;

    var handle = try runtime.spawnBlocking(blockingWork, .{21});
    defer handle.cancel();

    const result = handle.join();
    try std.testing.expectEqual(42, result);
}

test "Runtime: implicit run" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    const start = runtime.now();
    try std.testing.expect(start.value > 0);

    try runtime.sleep(.fromMilliseconds(10));

    const end = runtime.now();
    try std.testing.expect(end.value > start.value);
    try std.testing.expect(start.durationTo(end).toMilliseconds() >= 10);
}

test "Runtime: sleep from main" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    // Call sleep directly from main thread - no spawn needed
    const start = runtime.now();
    try runtime.sleep(.fromMilliseconds(10));
    const end = runtime.now();

    try std.testing.expect(end.value > start.value);
    try std.testing.expect(start.durationTo(end).toMilliseconds() >= 10);
}

test "runtime: spawnBlocking does not leak with a large result" {
    const runtime = try Runtime.init(std.testing.allocator, .{ .thread_pool = .{} });
    defer runtime.deinit();

    // Regression test for a blocking-task refcount leak. A large result forces
    // TaskPool.alloc down the direct allocator path (size > pool_item_size), so
    // the leaked allocation is reported by testing.allocator. With a small (e.g.
    // i32) result the task is pool-allocated and the leak is masked by
    // pool.deinit freeing the pool's backing buffer -- which is why the existing
    // smoke test did not catch it.
    const blockingWork = struct {
        fn call(x: u8) [4000]u8 {
            return [_]u8{x} ** 4000;
        }
    }.call;

    var handle = try runtime.spawnBlocking(blockingWork, .{@as(u8, 7)});
    const result = handle.join();
    try std.testing.expectEqual(@as(u8, 7), result[0]);
}

test "runtime: basic sleep" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    try runtime.sleep(.fromMilliseconds(1));
}

test "runtime: now() returns monotonic time" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    const start = runtime.now();
    try std.testing.expect(start.value > 0);

    // Sleep to ensure time advances
    try runtime.sleep(.fromMilliseconds(10));

    const end = runtime.now();
    try std.testing.expect(end.value > start.value);
    try std.testing.expect(start.durationTo(end).toMilliseconds() >= 10);
}

test "runtime: sleep is cancelable" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    const sleepingTask = struct {
        fn call(rt: *Runtime) !void {
            // This will sleep for 1 second but should be canceled before completion
            try rt.sleep(.fromMilliseconds(1000));
            // Should not reach here
            return error.TestUnexpectedResult;
        }
    }.call;

    var timer = time.Stopwatch.start();

    var handle = try runtime.spawn(sleepingTask, .{runtime});
    defer handle.cancel();

    // Cancel the sleeping task
    handle.cancel();

    // Should return error.Canceled
    const result = handle.join();
    try std.testing.expectError(error.Canceled, result);

    // Ensure the sleep was canceled before completion
    try std.testing.expect(timer.read().toMilliseconds() <= 500);
}

test "runtime: shielded sleep is not cancelable" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    const shieldedSleepTask = struct {
        fn call(rt: *Runtime) !void {
            rt.beginShield();
            defer rt.endShield();
            // This sleep should complete even when canceled because it's shielded
            try rt.sleep(.fromMilliseconds(50));
        }
    }.call;

    var timer = time.Stopwatch.start();

    var handle = try runtime.spawn(shieldedSleepTask, .{runtime});
    defer handle.cancel();

    // Wait a bit to ensure the task is actually in the waiting state
    try runtime.sleep(.fromMilliseconds(10));

    // Try to cancel the sleeping task
    handle.cancel();

    // Should complete successfully (not canceled) because the sleep was shielded
    const result = handle.join();
    try std.testing.expectEqual({}, result);

    // Ensure the sleep completed (took at least 50ms)
    try std.testing.expect(timer.read().toMilliseconds() >= 40);
}

test "runtime: yield from main allows tasks to run" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    var counter: usize = 0;

    const yieldingTask = struct {
        fn call(counter_ptr: *usize) !void {
            for (0..10) |_| {
                counter_ptr.* += 1;
                try yield();
            }
        }
    }.call;

    var handle = try runtime.spawn(yieldingTask, .{&counter});
    defer handle.cancel();

    // Instead of join(), use yield() from main to let the task run
    var iterations: usize = 0;
    while (counter < 10) : (iterations += 1) {
        if (iterations >= 100) {
            std.debug.print("yield from main not working: counter={}, iterations={}\n", .{ counter, iterations });
            return error.TestExpectedEqual;
        }
        try yield();
    }

    try std.testing.expectEqual(10, counter);
}

test "runtime: yield without an executor is a no-op" {
    // No Runtime has been initialized on this thread, so there's no current
    // executor. yield() should just fall back to an OS thread yield and return.
    try yield();
}

test "runtime: maybeYield without an executor is a no-op" {
    // Same as above, but for the fairness-checked variant.
    try maybeYield();
}

test "runtime: maybeYield yields once the ready queue crosses the fairness threshold" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    const ResetEvent = @import("sync/ResetEvent.zig");

    var event: ResetEvent = .init;
    var counter: usize = 0;

    const waiterTask = struct {
        fn call(reset_event: *ResetEvent, counter_ptr: *usize) !void {
            try reset_event.wait();
            counter_ptr.* += 1;
        }
    }.call;

    // Spawn more waiters than Executor.yield_ready_threshold so that, once they're
    // all woken at once, ready_count is high enough for maybeYield() to actually
    // reschedule instead of no-op.
    const task_count = Executor.yield_ready_threshold + 5;

    var group: Group = .init;
    defer group.cancel();

    for (0..task_count) |_| {
        try group.spawn(waiterTask, .{ &event, &counter });
    }

    // Every task is now parked in event.wait(), so waking them all at once fills
    // the ready queue past the fairness threshold.
    event.set();

    var iterations: usize = 0;
    while (counter < task_count) : (iterations += 1) {
        if (iterations >= 100) {
            std.debug.print("maybeYield not working: counter={}, iterations={}\n", .{ counter, iterations });
            return error.TestExpectedEqual;
        }
        try maybeYield();
    }

    try std.testing.expectEqual(task_count, counter);
    try group.wait();
    try std.testing.expect(!group.hasFailed());
}

test "runtime: sleep from main allows tasks to run" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    var counter: usize = 0;

    const yieldingTask = struct {
        fn call(counter_ptr: *usize) !void {
            for (0..10) |_| {
                counter_ptr.* += 1;
                try yield();
            }
        }
    }.call;

    var handle = try runtime.spawn(yieldingTask, .{&counter});
    defer handle.cancel();

    // Instead of join(), use sleep() from main to let the task run
    var iterations: usize = 0;
    while (counter < 10) : (iterations += 1) {
        if (iterations >= 100) {
            std.debug.print("sleep from main not working: counter={}, iterations={}\n", .{ counter, iterations });
            return error.TestExpectedEqual;
        }
        try runtime.sleep(.fromMilliseconds(1));
    }

    try std.testing.expectEqual(10, counter);
}

test "runtime: multi-threaded execution with 2 executors" {
    const runtime = try Runtime.init(std.testing.allocator, .{ .executors = .exact(2) });
    defer runtime.deinit();

    const TestContext = struct {
        var counter: usize = 0;

        fn task(rt: *Runtime) !void {
            try rt.sleep(.fromMilliseconds(10));
            _ = @atomicRmw(usize, &counter, .Add, 1, .monotonic);
        }
    };

    TestContext.counter = 0;

    var group: Group = .init;
    defer group.cancel();

    for (0..4) |_| {
        try group.spawn(TestContext.task, .{runtime});
    }

    try group.wait();
    try std.testing.expect(!group.hasFailed());

    try std.testing.expectEqual(4, TestContext.counter);
}

test "runtime: multi-threaded execution with 64 executors" {
    const runtime = try Runtime.init(std.testing.allocator, .{ .executors = .exact(64) });
    defer runtime.deinit();

    try std.testing.expectEqual(64, runtime.executors.items.len);
}

test "Runtime: multi-threaded with task migration" {
    const runtime = try Runtime.init(std.testing.allocator, .{ .executors = .exact(8) });
    defer runtime.deinit();

    const ResetEvent = @import("sync/ResetEvent.zig");

    const TestContext = struct {
        group: *Group,
        done: ResetEvent = .{},
        counter: std.atomic.Value(u32) = .init(0),

        fn task(ctx: *@This(), parent: *ResetEvent) !void {
            parent.set();

            const n = ctx.counter.fetchAdd(1, .acquire);
            if (n >= 99) {
                ctx.done.set();
                return;
            }

            var event: ResetEvent = .{};
            ctx.group.spawn(task, .{ ctx, &event }) catch |err| {
                std.debug.print("task migration failed: {}\n", .{err});
                return err;
            };
            event.wait() catch |err| {
                std.debug.print("event wait failed: {}\n", .{err});
                return err;
            };
        }
    };

    var group: Group = .init;
    defer group.cancel();

    var ctx: TestContext = .{ .group = &group };

    var event: ResetEvent = .{};

    try group.spawn(TestContext.task, .{ &ctx, &event });

    try ctx.done.wait();

    try group.wait();
    try std.testing.expect(!group.hasFailed());

    try std.testing.expectEqual(100, ctx.counter.load(.acquire));
}

test "runtime: wake-before-park awaken bit stress (single executor)" {
    try wakeBeforeParkStress(1);
}

test "runtime: wake-before-park awaken bit stress (two executors)" {
    try wakeBeforeParkStress(2);
}

fn wakeBeforeParkStress(executor_count: u6) !void {
    const ResetEvent = @import("sync/ResetEvent.zig");

    const runtime = try Runtime.init(std.testing.allocator, .{
        .executors = .exact(executor_count),
    });
    defer runtime.deinit();

    const Ctx = struct {
        // Number of ping-pong iterations to exercise the wake-before-park window.
        const iterations: u32 = 10_000;

        ping: ResetEvent = .{},
        pong: ResetEvent = .{},
        counter: std.atomic.Value(u32) = .init(0),

        // Waits on ping each iteration — this is the task that parks, and the one
        // whose awaken bit gets set when the waker fires between the condition check
        // and the actual park CAS in processCleanup.park.
        fn parker(ctx: *@This()) !void {
            for (0..iterations) |_| {
                try ctx.ping.wait();
                ctx.ping.reset();
                _ = ctx.counter.fetchAdd(1, .release);
                ctx.pong.set();
            }
        }

        // Fires ping immediately each iteration, without waiting for parker to park first.
        // With two executors this races directly with the park CAS, exercising the path
        // where scheduleTask sets awaken=true on a .ready task and processCleanup.park
        // consumes the token instead of transitioning to .waiting.
        fn waker(ctx: *@This()) !void {
            for (0..iterations) |_| {
                ctx.ping.set();
                try ctx.pong.wait();
                ctx.pong.reset();
            }
        }
    };

    var ctx: Ctx = .{};
    var group: Group = .init;
    defer group.cancel();

    try group.spawn(Ctx.parker, .{&ctx});
    try group.spawn(Ctx.waker, .{&ctx});

    try group.wait();
    try std.testing.expect(!group.hasFailed());
    // Any lost wake would cause parker to hang in ping.wait() forever — group.wait()
    // would never return. The counter confirms all iterations ran to completion.
    try std.testing.expectEqual(Ctx.iterations, ctx.counter.load(.acquire));
}

test "runtime: mutex contention with task migration" {
    const Mutex = @import("sync/Mutex.zig");

    const runtime = try Runtime.init(std.testing.allocator, .{ .executors = .exact(2) });
    defer runtime.deinit();

    var mutex: Mutex = .init;
    var counter: u32 = 0;

    const Worker = struct {
        fn run(m: *Mutex, c: *u32) !void {
            for (0..1_000) |_| {
                try m.lock();
                defer m.unlock();
                c.* += 1;
            }
        }
    };

    var group: Group = .init;
    defer group.cancel();

    try group.spawn(Worker.run, .{ &mutex, &counter });
    try group.spawn(Worker.run, .{ &mutex, &counter });

    try group.wait();
    try std.testing.expect(!group.hasFailed());
    try std.testing.expectEqual(2_000, counter);
}

test "runtime: disable main executor" {
    if (builtin.single_threaded) return error.SkipZigTest;

    // Create a runtime where the calling thread is not an executor.
    // All tasks run on background worker threads.
    const runtime = try Runtime.init(std.testing.allocator, .{
        .executors = .exact(2),
        .enable_main_executor = false,
    });
    defer runtime.deinit();

    const compute = struct {
        fn call(x: i32) i32 {
            return x * 2;
        }
    }.call;

    // Spawn tasks and join from the non-executor calling thread.
    // join() blocks via OS futex when called outside an executor context.
    var handle = try runtime.spawn(compute, .{21});
    const result = handle.join();
    try std.testing.expectEqual(42, result);
}
