# ZIO - Zig I/O Library

A lightweight async I/O library for Zig, built on top of coroutines and libxev.

## Features

- **Coroutine-based concurrency**: Cooperative multitasking using stack-switching coroutines
- **Cross-platform**: Supports Linux, macOS, and Windows
- **libxev integration**: Pure Zig async I/O operations with zero runtime allocations
- **Sleep functionality**: Non-blocking sleep using libxev timers
- **Simple API**: Easy-to-use interface for spawning coroutines and async operations
- **Zero C dependencies**: No external C libraries required

## Quick Start

```zig
const std = @import("std");
const zio = @import("zio");

fn myTask(runtime: *zio.Runtime, name: []const u8) void {
    std.debug.print("{s}: Starting\n", .{name});

    // Async sleep for 1 second
    runtime.sleep(1000) catch return;

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

ZIO uses libxev which is automatically fetched as a dependency. No external C libraries required!

```bash
# Build and run example
zig build run

# Run other examples
zig build run-error  # Error handling demo
zig build run-task   # Task(T) demo

# Run tests
zig build test
```

## Architecture

ZIO combines:

1. **Coroutines**: Stack-switching coroutines with platform-specific assembly implementations
2. **Event Loop**: libxev event loop for async I/O operations with zero runtime allocations
3. **Scheduler**: Cooperative scheduler that alternates between running coroutines and processing I/O events

The library provides a simple async/await-like experience using coroutines and yield points.

## Task System

ZIO provides a typed task system similar to futures/promises:

```zig
// Spawn tasks that return values
const task1 = try runtime.spawn(addNumbers, .{ 10, 20 }, .{});
const task2 = try runtime.spawn(fetchData, .{&runtime}, .{});

// Wait for results (typed!)
const sum = task1.wait();           // Returns i32
const data = task2.wait() catch |err| { ... }; // Returns ![]u8

// Tasks are reference counted and auto-cleanup
defer task1.deinit();
defer task2.deinit();
```

## Examples

- **Sleep Demo**: Basic coroutine sleep functionality
- **Error Demo**: Error handling with different return types
- **Task Demo**: Typed tasks with wait() semantics

Run examples with `zig build run-<example>`.