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
const RefCounter = @import("sync/ref_counter.zig").RefCounter;
const FutureResult = @import("future_result.zig").FutureResult;
const stack_pool = @import("stack_pool.zig");
const StackPool = stack_pool.StackPool;
const StackPoolOptions = stack_pool.StackPoolOptions;

// Compile-time detection of whether the backend needs ThreadPool
fn backendNeedsThreadPool() bool {
    return @hasField(xev.Loop, "thread_pool");
}

/// Options for spawning a coroutine
pub const SpawnOptions = struct {
    stack_size: ?usize = null,
};

// Runtime configuration options
pub const RuntimeOptions = struct {
    thread_pool: ThreadPoolOptions = .{},
    stack_pool: StackPoolOptions = .{},

    pub const ThreadPoolOptions = struct {
        enabled: bool = backendNeedsThreadPool(),
        max_threads: ?u32 = null, // null = CPU count
        stack_size: ?u32 = null, // null = default stack size
    };
};

// Runtime-specific errors
pub const ZioError = error{
    XevError,
    NotInCoroutine,
};

// Cancelable error set
pub const Cancelable = error{
    Canceled,
};

// Timer callback for libxev
fn markReadyFromXevCallback(
    userdata: ?*Coroutine,
    loop: *xev.Loop,
    completion: *xev.Completion,
    result: anyerror!void,
) xev.CallbackAction {
    _ = loop;
    _ = completion;
    _ = result catch {};

    if (userdata) |coro| {
        resumeTask(coro, .local);
    }
    return .disarm;
}

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

    // Push to completion queue (thread-safe lock-free stack)
    // Even if canceled, we still mark as complete so waiters wake up
    const executor = &any_blocking_task.runtime.executor;
    executor.blocking_completions.push(&any_blocking_task.awaitable);

    // Wake up main loop
    executor.async_wakeup.notify() catch {};
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

// Async callback to drain completed blocking tasks
fn drainBlockingCompletions(
    executor: ?*Executor,
    loop: *xev.Loop,
    c: *xev.Completion,
    result: xev.Async.WaitError!void,
) xev.CallbackAction {
    _ = result catch unreachable;
    _ = loop;
    _ = c;
    const self = executor.?;
    const runtime = self.runtime();

    // Atomically drain all completed blocking tasks (LIFO order)
    var drained = self.blocking_completions.popAll();
    while (drained.pop()) |awaitable| {
        // Mark awaitable as complete and wake all waiters (coroutines and threads)
        markComplete(awaitable, self);
        // Release the blocking task's reference (initial ref from init)
        runtime.releaseAwaitable(awaitable);
    }

    return .rearm;
}

// Re-export Awaitable types from core module
const awaitable_module = @import("core/Awaitable.zig");
pub const Awaitable = awaitable_module.Awaitable;
pub const AwaitableKind = awaitable_module.AwaitableKind;

/// Wait for an awaitable to complete. Works from both coroutines and threads.
/// When called from a coroutine, suspends the coroutine.
/// When called from a thread, parks the thread using futex.
/// Returns error.Canceled if the coroutine was canceled during the wait.
pub fn waitForComplete(awaitable: *Awaitable, runtime: *Runtime) Cancelable!void {
    // Fast path: check if already complete
    const fast_state = awaitable.state.load(.acquire);
    if (fast_state == 1) return;

    if (runtime.executor.current_coroutine) |current| {
        // Coroutine path: add to wait queue and suspend
        const task = AnyTask.fromCoroutine(current);
        const executor = Executor.fromCoroutine(current);

        // Check for self-join (would deadlock)
        if (builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
            if (&task.awaitable == awaitable) {
                std.debug.panic("cannot wait on self (would deadlock)", .{});
            }
        }
        awaitable.waiting_list.push(executor, &task.awaitable);

        // Double-check state before suspending (avoid lost wakeup)
        const double_check_state = awaitable.state.load(.acquire);
        if (double_check_state == 1) {
            // Completed while we were adding to queue, remove ourselves
            _ = awaitable.waiting_list.remove(executor, &task.awaitable);
            return;
        }

        executor.yield(.waiting, .allow_cancel) catch |err| {
            // If yield itself was canceled, remove from wait list
            _ = awaitable.waiting_list.remove(executor, &task.awaitable);
            return err;
        };

        // Pair with markComplete()'s .release
        _ = awaitable.state.load(.acquire);
        // Yield returned successfully, awaitable must be complete
    } else {
        // Thread path: park on the state using futex
        while (true) {
            const current_state = awaitable.state.load(.acquire);
            if (current_state == 1) return;
            std.Thread.Futex.wait(&awaitable.state, 0);
        }
    }
}

/// Wait for an awaitable to complete with a timeout. Works from both coroutines and threads.
/// Returns error.Timeout if the timeout expires before completion.
/// Returns error.Canceled if the coroutine was canceled during the wait.
/// For coroutines, uses runtime timer infrastructure.
/// For threads, uses futex timedWait directly.
pub fn timedWaitForComplete(awaitable: *Awaitable, runtime: *Runtime, timeout_ns: u64) error{ Timeout, Canceled }!void {
    // Fast path: check if already complete
    const fast_state = awaitable.state.load(.acquire);
    if (fast_state == 1) return;

    if (runtime.executor.current_coroutine) |current| {
        // Coroutine path: get executor and use timer infrastructure
        const task = AnyTask.fromCoroutine(current);
        const executor = Executor.fromCoroutine(current);

        awaitable.waiting_list.push(executor, &task.awaitable);

        const double_check_state = awaitable.state.load(.acquire);
        if (double_check_state == 1) {
            _ = awaitable.waiting_list.remove(executor, &task.awaitable);
            return;
        }

        const TimeoutContext = struct {
            wait_queue: *ConcurrentAwaitableList,
            awaitable: *Awaitable,
            executor: *Executor,
        };

        var timeout_ctx = TimeoutContext{
            .wait_queue = &awaitable.waiting_list,
            .awaitable = &task.awaitable,
            .executor = executor,
        };

        executor.timedWaitForReadyWithCallback(
            timeout_ns,
            TimeoutContext,
            &timeout_ctx,
            struct {
                fn onTimeout(ctx: *TimeoutContext) bool {
                    return ctx.wait_queue.remove(ctx.executor, ctx.awaitable);
                }
            }.onTimeout,
        ) catch |err| {
            // Handle both timeout and cancellation from yield
            if (err == error.Canceled) {
                _ = awaitable.waiting_list.remove(executor, &task.awaitable);
            }
            return err;
        };

        // Pair with markComplete()'s .release
        _ = awaitable.state.load(.acquire);
        // Yield returned successfully, awaitable must be complete
    } else {
        // Thread path: use futex timedWait
        while (true) {
            const current_state = awaitable.state.load(.acquire);
            if (current_state == 1) return;
            try std.Thread.Futex.timedWait(&awaitable.state, 0, timeout_ns);
        }
    }
}

/// Mark an awaitable as complete and wake all waiters (both coroutines and threads).
/// This is a standalone helper that can be called on any awaitable.
/// Waiting tasks may belong to different executors, so always uses `.maybe_remote` mode.
/// Can be called from any context - executor parameter is optional (null when called from thread pool).
pub fn markComplete(awaitable: *Awaitable, executor: ?*Executor) void {
    // Set state first (release semantics for memory ordering)
    awaitable.state.store(1, .release);

    // Wake all waiting coroutines (always use .maybe_remote since waiters can be on any executor)
    while (awaitable.waiting_list.pop(executor)) |waiting_awaitable| {
        switch (waiting_awaitable.kind) {
            .task => {
                const waiting_task = AnyTask.fromAwaitable(waiting_awaitable);
                resumeTask(&waiting_task.coro, .maybe_remote);
            },
            .select_waiter => {
                // For select waiters, extract the SelectWaiter and wake the task directly
                const waiter: *SelectWaiter = @fieldParentPtr("awaitable", waiting_awaitable);
                waiter.ready = true;
                resumeTask(&waiter.task.coro, .maybe_remote);
            },
            .blocking_task, .future => {
                // These should not be in waiting lists of other awaitables
                unreachable;
            },
        }
    }

    // Wake all waiting threads
    std.Thread.Futex.wake(&awaitable.state, std.math.maxInt(u32));
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
    const coro: *Coroutine = switch (T) {
        *Awaitable => blk: {
            const task = AnyTask.fromAwaitable(obj);
            break :blk &task.coro;
        },
        *AnyTask => &obj.coro,
        *Coroutine => obj,
        else => @compileError("resumeTask() requires *Awaitable, *AnyTask, or *Coroutine, got " ++ @typeName(T)),
    };

    const executor = Executor.fromCoroutine(coro);
    executor.markReady(mode, coro);
}

// Task for runtime scheduling - coroutine-based tasks
pub const AnyTask = struct {
    awaitable: Awaitable,
    coro: Coroutine,
    timer_c: xev.Completion = .{},
    timer_cancel_c: xev.Completion = .{},
    timer_generation: u2 = 0,
    shield_count: u32 = 0,

    pub inline fn fromAwaitable(awaitable: *Awaitable) *AnyTask {
        assert(awaitable.kind == .task);
        return @fieldParentPtr("awaitable", awaitable);
    }

    pub inline fn fromCoroutine(coro: *Coroutine) *AnyTask {
        return @fieldParentPtr("coro", coro);
    }

    /// Request cancellation of this task.
    /// The cancellation flag will be checked at the next yield point.
    pub fn cancel(self: *AnyTask) void {
        self.awaitable.requestCancellation();
    }
};

// Blocking task for runtime scheduling - thread pool based tasks
pub const AnyBlockingTask = struct {
    awaitable: Awaitable,
    thread_pool_task: xev.ThreadPool.Task,
    runtime: *Runtime,
    execute_fn: *const fn (*AnyBlockingTask) void,

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

        pub fn wait(parent: *Parent) !meta.Payload(T) {
            // Check if already completed
            if (parent.impl.future_result.get()) |res| {
                return res;
            }

            // Wait for completion
            const runtime = Parent.getRuntime(parent);
            try waitForComplete(&parent.impl.base.awaitable, runtime);

            return parent.impl.future_result.get().?;
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
    };
}

// Typed task that contains the AnyTask and FutureResult
pub fn Task(comptime T: type) type {
    return struct {
        const Self = @This();
        const Impl = FutureImpl(T, AnyTask, Self);

        impl: Impl,

        pub const deinit = Impl.deinit;
        pub const wait = Impl.wait;
        pub const cancel = Impl.cancel;
        pub const fromAny = Impl.fromAny;
        pub const fromAwaitable = Impl.fromAwaitable;

        pub fn getRuntime(self: *Self) *Runtime {
            const executor = Executor.fromCoroutine(&self.impl.base.coro);
            return executor.runtime();
        }

        fn destroyFn(runtime: *Runtime, awaitable: *Awaitable) void {
            const any_task = AnyTask.fromAwaitable(awaitable);
            const self = fromAny(any_task);
            // Stack should already be released when coroutine became dead, but check defensively
            if (any_task.coro.stack) |stack| {
                runtime.executor.stack_pool.release(stack);
            }
            runtime.allocator.destroy(self);
        }
    };
}

// Typed future that can be set from callbacks
pub fn Future(comptime T: type) type {
    return struct {
        const Self = @This();
        const Impl = FutureImpl(T, AnyFuture, Self);

        impl: Impl,

        pub const deinit = Impl.deinit;
        pub const wait = Impl.wait;
        pub const cancel = Impl.cancel;
        pub const fromAny = Impl.fromAny;
        pub const fromAwaitable = Impl.fromAwaitable;

        pub fn getRuntime(self: *Self) *Runtime {
            return self.impl.base.runtime;
        }

        fn destroyFn(runtime: *Runtime, awaitable: *Awaitable) void {
            const any_future = AnyFuture.fromAwaitable(awaitable);
            const self = fromAny(any_future);
            runtime.allocator.destroy(self);
        }

        pub fn init(runtime: *Runtime, allocator: Allocator) !*Self {
            const self = try allocator.create(Self);
            self.* = .{
                .impl = .{
                    .base = .{
                        .awaitable = .{
                            .kind = .future,
                            .destroy_fn = destroyFn,
                        },
                        .runtime = runtime,
                    },
                    .future_result = FutureResult(T){},
                },
            };

            // ref_count starts at 1 by default via RefCounter.init()

            return self;
        }

        pub fn set(self: *Self, value: T) void {
            const was_set = self.impl.future_result.set(value);
            if (!was_set) {
                // Value was already set, ignore
                return;
            }

            // Mark awaitable as complete and wake all waiters (coroutines and threads)
            markComplete(&self.impl.base.awaitable, Runtime.current_executor);
        }
    };
}

// Typed blocking task that contains the AnyBlockingTask and FutureResult
pub fn BlockingTask(comptime T: type) type {
    return struct {
        const Self = @This();
        const Impl = FutureImpl(T, AnyBlockingTask, Self);

        impl: Impl,

        pub const deinit = Impl.deinit;
        pub const wait = Impl.wait;
        pub const cancel = Impl.cancel;
        pub const fromAny = Impl.fromAny;
        pub const fromAwaitable = Impl.fromAwaitable;

        pub fn getRuntime(self: *Self) *Runtime {
            return self.impl.base.runtime;
        }

        pub fn init(
            runtime: *Runtime,
            allocator: Allocator,
            func: anytype,
            args: meta.ArgsType(func),
        ) !*Self {
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

            runtime.executor.thread_pool.?.schedule(
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
                .future => Future(T).fromAwaitable(self.awaitable).getRuntime(),
                .select_waiter => unreachable, // JoinHandles never point to select waiters
            };
            runtime.releaseAwaitable(self.awaitable);
        }

        pub fn join(self: *Self) !meta.Payload(T) {
            return switch (self.awaitable.kind) {
                .task => Task(T).fromAwaitable(self.awaitable).wait(),
                .blocking_task => BlockingTask(T).fromAwaitable(self.awaitable).wait(),
                .future => Future(T).fromAwaitable(self.awaitable).wait(),
                .select_waiter => unreachable, // JoinHandles never point to select waiters
            };
        }

        /// Check if the task has completed and a result is available.
        pub fn hasResult(self: *const Self) bool {
            return self.awaitable.state.load(.acquire) == 1;
        }

        /// Get the result value of type T (preserving any error union).
        /// Asserts that the task has already completed.
        /// This is used internally by select() to preserve error union types.
        fn getResult(self: *Self) T {
            assert(self.hasResult());

            // Get the stored result of type T
            return switch (self.awaitable.kind) {
                .task => Task(T).fromAwaitable(self.awaitable).impl.future_result.get().?,
                .blocking_task => BlockingTask(T).fromAwaitable(self.awaitable).impl.future_result.get().?,
                .future => Future(T).fromAwaitable(self.awaitable).impl.future_result.get().?,
                .select_waiter => unreachable,
            };
        }

        /// Request cancellation of this task.
        /// For coroutine tasks: Sets the cancellation flag, which will be checked at the next yield point.
        /// For blocking tasks: Sets the cancellation flag, which will skip execution if not yet started.
        /// For futures: Has no effect (futures are not cancelable).
        pub fn cancel(self: *Self) void {
            self.awaitable.requestCancellation();
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

/// Given a struct with each field a `JoinHandle(T)`, returns a union with the same
/// fields, each field type `T` (which may include error unions).
pub fn SelectUnion(comptime S: type) type {
    const struct_fields = @typeInfo(S).@"struct".fields;
    var fields: [struct_fields.len]std.builtin.Type.UnionField = undefined;
    for (&fields, struct_fields) |*union_field, struct_field| {
        // Extract T from JoinHandle(T)
        // struct_field.type is JoinHandle(T)
        const Handle = struct_field.type;
        // Handle.Result is T directly (may be an error union like ParseError!i32)
        const Result = Handle.Result;
        union_field.* = .{
            .name = struct_field.name,
            .type = Result,
            .alignment = struct_field.alignment,
        };
    }
    return @Type(.{ .@"union" = .{
        .layout = .auto,
        .tag_type = std.meta.FieldEnum(S),
        .fields = &fields,
        .decls = &.{},
    } });
}

// Simple singly-linked stack (LIFO) for single-threaded use
pub const SimpleAwaitableStack = @import("core/SimpleAwaitableStack.zig");

// Lock-free intrusive stack for cross-thread communication
pub const ConcurrentAwaitableStack = @import("core/ConcurrentAwaitableStack.zig");

// Simple doubly-linked list of awaitables (non-concurrent)
pub const SimpleAwaitableList = @import("core/SimpleAwaitableList.zig");

// Concurrent doubly-linked list of awaitables (thread-safe)
pub const ConcurrentAwaitableList = @import("core/ConcurrentAwaitableList.zig");

// Executor metrics
pub const ExecutorMetrics = struct {
    yields: u64 = 0,
    tasks_spawned: u64 = 0,
    tasks_completed: u64 = 0,
};

// Executor - per-thread execution unit for running coroutines
pub const Executor = struct {
    loop: xev.Loop,
    thread_pool: ?*xev.ThreadPool, // Reference to Runtime's thread pool
    stack_pool: StackPool,
    main_context: coroutines.Context,
    allocator: Allocator,
    current_coroutine: ?*Coroutine = null,

    tasks: std.AutoHashMapUnmanaged(*AnyTask, void) = .{},

    ready_queue: SimpleAwaitableStack = .{},
    next_ready_queue: SimpleAwaitableStack = .{},

    // Remote task support - lock-free LIFO stack for cross-thread resumption
    next_ready_queue_remote: ConcurrentAwaitableStack = .{},
    remote_wakeup: xev.Async = undefined,
    remote_completion: xev.Completion = undefined,
    remote_initialized: bool = false,

    // Blocking task support - lock-free LIFO stack
    blocking_completions: ConcurrentAwaitableStack = .{},
    async_wakeup: xev.Async = undefined,
    async_completion: xev.Completion = undefined,
    blocking_initialized: bool = false,

    // Stack pool cleanup tracking
    cleanup_interval_ms: i64,
    last_cleanup_ms: i64 = 0,

    // Runtime metrics
    metrics: ExecutorMetrics = .{},

    /// Get the Executor instance from any coroutine that belongs to it
    pub fn fromCoroutine(coro: *Coroutine) *Executor {
        return @fieldParentPtr("main_context", coro.parent_context_ptr);
    }

    /// Get the Runtime instance from this Executor
    pub inline fn runtime(self: *Executor) *Runtime {
        return @fieldParentPtr("executor", self);
    }

    pub fn init(allocator: Allocator, thread_pool: ?*xev.ThreadPool, options: RuntimeOptions) !Executor {
        // Initialize libxev loop with optional ThreadPool
        const loop = try xev.Loop.init(.{
            .thread_pool = thread_pool,
        });

        return Executor{
            .allocator = allocator,
            .loop = loop,
            .thread_pool = thread_pool,
            .stack_pool = StackPool.init(allocator, options.stack_pool),
            .cleanup_interval_ms = options.stack_pool.cleanup_interval_ms,
            .main_context = undefined,
        };
    }

    pub fn deinit(self: *Executor) void {
        // Note: ThreadPool is owned by Runtime, not Executor

        const rt = self.runtime();
        var iter = self.tasks.keyIterator();
        while (iter.next()) |task_ptr| {
            const task = task_ptr.*;
            rt.releaseAwaitable(&task.awaitable);
        }
        self.tasks.deinit(self.allocator);

        // Clean up remote task support
        if (self.remote_initialized) {
            self.remote_wakeup.deinit();
        }

        // Clean up blocking task support
        if (self.blocking_initialized) {
            self.async_wakeup.deinit();
        }

        self.loop.deinit();

        // Clean up stack pool
        self.stack_pool.deinit();
    }

    pub fn spawn(self: *Executor, func: anytype, args: meta.ArgsType(func), options: SpawnOptions) !JoinHandle(meta.ReturnType(func)) {
        const debug_crash = false;
        if (debug_crash) {
            const v = @call(.always_inline, func, args);
            std.debug.print("Spawned task with ID {any}\n", .{v});
        }

        // Ensure hashmap capacity first, before any allocations
        try self.tasks.ensureUnusedCapacity(self.allocator, 1);

        const Result = meta.ReturnType(func);
        const TypedTask = Task(Result);

        // Allocate task struct
        const task = try self.allocator.create(TypedTask);
        errdefer self.allocator.destroy(task);

        // Acquire stack from pool
        const stack = try self.stack_pool.acquire(options.stack_size orelse coroutines.DEFAULT_STACK_SIZE);
        errdefer self.stack_pool.release(stack);

        task.* = .{
            .impl = .{
                .base = .{
                    .awaitable = .{
                        .kind = .task,
                        .destroy_fn = &TypedTask.destroyFn,
                    },
                    .coro = .{
                        .stack = stack,
                        .parent_context_ptr = &self.main_context,
                        .state = .ready,
                    },
                },
                .future_result = .{},
            },
        };

        task.impl.base.coro.setup(func, args, &task.impl.future_result);

        // putNoClobber cannot fail since we ensured capacity
        self.tasks.putAssumeCapacityNoClobber(&task.impl.base, {});

        self.ready_queue.push(&task.impl.base.awaitable);

        // Track task spawn
        self.metrics.tasks_spawned += 1;

        task.impl.base.awaitable.ref_count.incr();
        return JoinHandle(Result){ .awaitable = &task.impl.base.awaitable };
    }

    pub const YieldCancelMode = enum { allow_cancel, no_cancel };

    /// Cooperatively yield control to other tasks.
    ///
    /// Suspends the current coroutine and allows other tasks to run. The coroutine
    /// will be rescheduled according to `desired_state`:
    /// - `.ready`: Reschedule immediately (cooperative yielding)
    /// - `.waiting`: Suspend until explicitly woken by another task
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
    pub fn yield(self: *Executor, desired_state: CoroutineState, comptime cancel_mode: YieldCancelMode) if (cancel_mode == .allow_cancel) Cancelable!void else void {
        const current_coro = self.current_coroutine orelse unreachable;
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

        current_coro.state = desired_state;
        if (desired_state == .ready) {
            self.next_ready_queue.push(&current_task.awaitable);
        }

        // If dead, always switch to scheduler for cleanup
        if (desired_state == .dead) {
            coroutines.switchContext(&current_coro.context, current_coro.parent_context_ptr);
            unreachable;
        }

        if (self.ready_queue.pop()) |next_awaitable| {
            const next_task = AnyTask.fromAwaitable(next_awaitable);

            self.current_coroutine = &next_task.coro;
            coroutines.switchContext(&current_coro.context, &next_task.coro.context);
        } else {
            coroutines.switchContext(&current_coro.context, current_coro.parent_context_ptr);
        }

        std.debug.assert(self.current_coroutine == current_coro);

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

    pub inline fn awaitablePtrFromTaskPtr(task: *AnyTask) *Awaitable {
        return &task.awaitable;
    }

    pub fn sleep(self: *Executor, milliseconds: u64) void {
        self.timedWaitForReady(milliseconds * 1_000_000) catch return;
        unreachable; // Should always timeout - waking without timeout is a bug
    }

    fn ensureRemoteInitialized(self: *Executor) !void {
        if (self.remote_initialized) return;

        self.remote_wakeup = try xev.Async.init();

        // Register async completion to wake up loop (draining happens in run())
        self.remote_wakeup.wait(
            &self.loop,
            &self.remote_completion,
            Executor,
            self,
            remoteWakeupCallback,
        );

        self.remote_initialized = true;
    }

    fn ensureBlockingInitialized(self: *Executor) !void {
        if (self.blocking_initialized) return;
        if (self.thread_pool == null) return error.ThreadPoolRequired;

        self.async_wakeup = try xev.Async.init();

        // Register async completion to drain blocking tasks
        self.async_wakeup.wait(
            &self.loop,
            &self.async_completion,
            Executor,
            self,
            drainBlockingCompletions,
        );

        self.blocking_initialized = true;
    }

    pub fn spawnBlocking(
        self: *Executor,
        func: anytype,
        args: meta.ArgsType(func),
    ) !JoinHandle(meta.ReturnType(func)) {
        try self.ensureBlockingInitialized();

        const Result = meta.ReturnType(func);
        const task = try BlockingTask(Result).init(
            self.runtime(),
            self.allocator,
            func,
            args,
        );

        return JoinHandle(Result){ .awaitable = &task.impl.base.awaitable };
    }

    /// Convenience function that spawns a task, runs the event loop until completion, and returns the result.
    /// This is equivalent to: `spawn()` + `run()` + `result()`, but in a single call.
    /// Returns an error union that includes errors from `spawn()`, `run()`, and the task itself.
    pub fn runUntilComplete(self: *Executor, func: anytype, args: meta.ArgsType(func), options: SpawnOptions) !meta.Payload(meta.ReturnType(func)) {
        var handle = try self.spawn(func, args, options);
        defer handle.deinit();
        try self.run();
        return handle.join();
    }

    pub fn run(self: *Executor) !void {
        // Set thread-local current executor
        Runtime.current_executor = self;
        defer Runtime.current_executor = null;

        // Initialize remote task support (for cross-thread resumption)
        try self.ensureRemoteInitialized();

        while (true) {
            // Time-based stack pool cleanup
            const now = std.time.milliTimestamp();
            if (now - self.last_cleanup_ms >= self.cleanup_interval_ms) {
                self.stack_pool.cleanup();
                self.last_cleanup_ms = now;
            }

            // Drain remote ready queue (cross-thread tasks)
            // Atomically drain all remote ready tasks and prepend to ready queue
            var drained = self.next_ready_queue_remote.popAll();
            self.ready_queue.prependByMoving(&drained);

            // Process all ready coroutines (once)
            while (self.ready_queue.pop()) |awaitable| {
                const task = AnyTask.fromAwaitable(awaitable);

                self.current_coroutine = &task.coro;
                defer self.current_coroutine = null;
                coroutines.switchContext(&self.main_context, &task.coro.context);

                // Handle dead coroutines (checks current_coroutine to catch tasks that died via direct switch in yield())
                if (self.current_coroutine) |current_coro| {
                    if (current_coro.state == .dead) {
                        const current_task = AnyTask.fromCoroutine(current_coro);
                        const current_awaitable = &current_task.awaitable;

                        // Release stack immediately since coroutine execution is complete
                        if (current_coro.stack) |stack| {
                            self.stack_pool.release(stack);
                            current_coro.stack = null;
                        }

                        // Mark awaitable as complete and wake all waiters (coroutines and threads)
                        markComplete(current_awaitable, self);

                        // Track task completion
                        self.metrics.tasks_completed += 1;

                        // Remove from tasks hashmap and release runtime's reference
                        _ = self.tasks.remove(current_task);
                        self.runtime().releaseAwaitable(current_awaitable);
                        // If ref_count > 0, Task(T) handles still exist, keep the task alive
                    }
                }

                // Other states (.ready, .waiting) are handled by yield() or markReady()
            }

            // If we have no active coroutines, exit
            if (self.tasks.size == 0) {
                self.loop.stop();
                break;
            }

            // First check for I/O events without blocking (processes cancellations)
            try self.loop.run(.no_wait);

            // Move yielded coroutines back to ready queue
            self.ready_queue.prependByMoving(&self.next_ready_queue);

            // If no ready work, block waiting for I/O
            if (self.ready_queue.head == null and self.next_ready_queue.head == null) {
                try self.loop.run(.once);
            }
        }
    }

    /// Mark a coroutine as ready.
    ///
    /// The `mode` parameter controls executor checking:
    /// - `.maybe_remote`: Checks if we're on the same executor and uses remote path if needed
    /// - `.local`: Skips the check and always uses local path (optimization for IO callbacks)
    pub fn markReady(self: *Executor, comptime mode: ResumeMode, coro: *Coroutine) void {
        if (coro.state != .waiting) std.debug.panic("coroutine is not waiting", .{});
        coro.state = .ready;
        const task = AnyTask.fromCoroutine(coro);

        if (mode == .maybe_remote) {
            // Check if we're on the same executor thread
            if (Runtime.current_executor == self) {
                // Same executor - use fast local path
                self.ready_queue.push(&task.awaitable);
            } else {
                // Different executor (or no current executor) - use remote path
                // Remote queue must be initialized by run() before cross-thread calls
                assert(self.remote_initialized);

                // Push to remote ready queue (thread-safe)
                self.next_ready_queue_remote.push(&task.awaitable);

                // Notify the target executor's event loop
                self.remote_wakeup.notify() catch {};
            }
        } else {
            // Fast path: we know we're on the same executor
            assert(Runtime.current_executor == self);
            self.ready_queue.push(&task.awaitable);
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
        const addr = @intFromPtr(ptr);
        const tagged = addr | @as(usize, generation);
        return @ptrFromInt(tagged);
    }

    /// Unpack a tagged pointer into the original pointer and generation.
    inline fn unpackTimerUserdata(comptime T: type, userdata: ?*anyopaque) struct { ptr: *T, generation: u2 } {
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
        self.yield(.waiting, .allow_cancel) catch |err| {
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

    pub fn timedWaitForReady(self: *Executor, timeout_ns: u64) error{ Timeout, Canceled }!void {
        const DummyContext = struct {};
        var dummy: DummyContext = .{};
        return self.timedWaitForReadyWithCallback(
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

    /// Wait for an xev completion to finish, handling cancellation properly.
    /// When a coroutine is canceled while waiting for an I/O operation,
    /// we need to cancel the operation (if the backend supports it) and
    /// wait for it to complete before returning error.Canceled.
    /// This prevents use-after-free bugs where the xev callback accesses
    /// freed stack memory.
    ///
    /// Returns error.Canceled if the operation was canceled.
    pub fn waitForXevCompletion(
        self: *Executor,
        completion: *xev.Completion,
    ) Cancelable!void {
        var was_canceled = false;
        var cancel_completion: xev.Completion = .{};

        while (completion.state() != .dead) {
            self.yield(.waiting, .allow_cancel) catch |err| switch (err) {
                error.Canceled => {
                    // First cancellation - try to cancel the xev operation
                    if (!was_canceled) {
                        was_canceled = true;

                        if (xev.backend == .io_uring) {
                            // io_uring supports cancellation - request cancellation
                            self.loop.cancel(
                                completion,
                                &cancel_completion,
                                void,
                                null,
                                struct {
                                    fn callback(
                                        _: ?*void,
                                        _: *xev.Loop,
                                        _: *xev.Completion,
                                        _: xev.CancelError!void,
                                    ) xev.CallbackAction {
                                        // We don't need to do anything here - the original
                                        // completion callback will fire and wake us up
                                        return .disarm;
                                    }
                                }.callback,
                            );
                        }
                        // For non-io_uring backends, just continue waiting for completion
                    }
                    // Continue waiting for the operation to complete
                },
            };
        }

        // Operation completed - return cancellation error if we were canceled
        if (was_canceled) {
            return error.Canceled;
        }
    }
};

// SelectWaiter - used by Runtime.select to wait on multiple handles
pub const SelectWaiter = struct {
    awaitable: Awaitable,
    task: *AnyTask,
    ready: bool = false,
};

// Runtime - orchestrator that wraps a single Executor (for now)
pub const Runtime = struct {
    executor: Executor,
    thread_pool: ?*xev.ThreadPool,
    allocator: Allocator,

    /// Thread-local storage for the current executor
    threadlocal var current_executor: ?*Executor = null;

    pub fn init(allocator: Allocator, options: RuntimeOptions) !Runtime {
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

        const executor = try Executor.init(allocator, thread_pool, options);
        errdefer executor.deinit();

        return Runtime{
            .executor = executor,
            .thread_pool = thread_pool,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Runtime) void {
        // Shutdown ThreadPool before cleaning up executor
        if (self.thread_pool) |tp| {
            tp.shutdown();
        }

        self.executor.deinit();

        // Clean up ThreadPool after executor
        if (self.thread_pool) |tp| {
            tp.deinit();
            self.allocator.destroy(tp);
        }
    }

    // High-level public API - delegates to Executor
    pub fn spawn(self: *Runtime, func: anytype, args: meta.ArgsType(func), options: SpawnOptions) !JoinHandle(meta.ReturnType(func)) {
        return self.executor.spawn(func, args, options);
    }

    pub fn spawnBlocking(self: *Runtime, func: anytype, args: meta.ArgsType(func)) !JoinHandle(meta.ReturnType(func)) {
        return self.executor.spawnBlocking(func, args);
    }

    pub fn run(self: *Runtime) !void {
        return self.executor.run();
    }

    pub fn runUntilComplete(self: *Runtime, func: anytype, args: meta.ArgsType(func), options: SpawnOptions) !meta.Payload(meta.ReturnType(func)) {
        return self.executor.runUntilComplete(func, args, options);
    }

    // Convenience methods that operate on the current coroutine context
    // These delegate to the current executor automatically
    // Most are no-op if not called from within a coroutine

    /// Cooperatively yield control to allow other tasks to run.
    /// The current task will be rescheduled and continue execution later.
    /// No-op if not called from within a coroutine.
    pub fn yield(self: *Runtime) Cancelable!void {
        if (self.executor.current_coroutine == null) return;
        return self.executor.yield(.ready, .allow_cancel);
    }

    /// Sleep for the specified number of milliseconds.
    /// Uses async sleep if in a coroutine, blocking sleep otherwise.
    pub fn sleep(self: *Runtime, milliseconds: u64) void {
        if (self.executor.current_coroutine) |_| {
            self.executor.sleep(milliseconds);
        } else {
            // Not in coroutine - use blocking sleep
            std.Thread.sleep(milliseconds * std.time.ns_per_ms);
        }
    }

    /// Begin a cancellation shield to prevent cancellation during critical sections.
    /// No-op if not called from within a coroutine.
    pub fn beginShield(self: *Runtime) void {
        if (self.executor.current_coroutine == null) return;
        self.executor.beginShield();
    }

    /// End a cancellation shield.
    /// No-op if not called from within a coroutine.
    pub fn endShield(self: *Runtime) void {
        if (self.executor.current_coroutine == null) return;
        self.executor.endShield();
    }

    /// Check if cancellation has been requested and return error.Canceled if so.
    /// This consumes the cancellation flag.
    /// Use this after endShield() to detect cancellation that occurred during the shielded section.
    /// No-op (returns successfully) if not called from within a coroutine.
    pub fn checkCanceled(self: *Runtime) Cancelable!void {
        if (self.executor.current_coroutine == null) return;
        return self.executor.checkCanceled();
    }

    pub fn getCurrent() ?*Runtime {
        // This function has no way to access the runtime without threadlocal
        // It should not be used - tests that use it need Runtime passed as parameter
        @compileError("Runtime.getCurrent() is not supported - pass *Runtime as parameter instead");
    }

    /// Get a copy of the current executor metrics
    pub fn getMetrics(self: *Runtime) ExecutorMetrics {
        return self.executor.getMetrics();
    }

    /// Reset all executor metrics to zero
    pub fn resetMetrics(self: *Runtime) void {
        self.executor.resetMetrics();
    }

    fn releaseAwaitable(self: *Runtime, awaitable: *Awaitable) void {
        if (awaitable.ref_count.decr()) {
            awaitable.destroy_fn(self, awaitable);
        }
    }

    /// Wait for multiple JoinHandles simultaneously and return whichever completes first.
    /// `handles` is a struct with each field a `JoinHandle(T)`, where `T` can be different for each field.
    /// Returns a tagged union with the same field names, containing the result of whichever completed first.
    ///
    /// When multiple handles complete at the same time, fields are checked in declaration order
    /// and the first ready handle is returned.
    ///
    /// Example:
    /// ```
    /// var h1 = try rt.spawn(task1, .{}, .{});
    /// var h2 = try rt.spawn(task2, .{}, .{});
    /// const result = rt.select(.{ .first = h1, .second = h2 });
    /// switch (result) {
    ///     .first => |val| ...,
    ///     .second => |val| ...,
    /// }
    /// ```
    pub fn select(self: *Runtime, handles: anytype) !SelectUnion(@TypeOf(handles)) {
        const U = SelectUnion(@TypeOf(handles));
        const S = @TypeOf(handles);
        const fields = @typeInfo(S).@"struct".fields;

        // Fast path: check if any handle is already complete
        inline for (fields) |field| {
            var handle = @field(handles, field.name);
            if (handle.hasResult()) {
                // Already complete, return immediately
                return @unionInit(U, field.name, handle.getResult());
            }
        }

        // Multi-wait path: Create separate waiter awaitables for each handle
        // We can't add the same awaitable to multiple lists (next/prev pointers conflict)
        const current_coro = self.executor.current_coroutine orelse return error.NotInCoroutine;
        const current_task = AnyTask.fromCoroutine(current_coro);
        const executor = Executor.fromCoroutine(current_coro);

        // Create waiter structures on the stack
        var waiters: [fields.len]SelectWaiter = undefined;
        inline for (&waiters, 0..) |*waiter, i| {
            waiter.* = .{
                .awaitable = .{
                    .kind = .select_waiter,
                    .destroy_fn = struct {
                        fn dummy(_: *Runtime, _: *Awaitable) void {}
                    }.dummy,
                },
                .task = current_task,
            };
            _ = i; // Will use below
        }

        // Add waiters to all waiting lists
        inline for (fields, 0..) |field, i| {
            var handle = @field(handles, field.name);
            handle.awaitable.waiting_list.push(executor, &waiters[i].awaitable);
        }

        // Clean up waiters on all exit paths (skip waiters marked ready by markComplete)
        defer {
            inline for (0..fields.len) |i| {
                if (!waiters[i].ready) {
                    var h = @field(handles, fields[i].name);
                    _ = h.awaitable.waiting_list.remove(executor, &waiters[i].awaitable);
                }
            }
        }

        // Double-check for completion (race condition prevention)
        inline for (fields, 0..) |field, i| {
            var handle = @field(handles, field.name);
            if (handle.hasResult()) {
                // Completed while we were adding to lists, defer will clean up
                return @unionInit(U, field.name, handle.getResult());
            }
            _ = i;
        }

        // Yield and wait for one to complete
        try executor.yield(.waiting, .allow_cancel);

        // We were woken up - find which one completed
        inline for (fields, 0..) |field, i| {
            var handle = @field(handles, field.name);
            if (handle.hasResult()) {
                // This one completed, defer will clean up all non-ready waiters
                return @unionInit(U, field.name, handle.getResult());
            }
            _ = i;
        }

        // Should never reach here - we were woken up, so something must be complete
        unreachable;
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

            const result = try handle.join();
            try testing.expectEqual(@as(i32, 42), result);
        }
    };

    try runtime.runUntilComplete(TestContext.asyncTask, .{&runtime}, .{});
}

test "runtime: Future basic set and get" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    const TestContext = struct {
        fn asyncTask(rt: *Runtime) !void {
            const future = try Future(i32).init(rt, testing.allocator);
            defer future.deinit();

            // Set value
            future.set(42);

            // Get value (should return immediately since already set)
            const result = try future.wait();
            try testing.expectEqual(@as(i32, 42), result);
        }
    };

    try runtime.runUntilComplete(TestContext.asyncTask, .{&runtime}, .{});
}

test "runtime: Future await from coroutine" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    const TestContext = struct {
        fn setterTask(rt: *Runtime, future: *Future(i32)) !void {
            // Simulate async work
            try rt.yield();
            try rt.yield();
            future.set(123);
        }

        fn getterTask(future: *Future(i32)) !i32 {
            // This will block until setter sets the value
            return future.wait();
        }

        fn asyncTask(rt: *Runtime) !void {
            const future = try Future(i32).init(rt, testing.allocator);
            defer future.deinit();

            // Spawn setter coroutine
            var setter_handle = try rt.spawn(setterTask, .{ rt, future }, .{});
            defer setter_handle.deinit();

            // Spawn getter coroutine
            var getter_handle = try rt.spawn(getterTask, .{future}, .{});
            defer getter_handle.deinit();

            const result = try getter_handle.join();
            try testing.expectEqual(@as(i32, 123), result);
        }
    };

    try runtime.runUntilComplete(TestContext.asyncTask, .{&runtime}, .{});
}

test "runtime: Future multiple waiters" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();
    const TestContext = struct {
        fn waiterTask(future: *Future(i32), expected: i32) !void {
            const result = try future.wait();
            try testing.expectEqual(expected, result);
        }

        fn setterTask(rt: *Runtime, future: *Future(i32)) !void {
            // Let waiters block first
            try rt.yield();
            try rt.yield();
            future.set(999);
        }

        fn asyncTask(rt: *Runtime) !void {
            const future = try Future(i32).init(rt, testing.allocator);
            defer future.deinit();

            // Spawn multiple waiters
            var waiter1 = try rt.spawn(waiterTask, .{ future, @as(i32, 999) }, .{});
            defer waiter1.deinit();
            var waiter2 = try rt.spawn(waiterTask, .{ future, @as(i32, 999) }, .{});
            defer waiter2.deinit();
            var waiter3 = try rt.spawn(waiterTask, .{ future, @as(i32, 999) }, .{});
            defer waiter3.deinit();

            // Spawn setter
            var setter = try rt.spawn(setterTask, .{ rt, future }, .{});
            defer setter.deinit();

            try rt.yield();
            try rt.yield();
            try rt.yield();
            try rt.yield();

            try waiter1.join();
            try waiter2.join();
            try waiter3.join();
        }
    };

    try runtime.runUntilComplete(TestContext.asyncTask, .{&runtime}, .{});
}

test "runtime: select basic - first completes" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    const TestContext = struct {
        fn slowTask(rt: *Runtime) i32 {
            rt.sleep(100);
            return 42;
        }

        fn fastTask(rt: *Runtime) i32 {
            rt.sleep(10);
            return 99;
        }

        fn asyncTask(rt: *Runtime) !void {
            var slow = try rt.spawn(slowTask, .{rt}, .{});
            defer slow.deinit();
            var fast = try rt.spawn(fastTask, .{rt}, .{});
            defer fast.deinit();

            const result = try rt.select(.{ .fast = fast, .slow = slow });
            switch (result) {
                .slow => |val| try testing.expectEqual(@as(i32, 42), val),
                .fast => |val| try testing.expectEqual(@as(i32, 99), val),
            }
            // Fast should win
            try testing.expectEqual(std.meta.Tag(@TypeOf(result)).fast, std.meta.activeTag(result));
        }
    };

    try runtime.runUntilComplete(TestContext.asyncTask, .{&runtime}, .{});
}

test "runtime: select already complete - fast path" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    const TestContext = struct {
        fn immediateTask() i32 {
            return 123;
        }

        fn slowTask(rt: *Runtime) i32 {
            rt.sleep(100);
            return 456;
        }

        fn asyncTask(rt: *Runtime) !void {
            var immediate = try rt.spawn(immediateTask, .{}, .{});
            defer immediate.deinit();

            // Give immediate task a chance to complete
            try rt.yield();
            try rt.yield();

            var slow = try rt.spawn(slowTask, .{rt}, .{});
            defer slow.deinit();

            // immediate should already be complete, select should return immediately
            const result = try rt.select(.{ .immediate = immediate, .slow = slow });
            switch (result) {
                .immediate => |val| try testing.expectEqual(@as(i32, 123), val),
                .slow => return error.TestUnexpectedResult,
            }
        }
    };

    try runtime.runUntilComplete(TestContext.asyncTask, .{&runtime}, .{});
}

test "runtime: select heterogeneous types" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    const TestContext = struct {
        fn intTask(rt: *Runtime) i32 {
            rt.sleep(100);
            return 42;
        }

        fn stringTask(rt: *Runtime) []const u8 {
            rt.sleep(10);
            return "hello";
        }

        fn boolTask(rt: *Runtime) bool {
            rt.sleep(150);
            return true;
        }

        fn asyncTask(rt: *Runtime) !void {
            var int_handle = try rt.spawn(intTask, .{rt}, .{});
            defer int_handle.deinit();
            var string_handle = try rt.spawn(stringTask, .{rt}, .{});
            defer string_handle.deinit();
            var bool_handle = try rt.spawn(boolTask, .{rt}, .{});
            defer bool_handle.deinit();

            const result = try rt.select(.{
                .string = string_handle,
                .int = int_handle,
                .bool = bool_handle,
            });

            switch (result) {
                .int => |val| {
                    try testing.expectEqual(@as(i32, 42), val);
                    return error.TestUnexpectedResult; // Should not complete first
                },
                .string => |val| {
                    try testing.expectEqualStrings("hello", val);
                    // This should win
                },
                .bool => |val| {
                    try testing.expectEqual(true, val);
                    return error.TestUnexpectedResult; // Should not complete first
                },
            }
        }
    };

    try runtime.runUntilComplete(TestContext.asyncTask, .{&runtime}, .{});
}

test "runtime: select with cancellation" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    const TestContext = struct {
        fn slowTask1(rt: *Runtime) i32 {
            rt.sleep(1000);
            return 1;
        }

        fn slowTask2(rt: *Runtime) i32 {
            rt.sleep(1000);
            return 2;
        }

        fn selectTask(rt: *Runtime) !i32 {
            var h1 = try rt.spawn(slowTask1, .{rt}, .{});
            defer h1.deinit();
            var h2 = try rt.spawn(slowTask2, .{rt}, .{});
            defer h2.deinit();

            const result = try rt.select(.{ .first = h1, .second = h2 });
            return switch (result) {
                .first => |v| v,
                .second => |v| v,
            };
        }

        fn asyncTask(rt: *Runtime) !void {
            var select_handle = try rt.spawn(selectTask, .{rt}, .{});
            defer select_handle.deinit();

            // Give it a chance to start waiting
            try rt.yield();
            try rt.yield();

            // Cancel the select operation
            select_handle.cancel();

            // Should return error.Canceled
            const result = select_handle.join();
            try testing.expectError(error.Canceled, result);
        }
    };

    try runtime.runUntilComplete(TestContext.asyncTask, .{&runtime}, .{});
}

test "runtime: select with error unions - success case" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    const TestContext = struct {
        const ParseError = error{ InvalidFormat, OutOfRange };
        const ValidationError = error{ TooShort, TooLong };

        fn parseTask(rt: *Runtime) ParseError!i32 {
            rt.sleep(100);
            return 42;
        }

        fn validateTask(rt: *Runtime) ValidationError![]const u8 {
            rt.sleep(10);
            return "valid";
        }

        fn asyncTask(rt: *Runtime) !void {
            var parse_handle = try rt.spawn(parseTask, .{rt}, .{});
            defer parse_handle.deinit();
            var validate_handle = try rt.spawn(validateTask, .{rt}, .{});
            defer validate_handle.deinit();

            const result = try rt.select(.{
                .validate = validate_handle,
                .parse = parse_handle,
            });

            // Result is a union where each field has the original error type
            switch (result) {
                .parse => |val_or_err| {
                    // val_or_err is ParseError!i32
                    const val = val_or_err catch |err| {
                        try testing.expect(false); // Should not error
                        return err;
                    };
                    try testing.expectEqual(@as(i32, 42), val);
                    return error.TestUnexpectedResult; // validate should win
                },
                .validate => |val_or_err| {
                    // val_or_err is ValidationError![]const u8
                    const val = val_or_err catch |err| {
                        try testing.expect(false); // Should not error
                        return err;
                    };
                    try testing.expectEqualStrings("valid", val);
                    // This should win
                },
            }
        }
    };

    try runtime.runUntilComplete(TestContext.asyncTask, .{&runtime}, .{});
}

test "runtime: select with error unions - error case" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    const TestContext = struct {
        const ParseError = error{ InvalidFormat, OutOfRange };

        fn failingTask(rt: *Runtime) ParseError!i32 {
            rt.sleep(10);
            return error.OutOfRange;
        }

        fn slowTask(rt: *Runtime) i32 {
            rt.sleep(100);
            return 99;
        }

        fn asyncTask(rt: *Runtime) !void {
            var failing = try rt.spawn(failingTask, .{rt}, .{});
            defer failing.deinit();
            var slow = try rt.spawn(slowTask, .{rt}, .{});
            defer slow.deinit();

            const result = try rt.select(.{ .failing = failing, .slow = slow });

            switch (result) {
                .failing => |val_or_err| {
                    // val_or_err is ParseError!i32
                    _ = val_or_err catch |err| {
                        // Should receive the original error
                        try testing.expectEqual(ParseError.OutOfRange, err);
                        return;
                    };
                    return error.TestUnexpectedResult; // Should have errored
                },
                .slow => |val| {
                    try testing.expectEqual(@as(i32, 99), val);
                    return error.TestUnexpectedResult; // failing should win
                },
            }
        }
    };

    try runtime.runUntilComplete(TestContext.asyncTask, .{&runtime}, .{});
}

test "runtime: select with mixed error types" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    const TestContext = struct {
        const ParseError = error{ InvalidFormat, OutOfRange };
        const IOError = error{ FileNotFound, PermissionDenied };

        fn task1(rt: *Runtime) ParseError!i32 {
            rt.sleep(100);
            return 100;
        }

        fn task2(rt: *Runtime) IOError![]const u8 {
            rt.sleep(10);
            return error.FileNotFound;
        }

        fn task3(rt: *Runtime) bool {
            rt.sleep(150);
            return true;
        }

        fn asyncTask(rt: *Runtime) !void {
            var h1 = try rt.spawn(task1, .{rt}, .{});
            defer h1.deinit();
            var h2 = try rt.spawn(task2, .{rt}, .{});
            defer h2.deinit();
            var h3 = try rt.spawn(task3, .{rt}, .{});
            defer h3.deinit();

            // rt.select returns Cancelable!SelectUnion(...)
            // SelectUnion has: { .h2: IOError![]const u8, .h1: ParseError!i32, .h3: bool }
            const result = try rt.select(.{ .h2 = h2, .h1 = h1, .h3 = h3 });

            switch (result) {
                .h1 => |val_or_err| {
                    _ = val_or_err catch return error.TestUnexpectedResult;
                    return error.TestUnexpectedResult;
                },
                .h2 => |val_or_err| {
                    // val_or_err is IOError![]const u8
                    _ = val_or_err catch |err| {
                        // Verify we got the original error type
                        try testing.expectEqual(IOError.FileNotFound, err);
                        return; // This is expected
                    };
                    return error.TestUnexpectedResult; // Should have errored
                },
                .h3 => |val| {
                    try testing.expectEqual(true, val);
                    return error.TestUnexpectedResult;
                },
            }
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

                const result = try casted.join();
                try testing.expectEqual(@as(i32, 42), result);
            }

            // Test casting error case
            {
                var handle = try rt.spawn(taskError, .{}, .{});
                var casted = handle.cast(anyerror!i32);
                defer casted.deinit();

                const result = casted.join();
                try testing.expectError(error.Foo, result);
            }
        }
    };

    try runtime.runUntilComplete(TestContext.asyncTask, .{&runtime}, .{});
}
