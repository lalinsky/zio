// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

//! Blocking execution of I/O operations without event loop.
//!
//! This module provides synchronous execution of file, pipe, and socket operations
//! for use in non-async contexts (when there's no runtime/executor).

const std = @import("std");
const builtin = @import("builtin");
const Completion = @import("completion.zig").Completion;
const Group = @import("completion.zig").Group;
const PipeClose = @import("completion.zig").PipeClose;
const NetClose = @import("completion.zig").NetClose;
const NetShutdown = @import("completion.zig").NetShutdown;
const NetRecv = @import("completion.zig").NetRecv;
const NetSend = @import("completion.zig").NetSend;
const NetSendFile = @import("completion.zig").NetSendFile;
const FileRead = @import("completion.zig").FileRead;
const ReadBuf = @import("buf.zig").ReadBuf;
const WriteBuf = @import("buf.zig").WriteBuf;
const NetRecvFrom = @import("completion.zig").NetRecvFrom;
const NetSendTo = @import("completion.zig").NetSendTo;
const NetRecvMsg = @import("completion.zig").NetRecvMsg;
const NetSendMsg = @import("completion.zig").NetSendMsg;
const NetOpen = @import("completion.zig").NetOpen;
const NetBind = @import("completion.zig").NetBind;
const NetListen = @import("completion.zig").NetListen;
const NetConnect = @import("completion.zig").NetConnect;
const NetAccept = @import("completion.zig").NetAccept;
const NetPoll = @import("completion.zig").NetPoll;
const PipePoll = @import("completion.zig").PipePoll;
const Timer = @import("completion.zig").Timer;
const Work = @import("completion.zig").Work;
const ProcessWait = @import("completion.zig").ProcessWait;
const DeviceIoControl = @import("completion.zig").DeviceIoControl;
const common = @import("backends/common.zig");
const os = @import("../os/root.zig");
const time = @import("../time.zig");

/// Execute a completion synchronously without an event loop.
/// This is used when there's no async runtime available.
///
/// Supports file, pipe, and socket operations (read/write use poll+I/O on POSIX).
/// Timer and async/work/group operations are not supported (require event loop).
pub fn executeBlocking(c: *Completion, allocator: std.mem.Allocator) void {
    // Mark completion as having no loop (including a stale `loop_set` from a
    // previous submitted incarnation)
    c.setLoop(null);
    c.cancel_state.store(.{}, .monotonic);

    switch (c.op) {
        .file_open => common.handleFileOpen(c, allocator),
        .file_create => common.handleFileCreate(c, allocator),
        .file_close => common.handleFileClose(c),
        .file_read => common.handleFileRead(c),
        .file_write => common.handleFileWrite(c),
        .file_read_streaming => common.handleFileReadStreaming(c),
        .file_write_streaming => common.handleFileWriteStreaming(c),
        .file_sync => common.handleFileSync(c),
        .file_set_size => common.handleFileSetSize(c),
        .file_set_permissions => common.handleFileSetPermissions(c),
        .file_set_owner => common.handleFileSetOwner(c),
        .file_set_timestamps => common.handleFileSetTimestamps(c),
        .dir_create_dir => common.handleDirCreateDir(c, allocator),
        .dir_rename => common.handleDirRename(c, allocator),
        .dir_rename_preserve => common.handleDirRenamePreserve(c, allocator),
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
        .pipe_poll => handlePipePoll(c),

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
        .net_poll => handleNetPoll(c),
        .net_send_file => handleNetSendFile(c, allocator),

        // Timer operation
        .timer => handleTimer(c),

        // Work operation
        .work => handleWork(c),

        // Process wait - blocking wait
        .process_wait => common.handleProcessWait(c),

        // Device I/O control - blocking ioctl
        .device_io_control => handleDeviceIoControl(c),

        // A gather group of individually-supported ops can be run sequentially.
        .group => handleBlockingGroup(c, allocator),

        // Async operations require the event loop
        .async => @panic("Async operations not supported in blocking mode (requires event loop)"),

        .mach_port => unreachable,
    }
}

/// Execute a group completion synchronously by running each child in turn.
///
/// Only gather groups whose children are all individually supported in blocking
/// mode are handled. Today that means close batches (see `io.fileCloseImpl` /
/// `io.netCloseImpl`), which the panic/crash path exercises when std's stack-trace
/// symbolization opens and then closes the executable through `debug_io`. Anything
/// else keeps the "requires event loop" panic. Children are validated before any is
/// run so we never leave a group half-executed.
fn handleBlockingGroup(c: *Completion, allocator: std.mem.Allocator) void {
    const group: *Group = @alignCast(@fieldParentPtr("c", c));

    // Race groups (used for timeouts) genuinely need the loop to arbitrate.
    if (group.race.load(.acquire)) {
        @panic("Race groups are not supported in blocking mode (requires event loop)");
    }

    // Validate every child is an op we can run inline before running any of them.
    var node = group.head;
    while (node) |n| : (node = n.next) {
        const child: *Completion = @alignCast(@fieldParentPtr("group", n));
        switch (child.op) {
            .file_close, .net_close => {},
            else => @panic("Group contains an operation not supported in blocking mode"),
        }
    }

    // Run each child to completion; each sets its own result.
    node = group.head;
    while (node) |n| : (node = n.next) {
        const child: *Completion = @alignCast(@fieldParentPtr("group", n));
        executeBlocking(child, allocator);
    }

    c.setResult(.group, {});
}

/// Synchronous file-to-socket transfer for the no-runtime path. Drives the same
/// FileRead/NetSend child ops as the event-loop fallback, but executes each one
/// inline via `executeBlocking`. Uses a local buffer so it is independent of the
/// backend's `net_send_file` capability (the loop is unavailable here, so we
/// can never use a native splice path anyway).
fn handleNetSendFile(c: *Completion, allocator: std.mem.Allocator) void {
    const op = c.cast(NetSendFile);
    var buf: [16 * 1024]u8 = undefined;
    var read_iov: [1]os.iovec = undefined;
    var send_iov: [1]os.iovec_const = undefined;
    var total: usize = 0;

    while (true) {
        const want = @min(buf.len, op.remaining);
        if (want == 0) break;

        var rd = FileRead.init(op.file, ReadBuf.fromSlice(buf[0..want], &read_iov), op.offset);
        executeBlocking(&rd.c, allocator);
        const n = rd.getResult() catch |err| return c.setError(err);
        if (n == 0) break; // EOF
        op.offset += n;

        var off: usize = 0;
        while (off < n) {
            var sd = NetSend.init(op.handle, WriteBuf.fromSlice(buf[off..n], &send_iov), .{});
            executeBlocking(&sd.c, allocator);
            const m = sd.getResult() catch |err| return c.setError(err);
            off += m;
            total += m;
            op.remaining -= m;
        }
    }
    c.setResult(.net_send_file, total);
}

/// Poll for socket/pipe readiness with infinite timeout.
/// Returns error if polling fails.
/// Works on both POSIX and Windows platforms.
fn pollForReady(fd: os.net.fd_t, events: i16) !void {
    var pfd = [_]os.net.pollfd{.{
        .fd = fd,
        .events = events,
        .revents = 0,
    }};
    _ = try os.net.poll(&pfd, -1);
}

/// Helper to handle pipe create operation
fn handlePipeCreate(c: *Completion) void {
    if (os.fs.pipe()) |fds| {
        c.setResult(.pipe_create, fds);
    } else |err| {
        c.setError(err);
    }
}

/// Helper to handle pipe close operation
fn handlePipeClose(c: *Completion) void {
    const data = c.cast(PipeClose);
    if (os.fs.close(data.handle)) |_| {
        c.setResult(.pipe_close, {});
    } else |err| {
        c.setError(err);
    }
}

/// Helper to handle pipe poll operation
fn handlePipePoll(c: *Completion) void {
    if (builtin.os.tag == .windows) {
        @panic("Pipe poll not supported on Windows in blocking mode");
    }

    const data = c.cast(PipePoll);
    const events: i16 = switch (data.event) {
        .read => os.net.POLL.IN,
        .write => os.net.POLL.OUT,
    };

    if (pollForReady(data.handle, events)) |_| {
        c.setResult(.pipe_poll, {});
    } else |err| {
        c.setError(err);
    }
}

/// Helper to handle socket close operation
fn handleNetClose(c: *Completion) void {
    const data = c.cast(NetClose);
    os.net.close(data.handle);
    c.setResult(.net_close, {});
}

/// Helper to handle socket shutdown operation
fn handleNetShutdown(c: *Completion) void {
    const data = c.cast(NetShutdown);
    if (os.net.shutdown(data.handle, data.how)) |_| {
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
        if (os.net.recv(data.handle, data.buffers.iovecs, data.flags)) |bytes_read| {
            c.setResult(.net_recv, bytes_read);
        } else |err| {
            c.setError(err);
        }
        return;
    }

    // POSIX: poll+recv loop to handle race if multiple threads access same socket
    while (true) {
        pollForReady(data.handle, os.net.POLL.IN) catch |err| {
            c.setError(err);
            return;
        };

        if (os.net.recv(data.handle, data.buffers.iovecs, data.flags)) |bytes_read| {
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
        if (os.net.send(data.handle, data.buffer.iovecs, data.flags)) |bytes_written| {
            c.setResult(.net_send, bytes_written);
        } else |err| {
            c.setError(err);
        }
        return;
    }

    // POSIX: poll+send loop to handle race if multiple threads access same socket
    while (true) {
        pollForReady(data.handle, os.net.POLL.OUT) catch |err| {
            c.setError(err);
            return;
        };

        if (os.net.send(data.handle, data.buffer.iovecs, data.flags)) |bytes_written| {
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
        if (os.net.recvfrom(data.handle, data.buffer.iovecs, data.flags, data.addr, data.addr_len)) |bytes_read| {
            c.setResult(.net_recvfrom, bytes_read);
        } else |err| {
            c.setError(err);
        }
        return;
    }

    // POSIX: poll+recvfrom loop to handle race if multiple threads access same socket
    while (true) {
        pollForReady(data.handle, os.net.POLL.IN) catch |err| {
            c.setError(err);
            return;
        };

        if (os.net.recvfrom(data.handle, data.buffer.iovecs, data.flags, data.addr, data.addr_len)) |bytes_read| {
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
        if (os.net.sendto(data.handle, data.buffer.iovecs, data.flags, data.addr, data.addr_len)) |bytes_written| {
            c.setResult(.net_sendto, bytes_written);
        } else |err| {
            c.setError(err);
        }
        return;
    }

    // POSIX: poll+sendto loop to handle race if multiple threads access same socket
    while (true) {
        pollForReady(data.handle, os.net.POLL.OUT) catch |err| {
            c.setError(err);
            return;
        };

        if (os.net.sendto(data.handle, data.buffer.iovecs, data.flags, data.addr, data.addr_len)) |bytes_written| {
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
        if (os.net.recvmsg(data.handle, data.data.iovecs, data.flags, data.addr, data.addr_len, data.control)) |result| {
            c.setResult(.net_recvmsg, result);
        } else |err| {
            c.setError(err);
        }
        return;
    }

    // POSIX: poll+recvmsg loop to handle race if multiple threads access same socket
    while (true) {
        pollForReady(data.handle, os.net.POLL.IN) catch |err| {
            c.setError(err);
            return;
        };

        if (os.net.recvmsg(data.handle, data.data.iovecs, data.flags, data.addr, data.addr_len, data.control)) |result| {
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
        if (os.net.sendmsg(data.handle, data.data.iovecs, data.flags, data.addr, data.addr_len, data.control)) |bytes_written| {
            c.setResult(.net_sendmsg, bytes_written);
        } else |err| {
            c.setError(err);
        }
        return;
    }

    // POSIX: poll+sendmsg loop to handle race if multiple threads access same socket
    while (true) {
        pollForReady(data.handle, os.net.POLL.OUT) catch |err| {
            c.setError(err);
            return;
        };

        if (os.net.sendmsg(data.handle, data.data.iovecs, data.flags, data.addr, data.addr_len, data.control)) |bytes_written| {
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
    if (os.net.connect(data.handle, data.addr, data.addr_len)) |_| {
        c.setResult(.net_connect, {});
        return;
    } else |err| switch (err) {
        error.WouldBlock, error.ConnectionPending => {
            // Poll for write readiness to wait for connection to complete
            pollForReady(data.handle, os.net.POLL.OUT) catch |poll_err| {
                c.setError(poll_err);
                return;
            };

            // Check the actual connection result via SO_ERROR
            const sock_err = os.net.getSockError(data.handle) catch |sock_err| {
                c.setError(sock_err);
                return;
            };

            if (sock_err == 0) {
                c.setResult(.net_connect, {});
            } else {
                c.setError(os.net.errnoToConnectError(@enumFromInt(sock_err)));
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
        if (os.net.accept(data.handle, data.addr, data.addr_len, data.flags)) |new_handle| {
            c.setResult(.net_accept, new_handle);
        } else |err| {
            c.setError(err);
        }
        return;
    }

    // POSIX: poll+accept loop to handle race if multiple threads access same socket
    while (true) {
        pollForReady(data.handle, os.net.POLL.IN) catch |err| {
            c.setError(err);
            return;
        };

        if (os.net.accept(data.handle, data.addr, data.addr_len, data.flags)) |new_handle| {
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

/// Helper to handle socket poll operation
fn handleNetPoll(c: *Completion) void {
    const data = c.cast(NetPoll);
    const events: i16 = switch (data.event) {
        .recv => os.net.POLL.IN,
        .send => os.net.POLL.OUT,
    };

    if (pollForReady(data.handle, events)) |_| {
        c.setResult(.net_poll, {});
    } else |err| {
        c.setError(err);
    }
}

/// Helper to handle timer operation
fn handleTimer(c: *Completion) void {
    const data = c.cast(Timer);

    const duration = switch (data.timeout) {
        .none => return c.setResult(.timer, {}), // No timeout, return immediately
        .duration => |d| d,
        .deadline => |deadline| blk: {
            const now = time.Timestamp.now(.monotonic);
            break :blk now.durationTo(deadline);
        },
    };

    // Sleep for the duration (handles zero duration gracefully)
    os.time.sleep(duration);
    c.setResult(.timer, {});
}

/// Helper to handle work operation
fn handleWork(c: *Completion) void {
    const data = c.cast(Work);

    // Execute work synchronously
    data.state.store(.running, .monotonic);
    data.func(data);
    data.state.store(.completed, .monotonic);
    c.setResult(.work, {});
}

/// Helper to handle device I/O control (ioctl) operation
fn handleDeviceIoControl(c: *Completion) void {
    const data = c.cast(DeviceIoControl);
    if (builtin.os.tag == .windows) {
        c.setResult(.device_io_control, os.fs.ioctl(data.handle, data.code, data.in, data.out));
    } else {
        c.setResult(.device_io_control, os.fs.ioctl(data.handle, data.code, data.arg));
    }
}
