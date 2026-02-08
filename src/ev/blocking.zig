// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

//! Blocking execution of I/O operations without event loop.
//!
//! This module provides synchronous execution of file and pipe operations
//! for use in non-async contexts (when there's no runtime/executor).

const std = @import("std");
const builtin = @import("builtin");
const Completion = @import("completion.zig").Completion;
const PipeClose = @import("completion.zig").PipeClose;
const PipeRead = @import("completion.zig").PipeRead;
const PipeWrite = @import("completion.zig").PipeWrite;
const common = @import("backends/common.zig");
const fs = @import("../os/fs.zig");
const net = @import("../os/net.zig");

/// Execute a completion synchronously without an event loop.
/// This is used when there's no async runtime available.
///
/// Supports file and pipe operations (read/write use poll+I/O on POSIX).
/// Network operations and timers are not supported.
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

        // Network operations require the event loop
        .net_open,
        .net_bind,
        .net_listen,
        .net_connect,
        .net_accept,
        .net_recv,
        .net_send,
        .net_recvfrom,
        .net_sendto,
        .net_recvmsg,
        .net_sendmsg,
        .net_poll,
        .net_shutdown,
        .net_close,
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
