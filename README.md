Low-level library for implementing stackful coroutines for Zig.

Tested on Linux, FreeBSD, NetBSD, macOS and Windows.

Features:
 - context switching on x86_64/aarch64/riscv64 architectures
 - allocating stacks on virtual memory with proper stack guard pages
 - automatic stack growth within the reserved virtual memory space
    * automatically handled by Windows
    * custom SIGSEGV handlers on POSIX _TBD_)
 - stacks are registered with Valgrind in debug mode
 
