# ZIO - Zig I/O Library

A lightweight async I/O library for Zig, built on top of coroutines and libuv.

## Features

- **Coroutine-based concurrency**: Cooperative multitasking using stack-switching coroutines
- **Cross-platform**: Supports x86_64 (Linux/Windows) and ARM64 architectures
- **libuv integration**: Async I/O operations using the battle-tested libuv library
- **Sleep functionality**: Non-blocking sleep using libuv timers
- **Simple API**: Easy-to-use interface for spawning coroutines and async operations

## Quick Start

```zig
const std = @import("std");
const zio = @import("zio");

fn myTask(name: []const u8) void {
    std.debug.print("{s}: Starting\n", .{name});

    // Async sleep for 1 second
    zio.sleep(1000) catch return;

    std.debug.print("{s}: Finished\n", .{name});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    // Initialize zio runtime
    try zio.init(gpa.allocator());
    defer zio.deinit();

    // Spawn coroutines
    _ = try zio.spawn(myTask, .{"Task-1"});
    _ = try zio.spawn(myTask, .{"Task-2"});

    // Run the event loop
    zio.run();
}
```

## Building

Requires libuv to be installed on your system:

```bash
# Ubuntu/Debian
sudo apt install libuv1-dev

# Build and run example
zig build run
```

## Architecture

ZIO combines:

1. **Coroutines**: Stack-switching coroutines with platform-specific assembly implementations
2. **Event Loop**: libuv event loop for async I/O operations
3. **Scheduler**: Cooperative scheduler that alternates between running coroutines and processing I/O events

The library provides a simple async/await-like experience using coroutines and yield points.