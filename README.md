Low-level library for implementing stackful coroutines for Zig.

Tested on Linux, FreeBSD, NetBSD, macOS and Windows.

Features:
 - context switching on x86_64/aarch64/riscv64 architectures via custom assembly
 - allocating stacks on virtual memory with proper stack guard pages
 - growable stacks within the reserved virtual memory space
    * automatic on Windows
    * opt-in on Linux, FreeBSD, NetBSD and macOS (uses custom SIGSEGV/SIGBUS handler)
 - stacks registered with Valgrind in debug mode
 

