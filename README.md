This is the beginning phrase of a new event loop for [zio](https://github.com/lalinsky/zio). It's a completion-based system, similar to [libxev](https://github.com/mitchellh/libxev), but with a few implementation differences, to make it more optimized.

Features:
- Timers with immediate cancelation/reset (doesn't need to go through submission queue)
- First class support for cross-thread event notifications
- Avoiding syscalls in kqueue/epoll by leaving fds register and having automatic cleanup

Supported platforms:
- Linux (io_uring, epoll, poll)
- Windows (IOCP, poll)
- macOS (kqueue, poll)
- FreeBSD (kqueue, poll)
- NetBSD (kqueue, poll)

  
