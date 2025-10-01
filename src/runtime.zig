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

// Task for runtime scheduling
pub const AnyTask = struct {
    next: ?*AnyTask = null,
    id: u64,
    coro: Coroutine,
    waiting_list: AnyTaskList = .{},
    ref_count: RefCounter(u32) = RefCounter(u32).init(),
    destroy_fn: *const fn (*Runtime, *AnyTask) void,
    in_list: if (builtin.mode == .Debug) bool else void = if (builtin.mode == .Debug) false else {},
};

// Typed task that contains the AnyTask and FutureResult
pub fn Task(comptime T: type) type {
    return struct {
        const Self = @This();

        any_task: AnyTask,
        future_result: FutureResult(T),
        runtime: *Runtime,

        fn destroyFn(runtime: *Runtime, any_task: *AnyTask) void {
            const self: *Self = @fieldParentPtr("any_task", any_task);
            any_task.coro.deinit(runtime.allocator);
            runtime.allocator.destroy(self);
        }

        fn deinit(self: *Self) void {
            self.runtime.releaseTask(&self.any_task);
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

// Public handle for spawned tasks
pub fn JoinHandle(comptime T: type) type {
    return struct {
        const Self = @This();

        kind: union(enum) {
            coro: *Task(T),
        },

        pub fn deinit(self: *Self) void {
            switch (self.kind) {
                .coro => |task| task.deinit(),
            }
        }

        pub fn join(self: *Self) T {
            return switch (self.kind) {
                .coro => |task| task.join(),
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

// Simple singly-linked list of tasks
pub const AnyTaskList = struct {
    head: ?*AnyTask = null,
    tail: ?*AnyTask = null,

    pub fn push(self: *AnyTaskList, task: *AnyTask) void {
        if (builtin.mode == .Debug) {
            std.debug.assert(!task.in_list);
            task.in_list = true;
        }
        task.next = null;
        if (self.tail) |tail| {
            tail.next = task;
            self.tail = task;
        } else {
            self.head = task;
            self.tail = task;
        }
    }

    pub fn pop(self: *AnyTaskList) ?*AnyTask {
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

    pub fn append(self: *AnyTaskList, task: *AnyTask) void {
        self.push(task);
    }

    pub fn concatByMoving(self: *AnyTaskList, other: *AnyTaskList) void {
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

    pub fn remove(self: *AnyTaskList, task: *AnyTask) bool {
        // Handle empty list
        if (self.head == null) return false;

        // Handle removing head
        if (self.head == task) {
            if (builtin.mode == .Debug) {
                std.debug.assert(task.in_list);
                task.in_list = false;
            }
            self.head = task.next;
            if (self.head == null) {
                self.tail = null;
            }
            task.next = null;
            return true;
        }

        // Search for task in the list
        var current = self.head;
        while (current) |curr| {
            if (curr.next == task) {
                if (builtin.mode == .Debug) {
                    std.debug.assert(task.in_list);
                    task.in_list = false;
                }
                curr.next = task.next;
                if (task == self.tail) {
                    self.tail = curr;
                }
                task.next = null;
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

    ready_queue: AnyTaskList = .{},
    cleanup_queue: AnyTaskList = .{},

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
            self.releaseTask(task);
        }
        self.tasks.deinit(self.allocator);

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
                .id = id,
                .coro = undefined,
                .destroy_fn = &Task(Result).destroyFn,
            },
            .future_result = .{},
            .runtime = self,
        };

        task.any_task.coro = try Coroutine.init(self.allocator, Result, func, args, &task.future_result, options);
        errdefer task.any_task.coro.deinit(self.allocator);

        entry.value_ptr.* = &task.any_task;

        self.ready_queue.append(&task.any_task);

        task.any_task.ref_count.incr();
        return JoinHandle(Result){ .kind = .{ .coro = task } };
    }

    pub fn yield(self: *Runtime) void {
        _ = self;
        coroutines.yield();
    }

    fn releaseTask(self: *Runtime, any_task: *AnyTask) void {
        if (any_task.ref_count.decr()) {
            any_task.destroy_fn(self, any_task);
        }
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

    pub fn run(self: *Runtime) !void {
        while (true) {
            var reschedule: AnyTaskList = .{};

            // Cleanup dead coroutines
            while (self.cleanup_queue.pop()) |task| {
                _ = self.tasks.remove(task.id);
                // Runtime releases its reference when removing from hashmap
                self.releaseTask(task);
                // If ref_count > 0, Task(T) handles still exist, keep the task alive
            }

            // Process all ready coroutines (once)
            while (self.ready_queue.pop()) |task| {
                task.coro.state = .running;
                task.coro.switchTo(&self.main_context);

                // If the coroutines just yielded, it will end up in running state, so mark it as ready
                if (task.coro.state == .running) {
                    task.coro.state = .ready;
                }

                switch (task.coro.state) {
                    .ready => reschedule.append(task),
                    .dead => {
                        while (task.waiting_list.pop()) |waiting_task| {
                            self.markReady(&waiting_task.coro);
                        }
                        self.cleanup_queue.append(task);
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

            // Wait for I/O events to make coroutines ready again
            try self.loop.run(.once);
        }
    }

    pub inline fn taskPtrFromCoroPtr(coro: *Coroutine) *AnyTask {
        const task: *AnyTask = @fieldParentPtr("coro", coro);
        return task;
    }

    pub fn markReady(self: *Runtime, coro: *Coroutine) void {
        if (coro.state != .waiting) std.debug.panic("coroutine is not waiting", .{});
        coro.state = .ready;
        const task = taskPtrFromCoroPtr(coro);
        self.ready_queue.append(task);
    }

    pub fn wait(self: *Runtime, task_id: u64) void {
        const task = self.tasks.get(task_id) orelse return;
        if (task.coro.state == .dead) {
            return;
        }
        const current_coro = coroutines.getCurrent() orelse std.debug.panic("not in coroutine", .{});
        const current_task = taskPtrFromCoroPtr(current_coro);
        if (current_task == task) {
            std.debug.panic("a task cannot wait on itself", .{});
        }
        task.waiting_list.append(current_task);
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
