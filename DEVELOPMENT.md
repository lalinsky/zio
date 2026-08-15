Code organization:
- Blocking API -> Event loop API -> OS-level wrappers
- In `src/os/` we have the OS-specific code, mostly wrappers around libc/WinAPI/syscalls,
  sometimes we try to abstract away the differences between platforms, but this is not always possible,
  and it gets messy in a few places
- In `src/ev/` we have the event loop implementation, with all the backends (epoll, kqueue, io_uring, etc.)
- In `src/coro/` we have the coroutine context switching and stack management
- In `src/runtime.zig` and `src/runtime/` we have the task scheduler and other runtime internals
- The rest of the code is implementing the higher-level APIs or the `std.Io` vtable

Logging and stderr:
- Library code logs with plain `std.log` (`common.log` is the `.zio`-scoped alias). Logging is
  task-aware: a log line from a task parks like any other I/O, and the user's `std.options.logFn`
  runs with the task context intact.
- Code that must not suspend runs inside a no-suspend region: `Executor.loopAdd`/`loopCancel`/
  `loopSetTimer` and `runtime.loopClearTimer` wrap the loop entry points, and `runtime.markCrashed`
  pins the crash path as one permanently. Inside a region (and on threads with no mounted task),
  waits block the thread instead of parking (`runtime.getWaitableTaskOrNull`), and stderr locking
  never waits on a lock a parked task can hold (#661). `runtime.beginNoSuspend`/`endNoSuspend` are
  for scheduler code that writes to stderr outside those wrappers, and are not exported from `zio`:
  ordinary code, including anything that logs from a task, needs none of this. They must be paired
  on one thread with no suspension point in between -- the depth lives on the `Executor`, so a task
  that suspends mid-region unbalances two of them and nothing detects it.
- The stderr locks and writers live in `src/stderr.zig` (user sink plus a scheduler fallback
  sink that no-suspend callers divert to only while a task holds the user lock); the `lockStderr`
  vtable shims are in `src/io.zig`.

Testing:
- Use `./check.sh` to format code, run unit tests
- Use `./check.sh --filter "test name"` to run specific tests
- Use `./check.sh --target x86_64-windows --wine` to cross-compile and test via Wine
- Use `./check.sh --target riscv64-linux --qemu` to cross-compile and test via QEMU
- Use `./check.sh --full` to build all tests, but also build examples (at least once before creating a PR)

Random notes on Zig usage:
- We are using Zig 0.16+, so modules like `std.posix`, `std.Thread`, `std.fs`, `std.net` no longer exist or are mostly empty, look at `src/os/` for replacements.
- Use `zig env` to get the path to the Zig standard library and read the source code, if you need to check something.
- Code that is written a certain way only because it has to work with the Zig 0.16 standard library is marked with a `TODO(zig-0.17):` comment saying what to do instead. Grep for it when porting the `zig-0.17` branch.

LLM usage:
- We explicitly allow using LLMs for code changes, but:
   1. You don't delegate thinking to the LLM, you need to design/architect the solution and be able to reason about it
   2. You need to fully understand every single line of the code
- LLM-generated submitted PRs, where it's clear the author does not understand the code, will be silently closd

Release process:
1. Update docs/changelog.md - change [Unreleased] to [X.Y.Z] with current date
2. Update version in build.zig.zon
3. Update README.md and docs/getting-started.md to reference vX.Y.Z in `zig fetch --save` command
4. Commit files with message "Release vX.Y.Z"
5. Tag the commit with vX.Y.Z
6. Push commit and tags: `git push && git push --tags`
7. Create GitHub release: `gh release create vX.Y.Z --title "vX.Y.Z" --notes "<changelog content>"`
