# ZIO - Async I/O framework for Zig

[![CI](https://github.com/lalinsky/zio/actions/workflows/test.yml/badge.svg)](https://github.com/lalinsky/zio/actions/workflows/test.yml)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Zig](https://img.shields.io/badge/zig-0.16.0-orange.svg)](https://ziglang.org/download/)
[![Documentation](https://img.shields.io/badge/docs-online-green.svg)](https://lalinsky.github.io/zio/)

ZIO is an asynchronous runtime for Zig, in the same spirit as Go's runtime or Tokio: it schedules lightweight coroutines onto a pool of OS threads, and gives you blocking-looking network, file, and process I/O that's actually backed by non-blocking, event-driven OS APIs under the hood. On top of that, it's a full implementation of the standard library's [`std.Io`] interface, so any Zig 0.16+ code written against `std.Io` runs on zio unmodified.

> The main branch is for Zig 0.16 . For Zig master (0.17+), use the [`zig-0.17`](https://github.com/lalinsky/zio/tree/zig-0.17) branch.

[`std.Io`]: https://ziglang.org/documentation/0.16.0/std/#std.Io

## Architecture

zio is built in layers, and each layer is usable on its own:

- **`zio.ev`**: a cross-platform, callback-based event loop (`io_uring`/`epoll`/`kqueue`/`iocp`/`poll`), in the same space as [libuv] or [libxev]. You can use this independently for async I/O without coroutines, or to embed zio's I/O into an existing callback-driven loop. For example, see [blazio], a CPython `asyncio` event loop built on `zio.ev`.
- **`zio.coro`**: stackful coroutine primitives (context switching, growable stacks, manual scheduling), with no I/O or scheduler attached. This is what you'd build a different kind of scheduler on top of, if `zio.Runtime`'s isn't the one you want.
- **`zio.Runtime`**: the full runtime. It schedules `zio.coro` coroutines across executor threads, drives their I/O through `zio.ev`, and adds structured concurrency (task groups), cancellation, synchronization primitives, and the `std.Io` implementation. Most programs use this directly and never touch the layers below it.

A runtime can run single-threaded, or multi-threaded in one of two modes. With work-stealing (the default), idle executors steal work from busy ones. This keeps every thread busy when runnable work is spread unevenly to begin with. With pinned scheduling, a task stays on whichever executor it was spawned on for its entire life, with no migration and no cross-executor synchronization on the scheduling path, at the cost of no rebalancing if load is uneven.

[libuv]: https://github.com/libuv/libuv
[libxev]: https://github.com/mitchellh/libxev
[blazio]: https://github.com/lalinsky/blazio

## Features

- Support for Linux (`io_uring` with automatic `epoll` fallback), Windows (`iocp`), macOS/FreeBSD/NetBSD/OpenBSD (`kqueue`), and many other systems (`poll`).
- User-mode coroutine context switching for `x86_64`, `x86`, `aarch64`, `arm`, `thumb`, `riscv32`, `riscv64`, `loongarch64` and `powerpc64` architectures.
- Growable stacks for the coroutines implemented by auto-extending virtual memory reservations.
- Single-threaded or multi-threaded coroutine scheduler, with or without work-stealing.
- Fully asynchronous network I/O on all systems. Supports TCP, UDP, Unix sockets, raw IP sockets, etc.
- Fully asynchronous file I/O on Linux, partially asynchronous (read/write) on Windows. Using blocking syscalls in a thread pool on other systems.
- Fully asynchronous DNS resolver on Linux, Windows and macOS. Using `getaddrinfo` in a thread pool on other systems.
- Synchronization primitives, including more advanced ones, like channels.
- Fast and safe cancellation support for all operations.
- Full timeout support, both for individual I/O operations and for arbitrary user code, with proper cleanup on either a timeout or an external cancel.
- Structured concurrency using task groups.
- Waiting on a mix of different operations at once, tasks, channels, timeouts, and anything else implementing the wait protocol.
- Integration with `std.log` and `std.debug.print` via custom `debug_io`, so logging and printing don't block the event loop.

## Installation

1) Add zio as a dependency in your `build.zig.zon`:

```bash
zig fetch --save "git+https://github.com/lalinsky/zio#v0.17.0"
```

2) In your `build.zig`, add the `zio` module as a dependency to your program:

```zig
const zio = b.dependency("zio", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("zio", zio.module("zio"));
```

## Usage

There are two main ways to use zio: the native API and the standard library's [`std.Io`] interface.
For most cases, prefer the `std.Io` interface, especially if you are writing a library.
The native API is more direct and has more features, but it ties you to the zio runtime.

A minimal TCP echo server, using zio's native API:

```zig
const std = @import("std");
const zio = @import("zio");

pub const std_options_debug_io = zio.debug_io;

fn handleClient(stream: zio.net.Stream) !void {
    defer stream.close();

    std.log.info("Client connected from {f}", .{stream.socket.address});

    var read_buffer: [1024]u8 = undefined;
    var reader = stream.reader(&read_buffer);

    var write_buffer: [1024]u8 = undefined;
    var writer = stream.writer(&write_buffer);

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
    const rt = try zio.Runtime.init(std.heap.smp_allocator, .{});
    defer rt.deinit();

    const addr = try zio.net.IpAddress.parseIp4("127.0.0.1", 8080);
    const server = try addr.listen(.{});
    defer server.close();

    std.log.info("TCP echo server listening on {f}", .{server.socket.address});

    var group: zio.Group = .init;
    defer group.cancel();

    while (true) {
        const stream = try server.accept(.{});
        errdefer stream.close();
        try group.spawn(handleClient, .{stream});
    }
}
```

The same server written against the standard library's [`std.Io`] interface:

```zig
const std = @import("std");
const zio = @import("zio");

const Io = std.Io;

fn handleClient(io: Io, stream: Io.net.Stream) Io.Cancelable!void {
    defer stream.close(io);

    var read_buffer: [1024]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);

    var write_buffer: [1024]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);

    while (true) {
        const line = reader.interface.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => break,
            error.ReadFailed => return if (reader.err.? == error.Canceled) error.Canceled else {},
            else => return,
        };
        writer.interface.writeAll(line) catch return if (writer.err.? == error.Canceled) error.Canceled else {};
        writer.interface.flush() catch return if (writer.err.? == error.Canceled) error.Canceled else {};
    }
}

pub fn main() !void {
    const rt = try zio.Runtime.init(std.heap.smp_allocator, .{});
    defer rt.deinit();
    const io = rt.io();

    const addr = try Io.net.IpAddress.parseIp4("127.0.0.1", 8080);
    var server = try addr.listen(io, .{});
    defer server.deinit(io);

    var group: Io.Group = .init;
    defer group.cancel(io);

    while (true) {
        const stream = try server.accept(io);
        errdefer stream.close(io);
        try group.concurrent(io, handleClient, .{ io, stream });
    }
}
```

See `examples/*.zig` for more examples.

## Frequently Asked Questions

### What is the difference between this project and `std.Io.Evented`?

In theory, from user perspective, there is very little difference. However, `std.Io.Evented` is very far from finished. It's missing essential functionality, if it even builds.
Zio already fully supports multiple operating systems.

The architecture of these two implementations is different. In the standard library, they prefer to reimplement the `std.Io` interface for each I/O backend, while in zio, I chose a layered architecture,
where I have a cross-platform event loop, and the fiber/coroutine runtime built on top of that. That makes it much easier to support multiple systems. Plus you can even reach into the event loop from your code, in case you need functionality not covered by the `std.Io` interface.

## Development

Building examples

```
zig build examples
```

Running tests (with options to run specific tests, or select a non-default I/O backend)

```bash
zig build test -Dtest-filter="foo" -Dbackend=epoll
```

See [DEVELOPMENT.md](DEVELOPMENT.md) for more details.

## License

This project is licensed under the [MIT license].

[MIT license]: https://github.com/lalinsky/zio/blob/main/LICENSE
