# Simple TCP Server

Now that you've seen a basic "Hello, world!" example, let's build something more interesting: a TCP echo server that can handle multiple clients concurrently.

## The Code

Replace the contents of `src/main.zig` with this:

```zig
--8<-- "examples/tcp_echo_server.zig"
```

Now build and run it:

```sh
$ zig build run
info: TCP echo server listening on 127.0.0.1:8080
info: Press Ctrl+C to stop the server
```

Then connect to it from another terminal:

```sh
$ telnet localhost 8080
Trying 127.0.0.1...
Connected to localhost.
Escape character is '^]'.
Hello, server!
Hello, server!
```

## How It Works

The server consists of two main parts: the main function that accepts connections, and the `handleClient` function that processes each connection.

### Setting Up the Server

The `main` function starts by initializing the runtime and creating a TCP listener:

```zig
const addr = try zio.net.IpAddress.parseIp4("127.0.0.1", 8080);
const server = try addr.listen(rt, .{});
```

This creates a server socket listening on `127.0.0.1:8080`.

### Task Groups

Before entering the accept loop, we create a task group:

```zig
var group: zio.Group = .init;
defer group.cancel(rt);
```

A [`Group`](../apidocs/#zio.Group) manages a collection of tasks and provides structured concurrency. When the group is cancelled (which happens automatically via `defer` when `main` exits), all tasks spawned into the group are also cancelled. This ensures proper cleanup of all client handlers.

### Accepting Connections

The server then enters an infinite loop accepting connections:

```zig
while (true) {
    const stream = try server.accept(rt);
    errdefer stream.close(rt);

    try group.spawn(rt, handleClient, .{ rt, stream });
}
```

For each incoming connection, we spawn a new task using [`group.spawn()`](../apidocs/#zio.Group.spawn). This creates a new fiber (lightweight thread) that runs the `handleClient` function concurrently with the main loop. This is what allows the server to handle multiple clients at the same time.

The `errdefer` ensures that if spawning fails, we close the stream to avoid leaking the file descriptor.

### Handling Clients

The `handleClient` function processes a single client connection:

```zig
fn handleClient(rt: *zio.Runtime, stream: zio.net.Stream) !void {
    defer stream.close(rt);

    var read_buffer: [1024]u8 = undefined;
    var reader = stream.reader(rt, &read_buffer);

    var write_buffer: [1024]u8 = undefined;
    var writer = stream.writer(rt, &write_buffer);

    while (true) {
        const line = reader.interface.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => break,
            error.ReadFailed => |e| return reader.err orelse e,
            else => |e| return e,
        };

        try rt.sleep(.fromMilliseconds(1000));

        try writer.interface.writeAll(line);
        try writer.interface.flush();
    }
}
```

This function:

1. Creates a reader and writer for the stream, each with their own buffer
2. Reads lines from the client using [`takeDelimiterInclusive()`](https://ziglang.org/documentation/0.15.2/std/#std.Io.Reader.takeDelimiterInclusive)
3. When `EndOfStream` is received, the loop breaks and the connection closes
4. For each line, it sleeps for 1 second (to demonstrate async behavior - multiple clients can be served concurrently during this delay)
5. Echoes the line back to the client

Notice that this looks like simple blocking code, but the runtime allows other tasks to run while we're waiting for I/O or sleeping. This is what makes it possible to handle thousands of concurrent connections efficiently.

## Key Concepts

### Tasks

A task in ZIO is a unit of concurrent execution, similar to a goroutine in Go or a fiber in Ruby. Tasks are lightweight - you can create thousands of them without running out of memory. Each task has its own stack that grows automatically as needed.

When you call `group.spawn()`, ZIO creates a new task and schedules it for execution. The runtime manages a pool of OS threads and distributes tasks across them automatically.

### Structured Concurrency

The task group provides structured concurrency, which means the lifetime of child tasks is bound to the parent scope. When the group is cancelled, all tasks in it are cancelled too. This prevents tasks from leaking and makes it easier to reason about concurrent code.

In our example, the `defer group.cancel(rt)` ensures that when `main` exits, all active client handlers are cancelled. This provides a clean shutdown.

### Async I/O

All I/O operations in ZIO are asynchronous under the hood. When you call [`writeAll()`](https://ziglang.org/documentation/0.15.2/std/#std.Io.Writer.writeAll) or read operations, they submit the operation to the event loop and suspend the current task. When the operation completes, the task is resumed automatically.

This gives you the simplicity of synchronous-looking code with the performance of asynchronous I/O.
