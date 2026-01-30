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

## Writing a TCP server


