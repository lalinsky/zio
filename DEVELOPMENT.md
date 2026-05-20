Code organization:
- Blocking API -> Event loop API -> OS-level wrappers
- In `src/os/` we have the OS-specific code, mostly wrappers around libc/WinAPI/syscalls,
  sometimes we try to abstract away the differences between platforms, but this is not always possible,
  and it gets messy in a few places
- In `src/ev/` we have the event loop implementation, with all the backends (epoll, kqueue, io_uring, etc.)
- In `src/coro/` we have the coroutine context switching and stack management
- In `src/runtime.zig` and `src/runtime/` we have the task scheduler and other runtime internals
- The rest of the code is implementing the higher-level APIs or the `std.Io` vtable

Testing:
- Use `./check.sh` to format code, run unit tests
- Use `./check.sh --filter "test name"` to run specific tests
- Use `./check.sh --target x86_64-windows --wine` to cross-compile and test via Wine
- Use `./check.sh --target riscv64-linux --qemu` to cross-compile and test via QEMU
- Use `./check.sh --full` to build all tests, but also build examples and benchmarks (at least once before creating a PR)

Random notes on Zig usage:
- We are using Zig 0.16+, so modules like `std.posix`, `std.Thread`, `std.fs`, `std.net` no longer exist or are mostly empty, look at `src/os/` for replacements.
- Use `zig env` to get the path to the Zig standard library and read the source code, if you need to check something.

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
