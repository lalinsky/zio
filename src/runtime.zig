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
const CoroutineOptions = coroutines.CoroutineOptions;
// const Error = coroutines.Error;
const RefCounter = @import("ref_counter.zig").RefCounter;
const FutureResult = @import("future_result.zig").FutureResult;
const stack_pool = @import("stack_pool.zig");
const StackPool = stack_pool.StackPool;
const StackPoolOptions = stack_pool.StackPoolOptions;

// Compile-time detection of whether the backend needs ThreadPool
fn backendNeedsThreadPool() bool {
    return @hasField(xev.Loop, "thread_pool");
}

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
        Runtime.fromCoroutine(coro).markReady(coro);
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

    // Push to completion queue (thread-safe MPSC)
    // Even if canceled, we still mark as complete so waiters wake up
    any_blocking_task.runtime.blocking_completions.push(&any_blocking_task.awaitable);

    // Wake up main loop
    any_blocking_task.runtime.async_wakeup.notify() catch {};
}

// Async callback to drain completed blocking tasks
fn drainBlockingCompletions(
    runtime: ?*Runtime,
    loop: *xev.Loop,
    c: *xev.Completion,
    result: xev.Async.WaitError!void,
) xev.CallbackAction {
    _ = result catch unreachable;
    _ = loop;
    _ = c;
    const self = runtime.?;

    // Drain all completed blocking tasks
    while (self.blocking_completions.pop()) |awaitable| {
        // Mark awaitable as complete and wake all waiters (coroutines and threads)
        awaitable.markComplete(self);
        // Release the blocking task's reference (initial ref from init)
        self.releaseAwaitable(awaitable);
    }

    return .rearm;
}

// Awaitable kind - distinguishes different awaitable types
pub const AwaitableKind = enum {
    coro,
    blocking_task,
    future,
};

// Awaitable - base type for anything that can be waited on
pub const Awaitable = struct {
    kind: AwaitableKind,
    next: ?*Awaitable = null,
    waiting_list: AwaitableList = .{},
    ref_count: RefCounter(u32) = RefCounter(u32).init(),
    destroy_fn: *const fn (*Runtime, *Awaitable) void,
    in_list: if (builtin.mode == .Debug) bool else void = if (builtin.mode == .Debug) false else {},

    // Universal state for both coroutines and threads
    // 0 = pending/not ready, 1 = complete/ready
    state: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    // Cancellation flag - set to request cancellation, consumed by yield()
    canceled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Wait for this awaitable to complete. Works from both coroutines and threads.
    /// When called from a coroutine, suspends the coroutine.
    /// When called from a thread, parks the thread using futex.
    /// Returns error.Canceled if the coroutine was canceled during the wait.
    pub fn waitForComplete(self: *Awaitable) Cancelable!void {
        // Fast path: check if already complete
        const fast_state = self.state.load(.acquire);
        if (fast_state == 1) return;

        if (coroutines.getCurrent()) |current| {
            // Coroutine path: add to wait queue and suspend
            const task = AnyTask.fromCoroutine(current);
            self.waiting_list.push(&task.awaitable);

            // Double-check state before suspending (avoid lost wakeup)
            const double_check_state = self.state.load(.acquire);
            if (double_check_state == 1) {
                // Completed while we were adding to queue, remove ourselves
                _ = self.waiting_list.remove(&task.awaitable);
                return;
            }

            const runtime = Runtime.fromCoroutine(current);
            runtime.yield(.waiting) catch |err| {
                // If yield itself was canceled, remove from wait list
                _ = self.waiting_list.remove(&task.awaitable);
                return err;
            };

            // Yield returned successfully, awaitable must be complete
        } else {
            // Thread path: park on the state using futex
            while (true) {
                const current_state = self.state.load(.acquire);
                if (current_state == 1) return;
                std.Thread.Futex.wait(&self.state, 0);
            }
        }
    }

    /// Wait for this awaitable to complete with a timeout. Works from both coroutines and threads.
    /// Returns error.Timeout if the timeout expires before completion.
    /// Returns error.Canceled if the coroutine was canceled during the wait.
    /// For coroutines, uses runtime timer infrastructure.
    /// For threads, uses futex timedWait directly.
    pub fn timedWaitForComplete(self: *Awaitable, timeout_ns: u64) error{ Timeout, Canceled }!void {
        // Fast path: check if already complete
        const fast_state = self.state.load(.acquire);
        if (fast_state == 1) return;

        if (coroutines.getCurrent()) |current| {
            // Coroutine path: get runtime and use timer infrastructure
            const task = AnyTask.fromCoroutine(current);
            const rt = Runtime.fromCoroutine(current);

            self.waiting_list.push(&task.awaitable);

            const double_check_state = self.state.load(.acquire);
            if (double_check_state == 1) {
                _ = self.waiting_list.remove(&task.awaitable);
                return;
            }

            const TimeoutContext = struct {
                wait_queue: *AwaitableList,
                awaitable: *Awaitable,
            };

            var timeout_ctx = TimeoutContext{
                .wait_queue = &self.waiting_list,
                .awaitable = &task.awaitable,
            };

            rt.timedWaitForReadyWithCallback(
                timeout_ns,
                TimeoutContext,
                &timeout_ctx,
                struct {
                    fn onTimeout(ctx: *TimeoutContext) bool {
                        return ctx.wait_queue.remove(ctx.awaitable);
                    }
                }.onTimeout,
            ) catch |err| {
                // Handle both timeout and cancellation from yield
                if (err == error.Canceled) {
                    _ = self.waiting_list.remove(&task.awaitable);
                }
                return err;
            };

            // Yield returned successfully, awaitable must be complete
        } else {
            // Thread path: use futex timedWait
            while (true) {
                const current_state = self.state.load(.acquire);
                if (current_state == 1) return;
                try std.Thread.Futex.timedWait(&self.state, 0, timeout_ns);
            }
        }
    }

    /// Mark this awaitable as complete and wake all waiters (both coroutines and threads).
    pub fn markComplete(self: *Awaitable, runtime: *Runtime) void {
        // Set state first (release semantics for memory ordering)
        self.state.store(1, .release);

        // Wake all waiting coroutines
        while (self.waiting_list.pop()) |waiting_awaitable| {
            const waiting_task = AnyTask.fromAwaitable(waiting_awaitable);
            runtime.markReady(&waiting_task.coro);
        }

        // Wake all waiting threads
        std.Thread.Futex.wake(&self.state, std.math.maxInt(u32));
    }

    /// Request cancellation of this awaitable.
    /// The cancellation flag will be consumed by the next yield() call.
    pub fn requestCancellation(self: *Awaitable) void {
        self.canceled.store(true, .release);
    }
};

// Task for runtime scheduling - coroutine-based tasks
pub const AnyTask = struct {
    awaitable: Awaitable,
    id: u64,
    coro: Coroutine,
    timer_c: xev.Completion = .{},
    timer_cancel_c: xev.Completion = .{},
    timer_generation: u2 = 0,
    shield_count: u32 = 0,

    pub inline fn fromAwaitable(awaitable: *Awaitable) *AnyTask {
        assert(awaitable.kind == .coro);
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

// Typed task that contains the AnyTask and FutureResult
pub fn Task(comptime T: type) type {
    return struct {
        const Self = @This();

        any_task: AnyTask,
        future_result: FutureResult(T),

        fn destroyFn(rt: *Runtime, awaitable: *Awaitable) void {
            const any_task = AnyTask.fromAwaitable(awaitable);
            const self: *Self = @fieldParentPtr("any_task", any_task);
            // Stack should already be released when coroutine became dead, but check defensively
            if (any_task.coro.stack) |stack| {
                rt.stack_pool.release(stack);
            }
            rt.allocator.destroy(self);
        }

        fn deinit(self: *Self) void {
            self.runtime().releaseAwaitable(&self.any_task.awaitable);
        }

        fn runtime(self: *Self) *Runtime {
            return Runtime.fromCoroutine(&self.any_task.coro);
        }

        fn join(self: *Self) !T {
            // Check if already completed
            if (self.future_result.get()) |res| {
                return res;
            }

            // Disallow self-join from within the same coroutine
            if (coroutines.getCurrent()) |current| {
                const current_task = AnyTask.fromCoroutine(current);
                if (current_task == &self.any_task) {
                    std.debug.panic("a task cannot join itself", .{});
                }
            }

            // Wait for task to complete (works from both coroutines and threads)
            try self.any_task.awaitable.waitForComplete();

            return self.future_result.get() orelse unreachable;
        }

        fn result(self: *Self) !T {
            return self.join();
        }

        /// Request cancellation of this task.
        /// The cancellation flag will be checked at the next yield point.
        pub fn cancel(self: *Self) void {
            self.any_task.cancel();
        }
    };
}

// Typed future that can be set from callbacks
pub fn Future(comptime T: type) type {
    return struct {
        const Self = @This();

        any_future: AnyFuture,
        future_result: FutureResult(T),

        fn destroyFn(rt: *Runtime, awaitable: *Awaitable) void {
            const any_future = AnyFuture.fromAwaitable(awaitable);
            const self: *Self = @fieldParentPtr("any_future", any_future);
            rt.allocator.destroy(self);
        }

        pub fn init(runtime: *Runtime, allocator: Allocator) !*Self {
            const self = try allocator.create(Self);
            self.* = .{
                .any_future = .{
                    .awaitable = .{
                        .kind = .future,
                        .destroy_fn = destroyFn,
                    },
                    .runtime = runtime,
                },
                .future_result = FutureResult(T){},
            };

            // ref_count starts at 1 by default via RefCounter.init()

            return self;
        }

        pub fn deinit(self: *Self) void {
            self.any_future.runtime.releaseAwaitable(&self.any_future.awaitable);
        }

        pub fn set(self: *Self, value: anyerror!T) void {
            const was_set = self.future_result.set(value);
            if (!was_set) {
                // Value was already set, ignore
                return;
            }

            // Mark awaitable as complete and wake all waiters (coroutines and threads)
            self.any_future.awaitable.markComplete(self.any_future.runtime);
        }

        pub fn wait(self: *Self) !T {
            // Check if already set
            if (self.future_result.get()) |res| {
                return res;
            }

            // Wait for future to be set (works from both coroutines and threads)
            try self.any_future.awaitable.waitForComplete();

            return self.future_result.get() orelse unreachable;
        }
    };
}

// Typed blocking task that contains the AnyBlockingTask and FutureResult
pub fn BlockingTask(comptime T: type) type {
    return struct {
        const Self = @This();

        any_blocking_task: AnyBlockingTask,
        future_result: FutureResult(T),
        runtime: *Runtime,

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
                    const blocking_task: *Self = @fieldParentPtr("any_blocking_task", any_blocking_task);
                    const self: *@This() = @fieldParentPtr("blocking_task", blocking_task);

                    const res = @call(.always_inline, func, self.args);
                    _ = self.blocking_task.future_result.set(res);
                }

                fn destroy(runtime_ptr: *Runtime, awaitable: *Awaitable) void {
                    const any_blocking_task = AnyBlockingTask.fromAwaitable(awaitable);
                    const blocking_task: *Self = @fieldParentPtr("any_blocking_task", any_blocking_task);
                    const self: *@This() = @fieldParentPtr("blocking_task", blocking_task);
                    runtime_ptr.allocator.destroy(self);
                }
            };

            const task_data = try allocator.create(TaskData);
            errdefer allocator.destroy(task_data);

            task_data.* = .{
                .blocking_task = .{
                    .any_blocking_task = .{
                        .awaitable = .{
                            .kind = .blocking_task,
                            .destroy_fn = &TaskData.destroy,
                        },
                        .thread_pool_task = .{ .callback = threadPoolCallback },
                        .runtime = runtime,
                        .execute_fn = &TaskData.execute,
                    },
                    .future_result = FutureResult(T){},
                    .runtime = runtime,
                },
                .args = args,
            };

            // Increment ref count for the JoinHandle
            task_data.blocking_task.any_blocking_task.awaitable.ref_count.incr();

            runtime.thread_pool.?.schedule(
                xev.ThreadPool.Batch.from(&task_data.blocking_task.any_blocking_task.thread_pool_task),
            );

            return &task_data.blocking_task;
        }

        fn deinit(self: *Self) void {
            self.runtime.releaseAwaitable(&self.any_blocking_task.awaitable);
        }

        fn join(self: *Self) !T {
            if (self.future_result.get()) |res| {
                return res;
            }

            // Wait for blocking task to complete (works from both coroutines and threads)
            // The waiter can be canceled even though the blocking task continues execution
            try self.any_blocking_task.awaitable.waitForComplete();

            return self.future_result.get() orelse unreachable;
        }

        fn result(self: *Self) !T {
            return self.join();
        }

        /// Request cancellation of this blocking task.
        /// If the task hasn't started executing yet, it will skip execution.
        /// If already executing, this has no effect (cannot stop blocking work).
        pub fn cancel(self: *Self) void {
            self.any_blocking_task.cancel();
        }
    };
}

// Public handle for spawned tasks and futures
pub fn JoinHandle(comptime T: type) type {
    return struct {
        const Self = @This();

        kind: union(enum) {
            coro: *Task(T),
            blocking: *BlockingTask(T),
            future: *Future(T),
        },

        pub fn deinit(self: *Self) void {
            switch (self.kind) {
                .coro => |task| task.deinit(),
                .blocking => |task| task.deinit(),
                .future => |future| future.deinit(),
            }
        }

        pub fn join(self: *Self) !T {
            return switch (self.kind) {
                .coro => |task| try task.join(),
                .blocking => |task| try task.join(),
                .future => |future| try future.wait(),
            };
        }

        pub fn result(self: *Self) !T {
            return self.join();
        }

        /// Request cancellation of this task.
        /// For coroutine tasks: Sets the cancellation flag, which will be checked at the next yield point.
        /// For blocking tasks: Sets the cancellation flag, which will skip execution if not yet started.
        /// For futures: Has no effect (futures are not cancelable).
        pub fn cancel(self: *Self) void {
            switch (self.kind) {
                .coro => |task| task.any_task.cancel(),
                .blocking => |task| task.any_blocking_task.cancel(),
                .future => {}, // Futures cannot be canceled
            }
        }
    };
}

// Simple singly-linked list of awaitables
pub const AwaitableList = struct {
    head: ?*Awaitable = null,
    tail: ?*Awaitable = null,

    pub fn push(self: *AwaitableList, awaitable: *Awaitable) void {
        if (builtin.mode == .Debug) {
            std.debug.assert(!awaitable.in_list);
            awaitable.in_list = true;
        }
        awaitable.next = null;
        if (self.tail) |tail| {
            tail.next = awaitable;
            self.tail = awaitable;
        } else {
            self.head = awaitable;
            self.tail = awaitable;
        }
    }

    pub fn pop(self: *AwaitableList) ?*Awaitable {
        const head = self.head orelse return null;
        if (builtin.mode == .Debug) {
            head.in_list = false;
        }
        self.head = head.next;
        if (self.head == null) {
            self.tail = null;
        }
        head.next = null;
        return head;
    }

    pub fn concatByMoving(self: *AwaitableList, other: *AwaitableList) void {
        if (other.head == null) return;

        if (self.tail) |tail| {
            tail.next = other.head;
            self.tail = other.tail;
        } else {
            self.head = other.head;
            self.tail = other.tail;
        }

        other.head = null;
        other.tail = null;
    }

    pub fn remove(self: *AwaitableList, awaitable: *Awaitable) bool {
        // Handle empty list
        if (self.head == null) return false;

        // Handle removing head
        if (self.head == awaitable) {
            if (builtin.mode == .Debug) {
                std.debug.assert(awaitable.in_list);
                awaitable.in_list = false;
            }
            self.head = awaitable.next;
            if (self.head == null) {
                self.tail = null;
            }
            awaitable.next = null;
            return true;
        }

        // Search for awaitable in the list
        var current = self.head;
        while (current) |curr| {
            if (curr.next == awaitable) {
                if (builtin.mode == .Debug) {
                    std.debug.assert(awaitable.in_list);
                    awaitable.in_list = false;
                }
                curr.next = awaitable.next;
                if (awaitable == self.tail) {
                    self.tail = curr;
                }
                awaitable.next = null;
                return true;
            }
            current = curr.next;
        }

        return false;
    }
};

// Runtime class - the main zio runtime
pub const Runtime = struct {
    loop: xev.Loop,
    thread_pool: ?*xev.ThreadPool = null,
    stack_pool: StackPool,
    count: u32 = 0,
    main_context: coroutines.Context,
    allocator: Allocator,

    tasks: std.AutoHashMapUnmanaged(u64, *AnyTask) = .{},

    ready_queue: AwaitableList = .{},
    next_ready_queue: AwaitableList = .{},
    cleanup_queue: AwaitableList = .{},

    // Blocking task support
    blocking_completions: xev.queue_mpsc.Intrusive(Awaitable) = undefined,
    async_wakeup: xev.Async = undefined,
    async_completion: xev.Completion = undefined,
    blocking_initialized: bool = false,

    // Stack pool cleanup tracking
    cleanup_interval_ms: i64,
    last_cleanup_ms: i64 = 0,

    /// Get the Runtime instance from any coroutine that belongs to it
    pub fn fromCoroutine(coro: *Coroutine) *Runtime {
        return @fieldParentPtr("main_context", coro.parent_context_ptr);
    }

    /// Get the current Runtime from within a coroutine
    pub fn getCurrent() ?*Runtime {
        if (coroutines.getCurrent()) |coro| {
            return fromCoroutine(coro);
        }
        return null;
    }

    pub fn init(allocator: Allocator, options: RuntimeOptions) !Runtime {
        // Initialize ThreadPool if enabled
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

        // Initialize libxev loop with optional ThreadPool
        const loop = try xev.Loop.init(.{
            .thread_pool = thread_pool,
        });

        return Runtime{
            .allocator = allocator,
            .loop = loop,
            .thread_pool = thread_pool,
            .stack_pool = StackPool.init(allocator, options.stack_pool),
            .cleanup_interval_ms = options.stack_pool.cleanup_interval_ms,
            .main_context = undefined,
        };
    }

    pub fn deinit(self: *Runtime) void {
        // Shutdown ThreadPool before cleaning up tasks and loop
        if (self.thread_pool) |tp| {
            tp.shutdown();
        }

        var iter = self.tasks.iterator();
        while (iter.next()) |entry| {
            const task = entry.value_ptr.*;
            self.releaseAwaitable(&task.awaitable);
        }
        self.tasks.deinit(self.allocator);

        // Clean up blocking task support
        if (self.blocking_initialized) {
            self.async_wakeup.deinit();
        }

        self.loop.deinit();

        // Clean up ThreadPool after loop
        if (self.thread_pool) |tp| {
            tp.deinit();
            self.allocator.destroy(tp);
        }

        // Clean up stack pool
        self.stack_pool.deinit();
    }

    pub fn spawn(self: *Runtime, func: anytype, args: meta.ArgsType(func), options: CoroutineOptions) !JoinHandle(meta.Result(func)) {
        const debug_crash = false;
        if (debug_crash) {
            const v = @call(.always_inline, func, args);
            std.debug.print("Spawned task with ID {any}\n", .{v});
        }

        const id = self.count;
        self.count += 1;

        const entry = try self.tasks.getOrPut(self.allocator, id);
        if (entry.found_existing) {
            std.debug.panic("Task ID {} already exists", .{id});
        }
        errdefer self.tasks.removeByPtr(entry.key_ptr);

        const Result = meta.ReturnType(func);
        const Payload = meta.Payload(Result);
        const TypedTask = Task(Payload);

        const task = try self.allocator.create(TypedTask);
        errdefer self.allocator.destroy(task);

        // Acquire stack from pool
        const stack = try self.stack_pool.acquire(options.stack_size);
        errdefer self.stack_pool.release(stack);

        task.* = .{
            .any_task = .{
                .id = id,
                .awaitable = .{
                    .kind = .coro,
                    .destroy_fn = &TypedTask.destroyFn,
                },
                .coro = .{
                    .stack = stack,
                    .parent_context_ptr = &self.main_context,
                    .state = .ready,
                },
            },
            .future_result = .{},
        };

        task.any_task.coro.setup(func, args, &task.future_result);

        entry.value_ptr.* = &task.any_task;

        self.ready_queue.push(&task.any_task.awaitable);

        task.any_task.awaitable.ref_count.incr();
        return JoinHandle(Payload){ .kind = .{ .coro = task } };
    }

    pub fn yield(self: *Runtime, desired_state: CoroutineState) Cancelable!void {
        const current_coro = coroutines.getCurrent() orelse unreachable;
        const current_task = AnyTask.fromCoroutine(current_coro);

        // Check and consume cancellation flag before yielding (unless shielded)
        if (current_task.shield_count == 0) {
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

            coroutines.setCurrent(&next_task.coro);
            coroutines.switchContext(&current_coro.context, &next_task.coro.context);
        } else {
            coroutines.switchContext(&current_coro.context, current_coro.parent_context_ptr);
        }

        std.debug.assert(coroutines.getCurrent() == current_coro);

        // Check again after resuming in case we were canceled while suspended (unless shielded)
        if (current_task.shield_count == 0) {
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
    pub fn beginShield(self: *Runtime) void {
        _ = self;
        const current_coro = coroutines.getCurrent() orelse unreachable;
        const current_task = AnyTask.fromCoroutine(current_coro);
        current_task.shield_count += 1;
    }

    /// End a cancellation shield.
    /// Must be paired with beginShield().
    pub fn endShield(self: *Runtime) void {
        _ = self;
        const current_coro = coroutines.getCurrent() orelse unreachable;
        const current_task = AnyTask.fromCoroutine(current_coro);
        std.debug.assert(current_task.shield_count > 0);
        current_task.shield_count -= 1;
    }

    fn releaseAwaitable(self: *Runtime, awaitable: *Awaitable) void {
        if (awaitable.ref_count.decr()) {
            awaitable.destroy_fn(self, awaitable);
        }
    }

    pub inline fn awaitablePtrFromTaskPtr(task: *AnyTask) *Awaitable {
        return &task.awaitable;
    }

    pub fn sleep(self: *Runtime, milliseconds: u64) void {
        self.timedWaitForReady(milliseconds * 1_000_000) catch return;
        unreachable; // Should always timeout - waking without timeout is a bug
    }

    fn ensureBlockingInitialized(self: *Runtime) !void {
        if (self.blocking_initialized) return;
        if (self.thread_pool == null) return error.ThreadPoolRequired;

        self.blocking_completions.init();
        self.async_wakeup = try xev.Async.init();

        // Register async completion to drain blocking tasks
        self.async_wakeup.wait(
            &self.loop,
            &self.async_completion,
            Runtime,
            self,
            drainBlockingCompletions,
        );

        self.blocking_initialized = true;
    }

    pub fn spawnBlocking(
        self: *Runtime,
        func: anytype,
        args: meta.ArgsType(func),
    ) !JoinHandle(meta.Result(func)) {
        try self.ensureBlockingInitialized();

        const Payload = meta.Result(func);
        const task = try BlockingTask(Payload).init(
            self,
            self.allocator,
            func,
            args,
        );

        return JoinHandle(Payload){ .kind = .{ .blocking = task } };
    }

    /// Convenience function that spawns a task, runs the event loop until completion, and returns the result.
    /// This is equivalent to: spawn() + run() + result(), but in a single call.
    /// Returns an error union that includes errors from spawn(), run(), and the task itself.
    pub fn runUntilComplete(self: *Runtime, func: anytype, args: meta.ArgsType(func), options: CoroutineOptions) !meta.Result(func) {
        var handle = try self.spawn(func, args, options);
        defer handle.deinit();
        try self.run();
        return handle.result();
    }

    pub fn run(self: *Runtime) !void {
        while (true) {
            // Time-based stack pool cleanup
            const now = std.time.milliTimestamp();
            if (now - self.last_cleanup_ms >= self.cleanup_interval_ms) {
                self.stack_pool.cleanup();
                self.last_cleanup_ms = now;
            }

            // Cleanup dead coroutines
            while (self.cleanup_queue.pop()) |awaitable| {
                const task = AnyTask.fromAwaitable(awaitable);
                _ = self.tasks.remove(task.id);
                // Runtime releases its reference when removing from hashmap
                self.releaseAwaitable(awaitable);
                // If ref_count > 0, Task(T) handles still exist, keep the task alive
            }

            // Process all ready coroutines (once)
            while (self.ready_queue.pop()) |awaitable| {
                const task = AnyTask.fromAwaitable(awaitable);

                coroutines.setCurrent(&task.coro);
                defer coroutines.clearCurrent();
                coroutines.switchContext(&self.main_context, &task.coro.context);

                // Handle dead coroutines (checks getCurrent() to catch tasks that died via direct switch in yield())
                if (coroutines.getCurrent()) |current_coro| {
                    if (current_coro.state == .dead) {
                        const current_task = AnyTask.fromCoroutine(current_coro);
                        const current_awaitable = &current_task.awaitable;

                        // Release stack immediately since coroutine execution is complete
                        if (current_coro.stack) |stack| {
                            self.stack_pool.release(stack);
                            current_coro.stack = null;
                        }

                        // Mark awaitable as complete and wake all waiters (coroutines and threads)
                        current_awaitable.markComplete(self);
                        self.cleanup_queue.push(current_awaitable);
                    }
                }

                // Other states (.ready, .waiting) are handled by yield() or markReady()
            }

            // Move yielded coroutines back to ready queue
            self.ready_queue.concatByMoving(&self.next_ready_queue);

            // If we have no active coroutines, exit
            if (self.tasks.size == 0) {
                self.loop.stop();
                break;
            }

            // Check for I/O events without blocking if we have pending work
            const mode: xev.RunMode = if (self.cleanup_queue.head != null or self.ready_queue.head != null)
                .no_wait
            else
                .once;

            try self.loop.run(mode);
        }
    }

    pub fn markReady(self: *Runtime, coro: *Coroutine) void {
        if (coro.state != .waiting) std.debug.panic("coroutine is not waiting", .{});
        coro.state = .ready;
        const task = AnyTask.fromCoroutine(coro);
        self.ready_queue.push(&task.awaitable);
    }

    pub fn wait(self: *Runtime, task_id: u64) Cancelable!void {
        const task = self.tasks.get(task_id) orelse return;
        if (task.coro.state == .dead) {
            return;
        }
        const current_coro = coroutines.getCurrent() orelse std.debug.panic("not in coroutine", .{});
        const current_task = AnyTask.fromCoroutine(current_coro);
        if (current_task == task) {
            std.debug.panic("a task cannot wait on itself", .{});
        }
        task.awaitable.waiting_list.push(&current_task.awaitable);
        self.yield(.waiting) catch |err| {
            // On cancellation, remove from wait queue
            _ = task.awaitable.waiting_list.remove(&current_task.awaitable);
            return err;
        };
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
        self: *Runtime,
        timeout_ns: u64,
        comptime TimeoutContext: type,
        timeout_ctx: *TimeoutContext,
        comptime onTimeout: fn (ctx: *TimeoutContext) bool,
    ) error{ Timeout, Canceled }!void {
        const current = coroutines.getCurrent() orelse unreachable;
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
                        Runtime.fromCoroutine(&t.coro).markReady(&t.coro);
                    }
                    return .disarm;
                }
            }.callback,
        );

        // Wait for either timeout or external markReady
        self.yield(.waiting) catch |err| {
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

    pub fn timedWaitForReady(self: *Runtime, timeout_ns: u64) error{ Timeout, Canceled }!void {
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
        self: *Runtime,
        completion: *xev.Completion,
    ) Cancelable!void {
        var was_canceled = false;
        var cancel_completion: xev.Completion = .{};

        while (completion.state() != .dead) {
            self.yield(.waiting) catch |err| switch (err) {
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

            const result = handle.join();
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
            const result = future.wait();
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
        fn setterTask(future: *Future(i32)) !void {
            // Simulate async work
            const rt = Runtime.getCurrent().?;
            try rt.yield(.ready);
            try rt.yield(.ready);
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
            var setter_handle = try rt.spawn(setterTask, .{future}, .{});
            defer setter_handle.deinit();

            // Spawn getter coroutine
            var getter_handle = try rt.spawn(getterTask, .{future}, .{});
            defer getter_handle.deinit();

            const result = getter_handle.join();
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
            const result = future.wait();
            try testing.expectEqual(expected, result);
        }

        fn setterTask(future: *Future(i32)) !void {
            // Let waiters block first
            const rt = Runtime.getCurrent().?;
            try rt.yield(.ready);
            try rt.yield(.ready);
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
            var setter = try rt.spawn(setterTask, .{future}, .{});
            defer setter.deinit();

            try rt.yield(.ready);
            try rt.yield(.ready);
            try rt.yield(.ready);
            try rt.yield(.ready);

            try waiter1.result();
            try waiter2.result();
            try waiter3.result();
        }
    };

    try runtime.runUntilComplete(TestContext.asyncTask, .{&runtime}, .{});
}
