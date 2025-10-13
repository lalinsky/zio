const std = @import("std");
const zio = @import("zio");

var should_exit = std.atomic.Value(bool).init(false);
var signal_count = std.atomic.Value(u32).init(0);

fn handleShutdown(args: struct { should_exit_ptr: *std.atomic.Value(bool), signal_count_ptr: *std.atomic.Value(u32) }) void {
    const count = args.signal_count_ptr.fetchAdd(1, .monotonic) + 1;
    std.debug.print("Received shutdown signal #{}\n", .{count});

    if (count >= 2) {
        std.debug.print("Received multiple signals, exiting...\n", .{});
        args.should_exit_ptr.store(true, .release);
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

    // Install signal handlers using Runtime.addSignalHandler
    try runtime.addSignalHandler(.int, handleShutdown, .{ .should_exit_ptr = &should_exit, .signal_count_ptr = &signal_count });
    try runtime.addSignalHandler(.term, handleShutdown, .{ .should_exit_ptr = &should_exit, .signal_count_ptr = &signal_count });

    // Run main loop
    try runtime.runUntilComplete(mainLoop, .{&runtime}, .{});
}
