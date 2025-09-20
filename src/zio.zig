const std = @import("std");
const print = std.debug.print;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const assert = std.debug.assert;
const c = @cImport({
    @cInclude("uv.h");
});

// Re-export coroutine functionality
pub const coroutines = @import("coroutines.zig");
pub const Coroutine = coroutines.Coroutine;
pub const CoroutineState = coroutines.CoroutineState;
pub const Error = coroutines.Error;

const MAX_COROUTINES = 32;
const STACK_SIZE = 8192;

// Zio-specific errors
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

// Runtime class - the main zio runtime
pub const Runtime = struct {
    loop: *c.uv_loop_t,
    count: u32,
    main_context: coroutines.Context,
    allocator: Allocator,

    coroutines: std.AutoHashMapUnmanaged(u64, *CoroNode) = .{},

    ready_queue: CoroList = .{},
    cleanup_queue: CoroList = .{},

    const Coro = Coroutine;
    const CoroList = std.DoublyLinkedList(Coro);
    const CoroNode = CoroList.Node;

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
            .loop = loop,
            .coroutines = undefined,
            .count = 0,
            .main_context = undefined,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Runtime) void {
        var iter = self.coroutines.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.*.data.stack);
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.coroutines.deinit(self.allocator);

        _ = c.uv_loop_close(self.loop);
        self.allocator.destroy(self.loop);
    }

    pub fn spawn(self: *Runtime, comptime func: anytype, args: anytype) !u32 {
        if (self.count >= MAX_COROUTINES) {
            return error.TooManyCoroutines;
        }

        const id = self.count;
        self.count += 1;

        const entry = try self.coroutines.getOrPut(self.allocator, id);
        if (entry.found_existing) {
            std.debug.panic("Coroutine ID {} already exists", .{id});
        }
        errdefer self.coroutines.removeByPtr(entry.key_ptr);

        var coro = try self.allocator.create(CoroNode);
        errdefer self.allocator.destroy(coro);

        const stack = try self.allocator.alignedAlloc(u8, coroutines.stack_alignment, STACK_SIZE);
        errdefer self.allocator.free(stack);

        coro.data = try Coroutine.init(id, stack, func, args);
        entry.value_ptr.* = coro;

        self.ready_queue.append(coro);

        return id;
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

    pub fn markReady(self: *Runtime, coro: *Coroutine) void {
        if (coro.state == .ready) return;
        coro.state = .ready;
        const node: *CoroNode = @fieldParentPtr("data", coro);
        self.ready_queue.append(node);
    }

    pub fn run(self: *Runtime) void {
        while (true) {
            var reschedule: CoroList = .{};

            // Cleanup dead coroutines
            while (self.cleanup_queue.pop()) |coro| {
                _ = self.coroutines.remove(coro.data.id);
                self.allocator.free(coro.data.stack);
                self.allocator.destroy(coro);
            }

            // Process all ready coroutines (once)
            while (self.ready_queue.pop()) |coro| {
                coro.data.state = .running;
                coro.data.switchTo(&self.main_context);

                // If the coroutines just yielded, it will end up in running state, so mark it as ready
                if (coro.data.state == .running) {
                    coro.data.state = .ready;
                }

                switch (coro.data.state) {
                    .ready => reschedule.append(coro),
                    .dead => self.cleanup_queue.append(coro),
                    else => {},
                }
            }

            // Re-add coroutines that we previously ready
            self.ready_queue.concatByMoving(&reschedule);

            // If we have no active coroutines, exit
            if (self.coroutines.size == 0) {
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

    pub fn getResult(self: *Runtime, id: u32) ?coroutines.CoroutineResult {
        const value = self.coroutines.get(id) orelse return null;
        return value.data.result;
    }
};
