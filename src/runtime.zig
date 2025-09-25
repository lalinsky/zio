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
const Error = coroutines.Error;
const RefCounter = @import("ref_counter.zig").RefCounter;

const MAX_COROUTINES = 32;
const STACK_SIZE = 8192;

// Waker interface for asynchronous operations
pub const Waker = struct {
    runtime: *Runtime,
    coroutine: *Coroutine,

    pub fn wake(self: Waker) void {
        self.runtime.markReady(self.coroutine);
    }
};

// Runtime-specific errors
pub const ZioError = error{
    XevError,
    NotInCoroutine,
} || Error;

// Timer callback for libxev
fn timerCallback(
    userdata: ?*Waker,
    loop: *xev.Loop,
    completion: *xev.Completion,
    result: xev.Timer.RunError!void,
) xev.CallbackAction {
    _ = loop;
    _ = completion;
    _ = result catch {
        // Timer error - still wake up the coroutine
    };

    if (userdata) |waker| {
        waker.wake();
    }
    return .disarm;
}

// Task for runtime scheduling
pub const AnyTask = struct {
    id: u64,
    coro: Coroutine,
    waiting_list: AnyTaskList = .{},
    ref_count: RefCounter(u32) = RefCounter(u32).init(),
};

// Typed task wrapper that provides type-safe wait() method
pub fn Task(comptime T: type) type {
    return struct {
        const Self = @This();

        task: *AnyTaskList.Node,
        runtime: *Runtime,

        pub fn init(task: *AnyTaskList.Node, runtime: *Runtime) Self {
            // Increment reference count when creating a Task(T) handle
            task.data.ref_count.incr();
            return Self{
                .task = task,
                .runtime = runtime,
            };
        }

        pub fn deinit(self: Self) void {
            // Decrement reference count for this Task(T) handle
            if (self.task.data.ref_count.decr()) {
                // Reference count reached zero, destroy the task
                self.task.data.coro.deinit(self.runtime.allocator);
                self.runtime.allocator.destroy(self.task);
            }
        }

        pub fn wait(self: Self) T {
            // Use the task directly to check if already completed
            if (self.task.data.coro.result != .pending) {
                const result = self.task.data.coro.getResult(T);
                return result.get();
            }

            // Use runtime's wait method for the waiting logic
            self.runtime.wait(self.task.data.id);

            const result = self.task.data.coro.getResult(T);
            return result.get();
        }
    };
}

// Linked list of tasks
pub const AnyTaskList = std.DoublyLinkedList(AnyTask);

// Runtime class - the main zio runtime
pub const Runtime = struct {
    loop: xev.Loop,
    count: u32 = 0,
    main_context: coroutines.Context,
    allocator: Allocator,

    tasks: std.AutoHashMapUnmanaged(u64, *AnyTaskList.Node) = .{},

    ready_queue: AnyTaskList = .{},
    cleanup_queue: AnyTaskList = .{},

    pub fn init(allocator: Allocator) !Runtime {
        // Initialize libxev loop
        const loop = try xev.Loop.init(.{});

        return Runtime{
            .allocator = allocator,
            .loop = loop,
            .main_context = undefined,
        };
    }

    pub fn deinit(self: *Runtime) void {
        var iter = self.tasks.iterator();
        while (iter.next()) |entry| {
            const task = entry.value_ptr.*;
            task.data.coro.deinit(self.allocator);
            self.allocator.destroy(task);
        }
        self.tasks.deinit(self.allocator);

        self.loop.deinit();
    }

    pub fn spawn(self: *Runtime, comptime func: anytype, args: anytype, options: CoroutineOptions) !Task(@TypeOf(@call(.auto, func, args))) {
        const T = @TypeOf(@call(.auto, func, args));

        if (self.count >= MAX_COROUTINES) {
            return error.TooManyCoroutines;
        }

        const id = self.count;
        self.count += 1;

        const entry = try self.tasks.getOrPut(self.allocator, id);
        if (entry.found_existing) {
            std.debug.panic("Task ID {} already exists", .{id});
        }
        errdefer self.tasks.removeByPtr(entry.key_ptr);

        var task = try self.allocator.create(AnyTaskList.Node);
        errdefer self.allocator.destroy(task);

        task.data = .{
            .id = id,
            .coro = undefined,
        };

        task.data.coro = try Coroutine.init(self.allocator, func, args, options);
        errdefer task.data.coro.deinit(self.allocator);

        entry.value_ptr.* = task;

        self.ready_queue.append(task);

        return Task(T).init(task, self);
    }

    pub fn yield(self: *Runtime) void {
        _ = self;
        coroutines.yield();
    }

    pub fn getWaker(self: *Runtime) Waker {
        const current = coroutines.getCurrent() orelse std.debug.panic("getWaker() must be called from within a coroutine", .{});
        return Waker{
            .runtime = self,
            .coroutine = current,
        };
    }

    pub fn sleep(self: *Runtime, milliseconds: u64) !void {
        const current = coroutines.getCurrent() orelse return ZioError.NotInCoroutine;

        // Stack allocate - safe because coroutine stack is stable
        var timer = xev.Timer.init() catch unreachable; // Can't fail in non-dynamic mode
        defer timer.deinit();
        var completion: xev.Completion = .{};
        var waker = self.getWaker();

        // Start the timer
        timer.run(
            &self.loop,
            &completion,
            milliseconds,
            Waker,
            &waker,
            timerCallback,
        );

        // Wait for timer to fire
        current.waitForReady();
    }

    pub fn run(self: *Runtime) !void {
        while (true) {
            var reschedule: AnyTaskList = .{};

            // Cleanup dead coroutines
            while (self.cleanup_queue.pop()) |task| {
                _ = self.tasks.remove(task.data.id);
                // Runtime releases its reference when removing from hashmap
                if (task.data.ref_count.decr()) {
                    // No more references, safe to deallocate
                    task.data.coro.deinit(self.allocator);
                    self.allocator.destroy(task);
                }
                // If ref_count > 0, Task(T) handles still exist, keep the task alive
            }

            // Process all ready coroutines (once)
            while (self.ready_queue.pop()) |task| {
                task.data.coro.state = .running;
                task.data.coro.switchTo(&self.main_context);

                // If the coroutines just yielded, it will end up in running state, so mark it as ready
                if (task.data.coro.state == .running) {
                    task.data.coro.state = .ready;
                }

                switch (task.data.coro.state) {
                    .ready => reschedule.append(task),
                    .dead => {
                        while (task.data.waiting_list.pop()) |waiting_task| {
                            self.markReady(&waiting_task.data.coro);
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
                break;
            }

            // Wait for I/O events to make coroutines ready again
            try self.loop.run(.once);
        }

        // Process any remaining events to clean up
        try self.loop.run(.no_wait);
    }

    pub fn getResult(self: *Runtime, comptime T: type, id: u64) ?coroutines.CoroutineResult(T) {
        const task = self.tasks.get(id) orelse return null;
        return task.data.coro.getResult(T);
    }

    inline fn taskPtrFromCoroPtr(coro: *Coroutine) *AnyTaskList.Node {
        const task: *AnyTask = @fieldParentPtr("coro", coro);
        const node: *AnyTaskList.Node = @fieldParentPtr("data", task);
        return node;
    }

    pub fn markReady(self: *Runtime, coro: *Coroutine) void {
        if (coro.state != .waiting) std.debug.panic("coroutine is not waiting", .{});
        coro.state = .ready;
        const task = taskPtrFromCoroPtr(coro);
        self.ready_queue.append(task);
    }

    pub fn wait(self: *Runtime, task_id: u64) void {
        const task = self.tasks.get(task_id) orelse return;
        if (task.data.coro.result != .pending) {
            return;
        }
        const current_coro = coroutines.getCurrent() orelse std.debug.panic("not in coroutine", .{});
        task.data.waiting_list.append(taskPtrFromCoroPtr(current_coro));
        current_coro.waitForReady();
    }
};
