const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

pub const Self = @This();

fd: posix.fd_t,

pub fn init(self: *Self) !void {
    self.fd = try posix.epoll_create1(linux.EPOLL.CLOEXEC);
}

pub fn deinit(self: *Self) void {
    posix.close(self.fd);
}

pub const OperationType = enum {
    noop,
    cancel,
    accept,
    connect,
    poll,
    read,
    pread,
    write,
    pwrite,
    send,
    recv,
    sendmsg,
    recvmsg,
    close,
    shutdown,
    timer,
};
