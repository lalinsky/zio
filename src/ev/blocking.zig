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
const common = @import("backends/common.zig");
const fs = @import("../os/fs.zig");
const net = @import("../os/net.zig");

/// Execute a completion synchronously without an event loop.
/// This is used when there's no async runtime available.
///
/// Supports file, pipe, and socket operations (read/write use poll+I/O on POSIX).
/// Network operations requiring the event loop (listen, connect, accept, etc.) and timers are not supported.
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

        // Network operations requiring event loop
        .net_listen,
        .net_connect,
        .net_accept,
        .net_poll,
        => @panic("Network operations not supported in blocking mode (requires event loop)"),

        // Timer and async operations require the event loop
        .timer,
        .async,
        .work,
        .group,
        => @panic("Timer/async operations not supported in blocking mode (requires event loop)"),
    }
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

    if (builtin.os.tag != .windows) {
        // POSIX: poll first since pipes are non-blocking
        var pfd = [_]net.pollfd{.{
            .fd = data.handle,
            .events = net.POLL.IN,
            .revents = 0,
        }};
        if (net.poll(&pfd, -1)) |_| {} else |err| {
            c.setError(err);
            return;
        }
    }

    // Now read - Windows blocks, POSIX should have data ready
    if (fs.readv(data.handle, data.buffer.iovecs)) |bytes_read| {
        c.setResult(.pipe_read, bytes_read);
    } else |err| {
        c.setError(err);
    }
}

/// Helper to handle pipe write operation
fn handlePipeWrite(c: *Completion) void {
    const data = c.cast(PipeWrite);

    if (builtin.os.tag != .windows) {
        // POSIX: poll first since pipes are non-blocking
        var pfd = [_]net.pollfd{.{
            .fd = data.handle,
            .events = net.POLL.OUT,
            .revents = 0,
        }};
        if (net.poll(&pfd, -1)) |_| {} else |err| {
            c.setError(err);
            return;
        }
    }

    // Now write - Windows blocks, POSIX should be ready
    if (fs.writev(data.handle, data.buffer.iovecs)) |bytes_written| {
        c.setResult(.pipe_write, bytes_written);
    } else |err| {
        c.setError(err);
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

    if (builtin.os.tag != .windows) {
        // POSIX: poll first since sockets are non-blocking
        var pfd = [_]net.pollfd{.{
            .fd = data.handle,
            .events = net.POLL.IN,
            .revents = 0,
        }};
        if (net.poll(&pfd, -1)) |_| {} else |err| {
            c.setError(err);
            return;
        }
    }

    // Now recv - Windows blocks, POSIX should have data ready
    if (net.recv(data.handle, data.buffers.iovecs, data.flags)) |bytes_read| {
        c.setResult(.net_recv, bytes_read);
    } else |err| {
        c.setError(err);
    }
}

/// Helper to handle socket send operation
fn handleNetSend(c: *Completion) void {
    const data = c.cast(NetSend);

    if (builtin.os.tag != .windows) {
        // POSIX: poll first since sockets are non-blocking
        var pfd = [_]net.pollfd{.{
            .fd = data.handle,
            .events = net.POLL.OUT,
            .revents = 0,
        }};
        if (net.poll(&pfd, -1)) |_| {} else |err| {
            c.setError(err);
            return;
        }
    }

    // Now send - Windows blocks, POSIX should be ready
    if (net.send(data.handle, data.buffer.iovecs, data.flags)) |bytes_written| {
        c.setResult(.net_send, bytes_written);
    } else |err| {
        c.setError(err);
    }
}

/// Helper to handle socket recvfrom operation
fn handleNetRecvFrom(c: *Completion) void {
    const data = c.cast(NetRecvFrom);

    if (builtin.os.tag != .windows) {
        // POSIX: poll first since sockets are non-blocking
        var pfd = [_]net.pollfd{.{
            .fd = data.handle,
            .events = net.POLL.IN,
            .revents = 0,
        }};
        if (net.poll(&pfd, -1)) |_| {} else |err| {
            c.setError(err);
            return;
        }
    }

    // Now recvfrom - Windows blocks, POSIX should have data ready
    if (net.recvfrom(data.handle, data.buffer.iovecs, data.flags, data.addr, data.addr_len)) |bytes_read| {
        c.setResult(.net_recvfrom, bytes_read);
    } else |err| {
        c.setError(err);
    }
}

/// Helper to handle socket sendto operation
fn handleNetSendTo(c: *Completion) void {
    const data = c.cast(NetSendTo);

    if (builtin.os.tag != .windows) {
        // POSIX: poll first since sockets are non-blocking
        var pfd = [_]net.pollfd{.{
            .fd = data.handle,
            .events = net.POLL.OUT,
            .revents = 0,
        }};
        if (net.poll(&pfd, -1)) |_| {} else |err| {
            c.setError(err);
            return;
        }
    }

    // Now sendto - Windows blocks, POSIX should be ready
    if (net.sendto(data.handle, data.buffer.iovecs, data.flags, data.addr, data.addr_len)) |bytes_written| {
        c.setResult(.net_sendto, bytes_written);
    } else |err| {
        c.setError(err);
    }
}

/// Helper to handle socket recvmsg operation
fn handleNetRecvMsg(c: *Completion) void {
    const data = c.cast(NetRecvMsg);

    if (builtin.os.tag != .windows) {
        // POSIX: poll first since sockets are non-blocking
        var pfd = [_]net.pollfd{.{
            .fd = data.handle,
            .events = net.POLL.IN,
            .revents = 0,
        }};
        if (net.poll(&pfd, -1)) |_| {} else |err| {
            c.setError(err);
            return;
        }
    }

    // Now recvmsg - Windows blocks, POSIX should have data ready
    if (net.recvmsg(data.handle, data.data.iovecs, data.flags, data.addr, data.addr_len, data.control)) |result| {
        c.setResult(.net_recvmsg, result);
    } else |err| {
        c.setError(err);
    }
}

/// Helper to handle socket sendmsg operation
fn handleNetSendMsg(c: *Completion) void {
    const data = c.cast(NetSendMsg);

    if (builtin.os.tag != .windows) {
        // POSIX: poll first since sockets are non-blocking
        var pfd = [_]net.pollfd{.{
            .fd = data.handle,
            .events = net.POLL.OUT,
            .revents = 0,
        }};
        if (net.poll(&pfd, -1)) |_| {} else |err| {
            c.setError(err);
            return;
        }
    }

    // Now sendmsg - Windows blocks, POSIX should be ready
    if (net.sendmsg(data.handle, data.data.iovecs, data.flags, data.addr, data.addr_len, data.control)) |bytes_written| {
        c.setResult(.net_sendmsg, bytes_written);
    } else |err| {
        c.setError(err);
    }
}
