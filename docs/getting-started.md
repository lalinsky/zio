# Getting Started

This guide will help you get started with ZIO in a new Zig project.

We will start completely from scratch, so you will just need to have Zig 0.15 installed. See the [Zig installation guide](https://ziglang.org/learn/getting-started/) for more information on that.

## Setup

Let's create a new Zig project:

```sh
$ zig init
info: created build.zig
info: created build.zig.zon
info: created src/main.zig
info: created src/root.zig
info: see `zig build --help` for a menu of options
```

Then add ZIO as a dependency to the project:

```sh
$ zig fetch --save "git+https://github.com/lalinsky/zio#v0.8.2"
info: resolved to commit 0000000000000000000000000000000000000000
```

Now open `build.zig` and add these lines after the `exe` definition:

```zig
const zio = b.dependency("zio", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("zio", zio.module("zio"));
```

## Hello World

Let's start with a classic "Hello, world!" program.

Put this into `src/main.zig`:

```zig
--8<-- "examples/hello_world.zig"
```

Now let's run it:

```sh
$ zig build run
Hello, world!
```

This example is a simple program that prints "Hello, world!" to the console.
It shows how to initialize the runtime, access stdout, and write to it using the [`std.Io.Writer`](https://ziglang.org/documentation/0.15.2/std/#std.Io.Writer) interface.

The code looks simple, but when you call [`writeAll()`](https://ziglang.org/documentation/0.15.2/std/#std.Io.Writer.writeAll), it will actually
submit a write operation to the event loop, and suspend the current task
until the operation is complete, so the execution model behind it is more
complex than it seems.

On its own, this is not very useful, possibly even wasteful, but once you
start doing more things concurrently, this pattern will become very useful.
The complexity happens under the hood, so you don't have to worry about it.
