# FAQ

## How is this different from other Zig async I/O projects?

There are many projects implementing stackful coroutines for Zig, unfortunately they are all missing something. The closest one to complete is [Tardy](https://github.com/tardy-org/tardy). Unfortunately, I didn't know about it when I started this project. However, even Tardy is missing many things that I wanted, like spawning non-cooperative tasks in a separate thread pool and being able to wait on their results from coroutines, more advanced synchronization primitives and Windows support. I wanted to start from an existing cross-platform event loop, originally [libuv](https://libuv.org/), later switched to [libxev](https://github.com/mitchellh/libxev), and just add coroutine runtime on top of that.

## How is this different from the future `std.Io` interface in Zig?

When I realized that the Zig team is working on the `std.Io` interface, I was questioning whether to continue working on this project, because there is a huge overlap. I still wanted something I can use now, instead of waiting and there are still things I'd be missing from `std.Io`, most specifically the ability to run tasks from a separate thread pool and wait on them from a coroutine, but also more control over task cancelation, and some more advanced synchronization primitives that are hard to implement without access to the event loop internals. I decided to continue with this project and when the interface is released, Zio will become one implementation of it.
