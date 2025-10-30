# Networking

ZIO provides async networking with TCP, UDP, and Unix domain sockets. All I/O operations look synchronous but are fully asynchronous under the hood.

## TCP

### TCP Server

```zig
const std = @import("std");
const zio = @import("zio");

fn handleClient(rt: *zio.Runtime, stream: zio.net.Stream) !void {
    defer stream.close(rt);

    var read_buffer: [1024]u8 = undefined;
    var reader = stream.reader(rt, &read_buffer);

    var write_buffer: [1024]u8 = undefined;
    var writer = stream.writer(rt, &write_buffer);

    // Read and echo back
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
    // Parse address
    const addr = try zio.net.IpAddress.parseIp4("127.0.0.1", 8080);

    // Start listening
    const server = try addr.listen(rt, .{});
    defer server.close(rt);

    std.log.info("Listening on 127.0.0.1:8080", .{});

    while (true) {
        // Accept connections
        const stream = try server.accept(rt);
        errdefer stream.close(rt);

        // Handle each client in a separate coroutine
        var task = try rt.spawn(handleClient, .{ rt, stream }, .{});
        task.deinit();
    }
}
```

### TCP Client

```zig
fn clientTask(rt: *zio.Runtime) !void {
    // Connect to server
    const addr = try zio.net.IpAddress.parseIp4("127.0.0.1", 8080);
    const stream = try addr.connect(rt);
    defer stream.close(rt);

    var read_buffer: [1024]u8 = undefined;
    var reader = stream.reader(rt, &read_buffer);

    var write_buffer: [1024]u8 = undefined;
    var writer = stream.writer(rt, &write_buffer);

    // Send a message
    try writer.interface.writeAll("Hello, server!\n");
    try writer.interface.flush();

    // Read response
    const response = try reader.interface.readUntilDelimiterOrEof(&read_buffer, '\n');
    if (response) |data| {
        std.log.info("Received: {s}", .{data});
    }
}
```

### Connect to Hostname

```zig
fn connectToHost(rt: *zio.Runtime, allocator: std.mem.Allocator) !void {
    // DNS resolution + connection (combined)
    const stream = try zio.net.tcpConnectToHost(rt, allocator, "example.com", 80);
    defer stream.close(rt);

    // Use stream...
}
```

## IP Addresses

### Parsing Addresses

```zig
// IPv4
const addr = try zio.net.IpAddress.parseIp4("192.168.1.1", 8080);

// IPv6
const addr6 = try zio.net.IpAddress.parseIp6("::1", 8080);

// Parse from string (auto-detect IPv4/IPv6)
const addr = try zio.net.IpAddress.parse("127.0.0.1:8080");
```

### Creating Addresses

```zig
// IPv4 from bytes
const addr = zio.net.IpAddress.initIp4(.{ 127, 0, 0, 1 }, 8080);

// IPv6 from bytes
const addr6 = zio.net.IpAddress.initIp6(.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, 8080);

// Any address (0.0.0.0)
const addr = zio.net.IpAddress.initIp4(.{ 0, 0, 0, 0 }, 8080);
```

## Stream I/O

### Buffered Reader/Writer

Streams provide standard `std.Io.Reader` and `std.Io.Writer` interfaces:

```zig
var read_buffer: [4096]u8 = undefined;
var reader = stream.reader(rt, &read_buffer);

var write_buffer: [4096]u8 = undefined;
var writer = stream.writer(rt, &write_buffer);

// Now use standard I/O methods
const line = try reader.interface.readUntilDelimiterAlloc(allocator, '\n', max_size);
try writer.interface.print("Number: {}\n", .{42});
try writer.interface.flush();
```

### Raw I/O

For lower-level control:

```zig
// Read up to buffer.len bytes
const bytes_read = try stream.read(rt, buffer);

// Read until buffer is full or EOF
const bytes_read = try stream.readAll(rt, buffer);

// Write some bytes
const bytes_written = try stream.write(rt, data);

// Write all bytes
try stream.writeAll(rt, data);
```

### Shutdown

Half-close a connection:

```zig
// Shutdown write side (send FIN)
try stream.shutdown(rt, .send);

// Shutdown read side
try stream.shutdown(rt, .receive);

// Shutdown both sides
try stream.shutdown(rt, .both);
```

## DNS Resolution

```zig
fn resolveDomain(rt: *zio.Runtime, allocator: std.mem.Allocator) !void {
    // Get list of addresses for a hostname
    const list = try zio.net.getAddressList(rt, allocator, "example.com", 80);
    defer list.deinit();

    for (list.addrs) |addr| {
        std.log.info("Resolved: {}", .{addr});
    }

    // Try connecting to each address
    for (list.addrs) |addr| {
        const stream = addr.connect(rt) catch |err| {
            std.log.warn("Failed to connect to {}: {}", .{ addr, err });
            continue;
        };
        defer stream.close(rt);

        // Connected successfully
        break;
    }
}
```

!!! note
    DNS resolution currently uses the thread pool for blocking calls. True async DNS is planned.

## UDP

UDP support for datagram-based communication:

```zig
// Bind UDP socket
const addr = try zio.net.IpAddress.parseIp4("0.0.0.0", 8080);
const socket = try addr.bindUdp(rt);
defer socket.close(rt);

// Receive datagram
var buffer: [1024]u8 = undefined;
const recv_info = try socket.recvFrom(rt, &buffer);
std.log.info("Received {} bytes from {}", .{ recv_info.len, recv_info.address });

// Send datagram
const target = try zio.net.IpAddress.parseIp4("127.0.0.1", 9090);
try socket.sendTo(rt, "Hello!", target);
```

## Unix Domain Sockets

For inter-process communication on Unix-like systems:

```zig
// Server
const addr = zio.net.UnixAddress.init("/tmp/my.sock");
const server = try addr.listen(rt, .{});
defer server.close(rt);

const stream = try server.accept(rt);
defer stream.close(rt);

// Client
const addr = zio.net.UnixAddress.init("/tmp/my.sock");
const stream = try addr.connect(rt);
defer stream.close(rt);
```

## Error Handling

Common networking errors:

```zig
stream.read(rt, buffer) catch |err| switch (err) {
    error.EndOfStream => {
        // Connection closed by peer
    },
    error.ConnectionReset => {
        // Connection reset by peer (TCP RST)
    },
    error.BrokenPipe => {
        // Write to closed socket
    },
    error.Canceled => {
        // Operation was canceled
    },
    else => return err,
};
```

## Best Practices

### 1. Always Close Resources

Use `defer` to ensure cleanup:

```zig
const stream = try addr.connect(rt);
defer stream.close(rt);
```

### 2. Use errdefer for Error Paths

When spawning tasks:

```zig
const stream = try server.accept(rt);
errdefer stream.close(rt);

var task = try rt.spawn(handleClient, .{ rt, stream }, .{});
task.deinit();
```

### 3. Buffer Sizes Matter

Choose buffer sizes based on your workload:

```zig
// Small messages
var buffer: [1024]u8 = undefined;

// Large transfers
var buffer: [65536]u8 = undefined;
```

### 4. Flush Buffered Writers

Always flush after writing:

```zig
try writer.interface.writeAll(data);
try writer.interface.flush();  // Don't forget!
```

### 5. Handle EndOfStream

Check for connection closure:

```zig
const data = reader.interface.readUntilDelimiterOrEof(&buffer, '\n') catch |err| switch (err) {
    error.EndOfStream => return,  // Clean closure
    else => return err,
};

if (data) |line| {
    // Process line
} else {
    // EOF without delimiter
}
```

## Next Steps

- [File I/O](file-io.md) - Work with files asynchronously
- [Examples](https://github.com/lalinsky/zio/tree/main/examples) - See complete networking examples
