# ZIO - Zig I/O Library

An async I/O library for Zig, built on top of stackful coroutines and libxev.

It uses non-blocking I/O in the background, but you can write your application code
in a blocking fashion, without callbacks or state machines. That results in much
more readable code. Additionally, you can use external libraries, if they support
the reader/writer interfaces, they don't even need to be aware they are running
in a coroutine and using non-blocking I/O.

Coroutines still allocate a fairly large stack, so they are not as cheap as
async functions in Rust or earlier versions of Zig (where were stackless state machines),
but they are still much cheaper than threads, you don't need to be afraid of
spawning many of them.

NOTE: This library is very similar to the future `std.Io` interface. Depending on
how the Zig standard library progresses in the future, we will either implement
the interface, or deprecate this library.

## Features

- Supports Linux, Windows and macOS
- Single-threaded event loop (similar to Python's asyncio, but I'm exploring options how to introduce multiple I/O threads)
- Spawn stackful coroutines, and wait for the results
- Spawn blocking tasks in a thread pool, and wait for the results
- File I/O on all platforms, Linux and Windows are truly non-blocking, other platforms are simulated using a thread pool
- Network I/O, supports TCP/UDP sockets, DNS resolution currently via thread pool
- Full `std.Io.Reader` and `std.Io.Writer` support for TCP streams
- Synchronization primitives matching `std.Thread` API (`Mutex`/`Condition`/`Semaphore`/`ResetEvent`)
- `Queue(T)` for producer-consumer patterns across coroutines

## TODO

- Support for async events (for coordinating multiple threads)
- Support for sub-processes
- Support for pipes

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
