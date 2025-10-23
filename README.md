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
- Single-threaded or multi-threaded runtime with one I/O event loop per executor thread
- Spawn stackful coroutines, and wait for the results
- Spawn blocking tasks in a thread pool, and wait for the results
- File I/O on all platforms, Linux and Windows are truly non-blocking, other platforms are simulated using a thread pool
- Network I/O, supports TCP/UDP sockets, DNS resolution currently via thread pool
- Full `std.Io.Reader` and `std.Io.Writer` support for TCP streams
- Synchronization primitives matching `std.Thread` API (`Mutex`, `Condition`, `Semaphore`, `ResetEvent`, `Notify`, `Barrier`)
- `Channel(T)` and `BroadcastChannel(T)` for producer-consumer patterns across coroutines

## Installation

1) Add zio as a dependency in your `build.zig.zon`:

```bash
zig fetch --save "git+https://github.com/lalinsky/zio"
```

2) In your `build.zig`, add the `zio` module as a dependency you your program:

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

    var runtime = try zio.Runtime.init(gpa.allocator(), .{});
    defer runtime.deinit();

    try runtime.runUntilComplete(serverTask, .{&runtime}, .{});
}
```

See `examples/*.zig` and [mini-redis](https://github.com/lalinsky/zio-mini-redis) for more examples.

## Building

```bash
# Build the library and examples
zig build

# Run tests
zig build test
```
