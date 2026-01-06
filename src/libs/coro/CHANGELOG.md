# Changelog

## [0.1.0] - 2026-01-05

Initial release.

### Features

- Context switching on x86_64/aarch64/riscv64/loongarch64 architectures via custom assembly
- Allocating stacks on virtual memory with proper stack guard pages
- Growable stacks within the reserved virtual memory space
  - Automatic on Windows
  - Opt-in on Linux, FreeBSD, NetBSD and macOS (uses custom SIGSEGV/SIGBUS handler)
- Stacks registered with Valgrind in debug mode
- Tested on Linux, FreeBSD, NetBSD, macOS and Windows
