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
pub const Scheduler = coroutines.Scheduler;
pub const CoroutineState = coroutines.CoroutineState;
pub const Error = coroutines.Error;

// Zio-specific errors
pub const ZioError = error{
    LibuvError,
    NotInCoroutine,
} || Error;

// Global state
var g_loop: ?*c.uv_loop_t = null;
var g_scheduler: ?*Scheduler = null;
var g_allocator: ?Allocator = null;

// Timer callback data
const TimerData = struct {
    coroutine: *Coroutine,
    completed: bool = false,
    allocator: Allocator,
    timer: *c.uv_timer_t,
};

// Initialize the zio runtime
pub fn init(allocator: Allocator) !void {
    g_allocator = allocator;

    // Initialize libuv loop
    g_loop = try allocator.create(c.uv_loop_t);
    const result = c.uv_loop_init(g_loop.?);
    if (result != 0) {
        allocator.destroy(g_loop.?);
        g_loop = null;
        return ZioError.LibuvError;
    }

    // Initialize scheduler
    g_scheduler = try allocator.create(Scheduler);
    g_scheduler.?.* = Scheduler.init(allocator);
}

// Cleanup the zio runtime
pub fn deinit() void {
    if (g_scheduler) |scheduler| {
        scheduler.deinit();
        g_allocator.?.destroy(scheduler);
        g_scheduler = null;
    }

    if (g_loop) |loop| {
        _ = c.uv_loop_close(loop);
        g_allocator.?.destroy(loop);
        g_loop = null;
    }

    g_allocator = null;
}

// Spawn a coroutine
pub fn spawn(comptime func: anytype, args: anytype) !u32 {
    const scheduler = g_scheduler orelse return ZioError.NotInCoroutine;
    return scheduler.spawn(func, args);
}

// Yield current coroutine
pub fn yield() void {
    const scheduler = g_scheduler orelse return;
    scheduler.yieldCurrent();
}

// Close callback for timer cleanup
fn timer_close_cb(handle: [*c]c.uv_handle_t) callconv(.c) void {
    const timer: *c.uv_timer_t = @ptrCast(@alignCast(handle));
    const data: *TimerData = @ptrCast(@alignCast(timer.*.data));
    data.allocator.destroy(data.timer);
    data.allocator.destroy(data);
}

// Timer callback for sleep
fn sleep_timer_cb(handle: [*c]c.uv_timer_t) callconv(.c) void {
    const data: *TimerData = @ptrCast(@alignCast(handle.*.data));
    data.completed = true;
    data.coroutine.state = .ready;

    // Close the timer handle properly
    c.uv_close(@ptrCast(handle), timer_close_cb);
}

// Async sleep function using libuv timer
pub fn sleep(milliseconds: u64) !void {
    const current = coroutines.getCurrentCoroutine() orelse return ZioError.NotInCoroutine;
    const loop = g_loop orelse return ZioError.LibuvError;
    const allocator = g_allocator orelse return ZioError.LibuvError;

    // Create timer handle
    const timer = try allocator.create(c.uv_timer_t);
    errdefer allocator.destroy(timer);

    const result = c.uv_timer_init(loop, timer);
    if (result != 0) {
        allocator.destroy(timer);
        return ZioError.LibuvError;
    }

    // Set up timer data (allocated on heap to survive past this function)
    const timer_data = try allocator.create(TimerData);
    timer_data.* = TimerData{
        .coroutine = current,
        .completed = false,
        .allocator = allocator,
        .timer = timer,
    };
    timer.*.data = timer_data;

    // Start the timer
    const start_result = c.uv_timer_start(timer, sleep_timer_cb, milliseconds, 0);
    if (start_result != 0) {
        allocator.destroy(timer_data);
        allocator.destroy(timer);
        return ZioError.LibuvError;
    }

    // Mark this coroutine as waiting and yield control
    current.state = .waiting;
    yield();

    // When we get here, the timer has fired and the coroutine is ready again
}

// Main event loop integration
pub fn run() void {
    const scheduler = g_scheduler orelse return;
    const loop = g_loop orelse return;

    while (true) {
        // Run all ready coroutines until none are ready
        while (scheduler.runOnce()) {}

        // Check if all coroutines are dead
        var all_dead = true;
        for (0..scheduler.count) |i| {
            if (scheduler.coroutines[i].state != .dead) {
                all_dead = false;
                break;
            }
        }
        if (all_dead) break;

        // Wait for I/O events to make coroutines ready again
        _ = c.uv_run(loop, c.UV_RUN_ONCE);
    }

    // Process any remaining close callbacks to clean up memory
    while (c.uv_loop_alive(loop) != 0) {
        _ = c.uv_run(loop, c.UV_RUN_ONCE);
    }
}