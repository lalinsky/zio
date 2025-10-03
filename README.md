# ZIO - Zig I/O Library

A lightweight async I/O library for Zig, built on top of stackful coroutines and libxev.

## Quick Start

```zig
const std = @import("std");
const zio = @import("zio");

fn echoClient(rt: *zio.Runtime, allocator: std.mem.Allocator) !void {
    // Connect to echo server using hostname
    var stream = try zio.net.tcpConnectToHost(rt, allocator, "localhost", 8080);
    defer stream.close();

    // Use buffered reader/writer
    var read_buffer: [1024]u8 = undefined;
    var write_buffer: [1024]u8 = undefined;
    var reader = stream.reader(&read_buffer);
    var writer = stream.writer(&write_buffer);

    // Send a line
    try writer.interface.writeAll("Hello, World!\n");
    try writer.interface.flush();

    // Read response line
    const response = try reader.interface.takeDelimiterExclusive('\n');
    std.debug.print("Echo: {s}\n", .{response});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    // Initialize runtime with thread pool for DNS resolution
    var runtime = try zio.Runtime.init(gpa.allocator(), .{
        .thread_pool = .{ .enabled = true },
    });
    defer runtime.deinit();

    // Spawn coroutine
    var task = try runtime.spawn(echoClient, .{ &runtime, gpa.allocator() }, .{});
    defer task.deinit();

    // Run the event loop
    try runtime.run();
    try task.result();
}
```

## Building

```bash
# Build the library and examples
zig build

# Run tests
zig build test
```
