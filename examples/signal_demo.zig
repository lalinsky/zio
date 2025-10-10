const std = @import("std");
const zio = @import("zio");

var should_exit = std.atomic.Value(bool).init(false);
var signal_count = std.atomic.Value(u32).init(0);

fn handleShutdown() void {
    const count = signal_count.fetchAdd(1, .monotonic) + 1;
    std.debug.print("Received shutdown signal #{}\n", .{count});

    if (count >= 2) {
        std.debug.print("Received multiple signals, exiting...\n", .{});
        should_exit.store(true, .release);
    } else {
        std.debug.print("Press Ctrl+C again to exit\n", .{});
    }
}

fn mainLoop(rt: *zio.Runtime) !void {
    std.debug.print("Signal handler demo running...\n", .{});
    std.debug.print("Press Ctrl+C to trigger SIGINT handler\n", .{});

    var i: u32 = 0;
    while (!should_exit.load(.acquire)) {
        rt.sleep(1000);
        i += 1;
        if (i % 5 == 0) {
            std.debug.print("Still running... ({}s)\n", .{i});
        }
    }

    std.debug.print("Exiting cleanly\n", .{});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var runtime = try zio.Runtime.init(gpa.allocator(), .{});
    defer runtime.deinit();

    // Install signal handlers
    const handler = try zio.signal.SignalHandler.init(&runtime, gpa.allocator());
    defer handler.deinit();

    try handler.installHandler(.int, handleShutdown);
    try handler.installHandler(.term, handleShutdown);

    // Spawn the handler coroutine
    var handler_task = try runtime.spawn(zio.signal.SignalHandler.run, .{handler}, .{});
    defer handler_task.deinit();

    // Run main loop
    try runtime.runUntilComplete(mainLoop, .{&runtime}, .{});
}
