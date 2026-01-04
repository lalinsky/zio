# ZIO - Async I/O framework for Zig

[![CI](https://github.com/lalinsky/zio/actions/workflows/test.yml/badge.svg)](https://github.com/lalinsky/zio/actions/workflows/test.yml)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Zig](https://img.shields.io/badge/zig-0.15.1-orange.svg)](https://ziglang.org/download/)
[![Documentation](https://img.shields.io/badge/docs-online-green.svg)](https://lalinsky.github.io/zio/)

The project consists of a few high-level components:
- Runtime for executing stackful coroutines (fibers, green threads) on one or more CPU threads.
- Asynchronous I/O layer that makes it look like operations are blocking, but uses event-driven I/O APIs under the hood.
- Synchronization primitives that cooperate with this runtime.
- Integration with standard library interfaces, like `std.Io`, `std.Io.Reader` and `std.Io.Writer`.

## Features

- Support Linux (`io_uring`, `epoll`), Windows (`iocp`), macOS (`kqueue`), most BSDs (`kqueue`), and other systems (`poll`).
- Stackful coroutines for `x86_64`, `aarch64`, `riscv64` and `loongarch64` architectures.
- Growable stacks for the coroutines implemented by auto-extending virtual memory reservations.
- Multi-threaded coroutine scheduler.
- Fully asynchronous network I/O.
- Asynchronous file I/O on Linux and Windows, simulated using auxiliary thread pool on other systems.
- Cancelation support for all operations.
- Synchronization primitives, including more advanced ones, like channels.

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

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const rt = try zio.Runtime.init(gpa.allocator(), .{});
    defer rt.deinit();

    const addr = try zio.net.IpAddress.parseIp4("127.0.0.1", 8080);

    const server = try addr.listen(rt, .{});
    defer server.close(rt);

    std.log.info("Listening on 127.0.0.1:8080", .{});

    while (true) {
        const stream = try server.accept(rt);
        errdefer stream.close(rt);

        var task = try rt.spawn(handleClient, .{ rt, stream }, .{});
        task.detach(rt);
    }
}
```

See `examples/*.zig` and [mini-redis](https://github.com/lalinsky/zio-mini-redis) for more examples.

You can also have a look at [Dusty](https://github.com/lalinsky/dusty), a HTTP server library that uses Zio.

## Building

```bash
# Build the library and examples
zig build

# Run tests
zig build test
```
## Sub-projects

To make CI testing easier, I've extracted platform-specific code to separate packages:

* [aio.zig](https://github.com/lalinsky/aio.zig) - callback-based asynchronous file/network library for Linux, Windows, macOS and most BSDs
* [coro.zig](https://github.com/lalinsky/coro.zig) - stackful coroutine library for x86_64, aarch64 and riscv64 architectures

## FAQ

### How is this different from other Zig async I/O projects?

There are many projects implementing stackful coroutines for Zig, unfortunately they are all missing something. The closest one to complete is [Tardy](https://github.com/tardy-org/tardy). Unfortunately, I didn't know about it when I started this project. However, even Tardy is missing many things that I wanted, like spawning non-cooperative tasks in a separate thread pool and being able to wait on their results from coroutines, more advanced synchronization primitives and Windows support. I wanted to start from an existing cross-platform event loop, originally [libuv](https://libuv.org/), later switched to [libxev](https://github.com/mitchellh/libxev), and just add coroutine runtime on top of that.

### How is this different from the future `std.Io` interface in Zig?

This library provides an implementation of the `std.Io` interface, see the [documentation](https://lalinsky.github.io/zio/stdio/).
