Completion-based I/O event loop for Zig.

This is a low-level library, intended to be used as part of [zio](https://github.com/lalinsky/zio) or a similar runtime.

Supports Linux (io_uring/epoll/poll), FreeBSD (kqueue/poll), NetBSD (kqueue/poll), macOS (kqueue/poll) and Windows (iocp/poll).

Features:
- Socket operations: `net_open`, `net_close`, `net_bind`, `net_listen`, `net_accept`, `net_connect`, `net_send`, `net_recv`, `net_sendto`, `net_recvfrom`, `net_poll`
- File operations: `file_open`, `file_close`, `file_read`, `file_write`, `file_sync`, `file_rename`, `file_delete`, `file_size`
- Timers: `timer`
- Cancelation: `cancel`
- Cross-thread notifications: `async`
- Auxiliary thread pool for blocking tasks: `work`
