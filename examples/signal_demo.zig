const std = @import("std");
const zio = @import("zio");

/// Demonstration of graceful shutdown using signal handling.
/// Press Ctrl+C to trigger a graceful shutdown.
fn serverTask(rt: *zio.Runtime, shutdown: *zio.ResetEvent) !void {
    std.log.info("Server started. Press Ctrl+C to stop.", .{});

    var counter: u64 = 0;
    while (true) {
        // Check if shutdown was requested
        if (shutdown.isSet()) {
            std.log.info("Server shutting down gracefully...", .{});
            break;
        }

        // Simulate some work
        counter += 1;
        if (counter % 10 == 0) {
            std.log.info("Server is running... processed {d} items", .{counter});
        }

        try rt.sleep(100); // Sleep for 100ms
    }

    std.log.info("Server stopped. Total items processed: {d}", .{counter});
}

fn signalHandler(rt: *zio.Runtime, shutdown: *zio.ResetEvent) !void {
    // Create signal handler for SIGINT (Ctrl+C)
    var sig = zio.Signal.init(.int);
    defer sig.deinit();

    // Wait for SIGINT (Ctrl+C)
    try sig.wait(rt);

    std.log.info("Received signal, initiating shutdown...", .{});
    shutdown.set();
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var runtime = try zio.Runtime.init(gpa.allocator(), .{});
    defer runtime.deinit();

    // Create shutdown event
    var shutdown = zio.ResetEvent.init;

    std.log.info("Starting demo (press Ctrl+C to stop gracefully)...", .{});

    // Spawn server task
    var server_task = try runtime.spawn(serverTask, .{ &runtime, &shutdown }, .{});
    defer server_task.deinit();

    // Spawn signal handler task
    var signal_task = try runtime.spawn(signalHandler, .{ &runtime, &shutdown }, .{});
    defer signal_task.deinit();

    // Run until all tasks complete
    try runtime.run();

    std.log.info("Demo completed.", .{});
}
