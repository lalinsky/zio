# ZIO - Async I/O framework for Zig

[![CI](https://github.com/lalinsky/zio/actions/workflows/test.yml/badge.svg)](https://github.com/lalinsky/zio/actions/workflows/test.yml)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Zig](https://img.shields.io/badge/zig-0.16.0-orange.svg)](https://ziglang.org/download/)
[![Documentation](https://img.shields.io/badge/docs-online-green.svg)](https://lalinsky.github.io/zio/)

The project consists of a few components, together forming a coroutine runtime, that uses asynchronous I/O event loop under the hood.
It's similar to [goroutines] in Go, but with the pros and cons of being implemented in a language with manual memory management
and without compiler support.

The key components are:
- Callback-based I/O event loop, using the best strategy for asynchronous operations on many supported operating systems. Accessible also as a standalone library, `zio.ev`.
- Coroutine library, custom assembly context switching for many architectures, growable stacks implemented using extending virtual memory reservations. Also usable also as a standalone library, `zio.coro`.
- Configurable scheduler that uses these two internal libraries, and allows for coroutines to run on a single or multiple threads, interweaving CPU tasks with I/O operations, aiming for a good balance between fairness and throughput. The multi-threaded version has two modes of operation, tasks pinned to their thread, or tasks freely migrating across threads.
- Public API for all common concurrency and I/O operations, that looks blocking from user code, but always use the event loop and suspend the current coroutine while waiting, allowing other coroutines to run in the meantime. This covers all kinds of synchronization primitives, networking, DNS, file reading/writing, directory operations.
- Implementation of the `std.Io` interface, which is basically a different version of the public API, still using the same runtime components.

> The main branch is for Zig 0.16 . For Zig master (0.17+), use the [`zig-0.17`](https://github.com/lalinsky/zio/tree/zig-0.17) branch.

[`std.Io`]: https://ziglang.org/documentation/0.16.0/std/#std.Io
[`std.Io.Reader`]: https://ziglang.org/documentation/0.16.0/std/#std.Io.Reader
[`std.Io.Writer`]: https://ziglang.org/documentation/0.16.0/std/#std.Io.Writer
[goroutines]: https://en.wikipedia.org/wiki/Go_(programming_language)#Concurrency

## Features

- Support for Linux (`io_uring`, `epoll`), Windows (`iocp`), macOS/FreeBSD/NetBSD/OpenBSD (`kqueue`), and many other systems (`poll`).
- User-mode coroutine context switching for `x86_64`, `aarch64`, `arm`, `thumb`, `riscv32`, `riscv64`, `loongarch64` and `powerpc64` architectures.
- Growable stacks for the coroutines implemented by auto-extending virtual memory reservations.
- Single-threaded or multi-threaded coroutine scheduler.
- Fully asynchronous network I/O on all systems. Supports TCP, UDP, Unix sockets, raw IP sockets, etc.
- Fully asynchronous file I/O on Linux, partially asynchronous (read/write) on Windows. Using blocking syscalls in a thread pool on other systems.
- Fully asynchronous DNS resolver on Linux, Windows and macOS. Using `getaddrinfo` in a thread pool on other systems.
- Safe cancelation support for all operations.
- Structured concurrency using task groups.
- Synchronization primitives, including more advanced ones, like channels.
- Low-level event loop access for integrating with existing C libraries.
- Integration with `std.log` and `std.debug.print` via custom `debug_io`.

## Installation

1) Add zio as a dependency in your `build.zig.zon`:

```bash
zig fetch --save "git+https://github.com/lalinsky/zio#v0.16.0"
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
