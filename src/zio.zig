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
    coroutine: *Coroutine,
    completed: bool = false,
    runtime: *Runtime,
    timer: *c.uv_timer_t,
};

// Runtime class - the main zio runtime
pub const Runtime = struct {
    loop: *c.uv_loop_t,
    coroutines: [MAX_COROUTINES]Coroutine,
    current: i32,
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
            .current = -1,
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
        if (self.current == -1) return;
        // Don't change state - let the coroutine decide its own state before yielding
        coroutines.yield();
    }

    fn runOnce(self: *Runtime) bool {
        // Find next ready coroutine
        var next: i32 = -1;
        for (0..self.count) |i| {
            if (self.coroutines[i].state == .ready) {
                next = @intCast(i);
                break;
            }
        }

        if (next == -1) return false; // No ready coroutines

        self.current = next;
        self.coroutines[@intCast(next)].state = .running;
        self.coroutines[@intCast(next)].switchTo(&self.main_context);

        return true;
    }

    pub fn sleep(self: *Runtime, milliseconds: u64) !void {
        const current = coroutines.getCurrentCoroutine() orelse return ZioError.NotInCoroutine;

        // Create timer handle
        const timer = try self.allocator.create(c.uv_timer_t);
        errdefer self.allocator.destroy(timer);

        const result = c.uv_timer_init(self.loop, timer);
        if (result != 0) {
            self.allocator.destroy(timer);
            return ZioError.LibuvError;
        }

        // Set up timer data (allocated on heap to survive past this function)
        const timer_data = try self.allocator.create(TimerData);
        timer_data.* = TimerData{
            .coroutine = current,
            .completed = false,
            .runtime = self,
            .timer = timer,
        };
        timer.*.data = timer_data;

        // Start the timer
        const start_result = c.uv_timer_start(timer, sleep_timer_cb, milliseconds, 0);
        if (start_result != 0) {
            self.allocator.destroy(timer_data);
            self.allocator.destroy(timer);
            return ZioError.LibuvError;
        }

        // Mark this coroutine as waiting and yield control
        current.state = .waiting;
        self.yield();

        // When we get here, the timer has fired and the coroutine is ready again
    }

    pub fn run(self: *Runtime) void {
        self.current = -1;

        while (true) {
            // Run all ready coroutines until none are ready
            while (self.runOnce()) {}

            // Check if all coroutines are dead
            var all_dead = true;
            for (0..self.count) |i| {
                if (self.coroutines[i].state != .dead) {
                    all_dead = false;
                    break;
                }
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


// Close callback for timer cleanup
fn timer_close_cb(handle: [*c]c.uv_handle_t) callconv(.c) void {
    const timer: *c.uv_timer_t = @ptrCast(@alignCast(handle));
    const data: *TimerData = @ptrCast(@alignCast(timer.*.data));
    data.runtime.allocator.destroy(data.timer);
    data.runtime.allocator.destroy(data);
}

// Timer callback for sleep
fn sleep_timer_cb(handle: [*c]c.uv_timer_t) callconv(.c) void {
    const data: *TimerData = @ptrCast(@alignCast(handle.*.data));
    data.completed = true;
    data.coroutine.state = .ready;

    // Close the timer handle properly
    c.uv_close(@ptrCast(handle), timer_close_cb);
}

