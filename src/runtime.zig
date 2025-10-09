const std = @import("std");
const print = std.debug.print;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const assert = std.debug.assert;
const xev = @import("xev");

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

// Waker interface for asynchronous operations
pub const Waiter = struct {
    runtime: *Runtime,
    coroutine: *Coroutine,

    pub fn markReady(self: Waiter) void {
        self.runtime.markReady(self.coroutine);
    }
};

// Runtime-specific errors
pub const ZioError = error{
    XevError,
    NotInCoroutine,
};

// Timer callback for libxev
fn markReadyFromXevCallback(
    userdata: ?*Waiter,
    loop: *xev.Loop,
    completion: *xev.Completion,
    result: anyerror!void,
) xev.CallbackAction {
    _ = loop;
    _ = completion;
    _ = result catch {};

    if (userdata) |waker| {
        waker.markReady();
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

    // Execute the user's blocking function
    any_blocking_task.execute_fn(any_blocking_task);

    // Push to completion queue (thread-safe MPSC)
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
        // Wake up all coroutines waiting on this blocking task
        while (awaitable.waiting_list.pop()) |waiting_awaitable| {
            const waiting_task = AnyTask.fromAwaitable(waiting_awaitable);
            self.markReady(&waiting_task.coro);
        }
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
};

// Task for runtime scheduling - coroutine-based tasks
pub const AnyTask = struct {
    awaitable: Awaitable,
    id: u64,
    coro: Coroutine,
    timer_c: xev.Completion = .{},
    timer_cancel_c: xev.Completion = .{},
    timer_generation: u2 = 0,

    pub inline fn fromAwaitable(awaitable: *Awaitable) *AnyTask {
        assert(awaitable.kind == .coro);
        return @fieldParentPtr("awaitable", awaitable);
    }

    pub inline fn fromCoroutine(coro: *Coroutine) *AnyTask {
        return @fieldParentPtr("coro", coro);
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

        fn join(self: *Self) T {
            // Check if already completed
            if (self.future_result.get()) |res| {
                return res;
            }

            // Use runtime's wait method for the waiting logic
            self.runtime().wait(self.any_task.id);

            return self.future_result.get() orelse unreachable;
        }

        fn result(self: *Self) T {
            return self.join();
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

        pub fn set(self: *Self, value: T) void {
            const was_set = self.future_result.set(value);
            if (!was_set) {
                // Value was already set, ignore
                return;
            }

            // Wake up all coroutines waiting on this future
            while (self.any_future.awaitable.waiting_list.pop()) |waiting_awaitable| {
                const waiting_task = AnyTask.fromAwaitable(waiting_awaitable);
                const runtime = Runtime.fromCoroutine(&waiting_task.coro);
                runtime.markReady(&waiting_task.coro);
            }
        }

        pub fn wait(self: *Self) T {
            // Check if already set
            if (self.future_result.get()) |res| {
                return res;
            }

            const current_coro = coroutines.getCurrent() orelse unreachable;
            const current_task = AnyTask.fromCoroutine(current_coro);

            self.any_future.awaitable.waiting_list.push(&current_task.awaitable);

            self.any_future.runtime.yield(.waiting);

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
            comptime func: anytype,
            args: anytype,
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

        fn join(self: *Self) T {
            if (self.future_result.get()) |res| {
                return res;
            }

            const current_coro = coroutines.getCurrent() orelse unreachable;
            const current_task = AnyTask.fromCoroutine(current_coro);

            self.any_blocking_task.awaitable.waiting_list.push(&current_task.awaitable);
            self.runtime.yield(.waiting);

            return self.future_result.get() orelse unreachable;
        }

        fn result(self: *Self) T {
            return self.join();
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

        pub fn join(self: *Self) T {
            return switch (self.kind) {
                .coro => |task| task.join(),
                .blocking => |task| task.join(),
                .future => |future| future.wait(),
            };
        }

        pub fn result(self: *Self) T {
            return self.join();
        }
    };
}

fn ReturnType(comptime func: anytype) type {
    return if (@typeInfo(@TypeOf(func)).@"fn".return_type) |ret| ret else void;
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

    pub fn spawn(self: *Runtime, comptime func: anytype, args: anytype, options: CoroutineOptions) !JoinHandle(ReturnType(func)) {
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

        const Result = ReturnType(func);
        const TypedTask = Task(Result);

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

        task.any_task.coro.setup(Result, func, args, &task.future_result);

        entry.value_ptr.* = &task.any_task;

        self.ready_queue.push(&task.any_task.awaitable);

        task.any_task.awaitable.ref_count.incr();
        return JoinHandle(Result){ .kind = .{ .coro = task } };
    }

    pub fn yield(self: *Runtime, desired_state: CoroutineState) void {
        const current_coro = coroutines.getCurrent() orelse unreachable;
        const current_task = AnyTask.fromCoroutine(current_coro);

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
    }

    fn releaseAwaitable(self: *Runtime, awaitable: *Awaitable) void {
        if (awaitable.ref_count.decr()) {
            awaitable.destroy_fn(self, awaitable);
        }
    }

    pub inline fn awaitablePtrFromTaskPtr(task: *AnyTask) *Awaitable {
        return &task.awaitable;
    }

    pub fn getWaiter(self: *Runtime) Waiter {
        const current = coroutines.getCurrent() orelse std.debug.panic("getWaker() must be called from within a coroutine", .{});
        return Waiter{
            .runtime = self,
            .coroutine = current,
        };
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
        comptime func: anytype,
        args: anytype,
    ) !JoinHandle(ReturnType(func)) {
        try self.ensureBlockingInitialized();

        const task = try BlockingTask(ReturnType(func)).init(
            self,
            self.allocator,
            func,
            args,
        );

        return JoinHandle(ReturnType(func)){ .kind = .{ .blocking = task } };
    }

    /// Convenience function that spawns a task, runs the event loop until completion, and returns the result.
    /// This is equivalent to: spawn() + run() + result(), but in a single call.
    /// Returns an error union that includes errors from spawn(), run(), and the task itself.
    pub fn runUntilComplete(self: *Runtime, comptime func: anytype, args: anytype, options: CoroutineOptions) !ReturnPayload(func) {
        var handle = try self.spawn(func, args, options);
        defer handle.deinit();
        try self.run();
        return handle.result();
    }

    fn ReturnPayload(comptime func: anytype) type {
        const T = ReturnType(func);
        return switch (@typeInfo(T)) {
            .error_union => |eu| eu.payload,
            else => T,
        };
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

                        while (current_awaitable.waiting_list.pop()) |waiting_awaitable| {
                            const waiting_task = AnyTask.fromAwaitable(waiting_awaitable);
                            self.markReady(&waiting_task.coro);
                        }
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

    pub fn wait(self: *Runtime, task_id: u64) void {
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
        self.yield(.waiting);
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
    ) error{Timeout}!void {
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
        self.yield(.waiting);

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

    pub fn timedWaitForReady(self: *Runtime, timeout_ns: u64) error{Timeout}!void {
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
            rt.yield(.ready);
            rt.yield(.ready);
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
            rt.yield(.ready);
            rt.yield(.ready);
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

            rt.yield(.ready);
            rt.yield(.ready);
            rt.yield(.ready);
            rt.yield(.ready);

            try waiter1.result();
            try waiter2.result();
            try waiter3.result();
        }
    };

    try runtime.runUntilComplete(TestContext.asyncTask, .{&runtime}, .{});
}
