# Getting Started

OK, so you want to use ZIO for your Zig project. Let's get started!

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

Now we add ZIO as a dependency to the project:

```sh
$ zig fetch --save git+https://github.com/lalinsky/zio
info: resolved to commit f4c56e3e7b7b9abd7360473d8af3ee55edcc9957
```

## Hello World

Let's start with a classic "Hello, world!" program.

Put this into `src/main.zig`:

```zig
--8<-- "examples/hello_world.zig"
```

This example is a simple program that prints "Hello, world!" to the console.
It shows how to initialize the runtime, and access the stdout stream and 
write to it using the `std.Io.Writer` interface.

The code looks simple, but when you call `writeAll()`, it will actually
submit a write operation to the event loop, and suspend the current task
until the operation is complete, so the execution model behind it is more
complex than it seems.

On its own, this is not very useful, possibly even wasteful, but once you
starting doing more things concurrently, this pattern will become very useful.
And the fact that it's happening in the background means you don't really
have to worry about it.
