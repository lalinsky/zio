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
const task_pool = @import("task_pool.zig");
const TaskPool = task_pool.TaskPool;
const TaskPoolOptions = task_pool.TaskPoolOptions;

// Compile-time detection of whether the backend needs ThreadPool
fn backendNeedsThreadPool() bool {
    return @hasField(xev.Loop, "thread_pool");
}

// Runtime configuration options
pub const RuntimeOptions = struct {
    thread_pool: ThreadPoolOptions = .{},
    stack_pool: StackPoolOptions = .{},
    task_pool: TaskPoolOptions = .{},

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

    pub fn waitForReady(self: Waiter) void {
        self.coroutine.waitForReady();
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

// Typed task that contains the AnyTask and FutureResult
pub fn Task(comptime T: type) type {
    return struct {
        const Self = @This();

        any_task: AnyTask,

        // FutureResult(T) is placed dynamically after AnyTask in the 512-byte allocation
        fn futureResult(self: *Self) *FutureResult(T) {
            comptime {
                const result_offset = std.mem.alignForward(usize, @sizeOf(AnyTask), @alignOf(FutureResult(T)));
                const total_size = result_offset + @sizeOf(FutureResult(T));
                if (total_size > task_pool.TASK_ALLOCATION_SIZE) {
                    @compileError(std.fmt.comptimePrint(
                        "Task(T) allocation too large: {} bytes (max {})",
                        .{ total_size, task_pool.TASK_ALLOCATION_SIZE },
                    ));
                }
            }
            const base: [*]u8 = @ptrCast(self);
            const result_offset = std.mem.alignForward(usize, @sizeOf(AnyTask), @alignOf(FutureResult(T)));
            return @ptrCast(@alignCast(base + result_offset));
        }

        fn destroyFn(rt: *Runtime, awaitable: *Awaitable) void {
            const any_task = AnyTask.fromAwaitable(awaitable);
            const self: *Self = @fieldParentPtr("any_task", any_task);
            // Stack should already be released when coroutine became dead, but check defensively
            if (any_task.coro.stack) |stack| {
                rt.stack_pool.release(stack);
            }
            const allocation: [*]align(task_pool.TASK_ALLOCATION_ALIGNMENT) u8 = @ptrCast(@alignCast(self));
            rt.task_pool.release(allocation);
        }

        fn deinit(self: *Self) void {
            self.runtime().releaseAwaitable(&self.any_task.awaitable);
        }

        fn runtime(self: *Self) *Runtime {
            return Runtime.fromCoroutine(&self.any_task.coro);
        }

        fn join(self: *Self) T {
            // Check if already completed
            if (self.futureResult().get()) |res| {
                return res;
            }

            // Use runtime's wait method for the waiting logic
            self.runtime().wait(self.any_task.id);

            return self.futureResult().get() orelse unreachable;
        }

        fn result(self: *Self) T {
            return self.join();
        }
    };
}

// Typed blocking task that contains the AnyBlockingTask and FutureResult
pub fn BlockingTask(comptime T: type) type {
    return struct {
        const Self = @This();

        any_blocking_task: AnyBlockingTask,
        runtime: *Runtime,

        // FutureResult(T) is placed dynamically after the base struct
        fn futureResult(self: *Self) *FutureResult(T) {
            const base: [*]u8 = @ptrCast(self);
            const result_offset = std.mem.alignForward(usize, @sizeOf(Self), @alignOf(FutureResult(T)));
            return @ptrCast(@alignCast(base + result_offset));
        }

        pub fn init(
            runtime: *Runtime,
            allocator: Allocator,
            comptime func: anytype,
            args: anytype,
        ) !*Self {
            const Args = @TypeOf(args);

            const TaskData = struct {
                blocking_task: Self,
                // FutureResult(T) placed dynamically after blocking_task
                // Args placed dynamically after FutureResult(T)

                fn futureResultOffset() usize {
                    return std.mem.alignForward(usize, @sizeOf(Self), @alignOf(FutureResult(T)));
                }

                fn argsOffset() usize {
                    const result_offset = futureResultOffset();
                    return std.mem.alignForward(usize, result_offset + @sizeOf(FutureResult(T)), @alignOf(Args));
                }

                fn futureResultPtr(self: *@This()) *FutureResult(T) {
                    const base: [*]u8 = @ptrCast(self);
                    return @ptrCast(@alignCast(base + futureResultOffset()));
                }

                fn argsPtr(self: *@This()) *Args {
                    const base: [*]u8 = @ptrCast(self);
                    return @ptrCast(@alignCast(base + argsOffset()));
                }

                fn execute(any_blocking_task: *AnyBlockingTask) void {
                    const blocking_task: *Self = @fieldParentPtr("any_blocking_task", any_blocking_task);
                    const self: *@This() = @fieldParentPtr("blocking_task", blocking_task);

                    const res = @call(.always_inline, func, self.argsPtr().*);
                    self.futureResultPtr().set(res);
                }

                fn destroy(runtime_ptr: *Runtime, awaitable: *Awaitable) void {
                    const any_blocking_task = AnyBlockingTask.fromAwaitable(awaitable);
                    const blocking_task: *Self = @fieldParentPtr("any_blocking_task", any_blocking_task);
                    const self: *@This() = @fieldParentPtr("blocking_task", blocking_task);

                    // Check at compile time if we used task pool
                    const total_size = comptime argsOffset() + @sizeOf(Args);
                    if (comptime total_size <= task_pool.TASK_ALLOCATION_SIZE) {
                        const allocation: [*]align(task_pool.TASK_ALLOCATION_ALIGNMENT) u8 = @ptrCast(@alignCast(self));
                        runtime_ptr.task_pool.release(allocation);
                    } else {
                        // Too large for pool, use regular allocator
                        runtime_ptr.allocator.destroy(self);
                    }
                }
            };

            // Check if we can use task pool
            comptime {
                const total_size = TaskData.argsOffset() + @sizeOf(Args);
                if (total_size > task_pool.TASK_ALLOCATION_SIZE) {
                    // Too large for pool, use regular allocator
                    const task_data = try allocator.create(TaskData);
                    errdefer allocator.destroy(task_data);

                    task_data.blocking_task = .{
                        .any_blocking_task = .{
                            .awaitable = .{
                                .kind = .blocking_task,
                                .destroy_fn = &TaskData.destroy,
                            },
                            .thread_pool_task = .{ .callback = threadPoolCallback },
                            .runtime = runtime,
                            .execute_fn = &TaskData.execute,
                        },
                        .runtime = runtime,
                    };
                    task_data.futureResultPtr().* = FutureResult(T){};
                    task_data.argsPtr().* = args;

                    // Increment ref count for the JoinHandle
                    task_data.blocking_task.any_blocking_task.awaitable.ref_count.incr();

                    runtime.thread_pool.?.schedule(
                        xev.ThreadPool.Batch.from(&task_data.blocking_task.any_blocking_task.thread_pool_task),
                    );

                    return &task_data.blocking_task;
                }
            }

            // Use task pool
            const allocation = try runtime.task_pool.acquire();
            const task_data: *TaskData = @ptrCast(@alignCast(allocation));

            task_data.blocking_task = .{
                .any_blocking_task = .{
                    .awaitable = .{
                        .kind = .blocking_task,
                        .destroy_fn = &TaskData.destroy,
                    },
                    .thread_pool_task = .{ .callback = threadPoolCallback },
                    .runtime = runtime,
                    .execute_fn = &TaskData.execute,
                },
                .runtime = runtime,
            };
            task_data.futureResultPtr().* = FutureResult(T){};
            task_data.argsPtr().* = args;

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
            if (self.futureResult().get()) |res| {
                return res;
            }

            const current_coro = coroutines.getCurrent() orelse unreachable;
            const current_task = AnyTask.fromCoroutine(current_coro);

            self.any_blocking_task.awaitable.waiting_list.append(&current_task.awaitable);
            current_coro.waitForReady();

            return self.futureResult().get() orelse unreachable;
        }

        fn result(self: *Self) T {
            return self.join();
        }
    };
}

// Public handle for spawned tasks
pub fn JoinHandle(comptime T: type) type {
    return struct {
        const Self = @This();

        kind: union(enum) {
            coro: *Task(T),
            blocking: *BlockingTask(T),
        },

        pub fn deinit(self: *Self) void {
            switch (self.kind) {
                .coro => |task| task.deinit(),
                .blocking => |task| task.deinit(),
            }
        }

        pub fn join(self: *Self) T {
            return switch (self.kind) {
                .coro => |task| task.join(),
                .blocking => |task| task.join(),
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

    pub fn append(self: *AwaitableList, awaitable: *Awaitable) void {
        self.push(awaitable);
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
    task_pool: TaskPool,
    count: u32 = 0,
    main_context: coroutines.Context,
    allocator: Allocator,

    tasks: std.AutoHashMapUnmanaged(u64, *AnyTask) = .{},

    ready_queue: AwaitableList = .{},
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
            .task_pool = TaskPool.init(allocator, options.task_pool),
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

        // Clean up stack pool and task pool
        self.stack_pool.deinit();
        self.task_pool.deinit();
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

        // Acquire allocation from task pool
        const allocation = try self.task_pool.acquire();
        const task: *TypedTask = @ptrCast(@alignCast(allocation));
        errdefer self.task_pool.release(allocation);

        // Acquire stack from pool
        const stack = try self.stack_pool.acquire(options.stack_size);
        errdefer self.stack_pool.release(stack);

        task.any_task = .{
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
        };

        // Initialize FutureResult in the dynamic location
        task.futureResult().* = .{};

        task.any_task.coro.setup(Result, func, args, task.futureResult());

        entry.value_ptr.* = &task.any_task;

        self.ready_queue.append(&task.any_task.awaitable);

        task.any_task.awaitable.ref_count.incr();
        return JoinHandle(Result){ .kind = .{ .coro = task } };
    }

    pub fn yield(self: *Runtime) void {
        _ = self;
        coroutines.yield();
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
            // Time-based stack pool and task pool cleanup
            const now = std.time.milliTimestamp();
            if (now - self.last_cleanup_ms >= self.cleanup_interval_ms) {
                self.stack_pool.cleanup();
                self.task_pool.cleanup();
                self.last_cleanup_ms = now;
            }

            var reschedule: AwaitableList = .{};

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
                task.coro.state = .running;
                task.coro.switchTo();

                // If the coroutines just yielded, it will end up in running state, so mark it as ready
                if (task.coro.state == .running) {
                    task.coro.state = .ready;
                }

                switch (task.coro.state) {
                    .ready => reschedule.append(awaitable),
                    .dead => {
                        // Release stack immediately since coroutine execution is complete
                        if (task.coro.stack) |stack| {
                            self.stack_pool.release(stack);
                            task.coro.stack = null;
                        }

                        while (awaitable.waiting_list.pop()) |waiting_awaitable| {
                            const waiting_task = AnyTask.fromAwaitable(waiting_awaitable);
                            self.markReady(&waiting_task.coro);
                        }
                        self.cleanup_queue.append(awaitable);
                    },
                    else => {},
                }
            }

            // Re-add coroutines that we previously ready
            self.ready_queue.concatByMoving(&reschedule);

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
        self.ready_queue.append(&task.awaitable);
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
        task.awaitable.waiting_list.append(&current_task.awaitable);
        current_coro.waitForReady();
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
        current.waitForReady();

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
