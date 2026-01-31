# NTP Client

In the previous tutorials, we've worked with TCP connections. Now let's explore UDP sockets and event-driven programming by building an NTP (Network Time Protocol) client that queries time servers.

This tutorial covers:

- **UDP sockets** - connectionless datagram communication
- **DNS lookup** - resolving hostnames to IP addresses
- **Timeouts** - setting time limits on I/O operations
- **Select** - waiting on multiple events simultaneously

## The Code

Replace the contents of `src/main.zig` with this:

```zig
--8<-- "examples/ntp_client.zig"
```

Now build and run it:

```sh
$ zig build run
info: NTP client starting. Press Ctrl+C to stop.
info: Server: pool.ntp.org:123
info: Update interval: 30s
info: Request timeout: 5s
info: Querying NTP server pool.ntp.org:123 (162.159.200.123:123)
info: Current time: 2026-01-31 19:45:32.847 UTC
info: Querying NTP server pool.ntp.org:123 (162.159.200.1:123)
info: Current time: 2026-01-31 19:46:02.851 UTC
^C
info: NTP client stopped.
```

You can specify a different NTP server:

```sh
$ zig build run -- time.google.com
```

## How It Works

This program demonstrates several networking concepts working together: DNS resolution, UDP communication, timeouts, and event multiplexing.

### DNS Lookup

Before we can contact an NTP server, we need to resolve its hostname to an IP address:

```zig
--8<-- "examples/ntp_client.zig:lookup"
```

[`HostName.lookup()`](../apidocs/#zio.net.HostName.lookup) returns an iterator that yields DNS results. The resolver may return multiple addresses (IPv4 and IPv6), and we take the first one. This happens asynchronously - the task suspends while DNS queries are performed.

### UDP Sockets

Unlike TCP which provides reliable, ordered, connection-oriented streams, UDP sends individual datagrams without establishing a connection:

```zig
const local_addr = try zio.net.IpAddress.parseIp4("0.0.0.0", 0);
const socket = try local_addr.bind(rt, .{});
defer socket.close(rt);
```

[`bind()`](../apidocs/#zio.net.IpAddress.bind) creates a UDP socket. Binding to `0.0.0.0:0` means "listen on any interface, on any available port" - the OS will assign a random port.

With TCP, we called [`connect()`](../apidocs/#zio.net.Stream.connect) to establish a connection. With UDP, there's no connection - we just send datagrams to any address we want.

### Sending and Receiving Datagrams

To send a datagram:

```zig
const sent = try socket.sendTo(rt, addr, &buffer, timeout);
```

[`sendTo()`](../apidocs/#zio.net.Socket.sendTo) sends data to a specific address. UDP doesn't guarantee delivery - the datagram might get lost, arrive out of order, or be duplicated. For NTP, this is acceptable since we query periodically.

To receive a datagram:

```zig
const result = socket.receiveFrom(rt, &buffer, timeout) catch |err| {
    std.log.warn("Failed to receive NTP response: {}", .{err});
    return err;
};
```

[`receiveFrom()`](../apidocs/#zio.net.Socket.receiveFrom) returns both the data and the sender's address. This is important for UDP since we can receive datagrams from any address.

### Timeouts

Both [`sendTo()`](../apidocs/#zio.net.Socket.sendTo) and [`receiveFrom()`](../apidocs/#zio.net.Socket.receiveFrom) accept a [`Timeout`](../apidocs/#zio.Timeout) parameter:

```zig
const request_timeout: zio.Timeout = .{ .duration = .fromSeconds(5) };

const result = socket.receiveFrom(rt, &buffer, request_timeout) catch |err| {
    // Handle timeout or other error
    return err;
};
```

If the operation doesn't complete within 5 seconds, it returns `error.Timeout`. This prevents the program from hanging indefinitely if the server doesn't respond.

You can also use `.none` for no timeout (wait indefinitely), or `.{ .deadline = timestamp }` to wait until a specific time.

### The NTP Protocol

NTP uses a simple binary protocol. We define the packet structure as an extern struct:

```zig
const NtpPacket = extern struct {
    flags: packed struct(u8) {
        mode: u3 = 3,      // Client mode
        version: u3 = 3,   // NTP version 3
        leap: u2 = 0,      // No leap second warning
    } = .{},
    stratum: u8 = 0,
    poll: u8 = 0,
    precision: u8 = 0,
    root_delay: u32 = 0,
    root_dispersion: u32 = 0,
    reference_id: u32 = 0,
    reference_timestamp: u64 = 0,
    origin_timestamp: u64 = 0,
    receive_timestamp: u64 = 0,
    transmit_timestamp: u64 = 0,
};
```

The `extern` keyword ensures the struct has C-compatible layout with no padding. We serialize it to bytes using [`writeStruct()`](https://ziglang.org/documentation/0.15.2/std/#std.Io.Writer.writeStruct):

```zig
const request: NtpPacket = .{};
var buffer: [@sizeOf(NtpPacket)]u8 = undefined;
var writer = std.Io.Writer.fixed(&buffer);
try writer.writeStruct(request, .big);
```

The `.big` endianness ensures multi-byte fields are in network byte order (big-endian).

When we receive the response, we deserialize it:

```zig
var reader = std.Io.Reader.fixed(buffer[0..result.len]);
const response = try reader.takeStruct(NtpPacket, .big);
```

The timestamp is in NTP format (seconds since 1900-01-01), which we convert to Unix time and print in a human-readable format.

### Select: Waiting on Multiple Events

The main loop needs to handle two events: the periodic timer and the shutdown signal (Ctrl+C):

```zig
--8<-- "examples/ntp_client.zig:select"
```

[`select()`](../apidocs/#zio.select) suspends the task until one of the events occurs. You pass a struct where each field is a pointer to something that can be waited on:

- [`JoinHandle`](../apidocs/#zio.JoinHandle) - fires when the task completes
- [`Timeout`](../apidocs/#zio.Timeout) - fires when the duration elapses
- [`Signal`](../apidocs/#zio.Signal) - fires when the signal is received
- [`Channel`](../apidocs/#zio.Channel) - fires when data is available to receive
- And more

`select()` returns a union indicating which event fired, so you can handle each case appropriately.

This is more efficient than spawning separate tasks and using channels. When you need to wait on multiple events in a single task, `select()` is the right tool.
