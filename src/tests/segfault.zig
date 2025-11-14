const std = @import("std");
const coro = @import("coro");

fn causeSegfault() void {
    // Use a low invalid address (not 0 to bypass Zig's null pointer check)
    // Use volatile to prevent compiler optimization
    var invalid_addr: usize = 10;
    _ = @as(*volatile usize, @ptrCast(&invalid_addr));
    const ptr: *u32 = @ptrFromInt(invalid_addr);

    std.debug.print("About to access invalid address at 0x{x}...\n", .{invalid_addr});

    // This will cause a segmentation fault
    _ = ptr.*;

    // Should never reach here
    std.debug.print("ERROR: Survived invalid pointer dereference!\n", .{});
}

fn runCoroutine(c: *coro.Coroutine) void {
    _ = c;
    std.debug.print("Inside coroutine, causing segfault...\n", .{});
    causeSegfault();
    std.debug.print("ERROR: Coroutine completed!\n", .{});
}

pub fn main() !void {
    std.debug.print("Segmentation Fault Test\n", .{});
    std.debug.print("========================\n\n", .{});

    // Setup automatic stack growth handler (it should chain to default handler)
    try coro.setupStackGrowth();
    defer coro.cleanupStackGrowth();

    var parent_context: coro.Context = undefined;
    var coroutine: coro.Coroutine = .{
        .parent_context_ptr = &parent_context,
        .context = undefined,
    };

    try coro.stackAlloc(&coroutine.context.stack_info, 64 * 1024, 4096);
    defer coro.stackFree(coroutine.context.stack_info);

    const Closure = coro.Closure(runCoroutine);
    var closure = Closure.init(.{});
    coroutine.setup(&Closure.start, &closure);

    std.debug.print("Running coroutine that will segfault...\n\n", .{});

    while (!coroutine.finished) {
        coroutine.step();
    }

    // Should never reach here
    std.debug.print("ERROR: Test completed without segfault!\n", .{});
    return error.SegfaultNotTriggered;
}
