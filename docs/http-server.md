# Simple HTTP Server

This example follows the same pattern as [the TCP server we built previously](tcp-server.md) - accepting connections and spawning tasks to handle clients - but uses Zig's standard library [`std.http.Server`](https://ziglang.org/documentation/0.15.2/std/#std.http.Server) to handle the HTTP protocol.

## The Code

Replace the contents of `src/main.zig` with this:

```zig
--8<-- "examples/http_server.zig"
```

Now build and run it:

```sh
$ zig build run
info: HTTP server listening on 127.0.0.1:8080
info: Visit http://127.0.0.1:8080 in your browser
info: Press Ctrl+C to stop the server
```

Open your browser and visit `http://localhost:8080` to see the response.

## How It Works

The structure is similar to the TCP server, but instead of reading raw bytes, we use `std.http.Server` to handle the HTTP protocol.

### Setting Up the HTTP Server

For each client connection, we create an HTTP server instance:

```zig
var server = std.http.Server.init(&reader.interface, &writer.interface);
```

The key here is that `std.http.Server` works with any [`std.Io.Reader`](https://ziglang.org/documentation/0.15.2/std/#std.Io.Reader) and [`std.Io.Writer`](https://ziglang.org/documentation/0.15.2/std/#std.Io.Writer). ZIO's stream reader and writer implement these standard interfaces, so they work seamlessly with existing Zig libraries.

### Handling Requests

The request handling loop receives HTTP requests and sends responses:

```zig
while (true) {
    var request = server.receiveHead() catch |err| switch (err) {
        error.ReadFailed => |e| return reader.err orelse e,
        else => |e| return e,
    };

    try request.respond(html, .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "text/html; charset=utf-8" },
        },
    });

    if (!request.head.keep_alive) {
        try stream.shutdown(rt, .both);
        break;
    }
}
```

The server supports HTTP keep-alive, allowing multiple requests over a single connection. When the client doesn't want keep-alive, we shut down the connection.

## Ecosystem Integration

This example shows an important aspect of ZIO: because it implements the standard [`std.Io.Reader`](https://ziglang.org/documentation/0.15.2/std/#std.Io.Reader) and [`std.Io.Writer`](https://ziglang.org/documentation/0.15.2/std/#std.Io.Writer) interfaces, you can use ZIO with any library from the Zig ecosystem that works with these interfaces. You don't need special "async" versions of libraries - regular Zig libraries just work.

This means you can:

- Use `std.http` for HTTP (as shown here)
- Use `std.crypto.tls` for TLS connections
- Use `std.json` for JSON parsing
- Use any third-party library that reads/writes data through standard interfaces

The runtime handles the async I/O under the hood, so library authors don't need to know about ZIO for their code to work with it.

---

*For more complex HTTP applications, check out [Dusty](https://github.com/lalinsky/dusty), a full-featured HTTP client/server library built on top of ZIO.*
