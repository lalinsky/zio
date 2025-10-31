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

## Results

Tasks can have results, you should use the [`join()`](/zio/apidocs/#zio.runtime.Runtime.spawn) method to wait on the task to complete and get the result:

```
fn sum(a: i32, b: i32) i32 {
    return a + b;
}

const task = try rt.spawn(sum, .{ 1, 2 }, .{});
const result = rt.join();

std.debug.assert(result == 3);
```

## Cancellation

Tasks can be cancelled using the [`cancel()`](/zio/apidocs/#zio.runtime.JoinHandle.cancel) method:

```zig
task.cancel();
```

When a task is cancelled:
- The task will be interrupted at the next suspension point (e.g., when it waits for I/O)
- Operations in the cancelled task will return `error.Canceled`
- You should handle cancellation errors appropriately in your task code

Example:

```zig
fn myTask(allocator: std.mem.Allocator, stream: zio.net.Stream) !void {
    defer stream.close();

    const buf = try allocator.alloc(u8, 1024);
    defer allocator.free(buf);

    while (true) {
        // This will return error.Canceled if the task is cancelled
        const n = try stream.read(buf);
        try processData(buf[0..n]);
    }
}

var task = try rt.spawn(myTask, .{ allocator, stream }, .{});

// Later, cancel the task
task.cancel();
```

When you receive `error.Canceled` in your task code, you should handle it appropriately
and *always* propage it. In most cases, you can just use `try` and it will do the right thing,
assuming you use `defer` and `errdefer` to handle cleanup of resources.

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
