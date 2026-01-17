// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

const std = @import("std");
const zio = @import("zio");

/// Demonstration of graceful shutdown using signal handling.
/// Press Ctrl+C to trigger a graceful shutdown.
fn serverTask(rt: *zio.Runtime, shutdown: *std.atomic.Value(bool)) !void {
    std.log.info("Server started. Press Ctrl+C to stop.", .{});

    var counter: u64 = 0;
    while (true) {
        // Check if shutdown was requested
        if (shutdown.load(.acquire)) {
            std.log.info("Server shutting down gracefully...", .{});
            break;
        }

        // Simulate some work
        counter += 1;
        if (counter % 10 == 0) {
            std.log.info("Server is running... processed {d} items", .{counter});
        }

        try rt.sleep(.fromMilliseconds(100)); // Sleep for 100ms
    }

    std.log.info("Server stopped. Total items processed: {d}", .{counter});
}

fn signalHandler(rt: *zio.Runtime, shutdown: *std.atomic.Value(bool)) !void {
    // Create signal handler for SIGINT (Ctrl+C)
    var sig = try zio.Signal.init(.interrupt);
    defer sig.deinit();

    // Wait for SIGINT (Ctrl+C)
    try sig.wait(rt);

    std.log.info("Received signal, initiating shutdown...", .{});
    shutdown.store(true, .release);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var rt = try zio.Runtime.init(gpa.allocator(), .{});
    defer rt.deinit();

    // Create shutdown flag
    var shutdown = std.atomic.Value(bool).init(false);

    std.log.info("Starting demo (press Ctrl+C to stop gracefully)...", .{});

    // Spawn server task
    var server_task = try rt.spawn(serverTask, .{ rt, &shutdown });
    defer server_task.cancel(rt);

    // Spawn signal handler task
    var signal_task = try rt.spawn(signalHandler, .{ rt, &shutdown });
    defer signal_task.cancel(rt);

    // Run until all tasks complete
    try rt.run();

    std.log.info("Demo completed.", .{});
}
