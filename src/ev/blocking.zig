// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

//! Blocking execution of I/O operations without event loop.
//!
//! This module provides synchronous execution of file, pipe, and socket operations
//! for use in non-async contexts (when there's no runtime/executor).

const std = @import("std");
const builtin = @import("builtin");
const Completion = @import("completion.zig").Completion;
const PipeClose = @import("completion.zig").PipeClose;
const PipeRead = @import("completion.zig").PipeRead;
const PipeWrite = @import("completion.zig").PipeWrite;
const NetClose = @import("completion.zig").NetClose;
const NetShutdown = @import("completion.zig").NetShutdown;
const NetRecv = @import("completion.zig").NetRecv;
const NetSend = @import("completion.zig").NetSend;
const NetRecvFrom = @import("completion.zig").NetRecvFrom;
const NetSendTo = @import("completion.zig").NetSendTo;
const NetRecvMsg = @import("completion.zig").NetRecvMsg;
const NetSendMsg = @import("completion.zig").NetSendMsg;
const NetOpen = @import("completion.zig").NetOpen;
const NetBind = @import("completion.zig").NetBind;
const NetListen = @import("completion.zig").NetListen;
const NetConnect = @import("completion.zig").NetConnect;
const NetAccept = @import("completion.zig").NetAccept;
const common = @import("backends/common.zig");
const fs = @import("../os/fs.zig");
const net = @import("../os/net.zig");

/// Execute a completion synchronously without an event loop.
/// This is used when there's no async runtime available.
///
/// Supports file, pipe, and socket operations (read/write use poll+I/O on POSIX).
/// Timer and async/work/group operations are not supported (require event loop).
pub fn executeBlocking(c: *Completion, allocator: std.mem.Allocator) void {
    // Mark completion as having no loop
    c.loop = null;

    switch (c.op) {
        .file_open => common.handleFileOpen(c, allocator),
        .file_create => common.handleFileCreate(c, allocator),
        .file_close => common.handleFileClose(c),
        .file_read => common.handleFileRead(c),
        .file_write => common.handleFileWrite(c),
        .file_sync => common.handleFileSync(c),
        .file_set_size => common.handleFileSetSize(c),
        .file_set_permissions => common.handleFileSetPermissions(c),
        .file_set_owner => common.handleFileSetOwner(c),
        .file_set_timestamps => common.handleFileSetTimestamps(c),
        .dir_create_dir => common.handleDirCreateDir(c, allocator),
        .dir_rename => common.handleDirRename(c, allocator),
        .dir_delete_file => common.handleDirDeleteFile(c, allocator),
        .dir_delete_dir => common.handleDirDeleteDir(c, allocator),
        .file_size => common.handleFileSize(c),
        .file_stat => common.handleFileStat(c, allocator),
        .dir_open => common.handleDirOpen(c, allocator),
        .dir_close => common.handleDirClose(c),
        .dir_set_permissions => common.handleDirSetPermissions(c),
        .dir_set_owner => common.handleDirSetOwner(c),
        .dir_set_file_permissions => common.handleDirSetFilePermissions(c, allocator),
        .dir_set_file_owner => common.handleDirSetFileOwner(c, allocator),
        .dir_set_file_timestamps => common.handleDirSetFileTimestamps(c, allocator),
        .dir_sym_link => common.handleDirSymLink(c, allocator),
        .dir_read_link => common.handleDirReadLink(c, allocator),
        .dir_hard_link => common.handleDirHardLink(c, allocator),
        .dir_access => common.handleDirAccess(c, allocator),
        .dir_real_path => common.handleDirRealPath(c),
        .dir_real_path_file => common.handleDirRealPathFile(c, allocator),
        .dir_read => common.handleDirRead(c),
        .file_real_path => common.handleFileRealPath(c),
        .file_hard_link => common.handleFileHardLink(c, allocator),

        // Pipe operations
        .pipe_create => handlePipeCreate(c),
        .pipe_close => handlePipeClose(c),
        .pipe_read => handlePipeRead(c),
        .pipe_write => handlePipeWrite(c),
        .pipe_poll => @panic("Pipe poll not supported in blocking mode (requires event loop)"),

        // Socket operations
        .net_open => common.handleNetOpen(c),
        .net_bind => common.handleNetBind(c),
        .net_close => handleNetClose(c),
        .net_shutdown => handleNetShutdown(c),
        .net_recv => handleNetRecv(c),
        .net_send => handleNetSend(c),
        .net_recvfrom => handleNetRecvFrom(c),
        .net_sendto => handleNetSendTo(c),
        .net_recvmsg => handleNetRecvMsg(c),
        .net_sendmsg => handleNetSendMsg(c),
        .net_listen => handleNetListen(c),
        .net_connect => handleNetConnect(c),
        .net_accept => handleNetAccept(c),

        // Network poll operation requiring event loop
        .net_poll => @panic("Network poll not supported in blocking mode (requires event loop)"),

        // Timer and async operations require the event loop
        .timer,
        .async,
        .work,
        .group,
        => @panic("Timer/async operations not supported in blocking mode (requires event loop)"),
    }
}

/// Poll for socket/pipe readiness with infinite timeout.
/// Returns error if polling fails.
/// Works on both POSIX and Windows platforms.
fn pollForReady(fd: net.fd_t, events: i16) !void {
    var pfd = [_]net.pollfd{.{
        .fd = fd,
        .events = events,
        .revents = 0,
    }};
    _ = try net.poll(&pfd, -1);
}

/// Helper to handle pipe create operation
fn handlePipeCreate(c: *Completion) void {
    if (fs.pipe()) |fds| {
        c.setResult(.pipe_create, fds);
    } else |err| {
        c.setError(err);
    }
}

/// Helper to handle pipe close operation
fn handlePipeClose(c: *Completion) void {
    const data = c.cast(PipeClose);
    if (fs.close(data.handle)) |_| {
        c.setResult(.pipe_close, {});
    } else |err| {
        c.setError(err);
    }
}

/// Helper to handle pipe read operation
fn handlePipeRead(c: *Completion) void {
    const data = c.cast(PipeRead);

    // Windows: blocking read, no poll needed
    if (builtin.os.tag == .windows) {
        if (fs.readv(data.handle, data.buffer.iovecs)) |bytes_read| {
            c.setResult(.pipe_read, bytes_read);
        } else |err| {
            c.setError(err);
        }
        return;
    }

    // POSIX: poll+read loop to handle race if multiple threads access same pipe
    while (true) {
        pollForReady(data.handle, net.POLL.IN) catch |err| {
            c.setError(err);
            return;
        };

        if (fs.readv(data.handle, data.buffer.iovecs)) |bytes_read| {
            c.setResult(.pipe_read, bytes_read);
            return;
        } else |err| switch (err) {
            error.WouldBlock => continue, // Another thread consumed data, retry
            else => {
                c.setError(err);
                return;
            },
        }
    }
}

/// Helper to handle pipe write operation
fn handlePipeWrite(c: *Completion) void {
    const data = c.cast(PipeWrite);

    // Windows: blocking write, no poll needed
    if (builtin.os.tag == .windows) {
        if (fs.writev(data.handle, data.buffer.iovecs)) |bytes_written| {
            c.setResult(.pipe_write, bytes_written);
        } else |err| {
            c.setError(err);
        }
        return;
    }

    // POSIX: poll+write loop to handle race if multiple threads access same pipe
    while (true) {
        pollForReady(data.handle, net.POLL.OUT) catch |err| {
            c.setError(err);
            return;
        };

        if (fs.writev(data.handle, data.buffer.iovecs)) |bytes_written| {
            c.setResult(.pipe_write, bytes_written);
            return;
        } else |err| switch (err) {
            error.WouldBlock => continue, // Another thread filled buffer, retry
            else => {
                c.setError(err);
                return;
            },
        }
    }
}

/// Helper to handle socket close operation
fn handleNetClose(c: *Completion) void {
    const data = c.cast(NetClose);
    net.close(data.handle);
    c.setResult(.net_close, {});
}

/// Helper to handle socket shutdown operation
fn handleNetShutdown(c: *Completion) void {
    const data = c.cast(NetShutdown);
    if (net.shutdown(data.handle, data.how)) |_| {
        c.setResult(.net_shutdown, {});
    } else |err| {
        c.setError(err);
    }
}

/// Helper to handle socket recv operation
fn handleNetRecv(c: *Completion) void {
    const data = c.cast(NetRecv);

    // Windows: blocking recv, no poll needed
    if (builtin.os.tag == .windows) {
        if (net.recv(data.handle, data.buffers.iovecs, data.flags)) |bytes_read| {
            c.setResult(.net_recv, bytes_read);
        } else |err| {
            c.setError(err);
        }
        return;
    }

    // POSIX: poll+recv loop to handle race if multiple threads access same socket
    while (true) {
        pollForReady(data.handle, net.POLL.IN) catch |err| {
            c.setError(err);
            return;
        };

        if (net.recv(data.handle, data.buffers.iovecs, data.flags)) |bytes_read| {
            c.setResult(.net_recv, bytes_read);
            return;
        } else |err| switch (err) {
            error.WouldBlock => continue, // Another thread consumed data, retry
            else => {
                c.setError(err);
                return;
            },
        }
    }
}

/// Helper to handle socket send operation
fn handleNetSend(c: *Completion) void {
    const data = c.cast(NetSend);

    // Windows: blocking send, no poll needed
    if (builtin.os.tag == .windows) {
        if (net.send(data.handle, data.buffer.iovecs, data.flags)) |bytes_written| {
            c.setResult(.net_send, bytes_written);
        } else |err| {
            c.setError(err);
        }
        return;
    }

    // POSIX: poll+send loop to handle race if multiple threads access same socket
    while (true) {
        pollForReady(data.handle, net.POLL.OUT) catch |err| {
            c.setError(err);
            return;
        };

        if (net.send(data.handle, data.buffer.iovecs, data.flags)) |bytes_written| {
            c.setResult(.net_send, bytes_written);
            return;
        } else |err| switch (err) {
            error.WouldBlock => continue, // Another thread filled buffer, retry
            else => {
                c.setError(err);
                return;
            },
        }
    }
}

/// Helper to handle socket recvfrom operation
fn handleNetRecvFrom(c: *Completion) void {
    const data = c.cast(NetRecvFrom);

    // Windows: blocking recvfrom, no poll needed
    if (builtin.os.tag == .windows) {
        if (net.recvfrom(data.handle, data.buffer.iovecs, data.flags, data.addr, data.addr_len)) |bytes_read| {
            c.setResult(.net_recvfrom, bytes_read);
        } else |err| {
            c.setError(err);
        }
        return;
    }

    // POSIX: poll+recvfrom loop to handle race if multiple threads access same socket
    while (true) {
        pollForReady(data.handle, net.POLL.IN) catch |err| {
            c.setError(err);
            return;
        };

        if (net.recvfrom(data.handle, data.buffer.iovecs, data.flags, data.addr, data.addr_len)) |bytes_read| {
            c.setResult(.net_recvfrom, bytes_read);
            return;
        } else |err| switch (err) {
            error.WouldBlock => continue, // Another thread consumed data, retry
            else => {
                c.setError(err);
                return;
            },
        }
    }
}

/// Helper to handle socket sendto operation
fn handleNetSendTo(c: *Completion) void {
    const data = c.cast(NetSendTo);

    // Windows: blocking sendto, no poll needed
    if (builtin.os.tag == .windows) {
        if (net.sendto(data.handle, data.buffer.iovecs, data.flags, data.addr, data.addr_len)) |bytes_written| {
            c.setResult(.net_sendto, bytes_written);
        } else |err| {
            c.setError(err);
        }
        return;
    }

    // POSIX: poll+sendto loop to handle race if multiple threads access same socket
    while (true) {
        pollForReady(data.handle, net.POLL.OUT) catch |err| {
            c.setError(err);
            return;
        };

        if (net.sendto(data.handle, data.buffer.iovecs, data.flags, data.addr, data.addr_len)) |bytes_written| {
            c.setResult(.net_sendto, bytes_written);
            return;
        } else |err| switch (err) {
            error.WouldBlock => continue, // Another thread filled buffer, retry
            else => {
                c.setError(err);
                return;
            },
        }
    }
}

/// Helper to handle socket recvmsg operation
fn handleNetRecvMsg(c: *Completion) void {
    const data = c.cast(NetRecvMsg);

    // Windows: blocking recvmsg (emulated in net layer), no poll needed
    if (builtin.os.tag == .windows) {
        if (net.recvmsg(data.handle, data.data.iovecs, data.flags, data.addr, data.addr_len, data.control)) |result| {
            c.setResult(.net_recvmsg, result);
        } else |err| {
            c.setError(err);
        }
        return;
    }

    // POSIX: poll+recvmsg loop to handle race if multiple threads access same socket
    while (true) {
        pollForReady(data.handle, net.POLL.IN) catch |err| {
            c.setError(err);
            return;
        };

        if (net.recvmsg(data.handle, data.data.iovecs, data.flags, data.addr, data.addr_len, data.control)) |result| {
            c.setResult(.net_recvmsg, result);
            return;
        } else |err| switch (err) {
            error.WouldBlock => continue, // Another thread consumed data, retry
            else => {
                c.setError(err);
                return;
            },
        }
    }
}

/// Helper to handle socket sendmsg operation
fn handleNetSendMsg(c: *Completion) void {
    const data = c.cast(NetSendMsg);

    // Windows: blocking sendmsg (emulated in net layer), no poll needed
    if (builtin.os.tag == .windows) {
        if (net.sendmsg(data.handle, data.data.iovecs, data.flags, data.addr, data.addr_len, data.control)) |bytes_written| {
            c.setResult(.net_sendmsg, bytes_written);
        } else |err| {
            c.setError(err);
        }
        return;
    }

    // POSIX: poll+sendmsg loop to handle race if multiple threads access same socket
    while (true) {
        pollForReady(data.handle, net.POLL.OUT) catch |err| {
            c.setError(err);
            return;
        };

        if (net.sendmsg(data.handle, data.data.iovecs, data.flags, data.addr, data.addr_len, data.control)) |bytes_written| {
            c.setResult(.net_sendmsg, bytes_written);
            return;
        } else |err| switch (err) {
            error.WouldBlock => continue, // Another thread filled buffer, retry
            else => {
                c.setError(err);
                return;
            },
        }
    }
}

/// Helper to handle socket listen operation
fn handleNetListen(c: *Completion) void {
    // Listen is synchronous - no polling needed
    common.handleNetListen(c);
}

/// Helper to handle socket connect operation
fn handleNetConnect(c: *Completion) void {
    const data = c.cast(NetConnect);

    // Try to connect first
    if (net.connect(data.handle, data.addr, data.addr_len)) |_| {
        c.setResult(.net_connect, {});
        return;
    } else |err| switch (err) {
        error.WouldBlock, error.ConnectionPending => {
            // Poll for write readiness to wait for connection to complete
            pollForReady(data.handle, net.POLL.OUT) catch |poll_err| {
                c.setError(poll_err);
                return;
            };

            // Check the actual connection result via SO_ERROR
            const sock_err = net.getSockError(data.handle) catch |sock_err| {
                c.setError(sock_err);
                return;
            };

            if (sock_err == 0) {
                c.setResult(.net_connect, {});
            } else {
                c.setError(net.errnoToConnectError(@enumFromInt(sock_err)));
            }
        },
        else => c.setError(err),
    }
}

/// Helper to handle socket accept operation
fn handleNetAccept(c: *Completion) void {
    const data = c.cast(NetAccept);

    // Windows: blocking accept, no poll needed
    if (builtin.os.tag == .windows) {
        if (net.accept(data.handle, data.addr, data.addr_len, data.flags)) |new_handle| {
            c.setResult(.net_accept, new_handle);
        } else |err| {
            c.setError(err);
        }
        return;
    }

    // POSIX: poll+accept loop to handle race if multiple threads access same socket
    while (true) {
        pollForReady(data.handle, net.POLL.IN) catch |err| {
            c.setError(err);
            return;
        };

        if (net.accept(data.handle, data.addr, data.addr_len, data.flags)) |new_handle| {
            c.setResult(.net_accept, new_handle);
            return;
        } else |err| switch (err) {
            error.WouldBlock => continue, // Another thread accepted connection, retry
            else => {
                c.setError(err);
                return;
            },
        }
    }
}
