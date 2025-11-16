// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const assert = std.debug.assert;

const aio = @import("aio");

const meta = @import("meta.zig");
const Cancelable = @import("common.zig").Cancelable;
const Timeoutable = @import("common.zig").Timeoutable;

const Coroutine = @import("coro").Coroutine;
const Context = @import("coro").Context;
const StackPool = @import("coro").StackPool;
const StackPoolConfig = @import("coro").StackPoolConfig;
const StackInfo = @import("coro").StackInfo;
const setupStackGrowth = @import("coro").setupStackGrowth;
const cleanupStackGrowth = @import("coro").cleanupStackGrowth;

const RefCounter = @import("utils/ref_counter.zig").RefCounter;

const AnyTask = @import("core/task.zig").AnyTask;
const Task = @import("core/task.zig").Task;
const ResumeMode = @import("core/task.zig").ResumeMode;
const resumeTask = @import("core/task.zig").resumeTask;
const BlockingTask = @import("core/blocking_task.zig").BlockingTask;
const Timeout = @import("core/timeout.zig").Timeout;

const select = @import("select.zig");
const stdio = @import("stdio.zig");

/// Executor selection for spawning a coroutine
pub const ExecutorId = enum(usize) {
    /// Round-robin assignment across all executors
    any = std.math.maxInt(usize),
    /// Inherit from current coroutine, or round-robin if not in a coroutine
    same = std.math.maxInt(usize) - 1,
    _,

    /// Pin to a specific executor ID
    pub fn id(n: usize) ExecutorId {
        return @enumFromInt(n);
    }

    /// Check if this is a specific executor ID (not .any or .same)
    pub fn isId(self: ExecutorId) bool {
        return self != .any and self != .same;
    }
};

/// Options for spawning a coroutine
pub const SpawnOptions = struct {
    /// Pin task to its home executor (prevents cross-thread migration).
    /// Pinned tasks always run on their original executor, even when woken from other threads.
    /// Useful for tasks with executor-specific state or when thread affinity is desired.
    pinned: bool = false,
};

// Runtime configuration options
pub const RuntimeOptions = struct {
    thread_pool: aio.ThreadPool.Options = .{},
    stack_pool: StackPoolConfig = .{
        .maximum_size = 8 * 1024 * 1024, // 8MB reserved
        .committed_size = 64 * 1024, // 64KB initial commit
        .max_unused_stacks = 16,
        .max_age_ns = 60 * std.time.ns_per_s, // 60 seconds
    },
    /// Number of executor threads to run.
    /// - null: auto-detect CPU count (multi-threaded)
    /// - 1: single-threaded mode (default)
    /// - N > 1: use N executor threads (multi-threaded)
    num_executors: ?usize = 1,
    /// Enable LIFO slot optimization for cache locality.
    /// When enabled, tasks woken by other tasks are placed in a LIFO slot
    /// for immediate execution, improving cache locality.
    /// Enabled by default as it also maintains backward-compatible timing
    /// (woken tasks run immediately instead of being deferred to next batch).
    lifo_slot_enabled: bool = true,
};

// Noop callback for async timer cancellation
fn noopTimerCancelCallback(
    l: *aio.Loop,
    c: *aio.Completion,
) void {
    _ = l;
    _ = c;
}

fn shutdownCallback(
    loop: *aio.Loop,
    c: *aio.Completion,
) void {
    _ = c;
    // Stop the event loop
    loop.stop();
}

const awaitable_module = @import("core/awaitable.zig");
const Awaitable = awaitable_module.Awaitable;
const AwaitableKind = awaitable_module.AwaitableKind;
const AwaitableList = awaitable_module.AwaitableList;

// Public handle for spawned tasks and futures
pub fn JoinHandle(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const Result = T;

        awaitable: ?*Awaitable,
        result: T,

        /// Helper to get result from awaitable and release it
        fn finishAwaitable(self: *Self, rt: *Runtime, awaitable: *Awaitable) void {
            self.result = switch (awaitable.kind) {
                .task => Task(T).fromAwaitable(awaitable).getResult(),
                .blocking_task => BlockingTask(T).fromAwaitable(awaitable).getResult(),
            };
            rt.releaseAwaitable(awaitable, false);
            self.awaitable = null;
        }

        /// Wait for the task to complete and return its result.
        ///
        /// If the current task is canceled while waiting, the spawned task will be canceled too.
        ///
        /// Example:
        /// ```zig
        /// var handle = try rt.spawn(myTask, .{}, .{});
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
                return awaitable.done.load(.acquire);
            }
            return true; // If awaitable is null, result is already cached
        }

        /// Get the result value of type T (preserving any error union).
        /// Asserts that the task has already completed.
        /// This is used internally by select() to preserve error union types.
        pub fn getResult(self: *Self) T {
            assert(self.hasResult());
            if (self.awaitable) |awaitable| {
                return switch (awaitable.kind) {
                    .task => Task(T).fromAwaitable(awaitable).getResult(),
                    .blocking_task => BlockingTask(T).fromAwaitable(awaitable).getResult(),
                };
            } else {
                return self.result;
            }
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
        /// var handle = try rt.spawn(myTask, .{}, .{});
        /// defer handle.cancel(rt);
        /// // Do some other work that could return early
        /// const result = handle.join(rt);
        /// // cancel() in defer is a no-op since join() already completed
        /// ```
        pub fn cancel(self: *Self, rt: *Runtime) void {
            // If awaitable is null, already completed/detached - no-op
            const awaitable = self.awaitable orelse return;

            // If already done, just clean up
            if (awaitable.done.load(.acquire)) {
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
        /// var handle = try rt.spawn(backgroundTask, .{}, .{});
        /// handle.detach(rt); // Task runs independently
        /// ```
        pub fn detach(self: *Self, rt: *Runtime) void {
            // If awaitable is null, already detached - no-op
            const awaitable = self.awaitable orelse return;

            rt.releaseAwaitable(awaitable, false);
            self.awaitable = null;
            self.result = undefined;
        }

        /// Get the executor ID for this task.
        /// Only valid for coroutine tasks (not blocking tasks or futures).
        /// Returns null if this is not a coroutine task or if already detached/completed.
        pub fn getExecutorId(self: *const Self) ?usize {
            const awaitable = self.awaitable orelse return null;
            return switch (awaitable.kind) {
                .task => {
                    const task = Task(T).fromAwaitable(awaitable);
                    const executor = task.task.getExecutor();
                    return executor.id;
                },
                .blocking_task => null,
            };
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
const WaitNode = @import("core/WaitNode.zig");
const ConcurrentStack = @import("utils/concurrent_stack.zig").ConcurrentStack;
const WaitQueue = @import("utils/wait_queue.zig").WaitQueue;
const SimpleStack = @import("utils/simple_stack.zig").SimpleStack;
const SimpleQueue = @import("utils/simple_queue.zig").SimpleQueue;

comptime {
    std.debug.assert(@alignOf(WaitNode) == 8);
}

pub fn registerExecutor(rt: *Runtime, executor: *Executor) !void {
    rt.executors_lock.lock();
    defer rt.executors_lock.unlock();

    if (builtin.mode == .Debug) {
        for (rt.executors.items) |other_executor| {
            std.debug.assert(other_executor != executor);
        }
    }

    try rt.executors.append(rt.allocator, executor);
}

pub fn unregisterExecutor(rt: *Runtime, executor: *Executor) void {
    rt.executors_lock.lock();
    defer rt.executors_lock.unlock();

    for (rt.executors.items, 0..) |other_executor, i| {
        if (other_executor == executor) {
            const removed = rt.executors.swapRemove(i);
            std.debug.assert(removed == executor);
            break;
        }
    }
}

pub fn getNextExecutor(rt: *Runtime) *Executor {
    rt.executors_lock.lock();
    defer rt.executors_lock.unlock();

    const executor = rt.executors.items[rt.next_executor_index % rt.executors.items.len];
    rt.next_executor_index += 1;
    return executor;
}

// Executor - per-thread execution unit for running coroutines
pub const Executor = struct {
    loop: aio.Loop,
    main_context: Context,
    allocator: Allocator,
    current_coroutine: ?*Coroutine = null,

    ready_queue: SimpleQueue(WaitNode) = .{},
    next_ready_queue: SimpleQueue(WaitNode) = .{},

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

    // Remote task support - lock-free LIFO stack for cross-thread resumption
    next_ready_queue_remote: ConcurrentStack(WaitNode) = .{},

    // Shutdown support
    shutdown_async: aio.Async = undefined,

    // Back-reference to runtime for global coordination
    runtime: *Runtime,

    // Worker thread (null for main executor that runs on calling thread)
    thread: ?std.Thread = null,

    // Coordination for thread startup
    available: bool = true,

    // Executor dedicated to this thread
    pub threadlocal var current: ?*Executor = null;

    /// Get the Executor instance from any coroutine that belongs to it
    pub fn fromCoroutine(coro: *Coroutine) *Executor {
        return @fieldParentPtr("main_context", coro.parent_context_ptr);
    }

    pub fn init(self: *Executor, allocator: Allocator, options: RuntimeOptions, runtime: *Runtime) !void {
        self.* = .{
            .allocator = allocator,
            .loop = undefined,
            .lifo_slot_enabled = options.lifo_slot_enabled,
            .main_context = undefined,
            .runtime = runtime,
        };

        try setupStackGrowth();
        errdefer cleanupStackGrowth();

        try self.loop.init(.{
            .allocator = self.allocator,
            .thread_pool = &self.runtime.thread_pool,
            .defer_callbacks = false,
        });
        errdefer self.loop.deinit();

        self.shutdown_async = aio.Async.init();
        self.shutdown_async.c.userdata = self;
        self.shutdown_async.c.callback = shutdownCallback;
        self.loop.add(&self.shutdown_async.c);

        try registerExecutor(self.runtime, self);
        errdefer unregisterExecutor(self.runtime, self);

        std.debug.assert(Executor.current == null);
        Executor.current = self;
    }

    pub fn deinit(self: *Executor) void {
        std.debug.assert(Executor.current == self);
        Executor.current = null;

        unregisterExecutor(self.runtime, self);

        self.loop.deinit();

        cleanupStackGrowth();
    }

    pub fn spawn(self: *Executor, func: anytype, args: meta.ArgsType(func), options: SpawnOptions) !JoinHandle(meta.ReturnType(func)) {
        const Result = meta.ReturnType(func);

        const task = try Task(Result).create(self, func, args, .{
            .pinned = options.pinned,
        });
        errdefer task.destroy(self);

        // Add to global awaitable registry (can fail if runtime is shutting down)
        try self.runtime.tasks.add(task.toAwaitable());
        errdefer _ = self.runtime.tasks.remove(task.toAwaitable());

        // Increment ref count for JoinHandle BEFORE scheduling
        // This prevents race where task completes before we create the handle
        task.toAwaitable().ref_count.incr();
        errdefer _ = task.toAwaitable().ref_count.decr();

        // Schedule the task to run (handles cross-thread notification)
        self.scheduleTask(task.task, .maybe_remote);

        return JoinHandle(Result){
            .awaitable = task.toAwaitable(),
            .result = undefined,
        };
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
        const current_coro = self.current_coroutine orelse return;
        const current_task = AnyTask.fromCoroutine(current_coro);

        // Check and consume cancellation flag before yielding (unless no_cancel)
        if (cancel_mode == .allow_cancel) {
            try current_task.checkCanceled(self.runtime);
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
        if (desired_state == .ready) {
            self.scheduleTaskLocal(current_task, true); // is_yield = true
        }

        // Try to switch directly to the next ready task (checks LIFO slot first)
        if (self.getNextTask()) |next_wait_node| {
            const next_task = AnyTask.fromWaitNode(next_wait_node);

            self.current_coroutine = &next_task.coro;
            current_coro.yieldTo(&next_task.coro);
        } else {
            // No ready tasks - return to scheduler
            current_coro.yield();
        }

        // After resuming, the task may have migrated to a different executor.
        // Re-derive the current executor from TLS instead of using the captured `self`.
        const resumed_executor = Runtime.current_executor orelse unreachable;
        std.debug.assert(resumed_executor.current_coroutine == current_coro);

        // Check again after resuming in case we were canceled while suspended (unless no_cancel)
        if (cancel_mode == .allow_cancel) {
            try current_task.checkCanceled(resumed_executor.runtime);
        }
    }

    /// Begin a cancellation shield.
    /// While shielded, yield() will not check or consume the cancellation flag.
    /// The flag remains set for when the shield ends.
    /// This is useful for cleanup operations (like close()) that must complete even if canceled.
    /// Must be paired with endShield().
    pub fn beginShield(self: *Executor) void {
        const current_coro = self.current_coroutine orelse unreachable;
        const current_task = AnyTask.fromCoroutine(current_coro);
        current_task.shield_count += 1;
    }

    /// End a cancellation shield.
    /// Must be paired with beginShield().
    pub fn endShield(self: *Executor) void {
        const current_coro = self.current_coroutine orelse unreachable;
        const current_task = AnyTask.fromCoroutine(current_coro);
        std.debug.assert(current_task.shield_count > 0);
        current_task.shield_count -= 1;
    }

    /// Check if cancellation has been requested and return error.Canceled if so.
    /// This consumes one pending error if available.
    /// Use this after endShield() to detect cancellation that occurred during the shielded section.
    pub fn checkCanceled(self: *Executor) Cancelable!void {
        const current_coro = self.current_coroutine orelse unreachable;
        const current_task = AnyTask.fromCoroutine(current_coro);
        try current_task.checkCanceled(self.runtime);
    }

    /// Pin the current task to its home executor (prevents cross-thread migration).
    /// While pinned, the task will always run on its original executor, even when
    /// woken from other threads. Useful for tasks with executor-specific state.
    /// Must be paired with endPin().
    pub fn beginPin(self: *Executor) void {
        const current_coro = self.current_coroutine orelse unreachable;
        const current_task = AnyTask.fromCoroutine(current_coro);
        current_task.pin_count += 1;
    }

    /// Unpin the current task (re-enables cross-thread migration if pin_count reaches 0).
    /// Must be paired with beginPin().
    pub fn endPin(self: *Executor) void {
        const current_coro = self.current_coroutine orelse unreachable;
        const current_task = AnyTask.fromCoroutine(current_coro);
        std.debug.assert(current_task.pin_count > 0);
        current_task.pin_count -= 1;
    }

    pub fn getCurrentTask(self: *Executor) ?*AnyTask {
        const coro = self.current_coroutine orelse return null;
        return AnyTask.fromCoroutine(coro);
    }

    pub inline fn awaitablePtrFromTaskPtr(task: *AnyTask) *Awaitable {
        return &task.awaitable;
    }

    pub fn sleep(self: *Executor, milliseconds: u64) Cancelable!void {
        // Set up timeout
        var timeout = Timeout.init;
        defer timeout.clear(self.runtime);
        timeout.set(self.runtime, milliseconds * std.time.ns_per_ms);

        // Yield with atomic state transition (.ready -> .waiting)
        self.yield(.ready, .waiting, .allow_cancel) catch |err| {
            // Check if this timeout triggered (expected for sleep), otherwise it was user cancellation
            self.runtime.checkTimeout(&timeout, err) catch |check_err| switch (check_err) {
                error.Timeout => return, // Timeout is expected for sleep - return successfully
                error.Canceled => return error.Canceled, // User cancellation - propagate
            };
            unreachable;
        };

        unreachable; // Should always be canceled (by timeout or user)
    }

    /// Run the executor event loop.
    /// Main executor (id=0) orchestrates shutdown when all tasks complete.
    /// Worker executors (id>0) run until signaled to shut down by main executor.
    pub fn run(self: *Executor) !void {
        // Set thread-local current executor
        Runtime.current_executor = self;
        defer Runtime.current_executor = null;

        // Check if we're starting with an empty task list
        // If so, immediately initiate shutdown (no work to do)
        self.runtime.maybeShutdown();

        var spin_count: u8 = 0;
        while (true) {
            // Exit if loop was stopped (by shutdown callback)
            if (self.loop.stopped()) break;

            // Drain remote ready queue (cross-thread tasks)
            // Atomically drain all remote ready tasks and append to ready queue
            var drained = self.next_ready_queue_remote.popAll();
            while (drained.pop()) |task| {
                self.ready_queue.push(task);
            }

            // Process all ready coroutines (once)
            // getNextTask() checks LIFO slot first for cache locality, then ready_queue
            while (self.getNextTask()) |wait_node| {
                const task = AnyTask.fromWaitNode(wait_node);

                self.current_coroutine = &task.coro;
                defer self.current_coroutine = null;

                task.coro.step();

                // Handle finished coroutines (checks current_coroutine to catch tasks that died via direct switch in yield())
                if (self.current_coroutine) |current_coro| {
                    if (current_coro.finished) {
                        const current_task = AnyTask.fromCoroutine(current_coro);
                        const current_awaitable = &current_task.awaitable;

                        // Release stack immediately since coroutine execution is complete
                        if (current_coro.context.stack_info.allocation_len > 0) {
                            self.runtime.stack_pool.release(current_coro.context.stack_info);
                            current_coro.context.stack_info.allocation_len = 0;
                        }

                        // Mark awaitable as complete and wake all waiters (coroutines and threads)
                        current_awaitable.markComplete();

                        // Release runtime's reference and check for shutdown
                        self.runtime.releaseAwaitable(current_awaitable, true);
                        // If ref_count > 0, Task(T) handles still exist, keep the task alive
                    }
                }

                // Other states (.ready, .waiting) are handled by yield() or markReady()
            }

            // Move yielded coroutines back to ready queue
            self.ready_queue.concatByMoving(&self.next_ready_queue);

            // Determine event loop run mode based on work availability and spin count
            // Spin briefly with non-blocking polls before blocking to reduce cross-thread wakeup latency
            const has_work = self.ready_queue.head != null or self.lifo_slot != null;
            const run_mode: aio.RunMode = if (has_work or spin_count < 16) .no_wait else .once;

            // Run event loop
            try self.loop.run(run_mode);

            // Update spin count: reset if work found, increment if spinning, don't change if blocked
            if (has_work) {
                spin_count = 0;
            } else if (run_mode == .no_wait) {
                spin_count +%= 1;
            }
        }
    }

    /// Get the next task to run, checking LIFO slot first for cache locality.
    ///
    /// The LIFO slot is checked first (when enabled) because recently woken tasks
    /// are likely cache-hot. However, we limit consecutive LIFO polls to prevent
    /// starvation of tasks in ready_queue.
    ///
    /// Returns null if no tasks are available.
    fn getNextTask(self: *Executor) ?*WaitNode {
        // LIFO slot optimization: check LIFO slot first for cache locality
        // But limit consecutive LIFO polls to prevent starvation of ready_queue tasks
        // Value matches Tokio's MAX_LIFO_POLLS_PER_TICK
        const MAX_LIFO_POLLS_PER_TICK = 3;

        if (self.lifo_slot_enabled) {
            if (self.lifo_slot_used < MAX_LIFO_POLLS_PER_TICK) {
                // Under starvation limit - can use LIFO slot
                if (self.lifo_slot) |task| {
                    self.lifo_slot = null;
                    self.lifo_slot_used += 1;
                    return task;
                }
            } else {
                // Hit starvation limit - move LIFO slot task to ready_queue (back of FIFO)
                // This gives other ready_queue tasks a chance to run first
                if (self.lifo_slot) |task| {
                    self.lifo_slot = null;
                    self.ready_queue.push(task);
                    // Don't reset counter - only reset when we actually poll from ready_queue
                }
            }
        }

        // Take from ready_queue
        if (self.ready_queue.pop()) |task| {
            self.lifo_slot_used = 0; // Reset starvation counter
            return task;
        }

        return null;
    }

    /// Schedule a task to the current executor's local queues.
    /// This must only be called when we're on the correct executor thread.
    ///
    /// The `is_yield` parameter determines scheduling behavior:
    /// - `true`: Task is yielding - goes to next_ready_queue (runs next iteration)
    /// - `false`: Task is being woken - goes to LIFO slot (immediate) or ready_queue (FIFO)
    fn scheduleTaskLocal(self: *Executor, task: *AnyTask, is_yield: bool) void {
        const wait_node = &task.awaitable.wait_node;
        if (is_yield) {
            // Yields → next_ready_queue (runs next iteration for fairness)
            self.next_ready_queue.push(wait_node);
        } else if (!self.lifo_slot_enabled) {
            // LIFO disabled - woken tasks go to ready_queue (FIFO, fair scheduling)
            self.ready_queue.push(wait_node);
        } else {
            // LIFO enabled - try LIFO slot for cache locality
            if (self.lifo_slot) |old_task| {
                // LIFO slot occupied - displaced task goes to ready_queue (FIFO)
                self.ready_queue.push(old_task);
            }
            // New task takes the LIFO slot (runs immediately, cache-hot)
            self.lifo_slot = wait_node;
        }
    }

    /// Schedule a task to a remote executor (different executor or no current executor).
    /// Uses the thread-safe remote queue and notifies the executor.
    fn scheduleTaskRemote(self: *Executor, task: *AnyTask) void {
        const wait_node = &task.awaitable.wait_node;

        // Push to remote ready queue (thread-safe)
        self.next_ready_queue_remote.push(wait_node);

        // Wake the target executor's event loop (only if initialized)
        self.loop.wake();
    }

    /// Schedule a task for execution. Called on the task's home executor (self).
    /// Atomically transitions task state to .ready and schedules it for execution.
    ///
    /// Task migration for cache locality:
    /// - Tasks resumed with .maybe_remote: May migrate to current executor if conditions allow
    /// - Tasks resumed with .local: Always stay on home executor (I/O callbacks, timeouts, cancellation)
    /// - New/ready tasks: Schedule on home executor
    ///
    /// The `mode` parameter:
    /// - `.maybe_remote`: Enables migration, uses remote queue when needed
    /// - `.local`: No migration, always uses home executor
    pub fn scheduleTask(self: *Executor, task: *AnyTask, comptime mode: ResumeMode) void {
        const old_state = task.state.swap(.ready, .acq_rel);

        // Task hasn't yielded yet - it will see .ready and skip the yield
        if (old_state == .preparing_to_wait) return;

        // Task already transitioned to .ready by another thread - avoid double-schedule
        if (old_state == .ready) return;

        // Validate state transitions
        if (old_state != .new and old_state != .waiting) {
            std.debug.panic("scheduleTask: unexpected state {} for task {*}", .{ old_state, task });
        }

        // Migration is allowed only when mode == .maybe_remote
        // (I/O callbacks, timeouts, cancellation use .local mode and don't migrate)
        if (old_state == .waiting and mode == .maybe_remote and task.canMigrate()) {
            const current_exec = Runtime.current_executor orelse {
                self.scheduleTaskRemote(task);
                return;
            };

            // Check if we can migrate (same runtime, different executor)
            if (current_exec.runtime == self.runtime) {
                // Same runtime - migrate to current executor for cache locality
                if (current_exec != self) {
                    task.coro.parent_context_ptr = &current_exec.main_context;
                }
                current_exec.scheduleTaskLocal(task, false);
                return;
            }

            // Different runtime - use remote scheduling on home executor
            self.scheduleTaskRemote(task);
            return;
        }

        // Default path: schedule on appropriate executor
        if (mode == .maybe_remote) {
            if (Runtime.current_executor == self) {
                self.scheduleTaskLocal(task, false);
            } else {
                self.scheduleTaskRemote(task);
            }
        } else {
            assert(Runtime.current_executor == self);
            self.scheduleTaskLocal(task, false);
        }
    }

    pub fn io(self: *Runtime) std.Io {
        return stdio.fromRuntime(self);
    }

    pub fn fromIo(io_: std.Io) *Runtime {
        return stdio.toRuntime(io_);
    }
};

// ThreadWaiter - used by external threads to wait on Awaitables
pub const ThreadWaiter = struct {
    wait_node: WaitNode,
    futex_state: std.atomic.Value(u32),

    const wait_node_vtable = WaitNode.VTable{
        .wake = waitNodeWake,
    };

    pub fn init() ThreadWaiter {
        return .{
            .wait_node = .{
                .vtable = &wait_node_vtable,
            },
            .futex_state = std.atomic.Value(u32).init(0),
        };
    }

    fn waitNodeWake(wait_node: *WaitNode) void {
        const self: *ThreadWaiter = @fieldParentPtr("wait_node", wait_node);
        self.futex_state.store(1, .release);
        std.Thread.Futex.wake(&self.futex_state, 1);
    }
};

// Runtime - orchestrator for one or more Executors
pub const Runtime = struct {
    thread_pool: aio.ThreadPool,
    stack_pool: StackPool,
    allocator: Allocator,
    options: RuntimeOptions,

    executors_lock: std.Thread.Mutex = .{},
    executors: std.ArrayList(*Executor) = .empty,
    main_executor: Executor,
    next_executor_index: usize = 0,

    tasks: AwaitableList = .{}, // Global awaitable registry with built-in closed state
    shutting_down: std.atomic.Value(bool), // Signals executors to stop (set once)

    /// Thread-local storage for the current executor
    pub threadlocal var current_executor: ?*Executor = null;

    pub fn init(allocator: Allocator, options: RuntimeOptions) !*Runtime {
        const self = try allocator.create(Runtime);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .options = options,
            .thread_pool = undefined,
            .main_executor = undefined,
            .stack_pool = .init(options.stack_pool),
            .shutting_down = .init(false),
        };

        try self.thread_pool.init(allocator, options.thread_pool);
        errdefer self.thread_pool.deinit();

        try self.executors.ensureTotalCapacity(allocator, 16);
        errdefer self.executors.deinit(allocator);

        try self.main_executor.init(allocator, options, self);
        errdefer self.main_executor.deinit();

        return self;
    }

    pub fn deinit(self: *Runtime) void {
        const allocator = self.allocator;

        // Shutdown ThreadPool before cleaning up executors
        self.thread_pool.stop();

        // Drain any remaining awaitables from global registry
        while (self.tasks.pop()) |awaitable| {
            self.releaseAwaitable(awaitable, false);
        }

        while (true) {
            var executor: ?*Executor = null;

            self.executors_lock.lock();
            if (self.executors.items.len > 0) {
                executor = self.executors.items[0];
            }
            self.executors_lock.unlock();

            const exec = executor orelse break;
            exec.deinit();
        }

        {
            self.executors_lock.lock();
            self.executors.deinit(allocator);
            self.executors_lock.unlock();
        }

        // Clean up ThreadPool after executors
        self.thread_pool.deinit();

        // Clean up stack pool
        self.stack_pool.deinit();

        // Free the Runtime allocation
        allocator.destroy(self);
    }

    // High-level public API - delegates to appropriate Executor
    pub fn spawn(self: *Runtime, func: anytype, args: meta.ArgsType(func), options: SpawnOptions) !JoinHandle(meta.ReturnType(func)) {
        if (self.tasks.isClosed()) {
            return error.RuntimeShutdown;
        }

        const executor = getNextExecutor(self);
        return executor.spawn(func, args, options);
    }

    pub fn spawnBlocking(self: *Runtime, func: anytype, args: meta.ArgsType(func)) !JoinHandle(meta.ReturnType(func)) {
        // Check if runtime is shutting down
        if (self.tasks.isClosed()) {
            return error.RuntimeShutdown;
        }

        const Result = meta.ReturnType(func);
        const task = try BlockingTask(Result).create(self, func, args);
        errdefer task.destroy(self);

        // Add to global awaitable registry (can fail if runtime is shutting down)
        try self.tasks.add(task.toAwaitable());
        errdefer _ = self.tasks.remove(task.toAwaitable());

        // Increment ref count for JoinHandle BEFORE scheduling
        // This prevents race where task completes before we create the handle
        task.toAwaitable().ref_count.incr();
        errdefer _ = task.toAwaitable().ref_count.decr();

        // Add the work to an executor's loop (loop will submit to thread pool)
        const executor = getNextExecutor(self);
        executor.loop.add(&task.task.work.c);

        return JoinHandle(Result){
            .awaitable = task.toAwaitable(),
            .result = undefined,
        };
    }

    pub fn run(self: *Runtime) !void {
        if (Executor.current) |local_executor| {
            try local_executor.run();
            return;
        }

        var executor: Executor = undefined;

        try executor.init(self.allocator, self.options, self);
        defer executor.deinit();

        try executor.run();
    }

    pub fn runUntilComplete(self: *Runtime, func: anytype, args: meta.ArgsType(func), options: SpawnOptions) !meta.Payload(meta.ReturnType(func)) {
        var handle = try self.spawn(func, args, options);
        defer handle.cancel(self);

        // Run all executors
        try self.run();

        return handle.join(self);
    }

    // Convenience methods that operate on the current coroutine context
    // These delegate to the current executor automatically
    // Most are no-op if not called from within a coroutine

    /// Cooperatively yield control to allow other tasks to run.
    /// The current task will be rescheduled and continue execution later.
    /// No-op if not called from within a coroutine.
    pub fn yield(self: *Runtime) Cancelable!void {
        _ = self;
        const executor = Runtime.current_executor orelse return;
        if (executor.current_coroutine == null) return;
        return executor.yield(.ready, .ready, .allow_cancel);
    }

    /// Sleep for the specified number of milliseconds.
    /// Uses async sleep if in a coroutine, blocking sleep otherwise.
    /// Returns error.Canceled if the coroutine was canceled during sleep.
    pub fn sleep(self: *Runtime, milliseconds: u64) Cancelable!void {
        _ = self;
        if (Runtime.current_executor) |executor| {
            if (executor.current_coroutine != null) {
                return executor.sleep(milliseconds);
            }
        }
        // Not in coroutine - use blocking sleep (cannot be canceled)
        aio.system.time.sleep(@min(milliseconds, std.math.maxInt(i32)));
    }

    /// Begin a cancellation shield to prevent cancellation during critical sections.
    /// No-op if not called from within a coroutine.
    pub fn beginShield(self: *Runtime) void {
        _ = self;
        const executor = Runtime.current_executor orelse return;
        if (executor.current_coroutine == null) return;
        executor.beginShield();
    }

    /// End a cancellation shield.
    /// No-op if not called from within a coroutine.
    pub fn endShield(self: *Runtime) void {
        _ = self;
        const executor = Runtime.current_executor orelse return;
        if (executor.current_coroutine == null) return;
        executor.endShield();
    }

    /// Check if the given timeout triggered the cancellation.
    /// This should be called in a catch block after receiving an error.
    /// If the error is not error.Canceled, returns the original error unchanged.
    /// If the timeout was triggered, returns error.Timeout.
    /// Otherwise, returns the original error (error.Canceled from user cancellation).
    /// No-op (returns void) if not called from within a coroutine.
    pub fn checkTimeout(self: *Runtime, timeout: *Timeout, err: anytype) !void {
        const executor = Runtime.current_executor orelse return;
        const current_coro = executor.current_coroutine orelse return;
        const current_task = AnyTask.fromCoroutine(current_coro);
        try current_task.checkTimeout(self, timeout, err);
    }

    /// Pin the current task to its home executor (prevents cross-thread migration).
    /// While pinned, the task will always run on its original executor, even when
    /// woken from other threads. Useful for tasks with executor-specific state.
    /// Must be paired with endPin().
    /// No-op if not called from within a coroutine.
    pub fn beginPin(self: *Runtime) void {
        _ = self;
        const executor = Runtime.current_executor orelse return;
        if (executor.current_coroutine == null) return;
        executor.beginPin();
    }

    /// Unpin the current task (re-enables cross-thread migration if pin_count reaches 0).
    /// Must be paired with beginPin().
    /// No-op if not called from within a coroutine.
    pub fn endPin(self: *Runtime) void {
        _ = self;
        const executor = Runtime.current_executor orelse return;
        if (executor.current_coroutine == null) return;
        executor.endPin();
    }

    /// Check if cancellation has been requested and return error.Canceled if so.
    /// This consumes the cancellation flag.
    /// Use this after endShield() to detect cancellation that occurred during the shielded section.
    /// No-op (returns successfully) if not called from within a coroutine.
    pub fn checkCanceled(self: *Runtime) Cancelable!void {
        _ = self;
        const executor = Runtime.current_executor orelse return;
        if (executor.current_coroutine == null) return;
        return executor.checkCanceled();
    }

    /// Get the currently executing task, or null if not in a coroutine.
    /// Uses the threadlocal current_executor to support multiple executors.
    pub fn getCurrentTask(self: *Runtime) ?*AnyTask {
        const executor = self.getCurrentExecutor() orelse return null;
        const current = executor.current_coroutine orelse return null;
        return AnyTask.fromCoroutine(current);
    }

    pub fn getCurrentExecutor(self: *Runtime) ?*Executor {
        _ = self;
        return Runtime.current_executor;
    }

    /// Get the current time in milliseconds.
    /// This uses the event loop's cached monotonic time for efficiency.
    /// In multi-threaded mode, uses the main executor's loop time.
    pub fn now(self: *Runtime) u64 {
        if (Executor.current) |local_executor| {
            return local_executor.loop.now();
        } else {
            return self.main_executor.loop.now();
        }
    }

    /// Check if task list is empty and initiate shutdown if so.
    /// Only one executor will succeed in closing the registry due to atomic transition.
    /// Can be called by any executor.
    fn maybeShutdown(self: *Runtime) void {
        if (self.tasks.isEmpty()) {
            // Try to atomically close the registry (empty_open → empty_closed)
            if (self.tasks.close()) {
                // We won the race - initiate shutdown
                self.shutting_down.store(true, .release);

                // Wake all executors (including main if sleeping in event loop)
                for (self.executors.items) |executor| {
                    executor.shutdown_async.notify();
                }
            } else |_| {
                // Another executor is closing or tasks were added - do nothing
            }
        }
    }

    pub fn releaseAwaitable(self: *Runtime, awaitable: *Awaitable, comptime done: bool) void {
        if (done) {
            _ = self.tasks.remove(awaitable);
        }
        if (awaitable.ref_count.decr()) {
            awaitable.destroy_fn(self, awaitable);
        }
        if (done) {
            self.maybeShutdown();
        }
    }
};

test "runtime: spawnBlocking smoke test" {
    if (builtin.os.tag != .linux) return error.SkipZigTest; // TODO: fix this

    const testing = std.testing;

    const runtime = try Runtime.init(testing.allocator, .{
        .thread_pool = .{},
    });
    defer runtime.deinit();

    const TestContext = struct {
        fn blockingWork(x: i32) i32 {
            return x * 2;
        }

        fn asyncTask(rt: *Runtime) !void {
            var handle = try rt.spawnBlocking(blockingWork, .{21});
            defer handle.cancel(rt);

            const result = handle.join(rt);
            try testing.expectEqual(@as(i32, 42), result);
        }
    };

    try runtime.runUntilComplete(TestContext.asyncTask, .{runtime}, .{});
}

test "runtime: JoinHandle.cast() error set conversion" {
    const testing = std.testing;

    const runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    const TestContext = struct {
        const MyError = error{ Foo, Bar };

        fn taskSuccess() MyError!i32 {
            return 42;
        }

        fn taskError() MyError!i32 {
            return error.Foo;
        }

        fn asyncTask(rt: *Runtime) !void {
            // Test casting success case
            {
                var handle = try rt.spawn(taskSuccess, .{}, .{});
                var casted = handle.cast(anyerror!i32);
                defer casted.cancel(rt);

                const result = try casted.join(rt);
                try testing.expectEqual(@as(i32, 42), result);
            }

            // Test casting error case
            {
                var handle = try rt.spawn(taskError, .{}, .{});
                var casted = handle.cast(anyerror!i32);
                defer casted.cancel(rt);

                const result = casted.join(rt);
                try testing.expectError(error.Foo, result);
            }
        }
    };

    try runtime.runUntilComplete(TestContext.asyncTask, .{runtime}, .{});
}

test "runtime: now() returns monotonic time" {
    const testing = std.testing;

    const runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    const TestContext = struct {
        fn asyncTask(rt: *Runtime) !void {
            const start = rt.now();
            try testing.expect(start > 0);

            // Sleep to ensure time advances
            try rt.sleep(10);

            const end = rt.now();
            try testing.expect(end > start);
            try testing.expect(end - start >= 10);
        }
    };

    try runtime.runUntilComplete(TestContext.asyncTask, .{runtime}, .{});
}

test "runtime: sleep is cancelable" {
    const testing = std.testing;

    const runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    const TestContext = struct {
        fn sleepingTask(rt: *Runtime) !void {
            // This will sleep for 1 second but should be canceled before completion
            try rt.sleep(1000);
            // Should not reach here
            return error.TestUnexpectedResult;
        }

        fn asyncTask(rt: *Runtime) !void {
            var timer = try std.time.Timer.start();

            var handle = try rt.spawn(sleepingTask, .{rt}, .{});
            defer handle.cancel(rt);

            // Give it a chance to start sleeping
            try rt.yield();
            try rt.yield();

            // Cancel the sleeping task
            handle.cancel(rt);

            // Should return error.Canceled
            const result = handle.join(rt);
            try testing.expectError(error.Canceled, result);

            // Ensure the sleep was canceled before completion
            const elapsed = timer.read();
            try testing.expect(elapsed <= 500 * std.time.ns_per_ms);
        }
    };

    try runtime.runUntilComplete(TestContext.asyncTask, .{runtime}, .{});
}
