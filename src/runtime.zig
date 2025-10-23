const std = @import("std");
const print = std.debug.print;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const assert = std.debug.assert;
const xev = @import("xev");

const meta = @import("meta.zig");

const coroutines = @import("coroutines.zig");
const Coroutine = coroutines.Coroutine;
const CoroutineState = coroutines.CoroutineState;

// const Error = coroutines.Error;
const RefCounter = @import("utils/ref_counter.zig").RefCounter;
const FutureResult = @import("future_result.zig").FutureResult;
const stack_pool = @import("stack_pool.zig");
const StackPool = stack_pool.StackPool;
const StackPoolOptions = stack_pool.StackPoolOptions;

const select = @import("select.zig");

const Io = @import("io.zig").Io;

// Compile-time detection of whether the backend needs ThreadPool
fn backendNeedsThreadPool() bool {
    return @hasField(xev.Loop, "thread_pool");
}

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
    stack_size: ?usize = null,
    executor: ExecutorId = .any,
    /// Pin task to its home executor (prevents cross-thread migration).
    /// Pinned tasks always run on their original executor, even when woken from other threads.
    /// Useful for tasks with executor-specific state or when thread affinity is desired.
    pinned: bool = false,
};

// Runtime configuration options
pub const RuntimeOptions = struct {
    thread_pool: ThreadPoolOptions = .{},
    stack_pool: StackPoolOptions = .{},
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

    pub const ThreadPoolOptions = struct {
        enabled: bool = backendNeedsThreadPool(),
        max_threads: ?u32 = null, // null = CPU count
        stack_size: ?u32 = null, // null = default stack size
    };
};

// Runtime-specific errors
pub const ZioError = error{
    NotInCoroutine,
    InvalidExecutorId,
    RuntimeShutdown,
};

// Cancelable error set
pub const Cancelable = error{
    Canceled,
};

// Noop callback for async timer cancellation
fn noopTimerCancelCallback(
    ud: ?*void,
    l: *xev.Loop,
    c: *xev.Completion,
    r: xev.Timer.CancelError!void,
) xev.CallbackAction {
    _ = ud;
    _ = l;
    _ = c;
    _ = r catch {};
    return .disarm;
}

// Thread pool callback for blocking tasks
fn threadPoolCallback(task: *xev.ThreadPool.Task) void {
    const any_blocking_task: *AnyBlockingTask = @fieldParentPtr("thread_pool_task", task);

    // Check if the task was canceled before it started executing
    if (!any_blocking_task.awaitable.canceled.load(.acquire)) {
        // Execute the user's blocking function only if not canceled
        any_blocking_task.execute_fn(any_blocking_task);
    }

    // Mark awaitable as complete and wake all waiters (thread-safe)
    // Even if canceled, we still mark as complete so waiters wake up
    any_blocking_task.awaitable.markComplete();

    // Release the blocking task's reference
    const runtime = any_blocking_task.runtime;
    runtime.releaseAwaitable(&any_blocking_task.awaitable);
}

// Async callback for remote ready tasks wakeup (cross-thread resumption)
// This just wakes up the loop - the actual draining happens in run().
fn remoteWakeupCallback(
    executor: ?*Executor,
    loop: *xev.Loop,
    c: *xev.Completion,
    result: xev.Async.WaitError!void,
) xev.CallbackAction {
    _ = result catch unreachable;
    _ = loop;
    _ = c;
    _ = executor;

    // Just wake up - draining happens in run() loop
    return .rearm;
}

fn shutdownCallback(
    executor: ?*Executor,
    loop: *xev.Loop,
    c: *xev.Completion,
    result: xev.Async.WaitError!void,
) xev.CallbackAction {
    _ = result catch unreachable;
    _ = c;
    _ = executor;

    // Stop the event loop
    loop.stop();
    return .disarm;
}

// Re-export Awaitable types from core module
const awaitable_module = @import("core/Awaitable.zig");
pub const Awaitable = awaitable_module.Awaitable;
pub const AwaitableKind = awaitable_module.AwaitableKind;

/// Wait for an awaitable to complete with a timeout. Works from both coroutines and threads.
/// Returns error.Timeout if the timeout expires before completion.
/// Returns error.Canceled if the coroutine was canceled during the wait.
/// For coroutines, uses runtime timer infrastructure.
/// For threads, uses futex timedWait directly.
pub fn timedWaitForComplete(awaitable: *Awaitable, runtime: *Runtime, timeout_ns: u64) error{ Timeout, Canceled }!void {
    // Fast path: check if already complete
    if (awaitable.done.load(.acquire)) return;

    if (runtime.getCurrentTask()) |task| {
        // Coroutine path: get executor and use timer infrastructure
        const executor = task.getExecutor();

        awaitable.waiting_list.push(&task.awaitable.wait_node);

        if (awaitable.done.load(.acquire)) {
            _ = awaitable.waiting_list.remove(&task.awaitable.wait_node);
            return;
        }

        const TimeoutContext = struct {
            wait_queue: *WaitQueue(WaitNode),
            wait_node: *WaitNode,
        };

        var timeout_ctx = TimeoutContext{
            .wait_queue = &awaitable.waiting_list,
            .wait_node = &task.awaitable.wait_node,
        };

        executor.timedWaitForReadyWithCallback(
            .ready,
            .waiting_sync,
            timeout_ns,
            TimeoutContext,
            &timeout_ctx,
            struct {
                fn onTimeout(ctx: *TimeoutContext) bool {
                    return ctx.wait_queue.remove(ctx.wait_node);
                }
            }.onTimeout,
        ) catch |err| {
            // Handle both timeout and cancellation from yield
            if (err == error.Canceled) {
                _ = awaitable.waiting_list.remove(&task.awaitable.wait_node);
            }
            return err;
        };

        // Pair with markComplete()'s .release
        _ = awaitable.done.load(.acquire);
        // Yield returned successfully, awaitable must be complete
    } else {
        // Thread path: use ThreadWaiter with futex timedWait
        var thread_waiter = ThreadWaiter.init();
        awaitable.waiting_list.push(&thread_waiter.wait_node);
        defer {
            _ = awaitable.waiting_list.remove(&thread_waiter.wait_node);
        }

        // Double-check before parking (avoid lost wakeup)
        if (awaitable.done.load(.acquire)) {
            return;
        }

        // Wait loop with timeout - check done flag and park on thread_waiter futex
        var timer = std.time.Timer.start() catch unreachable;
        while (!awaitable.done.load(.acquire)) {
            const elapsed_ns = timer.read();
            if (elapsed_ns >= timeout_ns) {
                return error.Timeout;
            }
            try std.Thread.Futex.timedWait(&thread_waiter.futex_state, 0, timeout_ns - elapsed_ns);
        }
    }
}

/// Resume mode - controls cross-thread checking
pub const ResumeMode = enum {
    /// May resume on a different executor - checks thread-local executor
    maybe_remote,
    /// Always resumes on the current executor - skips check (use for IO callbacks)
    local,
};

/// Resume a coroutine (mark it as ready).
/// Accepts *Awaitable, *AnyTask, or *Coroutine.
/// The coroutine must currently be in waiting state.
///
/// The `mode` parameter controls cross-thread checking:
/// - `.maybe_remote`: Checks if we're on the same executor (use for wait lists, futures)
/// - `.local`: Assumes we're on the same executor (use for IO callbacks)
pub fn resumeTask(obj: anytype, comptime mode: ResumeMode) void {
    const T = @TypeOf(obj);
    const task: *AnyTask = switch (T) {
        *AnyTask => obj,
        *Awaitable => AnyTask.fromAwaitable(obj),
        *Coroutine => AnyTask.fromCoroutine(obj),
        else => @compileError("resumeTask() requires, *AnyTask, *Awaitable or *Coroutine, got " ++ @typeName(T)),
    };

    const home_executor = Executor.fromCoroutine(&task.coro);
    home_executor.scheduleTask(task, mode);
}

// Task for runtime scheduling - coroutine-based tasks
pub const AnyTask = struct {
    awaitable: Awaitable,
    coro: Coroutine,
    timer_c: xev.Completion = .{},
    timer_cancel_c: xev.Completion = .{},
    timer_generation: u2 = 0,
    shield_count: u32 = 0,
    pin_count: u32 = 0,

    // Intrusive list node for Executor.tasks queue (WaitQueue)
    next: ?*AnyTask = null,
    prev: ?*AnyTask = null,
    in_list: bool = false,

    const wait_node_vtable = WaitNode.VTable{
        .wake = waitNodeWake,
    };

    fn waitNodeWake(wait_node: *WaitNode) void {
        const awaitable: *Awaitable = @fieldParentPtr("wait_node", wait_node);
        resumeTask(awaitable, .maybe_remote);
    }

    pub inline fn fromAwaitable(awaitable: *Awaitable) *AnyTask {
        assert(awaitable.kind == .task);
        return @fieldParentPtr("awaitable", awaitable);
    }

    pub inline fn fromWaitNode(wait_node: *WaitNode) *AnyTask {
        const awaitable: *Awaitable = @fieldParentPtr("wait_node", wait_node);
        assert(awaitable.kind == .task);
        return @fieldParentPtr("awaitable", awaitable);
    }

    pub inline fn fromCoroutine(coro: *Coroutine) *AnyTask {
        return @fieldParentPtr("coro", coro);
    }

    /// Get the executor that owns this task.
    pub inline fn getExecutor(self: *AnyTask) *Executor {
        return Executor.fromCoroutine(&self.coro);
    }

    /// Request cancellation of this task.
    /// The cancellation flag will be checked at the next yield point.
    pub fn cancel(self: *AnyTask) void {
        self.awaitable.requestCancellation();
    }
};

/// Registry of all tasks in the runtime.
/// Used for lifecycle management and preventing spawns during shutdown.
///
/// State encoding:
/// - sentinel0 (empty_open): No tasks, accepting new spawns
/// - sentinel1 (empty_closed): No tasks, runtime shutting down, reject spawns
/// - pointer: Has tasks, accepting new spawns
pub const AnyTaskList = struct {
    queue: WaitQueue(AnyTask) = .empty,

    const State = WaitQueue(AnyTask).State;
    const empty_open: State = .sentinel0;
    const empty_closed: State = .sentinel1;

    /// Add a task to the registry.
    /// Returns error.Closed if the runtime is shutting down.
    pub fn add(self: *AnyTaskList, task: *AnyTask) error{Closed}!void {
        if (!self.queue.pushUnless(empty_closed, task)) {
            return error.Closed;
        }
    }

    /// Remove a task from the registry.
    /// Returns true if the task was found and removed.
    pub fn remove(self: *AnyTaskList, task: *AnyTask) bool {
        return self.queue.remove(task);
    }

    /// Close the registry to prevent new task additions.
    /// Returns error.NotEmpty if the registry still has tasks.
    /// Idempotent: succeeds if already closed.
    pub fn close(self: *AnyTaskList) error{NotEmpty}!void {
        // Try atomic transition: empty_open → empty_closed
        if (!self.queue.tryTransition(empty_open, empty_closed)) {
            const state = self.queue.getState();
            if (state == empty_closed) return; // Already closed, OK
            return error.NotEmpty; // Has tasks
        }
    }

    /// Returns true if the registry has no tasks.
    /// Note: Does not distinguish between open/closed states.
    pub fn isEmpty(self: *const AnyTaskList) bool {
        const state = self.queue.getState();
        return !state.isPointer();
    }

    /// Returns true if the registry is closed (rejecting new spawns).
    pub fn isClosed(self: *const AnyTaskList) bool {
        return self.queue.getState() == empty_closed;
    }

    /// Remove and return the first task from the registry.
    /// When popping the last item, transitions to empty_open (not closed).
    pub fn pop(self: *AnyTaskList) ?*AnyTask {
        return self.queue.pop();
    }
};

// Blocking task for runtime scheduling - thread pool based tasks
pub const AnyBlockingTask = struct {
    awaitable: Awaitable,
    thread_pool_task: xev.ThreadPool.Task,
    runtime: *Runtime,
    execute_fn: *const fn (*AnyBlockingTask) void,

    const wait_node_vtable = WaitNode.VTable{};

    pub inline fn fromAwaitable(awaitable: *Awaitable) *AnyBlockingTask {
        assert(awaitable.kind == .blocking_task);
        return @fieldParentPtr("awaitable", awaitable);
    }

    /// Request cancellation of this blocking task.
    /// If the task hasn't started executing yet, it will skip execution.
    /// If already executing, this has no effect (cannot stop blocking work).
    pub fn cancel(self: *AnyBlockingTask) void {
        self.awaitable.requestCancellation();
    }
};

// Future for runtime - not backed by computation, can be set from callbacks
pub const AnyFuture = struct {
    awaitable: Awaitable,
    runtime: *Runtime,

    const wait_node_vtable = WaitNode.VTable{};

    pub inline fn fromAwaitable(awaitable: *Awaitable) *AnyFuture {
        assert(awaitable.kind == .future);
        return @fieldParentPtr("awaitable", awaitable);
    }
};

// Shared implementation for all Future types (Task, BlockingTask, Future)
fn FutureImpl(comptime T: type, comptime Base: type, comptime Parent: type) type {
    return struct {
        base: Base,
        future_result: FutureResult(T),

        // Future protocol - Result type
        pub const Result = T;

        pub fn wait(parent: *Parent) Cancelable!select.WaitResult(T) {
            // Check if already completed
            if (parent.impl.future_result.get()) |res| {
                return .{ .value = res };
            }

            // Wait for completion using select.wait()
            const runtime = Parent.getRuntime(parent);
            return try select.wait(runtime, parent);
        }

        pub fn cancel(parent: *Parent) void {
            parent.impl.base.awaitable.requestCancellation();
        }

        pub fn fromAny(base: *Base) *Parent {
            const impl_ptr: *@This() = @fieldParentPtr("base", base);
            return @fieldParentPtr("impl", impl_ptr);
        }

        pub fn fromAwaitable(awaitable: *Awaitable) *Parent {
            const base_ptr = Base.fromAwaitable(awaitable);
            return fromAny(base_ptr);
        }

        pub fn deinit(parent: *Parent) void {
            const runtime = Parent.getRuntime(parent);
            runtime.releaseAwaitable(&parent.impl.base.awaitable);
        }

        /// Registers a wait node to be notified when the task completes.
        /// This is part of the Future protocol for select().
        /// Returns false if the task is already complete (no wait needed), true if added to queue.
        pub fn asyncWait(parent: *const Parent, wait_node: *WaitNode) bool {
            return parent.impl.base.awaitable.asyncWait(wait_node);
        }

        /// Cancels a pending wait operation by removing the wait node.
        /// This is part of the Future protocol for select().
        pub fn asyncCancelWait(parent: *const Parent, wait_node: *WaitNode) void {
            parent.impl.base.awaitable.asyncCancelWait(wait_node);
        }

        /// Returns pointer to the underlying awaitable for self-wait detection.
        /// This is part of the Future protocol for select().
        pub fn toAwaitable(parent: *const Parent) *const Awaitable {
            return &parent.impl.base.awaitable;
        }

        /// Gets the result value.
        /// This is part of the Future protocol for select().
        /// Asserts that the task has completed.
        pub fn getResult(parent: *Parent) T {
            return parent.impl.future_result.get().?;
        }
    };
}

// Typed task that contains the AnyTask and FutureResult
pub fn Task(comptime T: type) type {
    return struct {
        const Self = @This();
        const Impl = FutureImpl(T, AnyTask, Self);

        impl: Impl,

        pub const Result = Impl.Result;
        pub const deinit = Impl.deinit;
        pub const wait = Impl.wait;
        pub const cancel = Impl.cancel;
        pub const fromAny = Impl.fromAny;
        pub const fromAwaitable = Impl.fromAwaitable;
        pub const asyncWait = Impl.asyncWait;
        pub const asyncCancelWait = Impl.asyncCancelWait;
        pub const toAwaitable = Impl.toAwaitable;
        pub const getResult = Impl.getResult;

        pub fn getRuntime(self: *Self) *Runtime {
            const executor = Executor.fromCoroutine(&self.impl.base.coro);
            return executor.runtime();
        }

        fn destroyFn(runtime: *Runtime, awaitable: *Awaitable) void {
            const any_task = AnyTask.fromAwaitable(awaitable);
            const self = fromAny(any_task);
            // Stack is released by executor when coroutine becomes dead
            std.debug.assert(any_task.coro.stack == null);
            runtime.allocator.destroy(self);
        }
    };
}

// Typed blocking task that contains the AnyBlockingTask and FutureResult
pub fn BlockingTask(comptime T: type) type {
    return struct {
        const Self = @This();
        const Impl = FutureImpl(T, AnyBlockingTask, Self);

        impl: Impl,

        pub const Result = Impl.Result;
        pub const deinit = Impl.deinit;
        pub const wait = Impl.wait;
        pub const cancel = Impl.cancel;
        pub const fromAny = Impl.fromAny;
        pub const fromAwaitable = Impl.fromAwaitable;
        pub const asyncWait = Impl.asyncWait;
        pub const asyncCancelWait = Impl.asyncCancelWait;
        pub const toAwaitable = Impl.toAwaitable;
        pub const getResult = Impl.getResult;

        pub fn getRuntime(self: *Self) *Runtime {
            return self.impl.base.runtime;
        }

        pub fn init(
            runtime: *Runtime,
            allocator: Allocator,
            func: anytype,
            args: meta.ArgsType(func),
        ) !*Self {
            const thread_pool = runtime.thread_pool orelse return error.NoThreadPool;

            const Args = @TypeOf(args);

            const TaskData = struct {
                blocking_task: Self,
                args: Args,

                fn execute(any_blocking_task: *AnyBlockingTask) void {
                    const blocking_task = Self.fromAny(any_blocking_task);
                    const self: *@This() = @fieldParentPtr("blocking_task", blocking_task);

                    const res = @call(.always_inline, func, self.args);
                    _ = self.blocking_task.impl.future_result.set(res);
                }

                fn destroy(rt: *Runtime, awaitable: *Awaitable) void {
                    const any_blocking_task = AnyBlockingTask.fromAwaitable(awaitable);
                    const blocking_task = Self.fromAny(any_blocking_task);
                    const self: *@This() = @fieldParentPtr("blocking_task", blocking_task);
                    rt.allocator.destroy(self);
                }
            };

            const task_data = try allocator.create(TaskData);
            errdefer allocator.destroy(task_data);

            task_data.* = .{
                .blocking_task = .{
                    .impl = .{
                        .base = .{
                            .awaitable = .{
                                .kind = .blocking_task,
                                .destroy_fn = &TaskData.destroy,
                                .wait_node = .{
                                    .vtable = &AnyBlockingTask.wait_node_vtable,
                                },
                            },
                            .thread_pool_task = .{ .callback = threadPoolCallback },
                            .runtime = runtime,
                            .execute_fn = &TaskData.execute,
                        },
                        .future_result = FutureResult(T){},
                    },
                },
                .args = args,
            };

            // Increment ref count for the JoinHandle
            task_data.blocking_task.impl.base.awaitable.ref_count.incr();

            thread_pool.schedule(
                xev.ThreadPool.Batch.from(&task_data.blocking_task.impl.base.thread_pool_task),
            );

            return &task_data.blocking_task;
        }
    };
}

// Public handle for spawned tasks and futures
pub fn JoinHandle(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const Result = T;

        awaitable: *Awaitable,

        pub fn deinit(self: *Self) void {
            const runtime = switch (self.awaitable.kind) {
                .task => Task(T).fromAwaitable(self.awaitable).getRuntime(),
                .blocking_task => BlockingTask(T).fromAwaitable(self.awaitable).getRuntime(),
            };
            runtime.releaseAwaitable(self.awaitable);
        }

        pub fn join(self: *Self, rt: *Runtime) T {
            return switch (self.awaitable.kind) {
                .task => select.waitUntilComplete(rt, Task(T).fromAwaitable(self.awaitable)),
                .blocking_task => select.waitUntilComplete(rt, BlockingTask(T).fromAwaitable(self.awaitable)),
            };
        }

        /// Check if the task has completed and a result is available.
        pub fn hasResult(self: *const Self) bool {
            return self.awaitable.done.load(.acquire);
        }

        /// Get the result value of type T (preserving any error union).
        /// Asserts that the task has already completed.
        /// This is used internally by select() to preserve error union types.
        pub fn getResult(self: *Self) T {
            assert(self.hasResult());

            // Get the stored result of type T
            return switch (self.awaitable.kind) {
                .task => Task(T).fromAwaitable(self.awaitable).impl.future_result.get().?,
                .blocking_task => BlockingTask(T).fromAwaitable(self.awaitable).impl.future_result.get().?,
            };
        }

        /// Registers a wait node to be notified when the task completes.
        /// This is part of the Future protocol for select().
        /// Returns false if the task is already complete (no wait needed), true if added to queue.
        pub fn asyncWait(self: Self, wait_node: *WaitNode) bool {
            return self.awaitable.asyncWait(wait_node);
        }

        /// Cancels a pending wait operation by removing the wait node.
        /// This is part of the Future protocol for select().
        pub fn asyncCancelWait(self: Self, wait_node: *WaitNode) void {
            self.awaitable.asyncCancelWait(wait_node);
        }

        /// Request cancellation of this task.
        /// For coroutine tasks: Sets the cancellation flag, which will be checked at the next yield point.
        /// For blocking tasks: Sets the cancellation flag, which will skip execution if not yet started.
        /// For futures: Has no effect (futures are not cancelable).
        pub fn cancel(self: *Self) void {
            self.awaitable.requestCancellation();
        }

        /// Get the executor ID for this task.
        /// Only valid for coroutine tasks (not blocking tasks or futures).
        /// Returns null if this is not a coroutine task.
        pub fn getExecutorId(self: *const Self) ?usize {
            return switch (self.awaitable.kind) {
                .task => {
                    const task = Task(T).fromAwaitable(self.awaitable);
                    const executor = task.impl.base.getExecutor();
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
            const P1 = meta.Payload(T);
            const P2 = meta.Payload(T2);
            if (P1 != P2) {
                @compileError("cast() can only change error set, not payload type. " ++
                    "Source payload: " ++ @typeName(P1) ++ ", target payload: " ++ @typeName(P2));
            }

            return JoinHandle(T2){ .awaitable = self.awaitable };
        }
    };
}

// Generic data structures (private)
const WaitNode = @import("core/WaitNode.zig");
const ConcurrentStack = @import("utils/concurrent_stack.zig").ConcurrentStack;
const WaitQueue = @import("utils/wait_queue.zig").WaitQueue;
const SimpleStack = @import("utils/simple_stack.zig").SimpleStack;
const SimpleQueue = @import("utils/simple_queue.zig").SimpleQueue;

// Executor metrics
pub const ExecutorMetrics = struct {
    yields: u64 = 0,
    tasks_spawned: u64 = 0,
    tasks_completed: u64 = 0,
};

comptime {
    std.debug.assert(@alignOf(WaitNode) == 8);
}

// Executor - per-thread execution unit for running coroutines
pub const Executor = struct {
    id: usize,
    loop: xev.Loop,
    stack_pool: StackPool,
    main_context: coroutines.Context,
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
    remote_wakeup: xev.Async = undefined,
    remote_completion: xev.Completion = undefined,
    remote_initialized: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    // Shutdown support
    shutdown_async: xev.Async = undefined,
    shutdown_completion: xev.Completion = undefined,

    // Stack pool cleanup tracking
    cleanup_interval_ms: i64,
    last_cleanup_ms: i64 = 0,

    // Runtime metrics
    metrics: ExecutorMetrics = .{},

    // Back-reference to runtime for global coordination
    runtime_ptr: *Runtime = undefined,

    // Worker thread (null for main executor that runs on calling thread)
    thread: ?std.Thread = null,

    // Coordination for thread startup
    ready: std.Thread.ResetEvent = .{},

    /// Get the Executor instance from any coroutine that belongs to it
    pub fn fromCoroutine(coro: *Coroutine) *Executor {
        return @fieldParentPtr("main_context", coro.parent_context_ptr);
    }

    /// Get the Runtime instance from this Executor
    pub inline fn runtime(self: *Executor) *Runtime {
        return self.runtime_ptr;
    }

    pub fn init(self: *Executor, id: usize, allocator: Allocator, options: RuntimeOptions) !void {
        // Establish stable memory location with defaults
        // Loop will be initialized later from the thread that runs it
        self.* = .{
            .id = id,
            .allocator = allocator,
            .loop = undefined,
            .stack_pool = StackPool.init(allocator, options.stack_pool),
            .cleanup_interval_ms = options.stack_pool.cleanup_interval_ms,
            .lifo_slot_enabled = options.lifo_slot_enabled,
            .main_context = undefined,
            .remote_wakeup = undefined,
            .remote_completion = undefined,
        };
    }

    fn initLoop(self: *Executor) !void {
        // Initialize loop from the thread that will run it
        self.loop = try xev.Loop.init(.{
            .thread_pool = self.runtime_ptr.thread_pool,
        });
        errdefer self.loop.deinit();

        // Initialize remote wakeup
        self.remote_wakeup = try xev.Async.init();
        errdefer self.remote_wakeup.deinit();

        // Register async completion to wake up loop (self pointer is stable)
        self.remote_wakeup.wait(
            &self.loop,
            &self.remote_completion,
            Executor,
            self,
            remoteWakeupCallback,
        );

        // Initialize shutdown async
        self.shutdown_async = try xev.Async.init();
        errdefer self.shutdown_async.deinit();

        // Register shutdown callback
        self.shutdown_async.wait(
            &self.loop,
            &self.shutdown_completion,
            Executor,
            self,
            shutdownCallback,
        );

        self.remote_initialized.store(true, .release);
    }

    fn deinitLoop(self: *Executor) void {
        self.shutdown_async.deinit();
        self.remote_wakeup.deinit();
        self.loop.deinit();
    }

    pub fn deinit(self: *Executor) void {
        // Note: ThreadPool and loop are owned by thread that runs them
        // Loop cleanup is handled in deinitLoop() called from run*()
        // Task cleanup is handled by Runtime.deinit()

        // Clean up stack pool
        self.stack_pool.deinit();
    }

    pub fn spawn(self: *Executor, func: anytype, args: meta.ArgsType(func), options: SpawnOptions) !JoinHandle(meta.ReturnType(func)) {
        const Result = meta.ReturnType(func);
        const TypedTask = Task(Result);

        // Allocate task struct
        const task = try self.allocator.create(TypedTask);
        errdefer self.allocator.destroy(task);

        // Acquire stack from pool (thread-safe with stack pool changes)
        const stack = try self.stack_pool.acquire(options.stack_size orelse coroutines.DEFAULT_STACK_SIZE);
        errdefer self.stack_pool.release(stack);

        task.* = .{
            .impl = .{
                .base = .{
                    .awaitable = .{
                        .kind = .task,
                        .destroy_fn = &TypedTask.destroyFn,
                        .wait_node = .{
                            .vtable = &AnyTask.wait_node_vtable,
                        },
                    },
                    .coro = .{
                        .stack = stack,
                        .parent_context_ptr = &self.main_context,
                        .state = .init(.waiting_sync),
                    },
                },
                .future_result = .{},
            },
        };

        task.impl.base.coro.setup(func, args, &task.impl.future_result);

        // Set pin count if task is pinned or assigned to a specific executor
        if (options.pinned or options.executor.isId()) {
            task.impl.base.pin_count = 1;
        }

        // Increment ref count for JoinHandle
        task.impl.base.awaitable.ref_count.incr();

        // Add to global task registry (can fail if runtime is shutting down)
        try self.runtime().tasks.add(&task.impl.base);
        errdefer _ = self.runtime().tasks.remove(&task.impl.base);

        // Schedule the task to run (handles cross-thread notification)
        self.scheduleTask(&task.impl.base, .maybe_remote);

        // Track task spawn
        self.metrics.tasks_spawned += 1;

        return JoinHandle(Result){ .awaitable = &task.impl.base.awaitable };
    }

    pub const YieldCancelMode = enum { allow_cancel, no_cancel };

    /// Cooperatively yield control to other tasks.
    ///
    /// Suspends the current coroutine and allows other tasks to run. The coroutine
    /// will be rescheduled according to `desired_state`:
    /// - `.ready`: Reschedule immediately (cooperative yielding)
    /// - `.waiting_io`: Suspend until I/O completes (e.g., waiting for xev completion)
    /// - `.waiting_sync`: Suspend until sync primitive signals (e.g., mutex, condition, channel)
    /// - `.dead`: Mark coroutine as complete (internal use only)
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
    pub fn yield(self: *Executor, expected_state: CoroutineState, desired_state: CoroutineState, comptime cancel_mode: YieldCancelMode) if (cancel_mode == .allow_cancel) Cancelable!void else void {
        const current_coro = self.current_coroutine orelse return;
        const current_task = AnyTask.fromCoroutine(current_coro);

        // Track yield
        self.metrics.yields += 1;

        // Check and consume cancellation flag before yielding (unless shielded or no_cancel)
        if (cancel_mode == .allow_cancel and current_task.shield_count == 0) {
            // cmpxchgStrong returns null on success, current value on failure
            if (current_task.awaitable.canceled.cmpxchgStrong(true, false, .acquire, .acquire) == null) {
                // CAS succeeded: we consumed true, return canceled
                return error.Canceled;
            }
        }

        // Atomically transition state - if this fails, someone changed our state
        if (current_coro.state.cmpxchgStrong(expected_state, desired_state, .release, .acquire)) |actual_state| {
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

        // If dead, always switch to scheduler for cleanup
        if (desired_state == .dead) {
            coroutines.switchContext(&current_coro.context, current_coro.parent_context_ptr);
            unreachable;
        }

        // Try to switch directly to the next ready task (checks LIFO slot first)
        if (self.getNextTask()) |next_wait_node| {
            const next_task = AnyTask.fromWaitNode(next_wait_node);

            self.current_coroutine = &next_task.coro;
            coroutines.switchContext(&current_coro.context, &next_task.coro.context);
        } else {
            // No ready tasks - return to scheduler
            coroutines.switchContext(&current_coro.context, current_coro.parent_context_ptr);
        }

        // After resuming, the task may have migrated to a different executor.
        // Re-derive the current executor from TLS instead of using the captured `self`.
        const resumed_executor = Runtime.current_executor orelse unreachable;
        std.debug.assert(resumed_executor.current_coroutine == current_coro);

        // Check again after resuming in case we were canceled while suspended (unless shielded or no_cancel)
        if (cancel_mode == .allow_cancel and current_task.shield_count == 0) {
            if (current_task.awaitable.canceled.cmpxchgStrong(true, false, .acquire, .acquire) == null) {
                return error.Canceled;
            }
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
    /// This consumes the cancellation flag.
    /// Use this after endShield() to detect cancellation that occurred during the shielded section.
    pub fn checkCanceled(self: *Executor) Cancelable!void {
        const current_coro = self.current_coroutine orelse unreachable;
        const current_task = AnyTask.fromCoroutine(current_coro);
        // Check and consume cancellation flag
        if (current_task.awaitable.canceled.cmpxchgStrong(true, false, .acquire, .acquire) == null) {
            return error.Canceled;
        }
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
        self.timedWaitForReady(.ready, .waiting_io, milliseconds * 1_000_000) catch |err| switch (err) {
            error.Timeout => return, // Expected for sleep - not an error
            error.Canceled => return error.Canceled, // Propagate cancellation
        };
        unreachable; // Should always timeout or be canceled
    }

    /// Check if task list is empty and initiate shutdown if so.
    /// Only one executor will succeed in closing the registry due to atomic transition.
    /// Can be called by any executor.
    fn maybeShutdown(self: *Executor) void {
        if (self.runtime_ptr.tasks.isEmpty()) {
            // Try to atomically close the registry (empty_open → empty_closed)
            if (self.runtime_ptr.tasks.close()) {
                // We won the race - initiate shutdown
                self.runtime_ptr.shutting_down.store(true, .release);

                // Wake all executors (including main if sleeping in event loop)
                for (self.runtime_ptr.executors.items) |*executor| {
                    executor.shutdown_async.notify() catch {};
                }
            } else |_| {
                // Another executor is closing or tasks were added - do nothing
            }
        }
    }

    /// Run the executor event loop.
    /// Main executor (id=0) orchestrates shutdown when all tasks complete.
    /// Worker executors (id>0) run until signaled to shut down by main executor.
    pub fn run(self: *Executor) !void {
        // Initialize loop on this thread
        try self.initLoop();
        defer self.deinitLoop();

        // Signal that executor is ready
        self.ready.set();

        // Set thread-local current executor
        Runtime.current_executor = self;
        defer Runtime.current_executor = null;

        // Check if we're starting with an empty task list
        // If so, immediately initiate shutdown (no work to do)
        self.maybeShutdown();

        var spin_count: u8 = 0;
        while (true) {
            // Exit if loop was stopped (by shutdown callback)
            if (self.loop.stopped()) break;

            // Time-based stack pool cleanup
            const now = std.time.milliTimestamp();
            if (now - self.last_cleanup_ms >= self.cleanup_interval_ms) {
                self.stack_pool.cleanup();
                self.last_cleanup_ms = now;
            }

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
                coroutines.switchContext(&self.main_context, &task.coro.context);

                // Handle dead coroutines (checks current_coroutine to catch tasks that died via direct switch in yield())
                if (self.current_coroutine) |current_coro| {
                    if (current_coro.state.load(.acquire) == .dead) {
                        const current_task = AnyTask.fromCoroutine(current_coro);
                        const current_awaitable = &current_task.awaitable;

                        // Release stack immediately since coroutine execution is complete
                        if (current_coro.stack) |stack| {
                            self.stack_pool.release(stack);
                            current_coro.stack = null;
                        }

                        // Mark awaitable as complete and wake all waiters (coroutines and threads)
                        current_awaitable.markComplete();

                        // Track task completion
                        self.metrics.tasks_completed += 1;

                        // Remove from global task registry and release runtime's reference
                        _ = self.runtime_ptr.tasks.remove(current_task);
                        self.runtime().releaseAwaitable(current_awaitable);
                        // If ref_count > 0, Task(T) handles still exist, keep the task alive

                        // Check if we just removed the last task and maybe initiate shutdown
                        self.maybeShutdown();
                    }
                }

                // Other states (.ready, .waiting_io, .waiting_sync) are handled by yield() or markReady()
            }

            // Move yielded coroutines back to ready queue
            self.ready_queue.concatByMoving(&self.next_ready_queue);

            // Determine event loop run mode based on work availability and spin count
            // Spin briefly with non-blocking polls before blocking to reduce cross-thread wakeup latency
            const has_work = self.ready_queue.head != null or self.lifo_slot != null;
            const run_mode: xev.RunMode = if (has_work or spin_count < 16) .no_wait else .once;

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

        // Notify the target executor's event loop (only if initialized)
        const initialized = self.remote_initialized.load(.acquire);
        if (initialized) {
            self.remote_wakeup.notify() catch |err| {
                std.log.warn("remote_wakeup.notify() failed for executor {}: {}", .{ self.id, err });
            };
        }
    }

    /// Schedule a task for execution. Called on the task's home executor (self).
    /// Atomically transitions task state to .ready and schedules it for execution.
    ///
    /// Task migration for cache locality:
    /// - Sync tasks (.waiting_sync) with .maybe_remote: May migrate to current executor if in same runtime
    /// - I/O tasks (.waiting_io): Always stay on home executor (cannot migrate)
    /// - Spawn tasks (.ready): Schedule on home executor
    ///
    /// The `mode` parameter:
    /// - `.maybe_remote`: Enables migration for sync tasks, uses remote queue when needed
    /// - `.local`: No migration, always uses home executor (for I/O callbacks)
    pub fn scheduleTask(self: *Executor, task: *AnyTask, comptime mode: ResumeMode) void {
        const old_state = task.coro.state.swap(.ready, .acq_rel);

        // Task hasn't yielded yet - it will see .ready and skip the yield
        if (old_state == .preparing_to_wait) return;

        // I/O tasks cannot migrate (bound to home executor's event loop)
        if (old_state == .waiting_io) {
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
            return;
        }

        // Task already transitioned to .ready by another thread - avoid double-schedule
        if (old_state == .ready) return;

        // Any non-waiting state is a bug
        if (!old_state.isWaiting()) {
            std.debug.panic("scheduleTask: unexpected state {} for task {*}", .{ old_state, task });
        }

        // Sync tasks can migrate for cache locality (waiting_sync state only)
        if (old_state == .waiting_sync and mode == .maybe_remote and task.pin_count == 0) {
            const current_exec = Runtime.current_executor orelse {
                self.scheduleTaskRemote(task);
                return;
            };

            // Check if we can migrate (same runtime, different executor)
            if (current_exec.runtime_ptr == self.runtime_ptr) {
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

        // Default path: .ready state (spawn) or .local mode
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

    /// Get a copy of the current metrics
    pub fn getMetrics(self: *Executor) ExecutorMetrics {
        return self.metrics;
    }

    /// Reset all metrics to zero
    pub fn resetMetrics(self: *Executor) void {
        self.metrics = .{};
    }

    /// Pack a pointer and 2-bit generation into a tagged pointer for userdata.
    /// Uses lower 2 bits for generation (pointers are aligned).
    inline fn packTimerUserdata(comptime T: type, ptr: *T, generation: u2) ?*anyopaque {
        comptime {
            if (@alignOf(T) < 4) @compileError("Timer userdata T must be at least 4-byte aligned");
        }
        const addr = @intFromPtr(ptr);
        const tagged = addr | @as(usize, generation);
        return @ptrFromInt(tagged);
    }

    /// Unpack a tagged pointer into the original pointer and generation.
    inline fn unpackTimerUserdata(comptime T: type, userdata: ?*anyopaque) struct { ptr: *T, generation: u2 } {
        comptime {
            if (@alignOf(T) < 4) @compileError("Timer userdata T must be at least 4-byte aligned");
        }
        const addr = @intFromPtr(userdata);
        const generation: u2 = @truncate(addr & 0x3);
        const ptr_addr = addr & ~@as(usize, 0x3);
        return .{
            .ptr = @ptrFromInt(ptr_addr),
            .generation = generation,
        };
    }

    /// Wait for the current coroutine to be marked ready, with a timeout and custom timeout handler.
    /// The onTimeout callback is called when the timer fires, and should return true if the
    /// coroutine should be woken with error.Timeout, or false if it was already signaled by
    /// another source (in which case the timeout is ignored).
    pub fn timedWaitForReadyWithCallback(
        self: *Executor,
        expected_state: CoroutineState,
        desired_state: CoroutineState,
        timeout_ns: u64,
        comptime TimeoutContext: type,
        timeout_ctx: *TimeoutContext,
        comptime onTimeout: fn (ctx: *TimeoutContext) bool,
    ) error{ Timeout, Canceled }!void {
        const current = self.current_coroutine orelse unreachable;
        const task = AnyTask.fromCoroutine(current);

        const CallbackContext = struct {
            user_ctx: *TimeoutContext,
            timed_out: bool,
        };

        var ctx = CallbackContext{
            .user_ctx = timeout_ctx,
            .timed_out = false,
        };

        var timer = xev.Timer.init() catch unreachable;
        defer timer.deinit();

        // Use timer reset which handles both initial start and restart after cancel
        // Pack context pointer with generation in lower 2 bits
        const tagged_userdata = packTimerUserdata(CallbackContext, &ctx, task.timer_generation);
        timer.reset(
            &self.loop,
            &task.timer_c,
            &task.timer_cancel_c,
            timeout_ns / 1_000_000,
            anyopaque,
            tagged_userdata,
            struct {
                fn callback(
                    userdata: ?*anyopaque,
                    l: *xev.Loop,
                    c: *xev.Completion,
                    r: xev.Timer.RunError!void,
                ) xev.CallbackAction {
                    _ = l;
                    _ = r catch {};

                    // Get task safely from completion (always valid)
                    const t: *AnyTask = @fieldParentPtr("timer_c", c);

                    // Unpack generation from tagged pointer (no deref yet!)
                    const unpacked = unpackTimerUserdata(CallbackContext, userdata);

                    // Check if this callback is from a stale timer
                    if (t.timer_generation != unpacked.generation) {
                        // Stale callback - context is freed, don't touch it!
                        return .disarm;
                    }

                    // Generation matches - safe to dereference context
                    const ctx_ptr = unpacked.ptr;
                    if (onTimeout(ctx_ptr.user_ctx)) {
                        ctx_ptr.timed_out = true;
                        resumeTask(&t.coro, .local);
                    }
                    return .disarm;
                }
            }.callback,
        );

        // Wait for either timeout or external markReady
        self.yield(expected_state, desired_state, .allow_cancel) catch |err| {
            // Invalidate pending callbacks before unwinding so they ignore this stack frame.
            task.timer_generation +%= 1;
            timer.cancel(
                &self.loop,
                &task.timer_c,
                &task.timer_cancel_c,
                void,
                null,
                noopTimerCancelCallback,
            );
            return err;
        };

        if (ctx.timed_out) {
            return error.Timeout;
        }

        // Timer already completed, no need to cancel
        if (task.timer_c.state() == .dead) {
            return;
        }

        // Was awakened by external markReady → increment generation to invalidate
        // any pending timer callback, then cancel async
        task.timer_generation +%= 1;
        timer.cancel(
            &self.loop,
            &task.timer_c,
            &task.timer_cancel_c,
            void,
            null,
            noopTimerCancelCallback,
        );
    }

    pub fn timedWaitForReady(self: *Executor, expected_state: CoroutineState, desired_state: CoroutineState, timeout_ns: u64) error{ Timeout, Canceled }!void {
        const DummyContext = struct {};
        var dummy: DummyContext = .{};
        return self.timedWaitForReadyWithCallback(
            expected_state,
            desired_state,
            timeout_ns,
            DummyContext,
            &dummy,
            struct {
                fn onTimeout(_: *DummyContext) bool {
                    return true;
                }
            }.onTimeout,
        );
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
    executors: std.ArrayList(Executor),
    thread_pool: ?*xev.ThreadPool,
    allocator: Allocator,
    options: RuntimeOptions,

    // Multi-executor coordination
    next_executor: std.atomic.Value(usize),
    tasks: AnyTaskList = .{}, // Global task registry with built-in closed state
    shutting_down: std.atomic.Value(bool), // Signals executors to stop (set once)

    /// Thread-local storage for the current executor
    pub threadlocal var current_executor: ?*Executor = null;

    pub fn init(allocator: Allocator, options: RuntimeOptions) !Runtime {
        // Determine number of executors
        const num_executors = if (options.num_executors) |n|
            n
        else blk: {
            // null = auto-detect CPU count
            const cpu_count = std.Thread.getCpuCount() catch 1;
            break :blk @max(1, cpu_count);
        };

        // Initialize ThreadPool if enabled (shared resource)
        var thread_pool: ?*xev.ThreadPool = null;
        if (options.thread_pool.enabled) {
            thread_pool = try allocator.create(xev.ThreadPool);

            var config = xev.ThreadPool.Config{};
            if (options.thread_pool.max_threads) |max| config.max_threads = max;
            if (options.thread_pool.stack_size) |size| config.stack_size = size;
            thread_pool.?.* = xev.ThreadPool.init(config);
        }
        errdefer if (thread_pool) |tp| {
            tp.shutdown();
            tp.deinit();
            allocator.destroy(tp);
        };

        // Initialize executors using ArrayList for clean error handling
        var executors = try std.ArrayList(Executor).initCapacity(allocator, num_executors);
        errdefer {
            for (executors.items) |*exec| {
                exec.deinit();
            }
            executors.deinit(allocator);
        }

        for (0..num_executors) |i| {
            var executor: Executor = undefined;
            try executor.init(i, allocator, options);
            executors.appendAssumeCapacity(executor);
        }

        return Runtime{
            .executors = executors,
            .thread_pool = thread_pool,
            .allocator = allocator,
            .options = options,
            .next_executor = std.atomic.Value(usize).init(0),
            .shutting_down = std.atomic.Value(bool).init(false),
        };
    }

    pub fn deinit(self: *Runtime) void {
        // Shutdown ThreadPool before cleaning up executors
        if (self.thread_pool) |tp| {
            tp.shutdown();
        }

        // Drain any remaining tasks from global registry
        while (self.tasks.pop()) |task| {
            self.releaseAwaitable(&task.awaitable);
        }

        // Deinit all executors (they own their threads)
        for (self.executors.items) |*exec| {
            exec.deinit();
        }

        // Free executors ArrayList
        self.executors.deinit(self.allocator);

        // Clean up ThreadPool after executors
        if (self.thread_pool) |tp| {
            tp.deinit();
            self.allocator.destroy(tp);
        }
    }

    // High-level public API - delegates to appropriate Executor
    pub fn spawn(self: *Runtime, func: anytype, args: meta.ArgsType(func), options: SpawnOptions) !JoinHandle(meta.ReturnType(func)) {
        // Check if runtime is shutting down
        if (self.tasks.isClosed()) {
            return error.RuntimeShutdown;
        }

        // Determine target executor
        const executor_id = switch (options.executor) {
            .any => self.next_executor.fetchAdd(1, .monotonic) % self.executors.items.len,
            .same => if (Runtime.current_executor) |current_exec|
                current_exec.id
            else
                self.next_executor.fetchAdd(1, .monotonic) % self.executors.items.len,
            _ => |id| blk: {
                const raw_id = @intFromEnum(id);
                if (raw_id >= self.executors.items.len) {
                    return error.InvalidExecutorId;
                }
                break :blk raw_id;
            },
        };

        const executor = &self.executors.items[executor_id];

        // Set runtime back-references (in case runtime was moved after init)
        executor.runtime_ptr = self;

        return executor.spawn(func, args, options);
    }

    pub fn spawnBlocking(self: *Runtime, func: anytype, args: meta.ArgsType(func)) !JoinHandle(meta.ReturnType(func)) {
        // Check if runtime is shutting down
        if (self.tasks.isClosed()) {
            return error.RuntimeShutdown;
        }

        if (self.thread_pool == null) return error.ThreadPoolRequired;

        const Result = meta.ReturnType(func);
        const task = try BlockingTask(Result).init(
            self,
            self.allocator,
            func,
            args,
        );

        return JoinHandle(Result){ .awaitable = &task.impl.base.awaitable };
    }

    /// Worker thread entry point
    fn workerThreadFn(self: *Runtime, executor_index: usize) void {
        self.executors.items[executor_index].run() catch |err| {
            std.log.err("Worker executor {} failed: {}", .{ executor_index, err });
        };
    }

    pub fn run(self: *Runtime) !void {
        // Set runtime back-references (in case runtime was moved after init)
        for (self.executors.items) |*exec| {
            exec.runtime_ptr = self;
        }

        // If single-threaded, just run the main executor
        if (self.executors.items.len == 1) {
            return self.executors.items[0].run();
        }

        // Multi-threaded: spawn worker threads for executors[1..]
        for (self.executors.items[1..], 1..) |*executor, i| {
            executor.thread = try std.Thread.spawn(.{}, workerThreadFn, .{ self, i });
        }

        // Wait for all workers to be ready (loop initialized)
        for (self.executors.items[1..]) |*executor| {
            executor.ready.wait();
        }

        // Run main executor on current thread
        const main_result = self.executors.items[0].run();

        // Join all worker threads
        for (self.executors.items[1..]) |*executor| {
            if (executor.thread) |thread| {
                thread.join();
            }
        }

        return main_result;
    }

    pub fn runUntilComplete(self: *Runtime, func: anytype, args: meta.ArgsType(func), options: SpawnOptions) !meta.Payload(meta.ReturnType(func)) {
        // Spawn on first executor (explicit pinning)
        var spawn_options = options;
        spawn_options.executor = ExecutorId.id(0);
        var handle = try self.spawn(func, args, spawn_options);
        defer handle.deinit();

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
        std.Thread.sleep(milliseconds * std.time.ns_per_ms);
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

    /// Get a copy of the current executor metrics (from executor 0).
    /// In multi-threaded mode, returns metrics from the main executor only.
    pub fn getMetrics(self: *Runtime) ExecutorMetrics {
        return self.executors.items[0].getMetrics();
    }

    /// Reset all executor metrics to zero
    pub fn resetMetrics(self: *Runtime) void {
        for (self.executors.items) |*executor| {
            executor.resetMetrics();
        }
    }

    /// Get the current time in milliseconds.
    /// This uses the event loop's cached monotonic time for efficiency.
    /// In multi-threaded mode, uses the main executor's loop time.
    pub fn now(self: *Runtime) i64 {
        return self.executors.items[0].loop.now();
    }

    fn releaseAwaitable(self: *Runtime, awaitable: *Awaitable) void {
        if (awaitable.ref_count.decr()) {
            awaitable.destroy_fn(self, awaitable);
        }
    }

    pub fn io(self: *Runtime) Io {
        return .{ .userdata = self };
    }

    pub fn fromIo(io_: Io) *Runtime {
        return @ptrCast(io_.userdata);
    }
};

test "runtime with thread pool smoke test" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{
        .thread_pool = .{ .enabled = true },
    });
    defer runtime.deinit();

    // Verify ThreadPool was created
    testing.expect(runtime.thread_pool != null) catch |err| {
        std.debug.print("ThreadPool was not created when enabled\n", .{});
        return err;
    };

    // Run empty runtime (should exit immediately)
    try runtime.run();
}

test "runtime: multi-threaded with auto-detect executors" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{
        .num_executors = null, // Auto-detect CPU count
    });
    defer runtime.deinit();

    // Verify we have multiple executors
    try testing.expect(runtime.executors.items.len >= 1);

    const TestContext = struct {
        fn task(rt: *Runtime, id: usize) Cancelable!usize {
            try rt.sleep(1);
            return id * 2;
        }

        fn mainTask(rt: *Runtime) !void {
            // Spawn multiple tasks
            var handles: [10]JoinHandle(Cancelable!usize) = undefined;
            for (&handles, 0..) |*handle, i| {
                handle.* = try rt.spawn(task, .{ rt, i }, .{});
            }
            defer for (&handles) |*handle| handle.deinit();

            // Wait for all tasks
            for (&handles, 0..) |*handle, i| {
                const result = try handle.join(rt);
                try testing.expectEqual(i * 2, result);
            }
        }
    };

    try runtime.runUntilComplete(TestContext.mainTask, .{&runtime}, .{});
}

test "runtime: multi-threaded with explicit executor count" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{
        .num_executors = 4,
    });
    defer runtime.deinit();

    // Verify we have exactly 4 executors
    try testing.expectEqual(@as(usize, 4), runtime.executors.items.len);

    const TestContext = struct {
        fn task(rt: *Runtime, id: usize) Cancelable!usize {
            try rt.sleep(1);
            return id * 2;
        }

        fn mainTask(rt: *Runtime) !void {
            // Spawn multiple tasks
            var handles: [10]JoinHandle(Cancelable!usize) = undefined;
            var n: usize = 0;
            defer {
                for (handles[0..n]) |*handle| {
                    handle.deinit();
                }
            }
            for (&handles, 0..) |*handle, i| {
                handle.* = try rt.spawn(task, .{ rt, i }, .{});
                n += 1;
            }

            // Wait for all tasks
            for (&handles, 0..) |*handle, i| {
                const result = try handle.join(rt);
                try testing.expectEqual(i * 2, result);
            }
        }
    };

    try runtime.runUntilComplete(TestContext.mainTask, .{&runtime}, .{});
}

test "runtime: multi-threaded with executor pinning" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{
        .num_executors = 4,
    });
    defer runtime.deinit();

    const TestContext = struct {
        fn task(executor_id: usize) usize {
            return executor_id;
        }

        fn mainTask(rt: *Runtime) !void {
            // Pin tasks to specific executors
            var handles: [4]JoinHandle(usize) = undefined;
            for (&handles, 0..) |*handle, i| {
                handle.* = try rt.spawn(task, .{i}, .{ .executor = ExecutorId.id(i) });
            }
            defer for (&handles) |*handle| handle.deinit();

            // Verify results
            for (&handles, 0..) |*handle, i| {
                const result = handle.join(rt);
                try testing.expectEqual(i, result);
            }
        }
    };

    try runtime.runUntilComplete(TestContext.mainTask, .{&runtime}, .{});
}

test "runtime: task colocation with getExecutorId" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{
        .num_executors = 4,
    });
    defer runtime.deinit();

    const TestContext = struct {
        fn getExecutorId() usize {
            const executor = Runtime.current_executor.?;
            return executor.id;
        }

        fn mainTask(rt: *Runtime) !void {
            // Spawn first task on executor 2
            var handle1 = try rt.spawn(getExecutorId, .{}, .{ .executor = ExecutorId.id(2) });
            defer handle1.deinit();

            // Get the executor ID from the first task
            const executor_id = handle1.getExecutorId();
            try testing.expect(executor_id != null);
            try testing.expectEqual(@as(usize, 2), executor_id.?);

            // Spawn second task colocated with the first task
            var handle2 = try rt.spawn(getExecutorId, .{}, .{ .executor = ExecutorId.id(executor_id.?) });
            defer handle2.deinit();

            // Verify both tasks ran on the same executor
            const result1 = handle1.join(rt);
            const result2 = handle2.join(rt);
            try testing.expectEqual(result1, result2);
            try testing.expectEqual(@as(usize, 2), result1);
        }
    };

    try runtime.runUntilComplete(TestContext.mainTask, .{&runtime}, .{});
}

test "runtime: spawnBlocking smoke test" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{
        .thread_pool = .{ .enabled = true },
    });
    defer runtime.deinit();

    const TestContext = struct {
        fn blockingWork(x: i32) i32 {
            return x * 2;
        }

        fn asyncTask(rt: *Runtime) !void {
            var handle = try rt.spawnBlocking(blockingWork, .{21});
            defer handle.deinit();

            const result = handle.join(rt);
            try testing.expectEqual(@as(i32, 42), result);
        }
    };

    try runtime.runUntilComplete(TestContext.asyncTask, .{&runtime}, .{});
}

test "runtime: JoinHandle.cast() error set conversion" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
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
                defer casted.deinit();

                const result = try casted.join(rt);
                try testing.expectEqual(@as(i32, 42), result);
            }

            // Test casting error case
            {
                var handle = try rt.spawn(taskError, .{}, .{});
                var casted = handle.cast(anyerror!i32);
                defer casted.deinit();

                const result = casted.join(rt);
                try testing.expectError(error.Foo, result);
            }
        }
    };

    try runtime.runUntilComplete(TestContext.asyncTask, .{&runtime}, .{});
}

test "runtime: now() returns monotonic time" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
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

    try runtime.runUntilComplete(TestContext.asyncTask, .{&runtime}, .{});
}

test "runtime: sleep is cancelable" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    const TestContext = struct {
        fn sleepingTask(rt: *Runtime) !void {
            // This will sleep for 1 second but should be canceled before completion
            try rt.sleep(1000);
            // Should not reach here
            return error.TestUnexpectedResult;
        }

        fn asyncTask(rt: *Runtime) !void {
            var handle = try rt.spawn(sleepingTask, .{rt}, .{});
            defer handle.deinit();

            // Give it a chance to start sleeping
            try rt.yield();
            try rt.yield();

            // Cancel the sleeping task
            handle.cancel();

            // Should return error.Canceled
            const result = handle.join(rt);
            try testing.expectError(error.Canceled, result);
        }
    };

    try runtime.runUntilComplete(TestContext.asyncTask, .{&runtime}, .{});
}
