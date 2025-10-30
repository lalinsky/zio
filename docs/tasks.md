# Tasks

## Introduction

You will not get much benefit from asynchronous I/O if you can only perform one operation at a time.
You need to introduce concurrency into your program, and that is traditionally not an easy problem to solve.

In Zio, tasks are the fundamental building block for concurrency. Tasks are what other platforms call
stackful coroutines, user-space threads, virtual threads, or fibers. They suspend while waiting on I/O
or other operations, allowing other tasks to run on the same CPU thread. And if configured to do so,
tasks can migrate between CPU threads, allowing for parallelism.

Because tasks suspend/resume as needed, it allows you to write concurrent code in a clear, sequential style.

## Stack Size

Unlike goroutines in Go or virtual threads in Java, tasks in Zio have a fixed stack size. This is a big limitation,
coming from the fact that Zig is a language with manual memory management. 
You need to be careful about your stack usage. If you use overflow the allocated stack space, 
your application will simply crash.

The default stack size is 256 KiB, but you can configure it to be larger or smaller, depending on your needs:

```zig
var task = rt.spawn(taskFn, .{ arg1, arg2 }, .{ .stack_size = 1024 * 1024 });
```

Zig developers have plans to introduce more control over allowed stack use of functions,
which would eliminate stack overflows, but for now, you need to be careful.
