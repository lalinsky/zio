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
const Timeoutable = @import("common.zig").Timeoutable;
const time = @import("time.zig");
const Duration = time.Duration;
const Timestamp = time.Timestamp;

const Coroutine = @import("coro/coroutines.zig").Coroutine;
const Context = @import("coro/coroutines.zig").Context;
const StackPool = @import("coro/stack_pool.zig").StackPool;
const StackPoolConfig = @import("coro/stack_pool.zig").Config;
const setupStackGrowth = @import("coro/stack.zig").setupStackGrowth;
const cleanupStackGrowth = @import("coro/stack.zig").cleanupStackGrowth;

const RefCounter = @import("utils/ref_counter.zig").RefCounter;

const AnyTask = @import("runtime/task.zig").AnyTask;
const TaskPool = @import("runtime/task.zig").TaskPool;
const spawnTask = @import("runtime/task.zig").spawnTask;
const AnyBlockingTask = @import("runtime/blocking_task.zig").AnyBlockingTask;
const spawnBlockingTask = @import("runtime/blocking_task.zig").spawnBlockingTask;
const AutoCancel = @import("runtime/autocancel.zig").AutoCancel;
const Group = @import("runtime/group.zig").Group;
const unregisterGroupTask = @import("runtime/group.zig").unregisterGroupTask;

const select = @import("select.zig");
const Futex = @import("sync/Futex.zig");
const waitForIo = @import("common.zig").waitForIo;

/// Number of executor threads to run (including main).
pub const ExecutorCount = enum(u6) {
    /// Auto-detect based on CPU count
    auto = 0,
    _,

    /// Create an exact executor count (1 = single-threaded, no worker threads)
    pub fn exact(n: u6) ExecutorCount {
        return @enumFromInt(n);
    }

    pub fn resolve(self: ExecutorCount) u6 {
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
        .maximum_size = 8 * 1024 * 1024, // 8MB reserved
        .committed_size = 64 * 1024, // 64KB initial commit
        .max_unused_stacks = 16,
        .max_age = .fromSeconds(60),
    },
    /// Number of executor threads to run (including main).
    executors: ExecutorCount = .exact(1),
    /// Enable LIFO slot optimization for cache locality.
    /// When enabled, tasks woken by other tasks are placed in a LIFO slot
    /// for immediate execution, improving cache locality.
    /// Enabled by default as it also maintains backward-compatible timing
    /// (woken tasks run immediately instead of being deferred to next batch).
    lifo_slot_enabled: bool = true,
};

const Awaitable = @import("runtime/awaitable.zig").Awaitable;

// Public handle for spawned tasks and futures
pub fn JoinHandle(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const Result = T;

        awaitable: ?*Awaitable,
        result: T,

        /// Helper to get result from awaitable and release it
        fn finishAwaitable(self: *Self, rt: *Runtime, awaitable: *Awaitable) void {
            self.result = awaitable.getTypedResult(T);
            awaitable.release(rt);
            self.awaitable = null;
        }

        /// Wait for the task to complete and return its result.
        ///
        /// If the current task is canceled while waiting, the spawned task will be canceled too.
        ///
        /// Example:
        /// ```zig
        /// var handle = try rt.spawn(myTask, .{});
        /// const result = handle.join(rt);
        /// ```
        pub fn join(self: *Self, rt: *Runtime) T {
            // If awaitable is null, result is already cached
            const awaitable = self.awaitable orelse return self.result;

            // Wait for completion
            _ = select.waitUntilComplete(rt, awaitable);

            // Get result and release awaitable
            self.finishAwaitable(rt, awaitable);
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

        /// Registers a wait node to be notified when the task completes.
        /// This is part of the Future protocol for select().
        /// Returns false if the task is already complete (no wait needed), true if added to queue.
        pub fn asyncWait(self: Self, rt: *Runtime, wait_node: *WaitNode) bool {
            if (self.awaitable) |awaitable| {
                return awaitable.asyncWait(rt, wait_node);
            }
            return false; // Already complete
        }

        /// Cancels a pending wait operation by removing the wait node.
        /// This is part of the Future protocol for select().
        pub fn asyncCancelWait(self: Self, rt: *Runtime, wait_node: *WaitNode) void {
            if (self.awaitable) |awaitable| {
                awaitable.asyncCancelWait(rt, wait_node);
            }
        }

        /// Request cancellation and wait for the task to complete.
        ///
        /// Safe to call after `join()` - typically used in defer for cleanup.
        ///
        /// Example:
        /// ```zig
        /// var handle = try rt.spawn(myTask, .{});
        /// defer handle.cancel(rt);
        /// // Do some other work that could return early
        /// const result = handle.join(rt);
        /// // cancel() in defer is a no-op since join() already completed
        /// ```
        pub fn cancel(self: *Self, rt: *Runtime) void {
            // If awaitable is null, already completed/detached - no-op
            const awaitable = self.awaitable orelse return;

            // If already done, just clean up
            if (awaitable.hasResult()) {
                self.finishAwaitable(rt, awaitable);
                return;
            }

            // Request cancellation
            awaitable.cancel();

            // Wait for completion
            _ = select.waitUntilComplete(rt, awaitable);

            // Get result and release awaitable
            self.finishAwaitable(rt, awaitable);
        }

        /// Detach the task, allowing it to run in the background.
        ///
        /// After detaching, the result is no longer retrievable.
        ///
        /// Example:
        /// ```zig
        /// var handle = try rt.spawn(backgroundTask, .{});
        /// handle.detach(rt); // Task runs independently
        /// ```
        pub fn detach(self: *Self, rt: *Runtime) void {
            // If awaitable is null, already detached - no-op
            const awaitable = self.awaitable orelse return;

            awaitable.release(rt);
            self.awaitable = null;
            self.result = undefined;
        }

        /// Cast this JoinHandle to a different error set while keeping the same payload type.
        /// This is safe because all error sets have the same runtime representation (u16).
        /// The payload type must remain unchanged.
        /// This is a move operation - the original handle is consumed.
        ///
        /// Example: JoinHandle(MyError!i32) can be cast to JoinHandle(anyerror!i32)
        pub fn cast(self: Self, comptime T2: type) JoinHandle(T2) {
            assert(self.awaitable != null);
            const P1 = meta.Payload(T);
            const P2 = meta.Payload(T2);
            if (P1 != P2) {
                @compileError("cast() can only change error set, not payload type. " ++
                    "Source payload: " ++ @typeName(P1) ++ ", target payload: " ++ @typeName(P2));
            }

            return JoinHandle(T2){
                .awaitable = self.awaitable,
                .result = undefined,
            };
        }
    };
}

// Generic data structures (private)
const WaitNode = @import("runtime/WaitNode.zig");
const ConcurrentStack = @import("utils/concurrent_stack.zig").ConcurrentStack;
const WaitQueue = @import("utils/wait_queue.zig").WaitQueue;
const SimpleStack = @import("utils/simple_stack.zig").SimpleStack;
const SimpleQueue = @import("utils/simple_queue.zig").SimpleQueue;

comptime {
    std.debug.assert(@alignOf(WaitNode) == 8);
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
    current_coroutine: ?*Coroutine = null,

    ready_queue: SimpleQueue(WaitNode) = .{},

    // LIFO slot optimization: when a task wakes another task, the woken task
    // is placed here for immediate execution, improving cache locality.
    // This is checked before ready_queue when selecting the next task to run.
    lifo_slot: ?*WaitNode = null,

    // Controls whether LIFO slot optimization is enabled.
    // When disabled, all wakeups go to next_ready_queue (deferred to next batch).
    // Initialized from RuntimeOptions.lifo_slot_enabled (default: true).
    lifo_slot_enabled: bool = true,

    // Tracks consecutive polls from LIFO slot to prevent starvation.
    // Reset when we poll from ready_queue instead.
    lifo_slot_used: u8 = 0,

    // Tracks tasks run since last event loop tick.
    // After EVENT_INTERVAL tasks, getNextTask() returns null to force I/O processing.
    tick_task_count: u8 = 0,

    // Tracks tasks waiting in ready_queue + lifo_slot + next_ready_queue.
    // Used by maybeYield to decide whether to yield based on pending work.
    ready_count: u32 = 0,

    // Timestamp of last event loop tick, used for time-based yield decisions.
    last_tick_time: Timestamp = .zero,

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

    // Executor dedicated to this thread
    pub threadlocal var current: ?*Executor = null;

    /// Get the Executor instance from any coroutine that belongs to it.
    /// Coroutines have parent_context_ptr pointing to main_task.coro.context,
    /// so we navigate: context -> coro -> main_task -> executor
    pub fn fromCoroutine(coro: *Coroutine) *Executor {
        const main_coro: *Coroutine = @fieldParentPtr("context", coro.parent_context_ptr);
        const main_task: *AnyTask = @fieldParentPtr("coro", main_coro);
        return @fieldParentPtr("main_task", main_task);
    }

    pub fn init(self: *Executor, runtime: *Runtime, id: u6) !void {
        self.* = .{
            .id = id,
            .loop = undefined,
            .lifo_slot_enabled = runtime.options.lifo_slot_enabled,
            .runtime = runtime,
            .shutdown = ev.Async.init(),
        };

        // Initialize main_task - this serves as both the scheduler context and
        // the task context for async operations called from main.
        // main_task.coro.context is where spawned tasks yield back to.
        self.main_task = .{
            .state = std.atomic.Value(AnyTask.State).init(.ready),
            .awaitable = .{
                .kind = .task,
                .wait_node = .{
                    .vtable = &AnyTask.wait_node_vtable,
                },
            },
            .coro = .{
                .parent_context_ptr = &self.main_task.coro.context, // points to itself
            },
            .closure = undefined, // main_task has no closure
        };

        try setupStackGrowth();
        errdefer cleanupStackGrowth();

        try self.loop.init(.{
            .allocator = self.runtime.allocator,
            .thread_pool = &self.runtime.thread_pool,
            .defer_callbacks = false,
        });
        errdefer self.loop.deinit();

        // Register shutdown handle to keep loop active and enable cross-thread shutdown
        self.shutdown.c.callback = shutdownCallback;
        self.loop.add(&self.shutdown.c);

        std.debug.assert(Executor.current == null);
        Executor.current = self;
    }

    pub fn deinit(self: *Executor) void {
        std.debug.assert(Executor.current == self);
        Executor.current = null;

        self.loop.deinit();

        cleanupStackGrowth();
    }

    fn shutdownCallback(loop: *ev.Loop, _: *ev.Completion) void {
        loop.stop();
    }

    pub const YieldCancelMode = enum { allow_cancel, no_cancel };

    /// Cooperatively yield control to other tasks.
    ///
    /// Suspends the current coroutine and allows other tasks to run. The coroutine
    /// will be rescheduled according to `desired_state`:
    /// - `.ready`: Reschedule immediately (cooperative yielding)
    /// - `.waiting`: Suspend until resumed (I/O, sync primitives, timeout, cancellation, etc.)
    ///
    /// ## Cancellation Mode
    ///
    /// The `cancel_mode` parameter is comptime and determines the return type:
    ///
    /// - `.allow_cancel`: Checks cancellation flag before and after yielding.
    ///   Returns `Cancelable!void` (may return `error.Canceled`).
    ///   Use for normal yields where cancellation should be propagated.
    ///
    /// - `.no_cancel`: Ignores cancellation flag completely.
    ///   Returns `void` (never fails, no error handling needed).
    ///   Use in critical sections where cancellation would break invariants
    ///   (e.g., lock-free algorithms, while holding locks).
    ///
    /// Using `.no_cancel` prevents interruption during critical operations but
    /// should be used sparingly as it delays cancellation response.
    pub fn yield(self: *Executor, expected_state: AnyTask.State, desired_state: AnyTask.State, comptime cancel_mode: YieldCancelMode) if (cancel_mode == .allow_cancel) Cancelable!void else void {
        const is_main = self.current_coroutine == null;
        const current_task = if (is_main) &self.main_task else AnyTask.fromCoroutine(self.current_coroutine.?);

        // Check and consume cancellation flag before yielding (unless no_cancel)
        if (cancel_mode == .allow_cancel) {
            try current_task.checkCancel();
        }

        // Atomically transition state - if this fails, someone changed our state
        if (current_task.state.cmpxchgStrong(expected_state, desired_state, .release, .acquire)) |actual_state| {
            // CAS failed - someone changed our state
            if (actual_state == .ready) {
                // We were woken up before we could yield - don't suspend
                return;
            } else {
                // Unexpected state - this is a bug
                std.debug.panic("Yield CAS failed with unexpected state: task {*} expected {} but was {} (not .ready)", .{ current_task, expected_state, actual_state });
            }
        }
        // If yielding with .ready state (cooperative yield), schedule for later execution
        // This bypasses LIFO slot for fairness - yields always go to back of queue
        // main_task is never queued - it just checks state in run()
        if (desired_state == .ready and !is_main) {
            self.scheduleTaskLocal(current_task, true); // is_yield = true
        }

        if (is_main) {
            // Main: always use scheduler loop (no direct scheduling)
            self.run(.until_ready) catch |err| {
                std.debug.panic("Event loop error during yield: {}", .{err});
            };
        } else {
            // Spawned task: try direct scheduling via yieldTo
            const current_coro = &current_task.coro;
            if (self.getNextTask()) |next_wait_node| {
                const next_task = AnyTask.fromWaitNode(next_wait_node);
                self.current_coroutine = &next_task.coro;
                current_coro.yieldTo(&next_task.coro);
            } else {
                // No ready tasks: return to scheduler
                current_coro.yield();
            }
        }

        // After resuming, the task may have migrated to a different executor.
        if (!is_main) {
            const resumed_executor = Executor.current orelse unreachable;
            std.debug.assert(resumed_executor.current_coroutine == &current_task.coro);
        }

        // Check after resuming in case we were canceled while suspended (unless no_cancel)
        if (cancel_mode == .allow_cancel) {
            try current_task.checkCancel();
        }
    }

    /// Yield to other tasks only if many are waiting, to balance fairness vs. context-switch overhead.
    const yield_ready_threshold = 13;

    pub fn maybeYield(self: *Executor, expected_state: AnyTask.State, desired_state: AnyTask.State, comptime cancel_mode: YieldCancelMode) if (cancel_mode == .allow_cancel) Cancelable!void else void {
        if (self.ready_count >= yield_ready_threshold) {
            return self.yield(expected_state, desired_state, cancel_mode);
        }
    }

    pub fn getCurrentTask(self: *Executor) *AnyTask {
        if (std.debug.runtime_safety) {
            std.debug.assert(current == self);
        }
        if (self.current_coroutine) |coro| {
            return AnyTask.fromCoroutine(coro);
        } else {
            return &self.main_task;
        }
    }

    pub const RunMode = enum {
        /// Run until main_task.state becomes .ready.
        /// Caller must set up the state before calling (e.g., .waiting for I/O).
        until_ready,
        /// Run until all tasks complete (task_count reaches 0).
        /// Sets main_task.state to .new, which is transitioned to .ready by onTaskComplete.
        until_idle,
        /// Run until explicitly stopped via loop.stop().
        /// Used for worker executor threads.
        until_stopped,
    };

    /// Run the executor event loop.
    pub fn run(self: *Executor, mode: RunMode) !void {
        std.debug.assert(Executor.current == self);

        switch (mode) {
            .until_ready => {},
            .until_idle => {
                // Set state to .new first to avoid race with onTaskComplete.
                // If the last task completes between our check and state change,
                // its CAS(.new, .ready) will succeed and wake us.
                self.main_task.state.store(.new, .release);
                // If no tasks, restore state and return
                if (self.runtime.task_count.load(.acquire) == 0) {
                    self.main_task.state.store(.ready, .release);
                    return;
                }
            },
            .until_stopped => {},
        }

        const check_ready = mode != .until_stopped;

        while (true) {
            // Process ready coroutines
            while (self.getNextTask()) |wait_node| {
                const task = AnyTask.fromWaitNode(wait_node);

                self.current_coroutine = &task.coro;
                defer self.current_coroutine = null;

                task.coro.step();

                // Handle finished coroutines
                if (self.current_coroutine) |current_coro| {
                    if (current_coro.finished) {
                        const current_task = AnyTask.fromCoroutine(current_coro);
                        const current_awaitable = &current_task.awaitable;

                        // Release stack immediately
                        if (current_coro.context.stack_info.allocation_len > 0) {
                            self.runtime.stack_pool.release(current_coro.context.stack_info, self.loop.now());
                            current_coro.context.stack_info.allocation_len = 0;
                        }

                        self.runtime.onTaskComplete(current_awaitable);
                    }
                }
            }

            // Exit if loop is stopped
            if (self.loop.stopped()) {
                return;
            }

            // Drain remote ready queue (cross-thread tasks) after processing current queue
            var drained = self.next_ready_queue_remote.popAll();
            while (drained.pop()) |task| {
                self.ready_queue.push(task);
                self.ready_count += 1;
            }

            // Run event loop - non-blocking if there's work, otherwise wait for I/O
            const main_ready = check_ready and self.main_task.state.load(.acquire) == .ready;
            const has_work = self.ready_queue.head != null or self.lifo_slot != null or main_ready;
            try self.loop.run(if (has_work) .no_wait else .once);

            // Reset task counter and update tick time after event loop tick
            self.tick_task_count = 0;
            self.last_tick_time = self.loop.now();

            // Check again after I/O
            if (check_ready and self.main_task.state.load(.acquire) == .ready) {
                return;
            }
        }
    }

    /// Get the next task to run, checking LIFO slot first for cache locality.
    ///
    /// The LIFO slot is checked first (when enabled) because recently woken tasks
    /// are likely cache-hot. However, we limit consecutive LIFO polls to prevent
    /// starvation of tasks in ready_queue.
    ///
    /// Returns null if no tasks are available, or if EVENT_INTERVAL tasks have
    /// been run since the last event loop tick (to ensure I/O responsiveness).
    fn getNextTask(self: *Executor) ?*WaitNode {
        // Maximum tasks to run before forcing an event loop tick (from Go's scheduler)
        const EVENT_INTERVAL = 61;

        // Force event loop tick after running EVENT_INTERVAL tasks
        if (self.tick_task_count >= EVENT_INTERVAL) {
            return null;
        }

        // LIFO slot optimization: check LIFO slot first for cache locality
        // But limit consecutive LIFO polls to prevent starvation of ready_queue tasks
        const MAX_LIFO_POLLS_PER_TICK = 3;

        if (self.lifo_slot_enabled) {
            if (self.lifo_slot_used < MAX_LIFO_POLLS_PER_TICK) {
                // Under starvation limit - can use LIFO slot
                if (self.lifo_slot) |task| {
                    self.lifo_slot = null;
                    self.lifo_slot_used += 1;
                    self.tick_task_count += 1;
                    self.ready_count -= 1;
                    return task;
                }
            } else {
                // Hit starvation limit - move LIFO slot task to ready_queue (back of FIFO)
                // This gives other ready_queue tasks a chance to run first
                if (self.lifo_slot) |task| {
                    self.lifo_slot = null;
                    self.ready_queue.push(task);
                    // Don't reset counter - only reset when we actually poll from ready_queue
                    // Note: ready_count stays the same (moved from lifo_slot to ready_queue)
                }
            }
        }

        // Take from ready_queue
        if (self.ready_queue.pop()) |task| {
            self.lifo_slot_used = 0; // Reset LIFO starvation counter
            self.tick_task_count += 1;
            self.ready_count -= 1;
            return task;
        }

        return null;
    }

    /// Schedule a task to the current executor's local queue.
    /// This must only be called when we're on the correct executor thread.
    ///
    /// The `is_yield` parameter determines scheduling behavior:
    /// - `true`: Task is yielding - goes to ready_queue (FIFO, bypasses LIFO slot)
    /// - `false`: Task is being woken - goes to LIFO slot (immediate) or ready_queue (FIFO)
    fn scheduleTaskLocal(self: *Executor, task: *AnyTask, is_yield: bool) void {
        const wait_node = &task.awaitable.wait_node;
        if (std.debug.runtime_safety) {
            std.debug.assert(!wait_node.in_list);
        }
        if (is_yield or !self.lifo_slot_enabled) {
            // Yields bypass LIFO slot for fairness, go to back of ready_queue
            // LIFO disabled also uses ready_queue (FIFO, fair scheduling)
            self.ready_queue.push(wait_node);
            self.ready_count += 1;
        } else {
            // LIFO enabled - try LIFO slot for cache locality
            if (self.lifo_slot) |old_task| {
                // LIFO slot occupied - displaced task goes to ready_queue (FIFO)
                self.ready_queue.push(old_task);
            }
            // New task takes the LIFO slot (runs immediately, cache-hot)
            self.lifo_slot = wait_node;
            self.ready_count += 1;
        }
    }

    /// Schedule a task to a remote executor (different executor or no current executor).
    /// Uses the thread-safe remote queue and notifies the executor.
    fn scheduleTaskRemote(self: *Executor, task: *AnyTask) void {
        const wait_node = &task.awaitable.wait_node;
        if (std.debug.runtime_safety) {
            std.debug.assert(!wait_node.in_list);
        }

        // Push to remote ready queue (thread-safe)
        self.next_ready_queue_remote.push(wait_node);

        // Wake the target executor's event loop (only if initialized)
        self.loop.wake();
    }

    /// Schedule a task for execution. Called on the task's home executor (self).
    /// Atomically transitions task state to .ready and schedules it for execution.
    /// May migrate the task to the current executor for cache locality.
    pub fn scheduleTask(self: *Executor, task: *AnyTask) void {
        const old_state = task.state.swap(.ready, .acq_rel);

        // Task hasn't yielded yet - it will see .ready and skip the yield
        if (old_state == .preparing_to_wait) return;

        // Task already transitioned to .ready by another thread - avoid double-schedule
        if (old_state == .ready) return;

        // Validate state transitions
        if (old_state != .new and old_state != .waiting) {
            std.debug.panic("scheduleTask: unexpected state {} for task {*}", .{ old_state, task });
        }

        // main_task is never queued - it just checks state in run()
        if (task == &self.main_task) {
            // Wake the loop if called from another thread
            if (Executor.current != self) {
                self.loop.wake();
            }
            return;
        }

        // Normal scheduling
        if (Executor.current) |current_exec| {
            // TODO: for now, we are forcing .new tasks to be remotely scheduled
            //       to distribute them across executors, until we have work stealing
            //       for re-balancing them
            if (current_exec.runtime == self.runtime and old_state != .new) {
                if (current_exec != self) {
                    task.coro.parent_context_ptr = &current_exec.main_task.coro.context;
                }
                current_exec.scheduleTaskLocal(task, false);
                return;
            }
        }

        // No current executor or different runtime
        self.scheduleTaskRemote(task);
    }
};

// Runtime - orchestrator for one or more Executors
pub const Runtime = struct {
    thread_pool: ev.ThreadPool,
    stack_pool: StackPool,
    task_pool: TaskPool,
    allocator: Allocator,
    options: RuntimeOptions,

    executors: std.ArrayList(*Executor) = .empty,
    main_executor: Executor,
    next_executor_index: std.atomic.Value(usize) = .init(0),
    workers: std.ArrayList(Worker) = .empty,
    tasks: WaitQueue(Awaitable) = .empty, // Global awaitable registry
    task_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0), // Active task counter
    shutting_down: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    futex_table: Futex.Table, // Global futex wait table

    const Worker = struct {
        thread: std.Thread = undefined,
        ready: std.Thread.ResetEvent = .{},
        err: ?anyerror = null,
        executor: Executor = undefined,
    };

    pub fn init(allocator: Allocator, options: RuntimeOptions) !*Runtime {
        const self = try allocator.create(Runtime);
        errdefer allocator.destroy(self);

        const num_executors = options.executors.resolve();

        var futex_table = try Futex.Table.init(allocator, num_executors);
        errdefer futex_table.deinit(allocator);

        self.* = .{
            .allocator = allocator,
            .options = options,
            .thread_pool = undefined,
            .main_executor = undefined,
            .stack_pool = .init(options.stack_pool),
            .task_pool = .init(allocator),
            .futex_table = futex_table,
        };

        try self.thread_pool.init(allocator, options.thread_pool);
        errdefer self.thread_pool.deinit();

        try self.executors.ensureTotalCapacity(allocator, num_executors);
        errdefer self.executors.deinit(allocator);

        try self.main_executor.init(self, 0);
        errdefer self.main_executor.deinit();
        self.executors.appendAssumeCapacity(&self.main_executor);

        // errdefer shutdown() must come after main_executor.init() because
        // shutdown() operates on main_executor (runs it until idle)
        errdefer self.shutdown();

        const num_workers = num_executors - 1;
        try self.workers.ensureTotalCapacity(allocator, num_workers);

        for (0..num_workers) |i| {
            std.log.debug("Spawning worker thread {}", .{i + 1});
            const worker = self.workers.addOneAssumeCapacity();
            errdefer _ = self.workers.pop();
            worker.* = .{};
            worker.thread = try std.Thread.spawn(.{}, runWorker, .{ self, worker, @as(u6, @intCast(i + 1)) });
        }

        for (self.workers.items, 0..) |*worker, i| {
            std.log.debug("Waiting for worker thread {}", .{i + 1});
            worker.ready.wait();
            if (worker.err) |e| {
                return e;
            }
            self.executors.appendAssumeCapacity(&worker.executor);
        }

        return self;
    }

    pub fn deinit(self: *Runtime) void {
        const allocator = self.allocator;

        // Gracefully shutdown - cancel tasks, stop executors, join worker threads
        self.shutdown();

        // After shutdown(), tasks should be in sentinel1 (closed) state
        std.debug.assert(self.tasks.getState() == .sentinel1);

        // Worker executors clean themselves up via defer in runWorker.
        // We only need to deinit the main executor here.
        self.main_executor.deinit();

        self.executors.deinit(allocator);

        // Clean up ThreadPool after executors
        self.thread_pool.deinit();

        // Clean up stack pool
        self.stack_pool.deinit();

        // Clean up task pool
        self.task_pool.deinit();

        // Clean up futex table
        self.futex_table.deinit(allocator);

        // Free the Runtime allocation
        allocator.destroy(self);
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

        while (!self.shutting_down.load(.acquire)) {
            worker.executor.run(.until_stopped) catch |e| {
                std.log.err("Worker executor error: {}, retrying in {f}", .{ e, backoff });
                os.time.sleep(backoff);
                backoff = .{ .ns = @min(backoff.ns *| 2, max_backoff.ns) };
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
    /// No-op if called from a thread without an executor.
    pub fn yield(self: *Runtime) Cancelable!void {
        _ = self;
        const executor = Executor.current orelse return;
        return executor.yield(.ready, .ready, .allow_cancel);
    }

    /// Sleep for the specified number of milliseconds.
    /// Returns error.Canceled if the task was canceled during sleep.
    pub fn sleep(self: *Runtime, duration: Duration) Cancelable!void {
        var timer = ev.Timer.init(.{ .duration = duration });
        try waitForIo(self, &timer.c);
    }

    /// Begin a cancellation shield to prevent being canceled during critical sections.
    pub fn beginShield(self: *Runtime) void {
        self.getCurrentTask().beginShield();
    }

    /// End a cancellation shield.
    pub fn endShield(self: *Runtime) void {
        self.getCurrentTask().endShield();
    }

    /// Check if cancellation has been requested and return error.Canceled if so.
    /// This consumes the cancellation flag.
    /// Use this after endShield() to detect cancellation that occurred during the shielded section.
    pub fn checkCancel(self: *Runtime) Cancelable!void {
        return self.getCurrentTask().checkCancel();
    }

    /// Get the currently executing task.
    /// Panics if called from a thread without an active executor context.
    pub fn getCurrentTask(self: *Runtime) *AnyTask {
        return self.getCurrentExecutor().getCurrentTask();
    }

    /// Get the current thread's executor.
    /// Panics if called from a thread without an active executor context.
    pub fn getCurrentExecutor(self: *Runtime) *Executor {
        const executor = Executor.current orelse @panic("no current executor");
        if (std.debug.runtime_safety) {
            std.debug.assert(executor.runtime == self);
        }
        return executor;
    }

    /// Get the current monotonic timestamp.
    /// This uses the event loop's cached time for efficiency.
    pub fn now(self: *Runtime) Timestamp {
        return self.getCurrentExecutor().loop.now();
    }

    pub fn onTaskComplete(self: *Runtime, awaitable: *Awaitable) void {
        // Mark awaitable as complete and wake all waiters
        awaitable.markComplete();

        // For group tasks, decrement counter and release group's reference
        if (awaitable.group_node.group) |group| {
            unregisterGroupTask(self, group, awaitable);
        }

        // Decref for list membership (if we successfully remove)
        if (self.tasks.remove(awaitable)) {
            awaitable.release(self);
        }
        // Decref for task completion
        awaitable.release(self);

        // Decrement task count
        const prev_count = self.task_count.fetchSub(1, .acq_rel);
        if (prev_count == 1) {
            // Last task completed - wake main executor if it's waiting in run() mode
            if (self.main_executor.main_task.state.cmpxchgStrong(.new, .ready, .release, .acquire) == null) {
                self.main_executor.loop.wake();
            }
        }
    }

    /// Gracefully shutdown the runtime.
    /// Cancels all remaining tasks, stops all executors, joins worker threads,
    /// and stops the thread pool.
    pub fn shutdown(self: *Runtime) void {
        // Set shutting_down flag to prevent new spawns and new executor selection
        self.shutting_down.store(true, .release);

        // Pop all tasks, cancel them, and decref for list membership.
        // popOrTransition transitions to sentinel1 (closed) when empty,
        // preventing new tasks from being added.
        while (self.tasks.popOrTransition(.sentinel0, .sentinel1)) |awaitable| {
            awaitable.cancel();
            awaitable.release(self);
        }

        // Run until all tasks complete
        self.main_executor.run(.until_idle) catch |err| {
            std.log.err("Error running main executor during shutdown: {}", .{err});
        };

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

        // Shutdown thread pool
        self.thread_pool.stop();
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
    defer handle.cancel(runtime);

    const result = handle.join(runtime);
    try std.testing.expectEqual(42, result);
}

test "runtime: JoinHandle.cast() error set conversion" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    const MyError = error{ Foo, Bar };

    const taskSuccess = struct {
        fn call() MyError!i32 {
            return 42;
        }
    }.call;

    const taskError = struct {
        fn call() MyError!i32 {
            return error.Foo;
        }
    }.call;

    // Test casting success case
    {
        var handle = try runtime.spawn(taskSuccess, .{});
        var casted = handle.cast(anyerror!i32);
        defer casted.cancel(runtime);

        const result = try casted.join(runtime);
        try std.testing.expectEqual(42, result);
    }

    // Test casting error case
    {
        var handle = try runtime.spawn(taskError, .{});
        var casted = handle.cast(anyerror!i32);
        defer casted.cancel(runtime);

        const result = casted.join(runtime);
        try std.testing.expectError(error.Foo, result);
    }
}

test "Runtime: implicit run" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    const TestContext = struct {
        fn asyncTask(rt: *Runtime) !void {
            const start = rt.now();
            try std.testing.expect(start.ns > 0);

            // Sleep to ensure time advances
            try rt.sleep(.fromMilliseconds(10));

            const end = rt.now();
            try std.testing.expect(end.ns > start.ns);
            try std.testing.expect(start.durationTo(end).toMilliseconds() >= 10);
        }
    };

    var task = try runtime.spawn(TestContext.asyncTask, .{runtime});
    try task.join(runtime);
}

test "Runtime: sleep from main" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    // Call sleep directly from main thread - no spawn needed
    const start = runtime.now();
    try runtime.sleep(.fromMilliseconds(10));
    const end = runtime.now();

    try std.testing.expect(end.ns > start.ns);
    try std.testing.expect(start.durationTo(end).toMilliseconds() >= 10);
}

test "runtime: basic sleep" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    const Sleeper = struct {
        fn run(rt: *Runtime) !void {
            try rt.sleep(.fromMilliseconds(1));
        }
    };

    var task = try runtime.spawn(Sleeper.run, .{runtime});
    try task.join(runtime);
}

test "runtime: now() returns monotonic time" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    const start = runtime.now();
    try std.testing.expect(start.ns > 0);

    // Sleep to ensure time advances
    try runtime.sleep(.fromMilliseconds(10));

    const end = runtime.now();
    try std.testing.expect(end.ns > start.ns);
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
    defer handle.cancel(runtime);

    // Cancel the sleeping task
    handle.cancel(runtime);

    // Should return error.Canceled
    const result = handle.join(runtime);
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
    defer handle.cancel(runtime);

    // Wait a bit to ensure the task is actually in the waiting state
    try runtime.sleep(.fromMilliseconds(10));

    // Try to cancel the sleeping task
    handle.cancel(runtime);

    // Should complete successfully (not canceled) because the sleep was shielded
    const result = handle.join(runtime);
    try std.testing.expectEqual({}, result);

    // Ensure the sleep completed (took at least 50ms)
    try std.testing.expect(timer.read().toMilliseconds() >= 40);
}

test "runtime: yield from main allows tasks to run" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    var counter: usize = 0;

    const yieldingTask = struct {
        fn call(rt: *Runtime, counter_ptr: *usize) !void {
            for (0..10) |_| {
                counter_ptr.* += 1;
                try rt.yield();
            }
        }
    }.call;

    var handle = try runtime.spawn(yieldingTask, .{ runtime, &counter });
    defer handle.cancel(runtime);

    // Instead of join(), use yield() from main to let the task run
    var iterations: usize = 0;
    while (counter < 10) : (iterations += 1) {
        if (iterations >= 100) {
            std.debug.print("yield from main not working: counter={}, iterations={}\n", .{ counter, iterations });
            return error.TestExpectedEqual;
        }
        try runtime.yield();
    }

    try std.testing.expectEqual(10, counter);
}

test "runtime: sleep from main allows tasks to run" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    var counter: usize = 0;

    const yieldingTask = struct {
        fn call(rt: *Runtime, counter_ptr: *usize) !void {
            for (0..10) |_| {
                counter_ptr.* += 1;
                try rt.yield();
            }
        }
    }.call;

    var handle = try runtime.spawn(yieldingTask, .{ runtime, &counter });
    defer handle.cancel(runtime);

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
    defer group.cancel(runtime);

    for (0..4) |_| {
        try group.spawn(runtime, TestContext.task, .{runtime});
    }

    try group.wait(runtime);
    try std.testing.expect(!group.hasFailed());

    try std.testing.expectEqual(4, TestContext.counter);
}
