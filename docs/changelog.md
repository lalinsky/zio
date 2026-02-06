# Changelog

All notable changes to this project will be documented in this file.

## [0.7.0] - 2026-02-06

### Added

- Added CI for 32-bit ARM/Thumb and RISC-V CPUs to make sure these don't break.

### Changed

- **BREAKING**: Removed `rt` parameter from most functions. It's no longer needed.
  You can now use `zio.spawn`, `zio.sleep`, or `zio.yield` instead of calling
  them as `rt` methods.
- Synchronization primitives like `Mutex`, `Condition` or `Channel` can be now used
  from any thread, outside of coroutines, or across multiple runtimes.
- `Dir` and `File` I/O operations can be now called from any thread and then will
  run regular blocking syscalls.
- Internal: Update our user-mode futex implemenentation to a global hash table,
  to allow it to be used from any thread.
- Internal: Replaced `std.Thread` synchronization primitives with custom OS wrappers.

## [0.6.0] - 2026-01-31

### Added

- Added support 32-bit ARM/Thumb and RISC-V CPUs
- Added `Pipe` to explicitly support streaming-only file descriptors (#267)
- Added `Socket` methods for configuring OS-level buffer sizes (#243)
- Added custom panic handler that fully extends stack before calling the default handler
- Added convenience `fromXxx()` methods to `Timeout`

### Changed

- All timeout parameters now accept `Timeout` instead of `Duration` (#238, #239)
- Increased default stack committment to 256KiB to avoid stack overflows in the default panic handler
- Internal refactoring to reduce memory usage and binary size

### Fixed

- Fixed possible race condition between `Channel.close` and task cancelation

## [0.5.1] - 2026-01-25

### Added

- Added `readVec` and `writeVec` methods to `Stream` (#236)
- Added custom panic handler to avoid stack overflow during panics (#237)

### Changed

- Made `ResetEvent.reset` idempotent (#235)

## [0.5.0] - 2026-01-24

This is a major release with many changes. It has been in development for a while, but I finally decided
to release it.

First of all, the codebase has been relicensed under the MIT license.

I replaced `libxev` with a custom I/O event loop, that has better cross-platform support,
natively supports multiple threads each running its own event loop, supports more filesystem operations,
consistent timer behavior across platforms, grouped operations, and more. This is avialable in `zio.ev` and
can be also used separately from the rest of the library. This switch was motivated by with Zig 0.16 which
removed a lot of lower-level I/O APIs, so it was hard to upgrade `libxev`, but in the end, I'm glad I did it.
The new event loop is more feature complete, more efficient, and more flexible.

The coroutine library has also been restructured, and it's now available in `zio.coro`.
I've added support for riscv64 and loongarch64 CPUs. Stack allocation has been completel rewritten,
it now properly allocates vitual memory from the operating system, marks guard pages and we also have
signal handlers for growing the virtual memory reservation on demand. Coroutines now start with 64KiB
of stack space, and grow dynamically as needed.

The `zio.select()` function has been completely rewritten, and now support comptime-based support
for waiting on things other than tasks. For example, you can use it to race two channel reads,
or add timeout support to any operation that doesn't handle timeouts natively.

There is now `zio.AutoCancel` for automatically cancelling the current task after a timeout.
This is useful when you want to call an arbitrary function that may take a long time to complete,
and you want to make sure it gets cancelled if it doesn't complete in a timely manner, for example,
in HTTP request handlers.

Many networking APIs now have direct timeout support. Additionally, in `zio.net.Stream.Reader` and
`zio.net.Stream.Writer`, you can call `setTimeout()` and it will make sure the underlaying 
`std.Io.Reader` or `std.Io.Writer` doesn't block for too long. This is similar to
POSIX socket read/write timeouts, but also supports absolute deadlines.

Many new APIs have been added, for compatibility with the future `std.Io` API.

Internally, I've done a lot of refactoring to prepare for a future scheduler replacement.
I've started with project with an event-loop-per-thread model, and I still think it's the better
approach for servers, but I'm slowly migrating to a hybrid model, where tasks primarily stick to
the thread they were created on, but also can be freely moved to other threads,
when it's beneficial for load balancing.

## [0.4.0] - 2025-10-25

### Added

- Extended runtime to support multiple threads/executors (not full work-stealing yet)
- Added `Signal` for listening to OS signals
- Added `Notify` and `Future(T)` synchronization primitives
- Added `select()` for waiting on multiple tasks

### Changed

- Added `zio.net.IpAddress` and `zio.net.UnixAddress`, matching the future `std.net` API
- Renamed `zio.TcpListener` to `zio.net.Server`
- Renamed `zio.TcpStream` to `zio.net.Stream`
- Renamed `zio.UdpSocket` to `zio.net.Socket` (`Socket` can be also as a low-level primitive)
- `join()` is now uncancelable, it will cancel the task if the parent task is cancelled
- `sleep()` now correctly propagates `error.Canceled`
- Internal refactoring to allow more objects (e.g. `ResetEvent`) to participate in `select()`

### Fixed

- IPv6 address truncatation in network operations

## [0.3.0] - 2025-10-16

### Added

- `Runtime.now()` for getting the current monotonic time in milliseconds
- `JoinHandle.cast()` for converting between compatible error sets
- Exported `Barrier` and `RefCounter` synchronization primitives

### Changed

- **BREAKING**: Renamed `Queue` to `Channel` with channel-style API
- **BREAKING**: `JoinHandle(T)` type parameter `T` now represents the full error union type, not just the success payload
- Updated to use `std.net.Address` directly
- Internal refactoring to prepare for future multi-threaded runtime support (executor separation, unified waiter lists, improved cancellation-safety)

### Fixed

- macOS crash in event loop (updated libxev with kqueue fixes)

## [0.2.0] - 2025-10-10

### Added

- Cancellation support for all task types with proper cleanup and error handling
- `Barrier` and `BroadcastChannel` synchronization primitives
- `Future(T)` object for task-less async operations
- Stack memory reuse and direct context switching for better performance
- Thread parking support for blocking operations

### Changed

- `JoinHandle(T)` type parameter `T` now represents only the success payload, errors are stored separately
- All async operations can now return `error.Canceled`
- Increased default stack size to 2MB on Windows due to inefficient filename handling in `std.os.windows`

### Fixed

- Windows TIB fields handling and shadow space allocation
- Socket I/O vectored operations and EOF translation
- Context switching clobber lists for x86_64 and aarch64

## [0.1.0] - 2025-10-05

Initial release.

[0.7.0]: https://github.com/lalinsky/zio/releases/tag/v0.7.0
[0.6.0]: https://github.com/lalinsky/zio/releases/tag/v0.6.0
[0.5.1]: https://github.com/lalinsky/zio/releases/tag/v0.5.1
[0.5.0]: https://github.com/lalinsky/zio/releases/tag/v0.5.0
[0.4.0]: https://github.com/lalinsky/zio/releases/tag/v0.4.0
[0.3.0]: https://github.com/lalinsky/zio/releases/tag/v0.3.0
[0.2.0]: https://github.com/lalinsky/zio/releases/tag/v0.2.0
[0.1.0]: https://github.com/lalinsky/zio/releases/tag/v0.1.0
