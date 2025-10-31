# Tasks

## Introduction

You would not get much benefit from asynchronous I/O if you only perform one operation at a time.
You need to introduce concurrency into your program in order to get the most out of it,
and that is traditionally not an easy problem to solve.

Zio does this through tasks, they are the fundamental building block for concurrency.
Tasks are what other platforms call stackful coroutines, virtual threads, or fibers.
They suspend while waiting on I/O or other operations, allowing other tasks to run on the same CPU thread.
Because tasks suspend/resume as needed, it allows you to write concurrent code in a clear, sequential style.

You can run thousands of tasks on a single CPU thread, they will still run concurrently, just not in parallel.
If you configure the runtime, you can also run tasks on multiple CPU threads, allowing for parallelism.

## Spawning

Tasks are created using the [`spawn`](/zio/apidocs/#zio.runtime.Runtime.spawn) method on the runtime. The basic syntax is:

```zig
var task = try rt.spawn(taskFunction, .{ arg1, arg2 }, .{});
```

The `spawn` method takes three parameters:
1. A function to run as a task
2. A tuple of arguments to pass to the function
3. Options for configuring the task (like stack size)

The task function should have a signature that matches the arguments you pass:

```zig
fn taskFunction(arg1: TypeA, arg2: TypeB) !void {
    // Your task code here
}
```

## JoinHandle and Lifecycle Management

When you spawn a task, you get a `JoinHandle` back. This handle allows you to interact with the spawned task - waiting for its result, canceling it, or detaching it to run in the background.

The `JoinHandle` is designed to be simple and safe to use:
- No manual cleanup needed (no `deinit()` method)
- All methods are idempotent - safe to call multiple times
- Internally caches the result after the first `join()` or `cancel()`
- Once detached or completed, all operations become no-ops

### Getting Results

Tasks can return results. Use the [`join()`](/zio/apidocs/#zio.runtime.JoinHandle.join) method to wait for the task to complete and get the result:

```zig
fn sum(a: i32, b: i32) i32 {
    return a + b;
}

var handle = try rt.spawn(sum, .{ 1, 2 }, .{});
const result = handle.join(rt);

std.debug.assert(result == 3);
```

The `join()` method waits for the task to complete, caches the result internally, and releases the task resources. Subsequent calls to `join()` will return the cached result without waiting.

### Cancellation

Tasks can be cancelled using the [`cancel()`](/zio/apidocs/#zio.runtime.JoinHandle.cancel) method. This requests cancellation and waits for the task to complete:

```zig
var handle = try rt.spawn(myTask, .{}, .{});
handle.cancel(rt);
```

The `cancel()` method:
- Requests cancellation of the task
- Waits for the task to complete
- Releases task resources
- Is safe to call after `join()` - it becomes a no-op if already completed

A common pattern is to use `cancel()` in a `defer` for cleanup:

```zig
var handle = try rt.spawn(myTask, .{}, .{});
defer handle.cancel(rt);

// Do some other work that could return early
const result = handle.join(rt);
// If join() completes, cancel() in defer is a no-op
```

When a task is cancelled:
- The task will be interrupted at the next suspension point (e.g., when it waits for I/O)
- Operations in the cancelled task will return `error.Canceled`
- You should handle cancellation errors appropriately in your task code

Example of a cancelable task:

```zig
fn myTask(rt: *zio.Runtime, stream: zio.net.Stream) !void {
    defer stream.close(rt);

    var buf: [1024]u8 = undefined;

    while (true) {
        // This will return error.Canceled if the task is cancelled
        const n = try stream.read(rt, &buf);
        try processData(buf[0..n]);
    }
}

var handle = try rt.spawn(myTask, .{ rt, stream }, .{});

// Later, cancel the task
handle.cancel(rt);
```

When you receive `error.Canceled` in your task code, you should handle it appropriately
and *always* propagate it. In most cases, you can just use `try` and it will do the right thing,
assuming you use `defer` and `errdefer` to handle cleanup of resources.

### Detaching Tasks

If you don't need to wait for a task's result or cancel it, you can detach it using the [`detach()`](/zio/apidocs/#zio.runtime.JoinHandle.detach) method. This allows the task to run independently in the background:

```zig
var handle = try rt.spawn(backgroundTask, .{}, .{});
handle.detach(rt); // Task runs independently
```

After detaching:
- The task continues running in the background
- You can no longer wait for its result or cancel it
- The handle can be discarded - no further cleanup needed
- The task's resources are freed when it completes

This is commonly used in server applications where you spawn a task for each connection:

```zig
fn serverTask(rt: *zio.Runtime) !void {
    const server = try addr.listen(rt, .{});
    defer server.close(rt);

    while (true) {
        const stream = try server.accept(rt);
        errdefer stream.close(rt);

        var handle = try rt.spawn(handleClient, .{ rt, stream }, .{});
        handle.detach(rt); // Let it run in the background
    }
}
```

### Lifecycle Patterns Summary

Here's a quick guide on which method to use:

**Use `join(rt)` when:**
- You need the task's result
- You want to wait for the task to complete before continuing

```zig
var handle = try rt.spawn(computeSum, .{ 1, 2 }, .{});
const result = handle.join(rt);
```

**Use `cancel(rt)` when:**
- You need to stop a task early
- You're cleaning up and want to ensure the task is stopped
- Best used with `defer` for cleanup

```zig
var handle = try rt.spawn(longRunningTask, .{}, .{});
defer handle.cancel(rt); // Ensures cleanup on early return
```

**Use `detach(rt)` when:**
- You don't need the result
- The task should run independently in the background
- Common for connection handlers in servers

```zig
var handle = try rt.spawn(handleConnection, .{stream}, .{});
handle.detach(rt); // Fire and forget
```

**Key insights:**
- All methods are idempotent - safe to call multiple times
- `join()` and `cancel()` cache the result, subsequent calls are no-ops
- `detach()` cannot be undone - once detached, you can't get the result
- No manual cleanup needed - no `deinit()` method exists

## Stack Size

Unlike goroutines in Go or virtual threads in Java, tasks in Zio have a fixed stack size. This is a big limitation,
coming from the fact that Zig is a language with manual memory management. 
You need to be careful about your stack usage. If you use overflow the allocated stack space, 
your application will simply crash.

The default stack size is 256 KiB, but you can configure it to be larger or smaller, depending on your needs:

```zig
var task = rt.spawn(myTask, .{}, .{ .stack_size = 1024 * 1024 });
```

Zig developers have plans to introduce more control over allowed stack use of functions,
which would eliminate stack overflows, but for now, you need to be careful.
