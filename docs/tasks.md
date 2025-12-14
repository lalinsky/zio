# Tasks

You would not get much benefit from asynchronous I/O if you only perform one operation at a time.
You need to introduce concurrency into your program in order to get the most out of it,
and that is traditionally not an easy problem to solve.

Zio does this through tasks, they are the fundamental building block for concurrency.
Tasks are what other platforms call stackful coroutines, virtual threads, or fibers.
They suspend while waiting on I/O or other operations, allowing other tasks to run on the same CPU thread.
Because tasks suspend/resume as needed, it allows you to write concurrent code in a clear, sequential style.

You can run thousands of tasks on a single CPU thread, they will still run concurrently, just not in parallel.
If you configure the runtime, you can also run tasks on multiple CPU threads, allowing for parallelism.

## Running Tasks

Tasks are created using the [`spawn()`](/zio/apidocs/#zio.runtime.Runtime.spawn) method on the runtime. The basic syntax is:

```zig
var task = try rt.spawn(taskFunction, .{ arg1, arg2 });
```

The `spawn()` method takes three parameters:

1. A function to run as a task
2. A tuple of arguments to pass to the function
3. Options for configuring the task (like stack size)

The task function should have a signature that matches the arguments you pass:

```zig
fn taskFunction(arg1: TypeA, arg2: TypeB) void {
    // Your task code here
}
```

You should use [`join()`](/zio/apidocs/#zio.runtime.JoinHandle.join) to wait on the task to complete. This releases the resources associated with the task.

In the simplest case, you would do something like this:

```zig
var task = try rt.spawn(myTask);
task.join();
```

Your task can also have result results and `join()` will return whatever value the task returned:

```zig
fn sum(a: i32, b: i32) i32 {
    return a + b;
}

const task = try rt.spawn(sum, .{ 1, 2 });
const result = rt.join(rt);

std.debug.assert(result == 3);
```

And lastly, tasks can return errors, for example:

```zig
fn divide(a: i32, b: i32) !i32 {
    if (b == 0) return error.DivisionByZero;
    return a / b;
}

const task = try rt.spawn(divide, .{ 4, 2 });
const result = try rt.join(rt); // using `try` here to catch the error

std.debug.assert(result == 2);
```

## Canceling Tasks

Tasks can be canceled using the [`cancel()`](/zio/apidocs/#zio.runtime.JoinHandle.cancel) method:

```zig
task.cancel();
```

When a task is canceled:

- The task will be interrupted at the next suspension point (e.g., when it waits for I/O)
- Operations in the canceled task will return `error.Canceled`
- You should handle the `error.Canceled` error appropriately in your task code and *always* propage it

Example:

```zig
fn myTask(rt: *zio.Runtime, stream: zio.net.Stream) !void {
    // The stream will get closed even if the task is canceled
    defer stream.close(rt);

    const buf: [256]u8 = undefined;
    while (true) {
        // This will return error.Canceled if the task is canceled
        const n = try stream.read(rt, &buf);
        try processData(buf[0..n]);
    }
}

var task = try rt.spawn(myTask, .{ rt, stream });

// Later, cancel the task
task.cancel(rt);
```

You can safely call `cancel()` after successful `join()`, so this pattern becomes very common to clean up task resources:

```zig
var task = try rt.spawn(myTask, .{ rt, stream });
defer task.cancel(rt);

// Do some other work that can fail

var result = task.join(rt);
```

## Detaching Tasks

You can also start a task and let it run in the background. This is useful, for example, if you hava a server and want
to handle each connection in a separate task. You can do this using the [`detach()`](/zio/apidocs/#zio.runtime.JoinHandle.detach) method:

```zig
var task = try rt.spawn(connectionHandler, .{ rt, stream });
task.detach(rt);
```

After calling `detach()`, you should no longer do anything with the task.

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
