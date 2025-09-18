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
fn markReady(comptime T: type, comptime HandleType: type, comptime field_name: []const u8) fn([*c]HandleType) callconv(.c) void {
    const FieldType = @TypeOf(@field(@as(T, undefined), field_name));
    return struct {
        fn callback(handle: [*c]HandleType) callconv(.c) void {
            const typed_handle: *FieldType = @ptrCast(@alignCast(handle));
            const data: *T = @ptrCast(@as(*allowzero T, @fieldParentPtr(field_name, typed_handle)));
            data.coroutine.state = .ready;
        }
    }.callback;
}

// Runtime class - the main zio runtime
pub const Runtime = struct {
    loop: *c.uv_loop_t,
    coroutines: [MAX_COROUTINES]Coroutine,
    count: u32,
    main_context: *anyopaque,
    allocator: Allocator,

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
        for (0..self.count) |i| {
            self.allocator.free(self.coroutines[i].stack);
        }
        _ = c.uv_loop_close(self.loop);
        self.allocator.destroy(self.loop);
    }

    pub fn spawn(self: *Runtime, comptime func: anytype, args: anytype) !u32 {
        if (self.count >= MAX_COROUTINES) {
            return error.TooManyCoroutines;
        }

        const id = self.count;
        const stack = try self.allocator.alignedAlloc(u8, coroutines.stack_alignment, STACK_SIZE);

        self.coroutines[id] = try Coroutine.init(id, stack, func, args);
        self.count += 1;

        return id;
    }

    pub fn yield(self: *Runtime) void {
        _ = self; // Runtime parameter not needed, but kept for API consistency
        // Don't change state - let the coroutine decide its own state before yielding
        coroutines.yield();
    }


    pub fn sleep(self: *Runtime, milliseconds: u64) !void {
        const current = coroutines.getCurrentCoroutine() orelse return ZioError.NotInCoroutine;

        // Stack allocate timer data
        var timer_data = TimerData{
            .timer = undefined, // Will be initialized by uv_timer_init
            .coroutine = current,
            .runtime = self,
        };

        // Both callbacks use the same generic pattern with explicit types
        const timer_cb = markReady(TimerData, c.uv_timer_t, "timer");
        const close_cb = markReady(TimerData, c.uv_handle_t, "timer");

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
            var all_dead = false;

            // Run all ready coroutines until none are ready
            while (true) {
                var found_ready = false;
                all_dead = true;

                // Find next ready coroutine and check if all are dead in single pass
                for (0..self.count) |i| {
                    const state = self.coroutines[i].state;

                    if (state != .dead) {
                        all_dead = false;
                    }

                    if (state == .ready and !found_ready) {
                        self.coroutines[i].state = .running;
                        self.coroutines[i].switchTo(&self.main_context);
                        found_ready = true;
                    }
                }

                if (all_dead or !found_ready) break;
            }

            if (all_dead) break;

            // Wait for I/O events to make coroutines ready again
            _ = c.uv_run(self.loop, c.UV_RUN_ONCE);
        }

        // Process any remaining close callbacks to clean up memory
        while (c.uv_loop_alive(self.loop) != 0) {
            _ = c.uv_run(self.loop, c.UV_RUN_ONCE);
        }
    }

    pub fn getResult(self: *Runtime, id: u32) ?coroutines.CoroutineResult {
        if (id >= self.count) return null;
        return self.coroutines[id].result;
    }

    pub fn getAllResults(self: *Runtime) []coroutines.CoroutineResult {
        var results: [MAX_COROUTINES]coroutines.CoroutineResult = undefined;
        for (0..self.count) |i| {
            results[i] = self.coroutines[i].result;
        }
        return results[0..self.count];
    }
};



