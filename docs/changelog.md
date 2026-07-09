# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

- Blocking operations running on thread-pool workers are now cancelable. Previously,
  canceling a task stuck in a blocking syscall had to wait for the syscall to finish;
  now the worker is interrupted with `SIGURG` and the operation returns `error.Canceled`.
  This covers `blockInPlace` and all file/directory operations that are delegated to the
  thread pool on backends without native async file I/O (kqueue, poll), including
  path-based metadata operations and directory reads. `getaddrinfo` itself cannot be
  interrupted, but a cancelation requested while the lookup was still queued is now
  honored before it starts. On Windows/WASI this degrades gracefully: queued-but-not-started
  work can still be canceled, in-progress syscalls run to completion as before.

- Added a `direct` flag to `FileOpenFlags`/`FileCreateFlags` for direct I/O, bypassing
  the OS page cache (`O_DIRECT` on Linux, `fcntl(F_NOCACHE)` on macOS,
  `FILE_FLAG_NO_BUFFERING` on Windows). The caller is responsible for meeting the
  platform's alignment requirements for buffers, offsets and transfer lengths.

- Added `Dir.iterate()` for native directory iteration, returning entry names and file
  kinds. The directory must be opened with `.iterate = true`.

- Added `Dir.deleteTree()` for recursively deleting a file or directory tree, ported
  from `std.Io.Dir`. Symlinks are removed, not followed. There is also
  `Dir.deleteTreeMinStackSize()`, a slower variant that keeps only one directory
  iterator open at a time to minimize memory usage.

- `Group` can now be used with `zio.select()` and `zio.wait()`. The group completes
  when its pending-task counter drains to zero. Unlike `Group.wait()`, this does not
  close the group and does not participate in fail-fast handling, so you can race a
  group against other futures and keep using it afterwards.

- Added a top-level `zio.maybeYield()`, a cheap fairness check for long CPU-bound
  loops: it yields only when enough other tasks are waiting on the current executor,
  and is a no-op when called from a thread without an executor.

- The io_uring backend now shares one kernel async worker pool across all executor
  rings via `IORING_SETUP_ATTACH_WQ`, instead of each ring creating its own.

- Task migration support can now be compiled out with the `task-migration` build option
  (default on). `RuntimeOptions.enable_task_migration` now defaults to whether support
  is compiled in, and enabling it at runtime in a build without support fails at init
  with `error.TaskMigrationNotCompiledIn`. Compiling it out removes the atomics that
  only exist to support cross-thread task movement.

- Replaced the per-executor run queue with a fixed-size ring buffer modeled on the
  local run queues in Go and Tokio, spilling into a shared overflow queue when full.
  This is the first phase of work-stealing; no stealing happens yet.

- `RuntimeOptions.executors = .auto` now honors the CPU limit of the current cgroup
  on Linux, in addition to the CPU affinity mask. Container CPU limits (Docker
  `--cpus`, Kubernetes `resources.limits.cpu`) and systemd `CPUQuota=` are enforced
  via the CFS bandwidth controller, which is invisible to `sched_getaffinity()`.
  Without this, `.auto` would size the executor pool to the host's CPU count and get
  throttled by the scheduler. The effective count is now `min(affinity, ceil(quota/period))`,
  mirroring Go's container-aware `GOMAXPROCS` default.

- Reduced locking in the event loop's timer processing: ticks with no due timers now
  skip the timer mutex entirely, and futex waits without a timeout skip the timer
  setup and one bucket-lock acquisition per wait.

- Fixed the coroutine context switch to clobber vector registers (`xmm`/`ymm` on
  x86_64, NEON on aarch64, RVV on riscv, LSX/LASX on loongarch64). The clobber lists
  only named the widest registers (e.g. `zmm` on x86_64), relying on them aliasing
  the narrower ones, but when the target CPU lacks the feature (e.g. AVX-512),
  LLVM silently drops such clobbers instead of applying them to the aliased
  registers. The compiler was then free to keep a vector value live across a
  context switch and read back another task's data. This surfaced on Windows, where
  the calling convention keeps values in callee-saved `xmm` registers.

- Fixed possible stack corruption in the IOCP backend on Windows. Overlapped I/O
  submissions passed the kernel pointers to stack-local out-parameters, which the
  kernel writes at completion time, after the submitting frame is gone. The
  out-parameters now live next to the `OVERLAPPED` for the whole operation.

- Fixed `File.setSize` on the io_uring backend with kernels older than 6.9, where
  `IORING_OP_FTRUNCATE` is not available. The opcode is now probed once at startup
  and older kernels transparently fall back to the thread pool.

- Fixed panic messages not being printed when panicking from scheduler code or
  signal handlers with `debug_io` enabled. I/O performed outside of a task context
  now takes a blocking path instead of re-entering the event loop, which would
  previously abort before writing the message.

## [0.15.0] - 2026-07-02

- Overhaul of the `epoll` and `kqueue` backends, to make them comparable to the performance of
  the io_uring backend. When migrating from libxev to our own event loop, I decided to use
  a similar approach for both backends, which really goes against the nature of these APIs.
  With this new rewrite, both backends keep fds registered in the kernel, so readiness is
  always available. This results in far fewer syscalls, and overall better performance.
  One side effect is that now tasks that were running on executor A can be moved to
  executor B, if the event loop B is where the fd is registered.

- Improved performance of `net.Stream.Writer.sendFile` on all platforms. There is now
  a native zero-copy implementation for Windows using `TransmitFile`, and the generic
  fallback now uses the entire reader/writer buffers, so it's always faster than the
  read/write loop fallback implemented in `std.Io.Writer`.

- Added `File.stdReader`/`File.stdWriter` to wrap a zio-opened file as the concrete
  `std.Io.File.Reader`/`std.Io.File.Writer` types, so it works with `std.Io` APIs that
  require them (like `std.Io.Writer.sendFileAll`).

- Implemented wall-clock timers, so you can now sleep/timeout using the real-time clock and be
  woken up exactly on time, even if the clock is adjusted. This is natively supported on Linux,
  but needs more careful coordination on other platforms.

- Added support for all clocks that `std.Io` supports (`real`, `boot`, `awake`, and the
  `cpu_process`/`cpu_thread` CPU-time clocks), as well as querying their resolution.

- Changed how `stdin`/`stdout`/`stderr` are handled on Windows, to make sure we can work
  with these without blocking the event loop, since they are not open as `OVERLAPPED` handles.

- Changed the `io_uring` backend from futex-based wake ups to `eventfd`, which works much
  more reliably. The previous futex approach introduced wake up latency that I could not explain.

- Error code `ETIMEDOUT` is now mapped to `error.ConnectionTimedOut` for send/recv operations.
  We are not using kernel-level socket timeouts, but it seems that these error codes can still happen.

- New `TaskLocal` API for storing custom task-local data.

- Added custom `random` and `randomSecure` APIs for generating random numbers,
  to reduce dependency on `std.Io.Threaded`.

- Fixed handling of Unix socket addresses containing null bytes.

- Fixed race in cross-thread handling of `AcceptEx` calls on Windows.

- Fixed shutdown sequence to properly stop the thread pool before closing the event loop.

- Fixed memory leak that happens after spawning blocking tasks on the thread pool.

## [0.14.0] - 2026-06-08

### Added

- Implemented `sendFile` for `net.Stream.Writer` on all platforms, for now just using generic code
  that does concurrent reads and writes. Platorm-specific improvements for Linux, FreeBSD and Windows 
  will be added later.
- Added support for opening/creating files with `resolve_beneath` on Linux, macOS, and FreeBSD.
  By default, the operation will fail on platforms that don't support it. You can disable it
  using the `resolve_beneath_mode` build option.
- Implemented support for `renamePreserve` on macOS.
- Implemented file locking on all platforms.
- Added `zio.Mutex.Recursive` that works in both blocking and non-blocking contexts.
- Added support for `pub const std_options_debug_io = zio.debug_io` in your root module,
  for integration with `std.log`, `std.debug.print` and also the default `panic` handler.

### Changed

- Setting `max_threads = 0` in the thread pool options now disables the thread pool, executing
  blocking work inline on the calling thread (the same behavior as a single-threaded build).
- Re-enabled task migration by default, so for example unlocking mutex will schedule the blocked
  task waiting on the mutex on the same thread, avoiding cross-thread wake up.
- Streaming file reads/writes now auto-detect the file type and use the appropriate method
  for async operations. This only affects macOS/BSDs on Linux with the epoll backend.
  Regular file reads/writes are still going through the thread pool, but pipes can go through
  the event loop.

### Fixed

- Fixed cross-thread I/O cancelation on kqueue backend.
- Fixed internal I/O opertion accounting on the IOCP backend that could lead to integer underflow in multi-threaded mode.
- Fixed mapping of `ESPIPE` to `error.Unseekable` to help `std.Io.File.Reader` with mode detection.
- Fixed macOS-specific `deleteFile` error mapping, to return `error.IsDir` when the path is a directory.
- Fixed handling of `follow_symlinks`, `path_only`, and `allow_ctty` file open/create flags.

## [0.13.0] - 2026-05-31

### Added

- Built-in async DNS resolver on Linux (io_uring backend), replacing `getaddrinfo`. Reads `/etc/hosts`
  and `resolv.conf`, supports search domains, CNAME following, parallel A/AAAA queries, EDNS0,
  TCP fallback for large responses, response caching, and deduplication of concurrent identical
  lookups. Enabled by default on io_uring; opt-in via `RuntimeOptions.dns.custom_resolver`.
- `Runtime.initStatic` for stack-allocated or externally-owned `Runtime` instances that don't
  need a heap allocation.
- Single-threaded build support (`single_threaded = true`).

### Changed

- **BREAKING**: DNS lookup API changed from an iterator (`Result` with `next()` / `deinit()`) to a
  caller-supplied buffer (`lookup(&storage, options)` returning a count). Eliminates the allocation
  and the need to remember `deinit`.
- **BREAKING**: `BroadcastChannel.subscribe()` now returns a `Consumer` value instead of taking a
  pointer, and `unsubscribe()` is gone — consumers no longer need to be unregistered.
- `HostName` now accepts numeric IPv4 and IPv6 addresses in addition to DNS names.
- io_uring: when the submission queue is full, operations are queued internally and retried on the
  next loop iteration instead of failing the caller.
- Coroutine stacks are now periodically evicted from the pool when they exceed `max_age`, reclaiming
  virtual memory that would otherwise accumulate during idle periods.

## [0.12.1] - 2026-05-22

### Added

- Added sparc64 coroutine context switching (untested) (#398)

### Fixed

- Fixed io_uring event loop hanging when an I/O wait is registered while still single-threaded and executor threads are subsequently started (#402)

## [0.12.0] - 2026-05-19

### Added

- `std.Io`: batch operations now support concurrent execution and timeouts (#387, #388)

### Fixed

- Fixed possible deadlock in `RwLock.unlockShared` (#395)
- Fixed sockets not opened in non-blocking mode on the epoll backend (#392)
- Fixed integer overflow when using `.executors = .auto` on machines with 64+ CPUs (#390)
- Fixed coroutine stack allocation size doubling on POSIX (#386)

## [0.11.0] - 2026-05-11

### Added

- `std.Io` interface is now essentially complete. All major operations are implemented:
  - Spawn and wait on child processes, with non-blocking pipe I/O on POSIX.
  - Iterate over directory entries.
  - Create nested directory paths.
  - Create files atomically (write to temp file, then rename into place), with optional `make_path`
    and `replace` support.
  - Rename files without overwriting existing destinations.
  - Batch multiple file I/O operations for linear execution (concurrent execution is deferred).
- `Stream.Reader.fromStd` and `Stream.Writer.fromStd` convert `std.Io.net.Stream` to zio's buffered
  reader/writer, enabling seamless interop between zio and std networking in the same program.

### Changed

- `net.Stream.Reader` and `net.Stream.Writer` are now lighter, storing only the socket handle instead of
  the full stream.

### Fixed

- Fixed a critical bug on Linux with the epoll backend where non-blocking network reads and writes could
  silently succeed with garbage data instead of returning `error.WouldBlock`.

## [0.10.0] - 2026-04-26

### Added

- Support for Zig 0.16.
- Implementation of the `std.Io` interface. Supports fiber-based futures/groups, file and network operations.
  Still missing child process and batch operations. The rest of the codebase will be adjusted over time to align with `std.Io`
  to avoid some unnecessary type conversions.

### Changed

- `server.accept()` now takes options argument with timeout.

### Fixed

- Internal refactoring to handle data races on weakly ordered architectures in some cases.


## [0.9.0] - 2026-03-02

### Added

- Fully asynchronous DNS resolver on macOS and Windows using their native APIs.
- Added support for 64-bit PowerPC CPUs.
- Added `RwLock` for async readers-writer locking.
- Added `Timestamp.fromSeconds()` and `toSeconds()` for second-based conversions.
- Added `Timestamp.untilNow()` to get the duration elapsed since a timestamp.

### Changed

- Removed unused `JoinHandle.cast()` method.

### Fixed

- Fixed incorrect assert that could panic on a race between task finishing naturally and being cancelled.
- Added some extra clobbers to context switching asssembly, already implicitly covered by others, but for consistency.

## [0.8.2] - 2026-02-17

### Fixed

- Fixed dependency loop compilation error when using zio as a dependency module, by inlining `Work.WorkFn` and `Work.CompletionFn` type aliases.

## [0.8.1] - 2026-02-17

### Added

- Added `blockInPlace` for running blocking functions on the thread pool without allocations.
- Added `os.thread.yield()` for yielding to the kernel from OS-level threads.

### Changed

- Removed LIFO slot optimization in the coroutine scheduler, to simplify the code while planning to rework the scheduler.
- Added check that prevents coroutines from being called multiple times per one event loop iteration.
- Internal refactoring of our `WaitQueue` primitive, to better express the semantics we need for synchronization primitives like `Mutex` or `Condition`.
- Internal refactoring of our `Waiter` primitive, avoiding indirect function calls and more direct integration with `select`.

### Fixed

- Fixed error returned from `Group` task closing the group, even if not in fail-fast mode.

## [0.8.0] - 2026-02-09

### Added

- Added `CompletionQueue` for waiting on multiple I/O operations.
- Added blocking I/O support for socket, pipe, poll, timer, and work operations. These operations can now be called from any thread without an async runtime.

### Changed

- Improved our CI setup, run significanly more tests in multi-threaded mode to catch possible race conditions.

### Fixed

- Fixed task migration race condition that could cause crashes under heavy multi-threaded load.
- Fixed pipe read/write using wrong offset in io_uring backend.
- Fixed NetBSD test failures.

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

[0.14.0]: https://github.com/lalinsky/zio/releases/tag/v0.14.0
[0.13.0]: https://github.com/lalinsky/zio/releases/tag/v0.13.0
[0.12.1]: https://github.com/lalinsky/zio/releases/tag/v0.12.1
[0.12.0]: https://github.com/lalinsky/zio/releases/tag/v0.12.0
[0.11.0]: https://github.com/lalinsky/zio/releases/tag/v0.11.0
[0.10.0]: https://github.com/lalinsky/zio/releases/tag/v0.10.0
[0.9.0]: https://github.com/lalinsky/zio/releases/tag/v0.9.0
[0.8.2]: https://github.com/lalinsky/zio/releases/tag/v0.8.2
[0.8.1]: https://github.com/lalinsky/zio/releases/tag/v0.8.1
[0.8.0]: https://github.com/lalinsky/zio/releases/tag/v0.8.0
[0.7.0]: https://github.com/lalinsky/zio/releases/tag/v0.7.0
[0.6.0]: https://github.com/lalinsky/zio/releases/tag/v0.6.0
[0.5.1]: https://github.com/lalinsky/zio/releases/tag/v0.5.1
[0.5.0]: https://github.com/lalinsky/zio/releases/tag/v0.5.0
[0.4.0]: https://github.com/lalinsky/zio/releases/tag/v0.4.0
[0.3.0]: https://github.com/lalinsky/zio/releases/tag/v0.3.0
[0.2.0]: https://github.com/lalinsky/zio/releases/tag/v0.2.0
[0.1.0]: https://github.com/lalinsky/zio/releases/tag/v0.1.0
