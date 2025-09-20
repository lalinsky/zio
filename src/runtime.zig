const std = @import("std");
const print = std.debug.print;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const assert = std.debug.assert;
const c = @cImport({
    @cInclude("uv.h");
});

const coroutines = @import("coroutines.zig");
const Coroutine = coroutines.Coroutine;
const CoroutineState = coroutines.CoroutineState;
const CoroutineOptions = coroutines.CoroutineOptions;
const Error = coroutines.Error;

const MAX_COROUTINES = 32;
const STACK_SIZE = 8192;

// Runtime-specific errors
pub const ZioError = error{
    LibuvError,
    NotInCoroutine,
} || Error;

// Timer callback data
const TimerData = struct {
    timer: c.uv_timer_t,
    coroutine: *Coroutine,
    runtime: *Runtime,
};

// Generic callback generator for any handle type
fn markReadyOnCallback(comptime T: type, comptime HandleType: type, comptime field_name: []const u8) fn ([*c]HandleType) callconv(.c) void {
    const FieldType = @TypeOf(@field(@as(T, undefined), field_name));
    return struct {
        fn callback(handle: [*c]HandleType) callconv(.c) void {
            const typed_handle: *FieldType = @ptrCast(@alignCast(handle));
            const data: *T = @ptrCast(@as(*allowzero T, @fieldParentPtr(field_name, typed_handle)));
            data.runtime.markReady(data.coroutine);
        }
    }.callback;
}

// Task for runtime scheduling
pub const AnyTask = struct {
    id: u64,
    coro: Coroutine,
    waiting_list: AnyTaskList = .{},
};

// Linked list of tasks
pub const AnyTaskList = std.DoublyLinkedList(AnyTask);

// Runtime class - the main zio runtime
pub const Runtime = struct {
    loop: *c.uv_loop_t,
    count: u32 = 0,
    main_context: coroutines.Context,
    allocator: Allocator,

    tasks: std.AutoHashMapUnmanaged(u64, *AnyTaskList.Node) = .{},

    ready_queue: AnyTaskList = .{},
    cleanup_queue: AnyTaskList = .{},

    pub fn init(allocator: Allocator) !Runtime {
        // Initialize libuv loop
        const loop = try allocator.create(c.uv_loop_t);
        errdefer allocator.destroy(loop);

        const result = c.uv_loop_init(loop);
        if (result != 0) {
            allocator.destroy(loop);
            return ZioError.LibuvError;
        }

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

        _ = c.uv_loop_close(self.loop);
        self.allocator.destroy(self.loop);
    }

    pub fn spawn(self: *Runtime, comptime func: anytype, args: anytype, options: CoroutineOptions) !u64 {
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

        return task.data.id;
    }

    pub fn yield(self: *Runtime) void {
        _ = self;
        coroutines.yield();
    }

    pub fn sleep(self: *Runtime, milliseconds: u64) !void {
        const current = coroutines.getCurrent() orelse return ZioError.NotInCoroutine;

        // Stack allocate timer data
        var timer_data = TimerData{
            .timer = undefined, // Will be initialized by uv_timer_init
            .coroutine = current,
            .runtime = self,
        };

        // Both callbacks use the same generic pattern with explicit types
        const timer_cb = markReadyOnCallback(TimerData, c.uv_timer_t, "timer");
        const close_cb = markReadyOnCallback(TimerData, c.uv_handle_t, "timer");

        const result = c.uv_timer_init(self.loop, &timer_data.timer);
        if (result != 0) {
            return ZioError.LibuvError;
        }

        defer {
            c.uv_close(@ptrCast(&timer_data.timer), close_cb);
            current.waitForReady();
        }

        // Start the timer
        const start_result = c.uv_timer_start(&timer_data.timer, timer_cb, milliseconds, 0);
        if (start_result != 0) {
            return ZioError.LibuvError;
        }

        // Wait for timer to fire
        current.waitForReady();

        // Timer fired, defer will handle cleanup
    }

    pub fn run(self: *Runtime) void {
        while (true) {
            var reschedule: AnyTaskList = .{};

            // Cleanup dead coroutines
            while (self.cleanup_queue.pop()) |task| {
                _ = self.tasks.remove(task.data.id);
                task.data.coro.deinit(self.allocator);
                self.allocator.destroy(task);
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
            _ = c.uv_run(self.loop, c.UV_RUN_ONCE);
        }

        // Process any remaining close callbacks to clean up memory
        while (c.uv_loop_alive(self.loop) != 0) {
            _ = c.uv_run(self.loop, c.UV_RUN_ONCE);
        }
    }

    pub fn getResult(self: *Runtime, id: u64) ?coroutines.CoroutineResult {
        const task = self.tasks.get(id) orelse return null;
        return task.data.coro.result;
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
