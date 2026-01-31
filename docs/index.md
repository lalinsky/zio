# ZIO - Async I/O framework for Zig

ZIO is an async I/O framework for Zig that provides:

- Runtime for executing stackful coroutines (fibers, green threads) on one or more CPU threads
- Asynchronous I/O layer that makes it look like operations are blocking for easy state management, but using event-driven OS APIs under the hood
- Synchronization primitives that cooperate with this runtime
- Integration with standard library interfaces, like [`std.Io.Reader`](https://ziglang.org/documentation/0.15.2/std/#std.Io.Reader) and [`std.Io.Writer`](https://ziglang.org/documentation/0.15.2/std/#std.Io.Writer)

It's similar to [goroutines](https://en.wikipedia.org/wiki/Go_(programming_language)#Concurrency) in Go, but with the pros and cons of being implemented in a language with manual memory management and without compiler support.

## Features

- Support for Linux (`io_uring`, `epoll`), Windows (`iocp`), macOS (`kqueue`), most BSDs (`kqueue`), and many other systems (`poll`)
- User-mode coroutine context switching for `x86_64`, `aarch64`, `arm`, `thumb`, `riscv32`, `riscv64` and `loongarch64` architectures
- Growable stacks for the coroutines implemented by auto-extending virtual memory reservations
- Multi-threaded coroutine scheduler
- Fully asynchronous network I/O on all systems
- Asynchronous file I/O on Linux and Windows, simulated using auxiliary thread pool on other systems
- Cancelation support for all operations
- Structured concurrency using task groups
- Synchronization primitives, including more advanced ones, like channels

## Quick Example

Basic TCP echo server:

```zig
--8<-- "examples/tcp_echo_server.zig"
```

See the [Tutorial](getting-started.md) to get started, or check out the examples in the repository.

## Ecosystem

The following libraries use ZIO for networking and concurrency:

- [Dusty](https://github.com/lalinsky/dusty) - HTTP client and server library
- [nats.zig](https://github.com/lalinsky/nats.zig) - NATS client library
- [pg.zig](https://github.com/lalinsky/pg.zig) - PostgreSQL client library

## Installation

See the [Getting Started](getting-started.md) guide for installation instructions.

## License

This project is licensed under the [MIT license](https://github.com/lalinsky/zio/blob/main/LICENSE).
