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
    waiting_list: AnyTaskList = AnyTaskList{},
    ref_count: RefCounter(u32) = RefCounter(u32).init(),
    in_list: if (builtin.mode == .Debug) bool else void = if (builtin.mode == .Debug) false else {},
};

// Typed task wrapper that provides type-safe wait() method
pub fn Task(comptime T: type) type {
    return struct {
        const Self = @This();

        task: *AnyTask,
        runtime: *Runtime,
        detached: bool = false,

        pub fn init(task: *AnyTask, runtime: *Runtime) Self {
            // Increment reference count when creating a Task(T) handle
            task.ref_count.incr();
            return Self{
                .task = task,
                .runtime = runtime,
            };
        }

        pub fn deinit(self: *Self) void {
            self.detach();
        }

        pub fn detach(self: *Self) void {
            if (self.detached) return;
            // Decrement reference count for this Task(T) handle
            if (self.task.ref_count.decr()) {
                // Reference count reached zero, destroy the task
                self.task.coro.deinit(self.runtime.allocator);
                self.runtime.allocator.destroy(self.task);
            }
            self.detached = true;
        }

        pub fn join(self: Self) T {
            // Use the task directly to check if already completed
            if (self.task.coro.result != .pending) {
                return self.task.coro.getResult(T).get();
            }

            // Use runtime's wait method for the waiting logic
            self.runtime.wait(self.task.id);

            const coro_result = self.task.coro.getResult(T);
            return coro_result.get();
        }

        pub fn result(self: Self) T {
            const coro_result = self.task.coro.result;
            switch (coro_result) {
                .pending => std.debug.panic("Task has not completed yet", .{}),
                .success => {
                    const typed_result = self.task.coro.getResult(T);
                    return typed_result.get();
                },
                .failure => |err| {
                    const type_info = @typeInfo(T);
                    if (type_info == .error_union) {
                        return @as(T, @errorCast(err));
                    } else {
                        std.debug.panic("Task failed with error: {}", .{err});
                    }
                },
            }
        }
    };
}

fn ReturnType(comptime func: anytype) type {
    return switch (@typeInfo(@TypeOf(func))) {
        .@"fn" => |info| if (info.return_type) |ret| ret else void,
        else => @compileError("ReturnType only supports function types"),
    };
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
    count: u32 = 0,
    main_context: coroutines.Context,
    allocator: Allocator,

    tasks: std.AutoHashMapUnmanaged(u64, *AnyTask) = .{},

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
            task.coro.deinit(self.allocator);
            self.allocator.destroy(task);
        }
        self.tasks.deinit(self.allocator);

        self.loop.deinit();
    }

    pub fn spawn(self: *Runtime, comptime func: anytype, args: anytype, options: CoroutineOptions) !Task(ReturnType(func)) {
        const id = self.count;
        self.count += 1;

        const entry = try self.tasks.getOrPut(self.allocator, id);
        if (entry.found_existing) {
            std.debug.panic("Task ID {} already exists", .{id});
        }
        errdefer self.tasks.removeByPtr(entry.key_ptr);

        var task = try self.allocator.create(AnyTask);
        errdefer self.allocator.destroy(task);

        task.* = .{
            .id = id,
            .coro = undefined,
        };

        task.coro = try Coroutine.init(self.allocator, func, args, options);
        errdefer task.coro.deinit(self.allocator);

        entry.value_ptr.* = task;

        self.ready_queue.push(task);

        task.ref_count.incr();
        return .{ .task = task, .runtime = self };
    }

    pub fn yield(self: *Runtime) void {
        _ = self;
        coroutines.yield();
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
                if (task.ref_count.decr()) {
                    // No more references, safe to deallocate
                    task.coro.deinit(self.allocator);
                    self.allocator.destroy(task);
                }
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
                    .ready => reschedule.push(task),
                    .dead => {
                        while (task.waiting_list.pop()) |waiting_task| {
                            self.markReady(&waiting_task.coro);
                        }
                        self.cleanup_queue.push(task);
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

    pub fn getResult(self: *Runtime, comptime T: type, id: u64) ?coroutines.CoroutineResult(T) {
        const task = self.tasks.get(id) orelse return null;
        return task.coro.getResult(T);
    }

    pub inline fn taskPtrFromCoroPtr(coro: *Coroutine) *AnyTask {
        const task: *AnyTask = @fieldParentPtr("coro", coro);
        return task;
    }

    pub fn markReady(self: *Runtime, coro: *Coroutine) void {
        if (coro.state != .waiting) std.debug.panic("coroutine is not waiting", .{});
        coro.state = .ready;
        const task = taskPtrFromCoroPtr(coro);
        self.ready_queue.push(task);
    }

    pub fn wait(self: *Runtime, task_id: u64) void {
        const task = self.tasks.get(task_id) orelse return;
        if (task.coro.result != .pending) {
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
