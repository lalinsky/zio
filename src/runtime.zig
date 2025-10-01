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

// Compile-time detection of whether the backend needs ThreadPool
fn backendNeedsThreadPool() bool {
    return @hasField(xev.Loop, "thread_pool");
}

// Runtime configuration options
pub const RuntimeOptions = struct {
    thread_pool: ThreadPoolOptions = .{},

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
        future_result: FutureResult(T),
        runtime: *Runtime,

        fn destroyFn(runtime: *Runtime, awaitable: *Awaitable) void {
            const any_task = AnyTask.fromAwaitable(awaitable);
            const self: *Self = @fieldParentPtr("any_task", any_task);
            any_task.coro.deinit(runtime.allocator);
            runtime.allocator.destroy(self);
        }

        fn deinit(self: *Self) void {
            self.runtime.releaseAwaitable(&self.any_task.awaitable);
        }

        fn join(self: *Self) T {
            // Check if already completed
            if (self.future_result.get()) |res| {
                return res;
            }

            // Use runtime's wait method for the waiting logic
            self.runtime.wait(self.any_task.id);

            return self.future_result.get() orelse unreachable;
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
                    self.blocking_task.future_result.set(res);
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

            self.any_blocking_task.awaitable.waiting_list.append(&current_task.awaitable);
            current_coro.waitForReady();

            return self.future_result.get() orelse unreachable;
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
        const task = try self.allocator.create(Task(Result));
        errdefer self.allocator.destroy(task);

        task.* = .{
            .any_task = .{
                .awaitable = .{
                    .kind = .coro,
                    .destroy_fn = &Task(Result).destroyFn,
                },
                .id = id,
                .coro = undefined,
            },
            .future_result = .{},
            .runtime = self,
        };

        task.any_task.coro = try Coroutine.init(self.allocator, Result, func, args, &task.future_result, options);
        errdefer task.any_task.coro.deinit(self.allocator);

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
        var waiter = self.getWaiter();

        var timer = xev.Timer.init() catch unreachable;
        defer timer.deinit();

        // Start the timer
        var completion: xev.Completion = undefined;
        timer.run(
            &self.loop,
            &completion,
            milliseconds,
            Waiter,
            &waiter,
            markReadyFromXevCallback,
        );

        // Wait for timer to fire
        waiter.waitForReady();
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

    pub fn run(self: *Runtime) !void {
        while (true) {
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
                task.coro.switchTo(&self.main_context);

                // If the coroutines just yielded, it will end up in running state, so mark it as ready
                if (task.coro.state == .running) {
                    task.coro.state = .ready;
                }

                switch (task.coro.state) {
                    .ready => reschedule.append(awaitable),
                    .dead => {
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

    var handle = try runtime.spawn(TestContext.asyncTask, .{&runtime}, .{});
    defer handle.deinit();

    try runtime.run();
    try handle.result();
}
