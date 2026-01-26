# ZIO - Async I/O framework for Zig

[![CI](https://github.com/lalinsky/zio/actions/workflows/test.yml/badge.svg)](https://github.com/lalinsky/zio/actions/workflows/test.yml)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Zig](https://img.shields.io/badge/zig-0.15.2-orange.svg)](https://ziglang.org/download/)
[![Documentation](https://img.shields.io/badge/docs-online-green.svg)](https://lalinsky.github.io/zio/)

The project consists of a few high-level components:
- Runtime for executing stackful coroutines (fibers, green threads) on one or more CPU threads.
- Asynchronous I/O layer that makes it look like operations are blocking for easy state management, but using event-driven OS APIs under the hood.
- Synchronization primitives that cooperate with this runtime.
- Integration with standard library interfaces, like [`std.Io`], [`std.Io.Reader`] and [`std.Io.Writer`].

It's similar to [goroutines] in Go, but with the pros and cons of being implemented in a language with manual memory management and without compiler support.

[`std.Io`]: https://ziglang.org/documentation/master/std/#std.Io
[`std.Io.Reader`]: https://ziglang.org/documentation/0.15.2/std/#std.Io.Reader
[`std.Io.Writer`]: https://ziglang.org/documentation/0.15.2/std/#std.Io.Writer
[`std.Io`]: https://ziglang.org/documentation/master/std/#std.Io.Writer
[goroutines]: https://en.wikipedia.org/wiki/Go_(programming_language)#Concurrency

*The `main` branch works with Zig 0.15. If you want to use the library with the development version of Zig with the `std.Io` interface, use the [`zig-0.16`] branch. Keep in mind that the development version Zig has frequent breaking changes, so the branch might not be always up to date. Contributions are welcome.*

[`zig-0.16`]: https://github.com/lalinsky/zio/tree/zig-0.16

## Features

- Support for Linux (`io_uring`, `epoll`), Windows (`iocp`), macOS (`kqueue`), most BSDs (`kqueue`), and many other systems (`poll`).
- User-mode coroutine context switching for `x86_64`, `aarch64`, `arm`, `riscv64` and `loongarch64` architectures.
- Growable stacks for the coroutines implemented by auto-extending virtual memory reservations.
- Multi-threaded coroutine scheduler.
- Fully asynchronous network I/O on all systems.
- Asynchronous file I/O on Linux and Windows, simulated using auxiliary thread pool on other systems.
- Cancelation support for all operations.
- Structured concurrency using task groups.
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

    std.log.info("Listening on {f}", .{server.socket.address});

    var group: zio.Group = .init;
    defer group.cancel(rt);

    while (true) {
        const stream = try server.accept(rt);
        errdefer stream.close(rt);

        try group.spawn(rt, handleClient, .{ rt, stream });
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

## License

This project is licensed under the [MIT license].

[MIT license]: https://github.com/lalinsky/zio/blob/main/LICENSE
