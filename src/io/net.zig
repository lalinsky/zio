const std = @import("std");
const builtin = @import("builtin");
const xev = @import("xev");
const Runtime = @import("../runtime.zig").Runtime;
const runIo = @import("base.zig").runIo;

const Handle = if (xev.backend == .iocp) std.os.windows.HANDLE else std.posix.socket_t;

pub const default_kernel_backlog = 256;

pub const ShutdownHow = std.posix.ShutdownHow;

pub const IpAddress = extern union {
    any: std.posix.sockaddr,
    ip4: std.net.Ip4Address,
    ip6: std.net.Ip6Address,

    pub fn initIp4(addr: [4]u8, port: u16) IpAddress {
        return .{ .ip4 = std.net.Ip4Address.init(addr, port) };
    }

    pub fn initIp6(addr: [16]u8, port: u16, flowinfo: u32, scope_id: u32) IpAddress {
        return .{ .ip6 = std.net.Ip6Address.init(addr, port, flowinfo, scope_id) };
    }

    pub fn parseIp4(buf: []const u8, port: u16) !IpAddress {
        return .{ .ip4 = try std.net.Ip4Address.parse(buf, port) };
    }

    pub fn parseIp6(buf: []const u8, port: u16) !IpAddress {
        return .{ .ip6 = try std.net.Ip6Address.parse(buf, port) };
    }

    pub const ListenOptions = struct {
        kernel_backlog: u31 = default_kernel_backlog,
        reuse_address: bool = false,
    };

    pub fn listen(self: IpAddress, rt: *Runtime, options: ListenOptions) !Server {
        return netListenIp(rt, self, options);
    }

    pub fn connect(self: IpAddress, rt: *Runtime) !Stream {
        return netConnectIp(rt, self);
    }
};

pub const UnixAddress = extern union {
    any: std.posix.sockaddr,
    un: std.posix.sockaddr.un,

    pub const max_len = 108;

    pub fn init(path: []const u8) !UnixAddress {
        var un = std.posix.sockaddr.un{ .family = std.posix.AF.UNIX, .path = undefined };
        if (path.len > max_len) return error.NameTooLong;
        @memcpy(un.path[0..path.len], path);
        un.path[path.len] = 0;
        return .{ .un = un };
    }

    pub const ListenOptions = struct {
        kernel_backlog: u31 = default_kernel_backlog,
    };

    pub fn listen(self: UnixAddress, rt: *Runtime, options: ListenOptions) !Server {
        return netListenUnix(rt, self, options);
    }

    pub fn connect(self: UnixAddress, rt: *Runtime) !Stream {
        return netConnectUnix(rt, self);
    }
};

pub const Address = extern union {
    any: std.posix.sockaddr,
    ip: IpAddress,
    unix: UnixAddress,

    pub fn connect(self: Address, rt: *Runtime) !Stream {
        switch (self.any.family) {
            std.posix.AF.INET, std.posix.AF.INET6 => return self.ip.connect(rt),
            std.posix.AF.UNIX => return self.unix.connect(rt),
            else => unreachable,
        }
    }
};

pub const Server = struct {
    handle: Handle,
    address: Address,

    pub fn accept(self: Server, rt: *Runtime) !Stream {
        const handle = try netAccept(rt, self.handle);
        return .{ .handle = handle };
    }

    pub fn shutdown(self: Server, rt: *Runtime, how: ShutdownHow) !void {
        return netShutdown(rt, self.handle, how);
    }

    pub fn close(self: Server, rt: *Runtime) void {
        return netClose(rt, self.handle);
    }
};

pub const Stream = struct {
    handle: Handle,

    pub fn send(self: Stream, rt: *Runtime, buf: []const u8) !usize {
        return netSend(rt, self.handle, buf);
    }

    pub fn receive(self: Stream, rt: *Runtime, buf: []u8) !usize {
        return netReceive(rt, self.handle, buf);
    }

    pub fn shutdown(self: Stream, rt: *Runtime, how: ShutdownHow) !void {
        return netShutdown(rt, self.handle, how);
    }

    pub fn close(self: Stream, rt: *Runtime) void {
        netClose(rt, self.handle);
    }
};

fn createStreamSocket(family: std.posix.sa_family_t) !Handle {
    if (builtin.os.tag == .windows) {
        return try std.os.windows.WSASocketW(family, std.posix.SOCK.STREAM, 0, null, 0, std.os.windows.ws2_32.WSA_FLAG_OVERLAPPED);
    } else {
        var flags: u32 = std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC;
        if (xev.backend != .io_uring) flags |= std.posix.SOCK.NONBLOCK;
        return try std.posix.socket(family, flags, 0);
    }
}

pub fn netListenIp(rt: *Runtime, addr: IpAddress, options: IpAddress.ListenOptions) !Server {
    const fd = try createStreamSocket(addr.any.family);
    errdefer netClose(rt, fd);

    const sock = if (xev.backend == .iocp) @as(std.os.windows.ws2_32.SOCKET, @ptrCast(fd)) else fd;

    const addr_len = switch (addr.any.family) {
        std.posix.AF.INET => addr.ip4.getOsSockLen(),
        std.posix.AF.INET6 => addr.ip6.getOsSockLen(),
        else => unreachable,
    };

    if (options.reuse_address) {
        try std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
    }

    try std.posix.bind(sock, &addr.any, addr_len);
    try std.posix.listen(sock, options.kernel_backlog);

    // Get the actual bound address (important for port 0)
    var actual_addr: IpAddress = undefined;
    var actual_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);
    try std.posix.getsockname(sock, &actual_addr.any, &actual_len);

    return .{ .handle = fd, .address = .{ .ip = actual_addr } };
}

pub fn netListenUnix(rt: *Runtime, addr: UnixAddress, options: UnixAddress.ListenOptions) !Server {
    const fd = try createStreamSocket(addr.any.family);
    errdefer netClose(rt, fd);

    const sock = if (xev.backend == .iocp) @as(std.os.windows.ws2_32.SOCKET, @ptrCast(fd)) else fd;

    const addr_len = switch (addr.any.family) {
        std.posix.AF.UNIX => @sizeOf(std.posix.sockaddr.un),
        else => unreachable,
    };

    try std.posix.bind(sock, &addr.any, addr_len);
    try std.posix.listen(sock, options.kernel_backlog);

    // Get the actual bound address
    var actual_addr: UnixAddress = undefined;
    var actual_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.un);
    try std.posix.getsockname(sock, &actual_addr.any, &actual_len);

    return .{ .handle = fd, .address = .{ .unix = actual_addr } };
}

pub fn netConnectIp(rt: *Runtime, addr: IpAddress) !Stream {
    const fd = try createStreamSocket(addr.any.family);
    errdefer netClose(rt, fd);

    try netConnect(rt, fd, .initPosix(@ptrCast(&addr)));
    return .{ .handle = fd };
}

pub fn netConnectUnix(rt: *Runtime, addr: UnixAddress) !Stream {
    const fd = try createStreamSocket(addr.any.family);
    errdefer netClose(rt, fd);

    try netConnect(rt, fd, .{ .un = addr.un });
    return .{ .handle = fd };
}

pub fn netReceive(rt: *Runtime, fd: Handle, buf: []u8) !usize {
    var completion: xev.Completion = .{ .op = .{
        .recv = .{
            .fd = fd,
            .buffer = .{ .slice = buf },
        },
    } };

    return runIo(rt, &completion, "recv");
}

pub fn netSend(rt: *Runtime, fd: Handle, buf: []const u8) !usize {
    var completion: xev.Completion = .{ .op = .{
        .send = .{
            .fd = fd,
            .buffer = .{ .slice = buf },
        },
    } };

    return runIo(rt, &completion, "send");
}

pub fn netAccept(rt: *Runtime, fd: Handle) !Handle {
    var completion: xev.Completion = .{ .op = .{
        .accept = .{
            .socket = fd,
        },
    } };

    if (xev.backend == .epoll) {
        completion.flags.dup = true;
    }

    return runIo(rt, &completion, "accept");
}

pub fn netConnect(rt: *Runtime, fd: Handle, addr: std.net.Address) !void {
    var completion: xev.Completion = .{ .op = .{
        .connect = .{
            .socket = fd,
            .addr = addr,
        },
    } };

    return runIo(rt, &completion, "connect");
}

pub fn netShutdown(rt: *Runtime, fd: Handle, how: ShutdownHow) !void {
    var completion: xev.Completion = .{ .op = .{
        .shutdown = .{
            .socket = fd,
            .how = how,
        },
    } };

    switch (xev.backend) {
        .epoll, .kqueue => completion.flags.threadpool = true,
        else => {},
    }

    return runIo(rt, &completion, "shutdown");
}

pub fn netClose(rt: *Runtime, fd: Handle) void {
    var completion: xev.Completion = .{ .op = .{
        .close = .{
            .fd = fd,
        },
    } };

    switch (xev.backend) {
        .epoll, .kqueue => completion.flags.threadpool = true,
        else => {},
    }

    rt.beginShield();
    defer rt.endShield();

    return runIo(rt, &completion, "close") catch {};
}

test {
    _ = @import("test/net.zig");
}
