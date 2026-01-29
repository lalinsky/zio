const std = @import("std");
const microzig = @import("microzig");
const zio = @import("zio");

const rp2xxx = microzig.hal;
const cyw43 = rp2xxx.cyw43;
const time = rp2xxx.time;

const Coroutine = zio.coro.Coroutine;

// Two stacks for coroutines
var stack_coro1: [4096]u8 align(16) = undefined;
var stack_coro2: [4096]u8 align(16) = undefined;

// Two coroutines
var coro1: Coroutine = undefined;
var coro2: Coroutine = undefined;

// Parent context for main
var main_context: zio.coro.Context = undefined;

// Coroutine 1: Fast blink 5 times, then yield
fn coroutine1Fn(coro: *Coroutine, userdata: ?*anyopaque) void {
    _ = userdata;

    while (true) {
        var i: u32 = 0;
        while (i < 5) : (i += 1) {
            cyw43.gpio.put(.led, true);
            time.sleep_ms(100);
            cyw43.gpio.put(.led, false);
            time.sleep_ms(100);
        }

        // Yield back to main
        coro.yield();
    }
}

// Coroutine 2: Slow blink 2 times, then yield
fn coroutine2Fn(coro: *Coroutine, userdata: ?*anyopaque) void {
    _ = userdata;

    while (true) {
        var i: u32 = 0;
        while (i < 2) : (i += 1) {
            cyw43.gpio.put(.led, true);
            time.sleep_ms(500);
            cyw43.gpio.put(.led, false);
            time.sleep_ms(500);
        }

        // Yield back to main
        coro.yield();
    }
}

pub fn main() !void {
    // Initialize CYW43 LED
    try cyw43.init();

    // Setup coroutine 1
    coro1.parent_context_ptr = &main_context;
    coro1.context.stack_info = .{
        .allocation_ptr = &stack_coro1,
        .base = @intFromPtr(&stack_coro1) + stack_coro1.len,
        .limit = @intFromPtr(&stack_coro1),
        .allocation_len = stack_coro1.len,
    };
    coro1.setup(coroutine1Fn, null);

    // Setup coroutine 2
    coro2.parent_context_ptr = &main_context;
    coro2.context.stack_info = .{
        .allocation_ptr = &stack_coro2,
        .base = @intFromPtr(&stack_coro2) + stack_coro2.len,
        .limit = @intFromPtr(&stack_coro2),
        .allocation_len = stack_coro2.len,
    };
    coro2.setup(coroutine2Fn, null);

    // Simple round-robin scheduler
    while (true) {
        // Run coroutine 1 (fast blinks)
        coro1.step();

        // Run coroutine 2 (slow blinks)
        coro2.step();
    }
}
