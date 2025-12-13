Completion-based I/O event loop for Zig.

This is a low-level library, intended to be used as part of [zio](https://github.com/lalinsky/zio) or a similar runtime.

Supports Linux (io_uring/epoll/poll), FreeBSD (kqueue/poll), NetBSD (kqueue/poll), macOS (kqueue/poll) and Windows (iocp/poll).

## Features

- Socket operations: `net_open`, `net_close`, `net_bind`, `net_listen`, `net_accept`, `net_connect`, `net_send`, `net_recv`, `net_sendto`, `net_recvfrom`, `net_poll`
- File operations: `file_open`, `file_close`, `file_read`, `file_write`, `file_sync`, `file_rename`, `file_delete`, `file_size`
- Timers: `timer`
- Cancelation: `cancel`
- Cross-thread notifications: `async`
- Auxiliary thread pool for blocking tasks: `work`

## Example

```zig
const std = @import("std");
const aio = @import("aio");

pub fn main() !void {
    // Initialize the event loop
    var loop: aio.Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    // Create a timer that fires after 1 second
    var timer: aio.Timer = .init(1000);
    timer.c.callback = onTimer;

    // Submit the timer to the loop
    loop.add(&timer.c);

    // Run until all operations complete
    try loop.run(.until_done);

    std.debug.print("Done!\n", .{});
}

fn onTimer(_: *aio.Loop, c: *aio.Completion) void {
    _ = c.getResult(.timer) catch |err| {
        std.debug.print("Timer error: {}\n", .{err});
        return;
    };
    std.debug.print("Timer fired!\n", .{});
}
```
