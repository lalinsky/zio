# ZIO - Async I/O framework for Zig

ZIO is an asynchronous runtime for Zig, in the same spirit as Go's runtime or Tokio: it schedules lightweight coroutines onto a pool of OS threads, and gives you blocking-looking network, file, and process I/O that's actually backed by non-blocking, event-driven OS APIs under the hood. On top of that, it's a full implementation of the standard library's [`std.Io`](https://ziglang.org/documentation/0.16.0/std/#std.Io) interface, so any Zig 0.16+ code written against `std.Io` runs on zio unmodified.

## Architecture

zio is built in layers, and each layer is usable on its own:

- **`zio.ev`**: a cross-platform, callback-based event loop (`io_uring`/`epoll`/`kqueue`/`iocp`/`poll`), in the same space as [libuv](https://github.com/libuv/libuv) or [libxev](https://github.com/mitchellh/libxev). You can use this independently for async I/O without coroutines, or to embed zio's I/O into an existing callback-driven loop. For example, see [blazio](https://github.com/lalinsky/blazio), a CPython `asyncio` event loop built on `zio.ev`.
- **`zio.coro`**: stackful coroutine primitives (context switching, growable stacks, manual scheduling), with no I/O or scheduler attached. This is what you'd build a different kind of scheduler on top of, if `zio.Runtime`'s isn't the one you want.
- **`zio.Runtime`**: the full runtime. It schedules `zio.coro` coroutines across executor threads, drives their I/O through `zio.ev`, and adds structured concurrency (task groups), cancellation, synchronization primitives, and the `std.Io` implementation. Most programs use this directly and never touch the layers below it.

A runtime can run single-threaded, or multi-threaded in one of two modes, chosen at compile time with `zio_options.scheduling` in your root module. The default is `.single_executor`, so running on more than one thread is opt-in:

```zig
pub const zio_options: zio.Options = .{ .scheduling = .pinned };
```

With `.work_stealing`, idle executors steal work from busy ones. This keeps every thread busy when runnable work is spread unevenly to begin with. With `.pinned`, a task stays on whichever executor it was spawned on for its entire life, with no migration and no cross-executor synchronization on the scheduling path, at the cost of no rebalancing if load is uneven. With `.single_executor`, the default, there is one executor and the count is known at compile time, which drops the executor topology entirely. `RuntimeOptions.executors` then only accepts `.exact(1)` or `.auto`, both meaning one; `.exact(N)` for larger N is a compile error that names the declaration to add.

Because the choice is made at compile time, the default removes the multi-executor machinery rather than branching around it, and `.pinned` removes the stealing machinery.

## Features

- Support for Linux (`io_uring` with automatic `epoll` fallback), Windows (`iocp`), macOS/FreeBSD/NetBSD/OpenBSD (`kqueue`), and many other systems (`poll`)
- User-mode coroutine context switching for `x86_64`, `x86`, `aarch64`, `arm`, `thumb`, `riscv32`, `riscv64`, `loongarch64` and `powerpc64` architectures
- Growable stacks for the coroutines implemented by auto-extending virtual memory reservations
- Single-threaded or multi-threaded coroutine scheduler, with or without work-stealing
- Fully asynchronous network I/O on all systems. Supports TCP, UDP, Unix sockets, raw IP sockets, etc.
- Fully asynchronous file I/O on Linux, partially asynchronous (read/write) on Windows. Using blocking syscalls in a thread pool on other systems.
- Fully asynchronous DNS resolver on Linux, Windows and macOS. Using `getaddrinfo` in a thread pool on other systems.
- Synchronization primitives, including more advanced ones, like channels
- Fast and safe cancellation support for all operations
- Full timeout support, both for individual I/O operations and for arbitrary user code, with proper cleanup on either a timeout or an external cancel
- Structured concurrency using task groups
- Waiting on a mix of different operations at once, tasks, channels, timeouts, and anything else implementing the wait protocol
- Integration with `std.log` and `std.debug.print` via custom `debug_io`, so logging and printing don't block the event loop

## Ecosystem

The following libraries use ZIO for networking and concurrency:

- [HTTP server and client](https://github.com/lalinsky/dusty)
- [PostgreSQL client](https://github.com/lalinsky/pg.zig)
- [Redis client](https://github.com/lalinsky/redis.zig)
- [NATS client](https://github.com/lalinsky/nats.zig)
- [Memcached client](https://github.com/lalinsky/memcached.zig)

## Quick Example

Basic TCP echo server:

```zig
--8<-- "examples/tcp_echo_server.zig"
```

See the [Tutorial](getting-started.md) to get started, or check out the examples in the repository.

## Installation

See the [Getting Started](getting-started.md) guide for installation instructions.

## License

This project is licensed under the [MIT license](https://github.com/lalinsky/zio/blob/main/LICENSE).
