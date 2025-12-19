# Using Io interface

In the upcoming Zig 0.16 release, there is going to be a new `std.Io` interface for doing I/O operations that replaces many part of the standard library.
You can read more about in [this article](https://kristoff.it/blog/zig-new-async-io/). Zio provides an implementation of the interface, so you will be able to use
our coroutine runtime with any code using that interface.

> Because Zig 0.16 is not released yet, we have a backported copy of the interface for Zig 0.15 and will be referring to it as `zio.Io`.
> When migrating to Zig 0.16, simply replace `zio.Io` with `std.Io`, everything else stays the same.

Simple sleep example:

```zig
const std = @import("std");
const zio = @import("zio");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const rt = try zio.Runtime.init(allocator, .{});
    defer rt.deinit();

    const io = rt.io();

    try io.sleep(.{ .nanoseconds = 10 * std.time.ns_per_ms }, .awake)
}
```

If you want something more complex, here is a TCP echo server:

```zig
const std = @import("std");
const zio = @import("zio");

const Io = zio.Io;

fn handleClient(io: Io, stream: Io.net.Stream) void {
    defer stream.close(io);

    std.log.info("Client connected from {f}", .{stream.socket.address});

    var read_buffer: [1024]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);

    var write_buffer: [1024]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);

    while (true) {
        const line = reader.interface.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => break,
            else => {
                std.log.err("Read error: {any}", .{err});
                return;
            },
        };

        std.log.info("Received: {s}", .{line});
        writer.interface.writeAll(line) catch |err| {
            std.log.err("Write error: {any}", .{err});
            return;
        };
        writer.interface.flush() catch |err| {
            std.log.err("Flush error: {any}", .{err});
            return;
        };
    }

    std.log.info("Client disconnected", .{});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const rt = try zio.Runtime.init(allocator, .{});
    defer rt.deinit();

    const io = rt.io();

    const addr = try Io.net.IpAddress.parseIp4("127.0.0.1", 8080);

    var server = try addr.listen(io, .{});
    defer server.socket.close(io);

    std.log.info("TCP echo server listening on {f}", .{server.socket.address});
    std.log.info("Press Ctrl+C to stop the server", .{});

    var group: Io.Group = .init;
    defer group.cancel(io);

    while (true) {
        const stream = try server.accept(io);
        errdefer stream.close(io);

        try group.concurrent(io, handleClient, .{ io, stream });
    }
}
```
