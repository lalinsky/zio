# ZIO - Async I/O framework for Zig

ZIO is a stackful coroutine-based async I/O framework for Zig that provides Go-style green threads and asynchronous I/O operations.

## Overview

There are two ways of doing asynchronous I/O: callbacks or continuations. Callback-based APIs are easier to implement but harder to use - you need to manage state yourself and handle many more allocations.

ZIO uses **stackful coroutines** (fibers, green threads) to make async code feel natural and idiomatic. State is stored directly on the stack, just like in synchronous code. This approach is similar to Go's goroutines, Rust's Tokio, or Python's asyncio.

The project consists of:

- **Runtime** for executing many stackful coroutines on one or more CPU threads
- **Synchronization primitives** that work with the runtime
- **Async I/O layer** that makes I/O calls look blocking while being fully asynchronous

This allows you to handle thousands of network connections on a single CPU thread. With the multi-threaded runtime, coroutines migrate between threads for reduced latency and load balancing.

## Features

- **Cross-platform**: Linux, Windows, and macOS (BSDs should work but aren't tested)
- **Flexible threading**: Single-threaded or multi-threaded runtime with one I/O event loop per executor thread
- **Efficient coroutines**: One small allocation per spawn, stack memory is reused
- **Thread pool**: Spawn blocking tasks in an auxiliary thread pool
- **Full async I/O**: TCP/UDP sockets, Unix sockets, file I/O, DNS resolution
- **Cancellation support**: All I/O operations on Linux and Windows
- **Standard interfaces**: Full `std.Io.Reader` and `std.Io.Writer` support
- **Synchronization**: Mutex, Condition, Semaphore, ResetEvent, Notify, Barrier
- **Channels**: `Channel(T)` and `BroadcastChannel(T)` for message passing
- **Signal handling**: Async OS signal handling

## Why ZIO?

### Natural code style
Streams implement standard `std.Io.Reader` and `std.Io.Writer` interfaces. You can use external libraries that were never written with async I/O in mind, and they just work.

### High performance
In single-threaded mode, ZIO outperforms Go, Tokio, and asyncio. In multi-threaded mode, it has comparable performance to Go and Tokio.

### Future-proof
When Zig 0.16 is released with the `std.Io` interface, ZIO will implement it, allowing you to use the entire standard library with this runtime.

## Quick Example

```zig
const std = @import("std");
const zio = @import("zio");

fn handleClient(rt: *zio.Runtime, stream: zio.net.Stream) !void {
    defer stream.close(rt);

    var read_buffer: [1024]u8 = undefined;
    var reader = stream.reader(rt, &read_buffer);

    var write_buffer: [1024]u8 = undefined;
    var writer = stream.writer(rt, &write_buffer);

    while (true) {
        const line = reader.interface.readUntilDelimiterOrEof(&read_buffer, '\n') catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (line) |data| {
            try writer.interface.writeAll(data);
            try writer.interface.writeByte('\n');
            try writer.interface.flush();
        }
    }
}

fn serverTask(rt: *zio.Runtime) !void {
    const addr = try zio.net.IpAddress.parseIp4("127.0.0.1", 8080);

    const server = try addr.listen(rt, .{});
    defer server.close(rt);

    std.log.info("Listening on 127.0.0.1:8080", .{});

    while (true) {
        const stream = try server.accept(rt);
        errdefer stream.close(rt);

        var task = try rt.spawn(handleClient, .{ rt, stream }, .{});
        task.deinit();
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const rt = try zio.Runtime.init(gpa.allocator(), .{});
    defer rt.deinit();

    try rt.runUntilComplete(serverTask, .{rt}, .{});
}
```

## Next Steps

- [Getting Started](getting-started.md) - Install ZIO and write your first server
- [User Guide](user-guide/runtime.md) - Learn about the runtime, networking, and file I/O
- [Examples](https://github.com/lalinsky/zio/tree/main/examples) - See complete example programs
