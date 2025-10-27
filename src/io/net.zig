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
    in: std.net.Ip4Address,
    in6: std.net.Ip6Address,

    pub fn initIp4(addr: [4]u8, port: u16) IpAddress {
        return .{ .in = std.net.Ip4Address.init(addr, port) };
    }

    pub fn initIp6(addr: [16]u8, port: u16, flowinfo: u32, scope_id: u32) IpAddress {
        return .{ .in6 = std.net.Ip6Address.init(addr, port, flowinfo, scope_id) };
    }

    pub fn fromStd(addr: std.net.Address) IpAddress {
        switch (addr.any.family) {
            std.posix.AF.INET => return .{ .in = addr.in },
            std.posix.AF.INET6 => return .{ .in6 = addr.in6 },
            else => unreachable,
        }
    }

    pub fn parseIpAndPort(name: []const u8) !IpAddress {
        const addr = try std.net.Address.parseIpAndPort(name);
        return fromStd(addr);
    }

    pub fn parseIp(name: []const u8, port: u16) !IpAddress {
        const addr = try std.net.Address.parseIp(name, port);
        return fromStd(addr);
    }

    pub fn parseIp4(buf: []const u8, port: u16) !IpAddress {
        return .{ .in = try std.net.Ip4Address.parse(buf, port) };
    }

    pub fn parseIp6(buf: []const u8, port: u16) !IpAddress {
        return .{ .in6 = try std.net.Ip6Address.parse(buf, port) };
    }

    /// Returns the port in native endian.
    /// Asserts that the address is ip4 or ip6.
    pub fn getPort(self: IpAddress) u16 {
        return switch (self.any.family) {
            std.posix.AF.INET => self.in.getPort(),
            std.posix.AF.INET6 => self.in6.getPort(),
            else => unreachable,
        };
    }

    /// `port` is native-endian.
    /// Asserts that the address is ip4 or ip6.
    pub fn setPort(self: *IpAddress, port: u16) void {
        switch (self.any.family) {
            std.posix.AF.INET => self.in.setPort(port),
            std.posix.AF.INET6 => self.in6.setPort(port),
            else => unreachable,
        }
    }

    pub fn format(self: IpAddress, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self.any.family) {
            std.posix.AF.INET => try self.in.format(w),
            std.posix.AF.INET6 => try self.in6.format(w),
            else => unreachable,
        }
    }

    pub const ListenOptions = struct {
        kernel_backlog: u31 = default_kernel_backlog,
        reuse_address: bool = false,
    };

    pub fn bind(self: IpAddress, rt: *Runtime) !Socket {
        return netBindIp(rt, self);
    }

    pub fn listen(self: IpAddress, rt: *Runtime, options: ListenOptions) !Server {
        return netListenIp(rt, self, options);
    }

    pub fn connect(self: IpAddress, rt: *Runtime) !Stream {
        return netConnectIp(rt, self);
    }
};

pub const UnixAddress = extern union {
    any: std.posix.sockaddr,
    un: if (std.net.has_unix_sockets) std.posix.sockaddr.un else void,

    pub const max_len = 108;

    pub fn init(path: []const u8) !UnixAddress {
        if (!std.net.has_unix_sockets) unreachable;
        var un = std.posix.sockaddr.un{ .family = std.posix.AF.UNIX, .path = undefined };
        if (path.len > max_len) return error.NameTooLong;
        @memcpy(un.path[0..path.len], path);
        un.path[path.len] = 0;
        return .{ .un = un };
    }

    pub const ListenOptions = struct {
        kernel_backlog: u31 = default_kernel_backlog,
    };

    pub fn format(self: UnixAddress, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (!std.net.has_unix_sockets) unreachable;
        switch (self.any.family) {
            std.posix.AF.UNIX => try w.writeAll(std.mem.sliceTo(&self.un.path, 0)),
            else => unreachable,
        }
    }

    pub fn bind(self: UnixAddress, rt: *Runtime) !Socket {
        return netBindUnix(rt, self);
    }

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

    /// Convert to std.net.Address
    pub fn toStd(self: *const Address) std.net.Address {
        return switch (self.any.family) {
            std.posix.AF.INET, std.posix.AF.INET6 => std.net.Address.initPosix(@ptrCast(self)),
            std.posix.AF.UNIX => if (std.net.has_unix_sockets) std.net.Address{ .un = self.unix.un } else unreachable,
            else => unreachable,
        };
    }

    /// Convert from std.net.Address
    pub fn fromStd(addr: std.net.Address) Address {
        return switch (addr.any.family) {
            std.posix.AF.INET => Address{ .ip = .{ .in = addr.in } },
            std.posix.AF.INET6 => Address{ .ip = .{ .in6 = addr.in6 } },
            std.posix.AF.UNIX => if (std.net.has_unix_sockets) Address{ .unix = .{ .un = addr.un } } else unreachable,
            else => unreachable,
        };
    }

    /// Convert sockaddr to IpAddress from raw bytes.
    /// This properly handles IPv4 and IPv6 addresses without alignment issues.
    fn fromStorageIp(data: []const u8) IpAddress {
        const sockaddr: *align(1) const std.posix.sockaddr = @ptrCast(data.ptr);
        return switch (sockaddr.family) {
            std.posix.AF.INET => blk: {
                var addr: IpAddress = .{ .in = undefined };
                @memcpy(std.mem.asBytes(&addr.in), data[0..@sizeOf(std.net.Ip4Address)]);
                break :blk addr;
            },
            std.posix.AF.INET6 => blk: {
                var addr: IpAddress = .{ .in6 = undefined };
                @memcpy(std.mem.asBytes(&addr.in6), data[0..@sizeOf(std.net.Ip6Address)]);
                break :blk addr;
            },
            else => unreachable,
        };
    }

    /// Convert sockaddr to Address from raw bytes.
    /// This properly handles IPv4, IPv6, and Unix socket addresses without alignment issues.
    fn fromStorage(data: []const u8) Address {
        const sockaddr: *align(1) const std.posix.sockaddr = @ptrCast(data.ptr);
        return switch (sockaddr.family) {
            std.posix.AF.INET, std.posix.AF.INET6 => Address{ .ip = fromStorageIp(data) },
            std.posix.AF.UNIX => blk: {
                if (!std.net.has_unix_sockets) unreachable;
                var addr: Address = .{ .unix = .{ .un = undefined } };
                const copy_len = @min(data.len, @sizeOf(std.posix.sockaddr.un));
                @memcpy(std.mem.asBytes(&addr.unix.un)[0..copy_len], data[0..copy_len]);
                break :blk addr;
            },
            else => unreachable,
        };
    }

    pub fn format(self: Address, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self.any.family) {
            std.posix.AF.INET, std.posix.AF.INET6 => return self.ip.format(w),
            std.posix.AF.UNIX => return self.unix.format(w),
            else => unreachable,
        }
    }

    pub fn connect(self: Address, rt: *Runtime) !Stream {
        switch (self.any.family) {
            std.posix.AF.INET, std.posix.AF.INET6 => return self.ip.connect(rt),
            std.posix.AF.UNIX => return self.unix.connect(rt),
            else => unreachable,
        }
    }
};

pub const ReceiveFromResult = struct {
    from: Address,
    len: usize,
};

pub const Socket = struct {
    handle: Handle,
    address: Address,

    /// Set a socket option
    pub fn setOption(self: Socket, level: i32, optname: u32, value: anytype) !void {
        const sock = if (xev.backend == .iocp)
            @as(std.os.windows.ws2_32.SOCKET, @ptrCast(self.handle))
        else
            self.handle;

        const bytes = std.mem.asBytes(&value);
        try std.posix.setsockopt(sock, level, optname, bytes);
    }

    /// Bind the socket to an address
    pub fn bind(self: *Socket, rt: *Runtime, addr: Address) !void {
        _ = rt;
        const sock = if (xev.backend == .iocp)
            @as(std.os.windows.ws2_32.SOCKET, @ptrCast(self.handle))
        else
            self.handle;

        const addr_len = switch (addr.any.family) {
            std.posix.AF.INET => addr.ip.in.getOsSockLen(),
            std.posix.AF.INET6 => addr.ip.in6.getOsSockLen(),
            std.posix.AF.UNIX => @sizeOf(std.posix.sockaddr.un),
            else => unreachable,
        };

        try std.posix.bind(sock, &addr.any, addr_len);

        // Update address with actual bound address (important for port 0)
        var actual_len: std.posix.socklen_t = @sizeOf(Address);
        try std.posix.getsockname(sock, &self.address.any, &actual_len);
    }

    /// Mark the socket as a listening socket
    pub fn listen(self: *Socket, rt: *Runtime, backlog: u31) !void {
        _ = rt;
        const sock = if (xev.backend == .iocp)
            @as(std.os.windows.ws2_32.SOCKET, @ptrCast(self.handle))
        else
            self.handle;

        try std.posix.listen(sock, backlog);
    }

    /// Connect the socket to a remote address
    pub fn connect(self: Socket, rt: *Runtime, addr: Address) !void {
        try netConnect(rt, self.handle, addr.toStd());
    }

    /// Receives data from the socket into the provided buffer.
    /// Returns the number of bytes received, which may be less than buf.len.
    /// A return value of 0 indicates the socket has been shut down.
    pub fn receive(self: Socket, rt: *Runtime, buf: []u8) !usize {
        return netRead(rt, self.handle, &.{buf});
    }

    /// Sends data from the provided buffer to the socket.
    /// Returns the number of bytes sent, which may be less than buf.len.
    pub fn send(self: Socket, rt: *Runtime, buf: []const u8) !usize {
        const empty: []const u8 = "";
        return netWrite(rt, self.handle, buf, &.{empty}, 0);
    }

    /// Receives a datagram from the socket, returning the sender's address and bytes read.
    /// Used for UDP and other datagram-based protocols.
    pub fn receiveFrom(self: Socket, rt: *Runtime, buf: []u8) !ReceiveFromResult {
        return switch (xev.backend) {
            .io_uring, .epoll => try self.receiveFromRecvmsg(rt, buf),
            .iocp, .kqueue => try self.receiveFromRecvfrom(rt, buf),
            .wasi_poll => error.Unsupported,
        };
    }

    fn receiveFromRecvfrom(self: Socket, rt: *Runtime, buf: []u8) !ReceiveFromResult {
        var completion: xev.Completion = .{
            .op = .{
                .recvfrom = .{
                    .fd = self.handle,
                    .buffer = .{ .slice = buf },
                },
            },
        };

        const bytes_read = runIo(rt, &completion, "recvfrom") catch |err| switch (err) {
            error.EOF => 0, // EOF is not an error
            else => return err,
        };
        const addr_bytes = std.mem.asBytes(&completion.op.recvfrom.addr)[0..completion.op.recvfrom.addr_size];
        const addr = Address.fromStorage(addr_bytes);

        return ReceiveFromResult{
            .from = addr,
            .len = bytes_read,
        };
    }

    fn receiveFromRecvmsg(self: Socket, rt: *Runtime, buf: []u8) !ReceiveFromResult {
        var iov = [_]std.posix.iovec{.{
            .base = buf.ptr,
            .len = buf.len,
        }};

        var addr_storage: std.posix.sockaddr.storage = undefined;
        var msg: std.posix.msghdr = .{
            .name = @ptrCast(&addr_storage),
            .namelen = @sizeOf(std.posix.sockaddr.storage),
            .iov = &iov,
            .iovlen = 1,
            .control = null,
            .controllen = 0,
            .flags = 0,
        };

        var completion: xev.Completion = .{
            .op = .{
                .recvmsg = .{
                    .fd = self.handle,
                    .msghdr = &msg,
                },
            },
        };

        const bytes_read = runIo(rt, &completion, "recvmsg") catch |err| switch (err) {
            error.EOF => 0, // EOF is not an error
            else => return err,
        };

        // Extract address from msghdr
        const addr_bytes: [*]const u8 = @ptrCast(msg.name);
        const addr = Address.fromStorage(addr_bytes[0..msg.namelen]);

        return ReceiveFromResult{
            .from = addr,
            .len = bytes_read,
        };
    }

    /// Sends a datagram to the specified address.
    /// Used for UDP and other datagram-based protocols.
    pub fn sendTo(self: Socket, rt: *Runtime, addr: Address, data: []const u8) !usize {
        return switch (xev.backend) {
            .io_uring, .epoll => try self.sendToSendmsg(rt, addr, data),
            .iocp, .kqueue => try self.sendToSendto(rt, addr, data),
            .wasi_poll => error.Unsupported,
        };
    }

    fn sendToSendto(self: Socket, rt: *Runtime, addr: Address, data: []const u8) !usize {
        var completion: xev.Completion = .{
            .op = .{
                .sendto = .{
                    .fd = self.handle,
                    .buffer = .{ .slice = data },
                    .addr = addr.toStd(),
                },
            },
        };

        return try runIo(rt, &completion, "sendto");
    }

    fn sendToSendmsg(self: Socket, rt: *Runtime, addr: Address, data: []const u8) !usize {
        var iov = [_]std.posix.iovec_const{.{
            .base = data.ptr,
            .len = data.len,
        }};

        const std_addr = addr.toStd();
        var msg: std.posix.msghdr_const = .{
            .name = @ptrCast(&std_addr.any),
            .namelen = std_addr.getOsSockLen(),
            .iov = &iov,
            .iovlen = 1,
            .control = null,
            .controllen = 0,
            .flags = 0,
        };

        var completion: xev.Completion = .{
            .op = .{
                .sendmsg = .{
                    .fd = self.handle,
                    .msghdr = &msg,
                },
            },
        };

        return try runIo(rt, &completion, "sendmsg");
    }

    pub fn shutdown(self: Socket, rt: *Runtime, how: ShutdownHow) !void {
        return netShutdown(rt, self.handle, how);
    }

    pub fn close(self: Socket, rt: *Runtime) void {
        return netClose(rt, self.handle);
    }
};

pub const Server = struct {
    socket: Socket,

    pub fn accept(self: Server, rt: *Runtime) !Stream {
        return netAccept(rt, self.socket.handle);
    }

    pub fn shutdown(self: Server, rt: *Runtime, how: ShutdownHow) !void {
        return self.socket.shutdown(rt, how);
    }

    pub fn close(self: Server, rt: *Runtime) void {
        return self.socket.close(rt);
    }
};

pub const Stream = struct {
    socket: Socket,

    /// Reads data from the stream into the provided buffer.
    /// Returns the number of bytes read, which may be less than buf.len.
    /// A return value of 0 indicates end-of-stream.
    pub fn read(self: Stream, rt: *Runtime, buf: []u8) !usize {
        var bufs = [_][]u8{buf};
        return netRead(rt, self.socket.handle, &bufs);
    }

    /// Reads data from the stream into the provided buffer until it is full or the stream is closed.
    /// A return value of 0 indicates end-of-stream.
    pub fn readAll(self: Stream, rt: *Runtime, buf: []u8) !void {
        var offset: usize = 0;
        while (offset < buf.len) {
            const n = try self.read(rt, buf[offset..]);
            if (n == 0) break;
            offset += n;
        }
    }

    /// Writes data from the provided buffer to the stream.
    /// Returns the number of bytes written, which may be less than buf.len.
    pub fn write(self: Stream, rt: *Runtime, buf: []const u8) !usize {
        const empty: []const u8 = "";
        return netWrite(rt, self.socket.handle, buf, &.{empty}, 0);
    }

    /// Writes data from the provided buffer to the stream until it is empty.
    /// Returns an error if the stream is closed or if the write fails.
    pub fn writeAll(self: Stream, rt: *Runtime, buf: []const u8) !void {
        var offset: usize = 0;
        while (offset < buf.len) {
            const n = try self.write(rt, buf[offset..]);
            offset += n;
        }
    }

    /// Shuts down all or part of a full-duplex connection.
    pub fn shutdown(self: Stream, rt: *Runtime, how: ShutdownHow) !void {
        return self.socket.shutdown(rt, how);
    }

    /// Closes the stream.
    pub fn close(self: Stream, rt: *Runtime) void {
        self.socket.close(rt);
    }

    pub const Reader = struct {
        rt: *Runtime,
        stream: Stream,
        interface: std.Io.Reader,
        err: ?xev.ReadError = null,

        pub fn init(stream: Stream, rt: *Runtime, buffer: []u8) Reader {
            return .{
                .rt = rt,
                .stream = stream,
                .interface = .{
                    .vtable = &.{
                        .stream = streamImpl,
                        .readVec = readVecImpl,
                    },
                    .buffer = buffer,
                    .seek = 0,
                    .end = 0,
                },
            };
        }

        fn streamImpl(io_r: *std.Io.Reader, io_w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
            const dest = limit.slice(try io_w.writableSliceGreedy(1));
            var data: [1][]u8 = .{dest};
            const n = try readVecImpl(io_r, &data);
            io_w.advance(n);
            return n;
        }

        fn readVecImpl(io_r: *std.Io.Reader, data: [][]u8) std.Io.Reader.Error!usize {
            const r: *Reader = @alignCast(@fieldParentPtr("interface", io_r));
            var iovecs_buffer: [2][]u8 = undefined;
            const dest_n, const data_size = try io_r.writableVector(&iovecs_buffer, data);
            if (dest_n == 0) return 0;
            const dest = iovecs_buffer[0..dest_n];
            std.debug.assert(dest[0].len > 0);
            const n = netRead(r.rt, r.stream.socket.handle, dest) catch |err| {
                r.err = err;
                return error.ReadFailed;
            };
            if (n == 0) {
                return error.EndOfStream;
            }
            if (n > data_size) {
                io_r.end += n - data_size;
                return data_size;
            }
            return n;
        }
    };

    pub const Writer = struct {
        rt: *Runtime,
        stream: Stream,
        interface: std.Io.Writer,
        err: ?xev.WriteError = null,

        pub fn init(stream: Stream, rt: *Runtime, buffer: []u8) Writer {
            return .{
                .rt = rt,
                .stream = stream,
                .interface = .{
                    .vtable = &.{
                        .drain = drainImpl,
                    },
                    .buffer = buffer,
                },
            };
        }

        fn drainImpl(io_w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
            const w: *Writer = @alignCast(@fieldParentPtr("interface", io_w));
            const buffered = io_w.buffered();
            const n = netWrite(w.rt, w.stream.socket.handle, buffered, data, splat) catch |err| {
                w.err = err;
                return error.WriteFailed;
            };
            return io_w.consume(n);
        }
    };

    /// Creates a buffered reader for the given stream.
    pub fn reader(stream: Stream, rt: *Runtime, buffer: []u8) Reader {
        return .init(stream, rt, buffer);
    }

    /// Creates a buffered writer for the given stream.
    pub fn writer(stream: Stream, rt: *Runtime, buffer: []u8) Writer {
        return .init(stream, rt, buffer);
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

fn createDatagramSocket(family: std.posix.sa_family_t) !Handle {
    if (builtin.os.tag == .windows) {
        return try std.os.windows.WSASocketW(family, std.posix.SOCK.DGRAM, 0, null, 0, std.os.windows.ws2_32.WSA_FLAG_OVERLAPPED);
    } else {
        var flags: u32 = std.posix.SOCK.DGRAM | std.posix.SOCK.CLOEXEC;
        if (xev.backend != .io_uring) flags |= std.posix.SOCK.NONBLOCK;
        return try std.posix.socket(family, flags, 0);
    }
}

pub fn netListenIp(rt: *Runtime, addr: IpAddress, options: IpAddress.ListenOptions) !Server {
    const fd = try createStreamSocket(addr.any.family);
    errdefer netClose(rt, fd);

    var socket: Socket = .{
        .handle = fd,
        .address = .{ .ip = addr },
    };

    if (options.reuse_address) {
        try socket.setOption(std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, @as(c_int, 1));
    }

    try socket.bind(rt, .{ .ip = addr });
    try socket.listen(rt, options.kernel_backlog);

    return .{ .socket = socket };
}

pub fn netListenUnix(rt: *Runtime, addr: UnixAddress, options: UnixAddress.ListenOptions) !Server {
    if (!std.net.has_unix_sockets) unreachable;

    const fd = try createStreamSocket(addr.any.family);
    errdefer netClose(rt, fd);

    var socket: Socket = .{
        .handle = fd,
        .address = .{ .unix = addr },
    };

    try socket.bind(rt, .{ .unix = addr });
    try socket.listen(rt, options.kernel_backlog);

    return .{ .socket = socket };
}

pub fn netConnectIp(rt: *Runtime, addr: IpAddress) !Stream {
    const fd = try createStreamSocket(addr.any.family);
    errdefer netClose(rt, fd);

    try netConnect(rt, fd, .initPosix(@ptrCast(&addr)));
    return .{ .socket = .{ .handle = fd, .address = .{ .ip = addr } } };
}

pub fn netConnectUnix(rt: *Runtime, addr: UnixAddress) !Stream {
    if (!std.net.has_unix_sockets) unreachable;

    const fd = try createStreamSocket(addr.any.family);
    errdefer netClose(rt, fd);

    try netConnect(rt, fd, .{ .un = addr.un });
    return .{ .socket = .{ .handle = fd, .address = .{ .unix = addr } } };
}

pub fn netBindIp(rt: *Runtime, addr: IpAddress) !Socket {
    const fd = try createDatagramSocket(addr.any.family);
    errdefer netClose(rt, fd);

    var socket: Socket = .{
        .handle = fd,
        .address = .{ .ip = addr },
    };

    try socket.bind(rt, .{ .ip = addr });

    return socket;
}

pub fn netBindUnix(rt: *Runtime, addr: UnixAddress) !Socket {
    if (!std.net.has_unix_sockets) unreachable;

    const fd = try createDatagramSocket(addr.any.family);
    errdefer netClose(rt, fd);

    var socket: Socket = .{
        .handle = fd,
        .address = .{ .unix = addr },
    };

    try socket.bind(rt, .{ .unix = addr });

    return socket;
}

pub fn netRead(rt: *Runtime, fd: Handle, bufs: [][]u8) !usize {
    var completion: xev.Completion = .{ .op = .{
        .recv = .{
            .fd = fd,
            .buffer = .fromSlices(bufs),
        },
    } };

    return runIo(rt, &completion, "recv") catch |err| switch (err) {
        error.EOF => 0, // EOF is not an error
        else => err,
    };
}

fn addBuf(buf: *xev.WriteBuffer, data: []const u8) !void {
    if (buf.vectors.len < buf.vectors.data.len) {
        buf.vectors.data[buf.vectors.len] = if (xev.backend == .iocp) .{
            .buf = @constCast(data.ptr),
            .len = @intCast(data.len),
        } else .{
            .base = data.ptr,
            .len = data.len,
        };
        buf.vectors.len += 1;
    }
    return error.BufferFull;
}

fn fillBuf(out: *xev.WriteBuffer, header: []const u8, data: []const []const u8, splat: usize, splat_buffer: []u8) void {
    addBuf(out, header) catch return;
    if (data.len == 0) return;
    const last_index = data.len - 1;
    for (data[0..last_index]) |bytes| addBuf(out, bytes) catch return;
    const pattern = data[last_index];
    switch (splat) {
        0 => {},
        1 => addBuf(out, pattern) catch return,
        else => switch (pattern.len) {
            0 => {},
            1 => {
                const memset_len = @min(splat_buffer.len, splat);
                const buf = splat_buffer[0..memset_len];
                @memset(buf, pattern[0]);
                addBuf(out, buf) catch return;
                var remaining_splat = splat - buf.len;
                while (remaining_splat > splat_buffer.len) {
                    std.debug.assert(buf.len == splat_buffer.len);
                    addBuf(out, splat_buffer) catch return;
                    remaining_splat -= splat_buffer.len;
                }
                addBuf(out, splat_buffer[0..remaining_splat]) catch return;
            },
            else => for (0..splat) |_| addBuf(out, pattern) catch return,
        },
    }
}

pub fn netWrite(rt: *Runtime, fd: Handle, header: []const u8, data: []const []const u8, splat: usize) !usize {
    var splat_buf: [64]u8 = undefined;
    var buf: xev.WriteBuffer = .{ .vectors = .{ .data = undefined, .len = 0 } };
    fillBuf(&buf, header, data, splat, &splat_buf);

    var completion: xev.Completion = .{ .op = .{
        .send = .{
            .fd = fd,
            .buffer = buf,
        },
    } };

    return runIo(rt, &completion, "send");
}

pub fn netAccept(rt: *Runtime, fd: Handle) !Stream {
    var completion: xev.Completion = .{ .op = .{
        .accept = .{
            .socket = fd,
        },
    } };

    const handle = try runIo(rt, &completion, "accept");

    // Extract peer address from completion
    const addr = switch (xev.backend) {
        .epoll, .io_uring, .kqueue => Address.fromStorage(std.mem.asBytes(&completion.op.accept.addr)),
        .iocp => blk: {
            // Windows IOCP: Extract peer address from storage buffer using GetAcceptExSockaddrs
            var local_addr: *std.posix.sockaddr = undefined;
            var local_addr_len: i32 = undefined;
            var remote_addr: *std.posix.sockaddr = undefined;
            var remote_addr_len: i32 = undefined;

            std.os.windows.ws2_32.GetAcceptExSockaddrs(
                @ptrCast(&completion.op.accept.storage),
                0, // dwReceiveDataLength (same as AcceptEx)
                0, // dwLocalAddressLength (same as AcceptEx)
                @intCast(@sizeOf(std.posix.sockaddr.storage)), // dwRemoteAddressLength (same as AcceptEx)
                &local_addr,
                &local_addr_len,
                &remote_addr,
                &remote_addr_len,
            );

            // Convert remote_addr to Address using raw bytes
            const remote_bytes: [*]const u8 = @ptrCast(remote_addr);
            break :blk Address.fromStorage(remote_bytes[0..@intCast(remote_addr_len)]);
        },
        .wasi_poll => blk: {
            // WASI doesn't provide peer address info
            break :blk Address{ .ip = .{ .in = std.net.Ip4Address.unspecified(0) } };
        },
    };

    return .{ .socket = .{ .handle = handle, .address = addr } };
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

    return runIo(rt, &completion, "shutdown");
}

pub fn netClose(rt: *Runtime, fd: Handle) void {
    var completion: xev.Completion = .{ .op = .{
        .close = .{
            .fd = fd,
        },
    } };

    rt.beginShield();
    defer rt.endShield();

    return runIo(rt, &completion, "close") catch {};
}

test {
    _ = @import("test/net.zig");
}
