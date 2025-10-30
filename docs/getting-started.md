# Getting Started

This guide will help you install ZIO and write your first async program.

## Installation

### 1. Add ZIO as a dependency

In your project directory, run:

```bash
zig fetch --save "git+https://github.com/lalinsky/zio"
```

This adds ZIO to your `build.zig.zon` file.

### 2. Update your build.zig

Add the `zio` module as a dependency to your program:

```zig
const zio = b.dependency("zio", .{
    .target = target,
    .optimize = optimize,
});

// Add to your executable
exe.root_module.addImport("zio", zio.module("zio"));
```

## Your First Program

Let's write a simple TCP echo server that handles multiple clients concurrently.

Create `src/main.zig`:

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
        const line = reader.interface.readUntilDelimiterOrEof(&read_buffer, '\n') catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };

        if (line) |data| {
            try writer.interface.writeAll(data);
            try writer.interface.writeByte('\n');
            try writer.interface.flush();
        } else break;
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

        // Spawn a new coroutine for each client
        var task = try rt.spawn(handleClient, .{ rt, stream }, .{});
        task.deinit();
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const rt = try zio.Runtime.init(gpa.allocator(), .{});
    defer rt.deinit();

    try rt.runUntilComplete(serverTask, .{rt}, .{});
}
```

## Build and Run

```bash
zig build run
```

## Test It

In another terminal:

```bash
telnet localhost 8080
```

Type a message and press Enter. The server will echo it back!

## Understanding the Code

### 1. Create the Runtime

```zig
const rt = try zio.Runtime.init(gpa.allocator(), .{});
defer rt.deinit();
```

The Runtime manages all coroutines and the event loop. With default options, it runs in single-threaded mode.

### 2. Start the Server

```zig
try rt.runUntilComplete(serverTask, .{rt}, .{});
```

This runs `serverTask` as the main coroutine and blocks until it completes.

### 3. Accept Connections

```zig
const server = try addr.listen(rt, .{});
const stream = try server.accept(rt);
```

`accept()` suspends the coroutine until a client connects, but doesn't block the event loop.

### 4. Spawn Tasks

```zig
var task = try rt.spawn(handleClient, .{ rt, stream }, .{});
task.deinit();
```

Each client gets its own coroutine. The `spawn()` creates a new stack for the coroutine. Calling `deinit()` detaches the task - we don't need to wait for it.

### 5. Async I/O

```zig
const line = reader.interface.readUntilDelimiterOrEof(&read_buffer, '\n') catch ...
try writer.interface.writeAll(data);
```

These look like blocking calls, but they're fully asynchronous! The coroutine suspends while waiting for I/O, allowing other coroutines to run.

## What's Next?

- [Runtime & Tasks](user-guide/runtime.md) - Learn about runtime options, spawning tasks, and task management
- [Networking](user-guide/networking.md) - Deep dive into TCP, UDP, and Unix sockets
- [File I/O](user-guide/file-io.md) - Work with files asynchronously
