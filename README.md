# ZIO - Zig I/O Library

A lightweight async I/O library for Zig, built on top of stackful coroutines and libxev.

## Quick Start

```zig
const std = @import("std");
const zio = @import("zio");

fn myTask(rt: *zio.Runtime, name: []const u8) void {
    std.debug.print("{s}: Starting\n", .{name});

    rt.sleep(1000);

    std.debug.print("{s}: Finished\n", .{name});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    // Initialize zio runtime
    var runtime = try zio.Runtime.init(gpa.allocator());
    defer runtime.deinit();

    // Spawn coroutines
    const task1 = try runtime.spawn(myTask, .{ &runtime, "Task-1" }, .{});
    defer task1.deinit();
    const task2 = try runtime.spawn(myTask, .{ &runtime, "Task-2" }, .{});
    defer task2.deinit();

    // Run the event loop
    try runtime.run();
}
```

## Building

```bash
# Build the library and examples
zig build

# Run tests
zig build test
```
