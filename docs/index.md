# ZIO - Async I/O framework for Zig

There are two ways of doing asynchronous I/O, either you use callbacks and have the I/O operation call you when it's done, or you have some sort of continuation system and suspend your code while waiting for I/O. Callback-based APIs are easier to implement, they don't need any special runtime or language support. However, they are much harder to use, you need to manage state yourself and most likely need many more allocations to do so.

This project started out of my frustration with the state of networking in Zig. I've tried to write a nice wrapper for libuv in Zig, but it just doesn't work, you have to allocate memory all the time, you need to depend on reference counted pointers. Then it occurred to me that I could do Go-style stackful coroutines and use the stack for storing the state. The resulting code feels much more idiomatic. So I did an experiment with custom assembly for switching contexts, used libuv as my event loop, created a translation layer from libuv callbacks to coroutines, later switched libuv for libxev, and then worked more on the scheduler, especially making it run in multi-threaded mode.

The project consists of a runtime for executing many stackful coroutines (fibers, green threads) on one or more CPU threads, synchronization primitives that work with this runtime and an asynchronous I/O layer that makes it look like I/O calls are blocking, allowing surrounding state to be stored directly on the stack. This makes it possible for you to handle thousands of network connections on a single CPU thread. And if you use multiple executors, you can spread the load across multiple CPU threads. When using the multi-threaded runtime, coroutines migrate from one thread to another, both for reduced latency in message passing applications, but also for load balancing.

Streams implement the standard `std.Io.Reader` and `std.Io.Writer` interfaces, so you can use external libraries, that were never written with asynchronous I/O in mind and they will just work. Additionally, when Zig 0.16 is released with the `std.Io` interface, I will implement that as well, allowing you to use the entire standard library with this runtime.

You can see this as an alternative to the Go runtime, the Tokio project for Rust, or Python's asyncio. In a single-threaded mode, Zio outperforms any of these. In multi-threaded mode, it has comparable performance to Go and Tokio, but those are more mature projects and they have invested a lot of effort to ensuring fairness and load balancing of their schedulers.

## Features

- Supports Linux, Windows and macOS (BSDs should work, but not tested)
- Single-threaded or multi-threaded runtime with one I/O event loop per executor thread
- Spawning coroutines, one small allocation per spawn, stack memory is reused
- Spawning blocking tasks in an auxiliary thread pool
- Fully asynchronous network I/O, supports TCP/UDP sockets, Unix sockets, DNS resolution currently via thread pool
- Asynchronous file I/O, Linux and Windows are truly asynchronous, other platforms are simulated using a thread pool
- Cancellation support for all I/O operations on Linux and Windows, on other platforms we just stop polling, but can't cancel an active operation
- Full `std.Io.Reader` and `std.Io.Writer` support for files and streaming sockets (TCP, Unix)
- Synchronization primitives matching `std.Thread` API (`Mutex`, `Condition`, `Semaphore`, `ResetEvent`, `Notify`, `Barrier`)
- `Channel(T)` and `BroadcastChannel(T)` for producer-consumer patterns across coroutines
- Signal handling

## Installation

1) Add zio as a dependency in your `build.zig.zon`:

```bash
zig fetch --save "git+https://github.com/lalinsky/zio"
```

2) In your `build.zig`, add the `zio` module as a dependency to your program:

```zig
const zio = b.dependency("zio", .{
    .target = target,
    .optimize = optimize,
});

// the executable from your call to b.addExecutable(...)
exe.root_module.addImport("zio", zio.module("zio"));
```

## Usage

Basic TCP echo server:

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
        const line = reader.interface.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        try writer.interface.writeAll(line);
        try writer.interface.flush();
    }
}

fn serverTask(rt: *zio.Runtime) !void {
    const addr = try zio.net.IpAddress.parseIp4("127.0.0.1", 8080);

    const server = try addr.listen(rt);
    defer server.close(rt);

    std.log.info("Listening on 127.0.0.1:8080");

    while (true) {
        const stream = try server.accept(rt);
        errdefer stream.close(rt);

        var task = try rt.spawn(handleClient, .{ rt, stream });
        task.deinit();
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const rt = try zio.Runtime.init(gpa.allocator());
    defer rt.deinit();

    var handle = try rt.spawn(serverTask, .{rt});
    try handle.join(rt);
}
```

See `examples/*.zig` and [mini-redis](https://github.com/lalinsky/zio-mini-redis) for more examples.
