# Runtime & Tasks

The Runtime is the core of ZIO. It manages coroutines (tasks), the event loop, and schedules work across one or more threads.

## Creating a Runtime

### Basic Setup

```zig
const std = @import("std");
const zio = @import("zio");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const rt = try zio.Runtime.init(gpa.allocator(), .{});
    defer rt.deinit();

    // Your async code here
}
```

### Runtime Options

```zig
const rt = try zio.Runtime.init(allocator, .{
    .num_executors = null,  // Auto-detect CPU count (default: 1)
    .thread_pool = .{
        .enabled = true,     // Enable thread pool for blocking tasks
        .max_threads = 4,    // Max threads in pool
    },
    .stack_pool = .{
        .stack_size = 65536,     // Default stack size per coroutine
        .initial_count = 8,      // Pre-allocate 8 stacks
        .max_cached_count = 32,  // Cache up to 32 stacks
    },
    .lifo_slot_enabled = true,  // Cache locality optimization
});
```

#### Single-threaded vs Multi-threaded

```zig
// Single-threaded (default)
const rt = try zio.Runtime.init(allocator, .{});

// Multi-threaded - auto-detect CPU count
const rt = try zio.Runtime.init(allocator, .{ .num_executors = null });

// Multi-threaded - specific count
const rt = try zio.Runtime.init(allocator, .{ .num_executors = 4 });
```

## Running the Runtime

### runUntilComplete

Runs a task and blocks until it completes:

```zig
fn mainTask(rt: *zio.Runtime) !void {
    std.log.info("Task running", .{});
}

try rt.runUntilComplete(mainTask, .{rt}, .{});
```

### run

Starts the event loop and runs until all tasks complete:

```zig
// Spawn some tasks
var task1 = try rt.spawn(worker, .{rt}, .{});
var task2 = try rt.spawn(worker, .{rt}, .{});

// Run until all tasks finish
try rt.run();

// Clean up
task1.deinit();
task2.deinit();
```

## Spawning Tasks

### Basic Spawn

```zig
fn worker(rt: *zio.Runtime, id: u32) !void {
    std.log.info("Worker {} started", .{id});
    try rt.sleep(1000);  // Sleep 1 second
    std.log.info("Worker {} done", .{id});
}

var task = try rt.spawn(worker, .{ rt, 1 }, .{});
task.deinit();  // Detach - we don't need the result
```

### Spawn Options

```zig
var task = try rt.spawn(worker, .{rt}, .{
    .stack_size = 131072,    // Custom stack size (128 KB)
    .executor = .any,        // Run on any executor (default)
    .pinned = false,         // Allow migration (default)
});
```

#### Executor Placement

```zig
// Run on any available executor
.executor = .any

// Run on the same executor as the parent
.executor = .same

// Run on a specific executor
.executor = .{ .id = 2 }
```

#### Pinned Tasks

```zig
// Prevent task from migrating between threads
var task = try rt.spawn(worker, .{rt}, .{ .pinned = true });
```

Use pinning when a task has thread-local state or for cache locality.

## Waiting for Tasks

### join

Wait for a task and get its result:

```zig
fn compute(rt: *zio.Runtime) !u32 {
    try rt.sleep(100);
    return 42;
}

var task = try rt.spawn(compute, .{rt}, .{});
defer task.deinit();

const result = try task.join(rt);
std.log.info("Result: {}", .{result});
```

### Detached Tasks

If you don't need the result, call `deinit()` immediately:

```zig
var task = try rt.spawn(backgroundWork, .{rt}, .{});
task.deinit();  // Detach - task runs independently
```

## Sleeping and Yielding

### sleep

Suspend the current coroutine for a duration:

```zig
try rt.sleep(1000);  // Sleep for 1000 milliseconds (1 second)
```

### yield

Voluntarily give up the CPU to allow other tasks to run:

```zig
try rt.yield();
```

## Thread Pool

For CPU-intensive or blocking operations (like synchronous file I/O on some platforms), use the thread pool:

```zig
// Enable thread pool during init
const rt = try zio.Runtime.init(allocator, .{
    .thread_pool = .{ .enabled = true },
});

// Spawn blocking work
fn blockingWork(data: []const u8) !void {
    // CPU-intensive or blocking operation
}

// This runs on a thread pool thread, not a coroutine
// (API details depend on implementation)
```

## Error Handling

Tasks can return errors. The runtime propagates them:

```zig
fn failingTask(rt: *zio.Runtime) !void {
    return error.SomethingWrong;
}

var task = try rt.spawn(failingTask, .{rt}, .{});
defer task.deinit();

// join() propagates the error
task.join(rt) catch |err| {
    std.log.err("Task failed: {}", .{err});
};
```

## Best Practices

### 1. One Runtime per Application

Create a single runtime at the start of your program:

```zig
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const rt = try zio.Runtime.init(gpa.allocator(), .{});
    defer rt.deinit();

    try rt.runUntilComplete(mainTask, .{rt}, .{});
}
```

### 2. Pass Runtime as First Argument

By convention, pass `rt: *zio.Runtime` as the first parameter:

```zig
fn myTask(rt: *zio.Runtime, arg1: u32, arg2: []const u8) !void {
    // ...
}
```

### 3. Use defer for Cleanup

Always defer task cleanup:

```zig
var task = try rt.spawn(worker, .{rt}, .{});
defer task.deinit();
```

### 4. Keep Stacks Small

Default stack size (64 KB) is usually enough. Only increase if you have deep recursion or large stack variables.

### 5. Spawn Liberally

Coroutines are lightweight! Don't be afraid to spawn thousands of tasks.

## Next Steps

- [Networking](networking.md) - Use async I/O for network operations
- [File I/O](file-io.md) - Read and write files asynchronously
