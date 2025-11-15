# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Added `Channel.asyncSend()`, `Channel.asyncReceive()` and `BroadcastChannel.asyncReceive()` methods for using channels in `select()`
- Added support for `Signal` to be used in `select()`

### Changed

- Updated to Zig 0.15.2 (minimum required version)
- `select()` and `wait()` now require futures to be passed as pointers (use `&future` instead of `future`)
- Channel methods `isEmpty()`, `isFull()`, `tryReceive()`, `trySend()`, and `close()` no longer require a `*Runtime` parameter
- `JoinHandle.deinit()` is now `JoinHandle.detach()`
- `JoinHandle.cancel()` now waits for the task to complete, after requesting cancellation
- `JoinHandle` methods `join()`, `cancel()`, and `detach()` now all requires a `*Runtime` parameter
- Replaced `Socket.setOption()` with specific methods: `setReuseAddress()`, `setReusePort()`, `setKeepAlive()`, and `setNoDelay()`

### Fixed

- Fixed EOF handling in socket read that got broken after refactoring in 0.4.0

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

[0.4.0]: https://github.com/lalinsky/zio/releases/tag/v0.4.0
[0.3.0]: https://github.com/lalinsky/zio/releases/tag/v0.3.0
[0.2.0]: https://github.com/lalinsky/zio/releases/tag/v0.2.0
[0.1.0]: https://github.com/lalinsky/zio/releases/tag/v0.1.0
