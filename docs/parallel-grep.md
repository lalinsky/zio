# Parallel Grep

Now that you have seen how to build servers, let's take a step back from networking and focus on core concurrency primitives. In this chapter, we'll explore:

- **Channels** - ZIO's primary mechanism for communicating between tasks
- **Worker pools** - distributing work across multiple concurrent tasks
- **File I/O** - reading files asynchronously
- **Multi-threaded execution** - running tasks across multiple CPU cores

We'll build a parallel grep tool that searches for patterns in multiple files concurrently, using a worker pool pattern with channels to coordinate the work.

## The Code

Replace the contents of `src/main.zig` with this:

```zig
--8<-- "examples/parallel_grep.zig"
```

Now build and run it:

```sh
$ zig build run -- "TODO" src/*.zig
info: Worker 0 searching src/main.zig
info: Worker 1 searching src/root.zig
src/main.zig:42: // TODO: Add error handling
src/root.zig:15: // TODO: Implement feature
info: Worker 0 exiting
info: Worker 1 exiting
info: Search complete.
```

## How It Works

This program uses a worker pool pattern with channels to distribute file searching across multiple tasks. It consists of three types of tasks: the main coordinator, worker tasks, and a collector task.

### Multi-threaded Runtime

First, notice how we initialize the runtime:

```zig
var rt = try zio.Runtime.init(gpa, .{ .executors = .auto });
```

The `.executors = .auto` option tells ZIO to create one executor (OS thread) per CPU core. This means our tasks can truly run in parallel across multiple cores, not just concurrently on a single core.

In the previous examples, we didn't specify this option, so the runtime defaulted to a single executor. That was fine for I/O-bound network servers where tasks spend most of their time waiting. But for this CPU-bound workload (searching file contents), using multiple cores gives us real parallelism.

### Channels

Before we dive into the tasks, let's understand the communication mechanism:

```zig
--8<-- "examples/parallel_grep.zig:channels"
```

A [`Channel`](../apidocs/#zio.Channel) is a typed queue for passing messages between tasks. Channels can be:

- **Buffered** (like `work_channel` with 16 slots) - [`send()`](../apidocs/#zio.Channel.send) blocks only when the buffer is full
- **Unbuffered** (like `results_channel` with empty slice) - [`send()`](../apidocs/#zio.Channel.send) blocks until a receiver calls [`receive()`](../apidocs/#zio.Channel.receive)

Channels provide a safe way to communicate between concurrent tasks without shared memory or locks.

### Worker Pool

The program spawns 4 worker tasks that process files from a shared queue:

```zig
--8<-- "examples/parallel_grep.zig:spawn_workers"
```

Each worker runs this loop:

```zig
--8<-- "examples/parallel_grep.zig:worker"
```

The worker:

1. Receives a file path from `work_channel`
2. When the channel is closed, the worker exits gracefully
3. Searches the file for the pattern
4. Sends any matches to `results_channel`
5. Repeats until the work queue is exhausted

### The Collector Task

A separate task collects and prints results:

```zig
--8<-- "examples/parallel_grep.zig:collector"
```

The collector runs in its own task to avoid blocking workers. It creates the stdout writer once before the loop, then receives results, prints them, and frees the memory allocated by workers. This demonstrates how ownership can be transferred between tasks through channels.

### Coordinating the Work

The main function orchestrates everything:

```zig
--8<-- "examples/parallel_grep.zig:coordination"
```

This shutdown sequence is important:

1. Send all file paths to workers
2. Close `work_channel` - workers will exit when they drain the queue
3. Wait for workers to finish - ensures all results are sent
4. Close `results_channel` - signals collector to exit
5. Wait for collector to finish - ensures all output is printed

This is a graceful shutdown that ensures no work is lost and all tasks clean up properly.

### Memory Management

Notice how memory flows through the system:

```zig
// In searchFile (called by workers)
const result = SearchResult{
    .file_path = path,
    .line_number = line_number,
    .line = try gpa.dupe(u8, line),  // Allocate
};
errdefer gpa.free(result.line);  // Free if send fails
try results_channel.send(result);
```

```zig
// In collector
const result = results_channel.receive() catch ...
// ... print result ...
gpa.free(result.line);  // Free
```

The worker allocates memory for each matching line, sends ownership through the channel, and the collector frees it. Channels ensure this transfer is safe - there's no risk of use-after-free or double-free.

## Key Concepts

### Multi-threaded Execution

ZIO's runtime can use multiple OS threads (executors) to run tasks in parallel:

- `.executors = .auto` - auto-detect based on CPU count (good for CPU-bound work)
- `.executors = .exact(1)` - single-threaded (default, good for I/O-bound work)
- `.executors = .exact(N)` - explicit number of threads

Tasks are automatically distributed across executors. Channels handle synchronization, so you don't need locks or atomic operations - just send and receive messages safely between tasks.

For I/O-bound workloads (like web servers), a single executor is often sufficient since tasks spend most of their time waiting. For CPU-bound workloads (like file processing, data analysis, or computation), multiple executors let you use all available CPU cores.

### Channels

Channels are the primary way to communicate between tasks in ZIO. They provide:

- **Type safety** - channels are typed, so you can only send/receive values of the declared type
- **Blocking semantics** - [`send()`](../apidocs/#zio.Channel.send) and [`receive()`](../apidocs/#zio.Channel.receive) suspend the task when the operation can't complete immediately
- **Graceful closure** - closed channels return `error.ChannelClosed` to signal no more data will be sent

Use buffered channels when you want to decouple producers and consumers, allowing bursts of work. Use unbuffered channels when you want direct handoff between tasks.

### Worker Pools

The worker pool pattern is useful when you have:

- A queue of independent work items
- Tasks that can process items in parallel
- A fixed number of workers to limit resource usage

In our example, the 4 workers share the work queue, automatically load-balancing. If one worker gets a large file, others keep processing smaller files.

### Graceful Shutdown

The shutdown sequence demonstrates structured concurrency with channels:

1. Close the work channel - tells workers "no more work is coming"
2. Wait for workers - ensures they finish processing what they have
3. Close the results channel - tells collector "no more results are coming"
4. Wait for collector - ensures it finishes printing

This pattern prevents data loss and ensures clean shutdown, even with complex task dependencies.

### Comparing Concurrency Patterns

- **Previous examples (TCP/HTTP servers):** Tasks are created per client and live until the connection closes
- **This example (parallel grep):** Tasks are created upfront and share work through channels

Both patterns have their uses. Use per-client tasks when each client has its own long-lived state. Use worker pools when you have many small, independent work items to process.
