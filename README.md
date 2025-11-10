Completion-based I/O event loop for Zig.

This is a low-level library, intended to be used as part of [ZIO](https://github.com/lalinsky/zio) or a similar runtime, not on its own.

Supports Linux (io_uring/epoll/poll), FreeBSD (kqueue/poll), NetBSD (kqueue/poll), macOS (kqueue/poll) and Windows (poll).

Features:
- Socket operations: `net_open`, `net_close`, `net_send`, `net_recv`, `net_sendto`, `net_recvfrom`
- File operation: `file_open`, `file_close`, `file_read`, `file_write`
- Timers: `timer`
- Cancelation: `cancel`
- Cross-thread notifications: `async`
- Auxiliary thread pool for blocking tasks: `work`
