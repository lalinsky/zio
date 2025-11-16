const std = @import("std");
const coro = @import("coro");

/// Recursive function that consumes stack space
fn deepRecursion(c: *coro.Coroutine, depth: u32, max_depth: u32) void {
    // Allocate a large buffer on the stack to consume space quickly
    var buffer: [1024]u8 = undefined;
    @memset(&buffer, @intCast(depth & 0xFF));

    if (depth >= max_depth) {
        // Force use of buffer to prevent optimization
        std.debug.print("Reached depth {}, buffer[0] = {}\n", .{ depth, buffer[0] });
        return;
    }

    // Keep recursing - this will eventually overflow
    deepRecursion(c, depth + 1, max_depth);
}

fn runCoroutine(c: *coro.Coroutine, max_depth: u32) void {
    std.debug.print("Starting deep recursion (target depth: {})...\n", .{max_depth});
    deepRecursion(c, 0, max_depth);
    std.debug.print("Completed successfully!\n", .{});
}

pub fn main() !void {
    std.debug.print("Stack Overflow Test\n", .{});
    std.debug.print("===================\n\n", .{});

    // Setup automatic stack growth handler
    try coro.setupStackGrowth();
    defer coro.cleanupStackGrowth();

    var parent_context: coro.Context = undefined;
    var coroutine: coro.Coroutine = .{
        .parent_context_ptr = &parent_context,
        .context = undefined,
    };

    // Allocate a small stack (16KB max, 4KB initial) to trigger overflow quickly
    const maximum_size = 16 * 1024; // 16KB total
    const initial_commit = 4 * 1024; // 4KB initially committed
    try coro.stackAlloc(&coroutine.context.stack_info, maximum_size, initial_commit);
    defer coro.stackFree(coroutine.context.stack_info);

    std.debug.print("Stack configuration:\n", .{});
    std.debug.print("  Maximum size: {} KB\n", .{maximum_size / 1024});
    std.debug.print("  Initial commit: {} KB\n", .{initial_commit / 1024});
    std.debug.print("  Stack will grow automatically up to maximum\n\n", .{});

    // Set up the coroutine - targeting 1000 recursion depth
    // With 1KB per frame, this needs ~1MB of stack, which will overflow our 16KB limit
    const Closure = coro.Closure(runCoroutine);
    var closure = Closure.init(.{1000});
    coroutine.setup(&Closure.start, &closure);

    std.debug.print("Running coroutine...\n\n", .{});

    // Run the coroutine - this should trigger a stack overflow
    while (!coroutine.finished) {
        coroutine.step();
    }

    // We should never reach here due to stack overflow
    std.debug.print("ERROR: Coroutine completed without stack overflow!\n", .{});
    return error.StackOverflowNotTriggered;
}
