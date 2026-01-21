# zio.ev - Low-level event loop

Callback-based async I/O event loop, similar to [libuv] or [libxev].

[libuv]: https://libuv.org/
[libxev]: https://github.com/mitchellh/libxev

## Features

- Support for Linux (`io_uring`, `epoll`), Windows (`iocp`), macOS (`kqueue`), most BSDs (`kqueue`), and many other systems (`poll`).
- Asynchronous network I/O on all systems.
- Asynchronous file and directory I/O on Linux and Windows, simulated using auxiliary thread pool on other systems.
- Timers, async notifications, and thread pool work items.
- Cancellation support for all operations.
- Structured concurrency using groups.
- Zero-allocation intrusive data structures.
- Thread-safe cancellation and cross-thread waking.

## Usage

```zig
const std = @import("std");
const ev = @import("zio").ev;

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();

    var loop: ev.Loop = try .init(gpa.allocator(), .{});
    defer loop.deinit();

    var timer: ev.Timer = .init(.fromSeconds(1));
    timer.c.callback = timerCallback;
    loop.add(&timer.c);

    try loop.run(.until_done);
}

fn timerCallback(loop: *ev.Loop, c: *ev.Completion) void {
    const timer: *ev.Timer = c.cast(ev.Timer);
    timer.getResult() catch |err| {
        std.debug.print("timer error: {}\n", .{err});
        return;
    };
    std.debug.print("timer fired!\n", .{});
    loop.add(c); // re-arm the timer
}
```

## Completion types

All operations use a `Completion` struct that tracks state, callbacks, and results:

| Type | Description |
|------|-------------|
| `Timer` | One-shot or reschedulable timer |
| `Group` | Structured concurrency (gather or race mode) |
| `Async` | Cross-thread notifications |
| `Work` | Thread pool work items |
| `Net*` | Network operations (open, bind, listen, connect, accept, recv, send, close, etc.) |
| `File*` | File operations (open, create, read, write, sync, close, etc.) |
| `Dir*` | Directory operations (create, rename, delete, read, symlink, etc.) |
