# Signal Handling

You can use [`Signal`](apidocs/#zio.Signal) to listen for
[operating system signals](https://en.wikipedia.org/wiki/Signal_(IPC)), like `SIGINT` or `SIGTERM`. The most common use for signal handling is graceful shutdown of your
application, such as a server. Unlike traditional signal handlers, these are not callbacks,
but objects that you can wait for.

There are a few ways how you can use `Signal`. In the simplest case, you
spawn a new task, create a `Signal` and wait for it to be triggered. When
the signal is received, you can stop your server gracefully. Here is an example:

```zig
var sigint = try zio.Signal.init(.interrupt);
defer sigint.deinit();

try sigint.wait(rt);
std.log.info("Received SIGINT, initiating shutdown...", .{});

server.shutdown();
```

You can also use `Signal` inside [`select()`](apidocs/#zio.select) to wait
for multiple signals at the same time:

```zig
var sigint = try zio.Signal.init(.interrupt);
defer sigint.deinit();

var sigterm = try zio.Signal.init(.terminate);
defer sigterm.deinit();

const result = try zio.select(rt, .{ 
    .sigint = &sigint,
    .sigterm = &sigterm
});
switch (result) {
    .sigint => {
        std.log.info("Received SIGINT, initiating graceful shutdown...", .{});
        server.shutdown(.{ .graceful = true });
    },
    .sigterm => {
        std.log.info("Received SIGTERM, initiating shutdown...", .{});
        server.shutdown(.{ .graceful = false });
    },
}
```

Alternatively, if you have some idle main loop, you could use `Signal` like this:

```zig
var sigint = try zio.Signal.init(.interrupt);
defer sigint.deinit();

while (true) {
    // some other work

    sigint.timedWait(rt, .{ .duration = .fromMilliseconds(100) }) catch |err| {
        if (err == error.Timeout) {
            continue;
        }
        return err;
    };

    std.log.info("Received SIGINT, initiating shutdown...", .{});
    server.shutdown(.{ .graceful = true });
    break;
}
```
