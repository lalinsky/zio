const std = @import("std");
const builtin = @import("builtin");
const posix = @import("../posix.zig");
const time = @import("../../time.zig");

const log = std.log.scoped(.zio_socket);

fn unexpectedWSAError(err: std.os.windows.ws2_32.WinsockError) error{Unexpected} {
    if (posix.unexpected_error_tracing) {
        std.debug.print(
            \\unexpected WSA error: {}
            \\please file a bug report: https://github.com/lalinsky/aio.zig/issues/new
            \\
        , .{err});
        if (comptime builtin.zig_version.order(.{ .major = 0, .minor = 16, .patch = 0 }) != .lt) {
            std.debug.dumpCurrentStackTrace(.{});
        } else {
            std.debug.dumpCurrentStackTrace(null);
        }
    }
    return error.Unexpected;
}

var wsa_init_once = std.once(wsaInit);

fn wsaInit() void {
    if (builtin.os.tag == .windows) {
        var wsa_data: std.os.windows.ws2_32.WSADATA = undefined;
        _ = std.os.windows.ws2_32.WSAStartup(2 << 8 | 2, &wsa_data);
    }
}

pub fn ensureWSAInitialized() void {
    wsa_init_once.call();
}

pub const fd_t = switch (builtin.os.tag) {
    .windows => std.os.windows.ws2_32.SOCKET,
    else => posix.system.fd_t,
};

pub const pollfd = switch (builtin.os.tag) {
    .windows => std.os.windows.ws2_32.pollfd,
    else => posix.system.pollfd,
};

pub const POLL = switch (builtin.os.tag) {
    .windows => std.os.windows.ws2_32.POLL,
    else => posix.system.POLL,
};

pub const sockaddr = posix.system.sockaddr;
pub const AF = posix.system.AF;
pub const socklen_t = if (builtin.os.tag == .windows) i32 else posix.system.socklen_t;
pub const SOL = posix.system.SOL;
pub const SO = posix.system.SO;

// Vectored I/O types
pub const iovec = switch (builtin.os.tag) {
    .windows => std.os.windows.ws2_32.WSABUF,
    else => std.posix.iovec,
};

pub const iovec_const = switch (builtin.os.tag) {
    .windows => std.os.windows.ws2_32.WSABUF,
    else => std.posix.iovec_const,
};

// Helper functions for single buffer conversion
pub inline fn iovecFromSlice(buffer: []u8) iovec {
    return switch (builtin.os.tag) {
        .windows => .{ .len = @intCast(buffer.len), .buf = buffer.ptr },
        else => .{ .base = buffer.ptr, .len = buffer.len },
    };
}

pub inline fn iovecConstFromSlice(buffer: []const u8) iovec_const {
    return switch (builtin.os.tag) {
        .windows => .{ .len = @intCast(buffer.len), .buf = @constCast(buffer.ptr) },
        else => .{ .base = buffer.ptr, .len = buffer.len },
    };
}

pub const PollError = error{
    SystemResources,
    Unexpected,
};

pub fn poll(fds: []pollfd, timeout: i32) PollError!usize {
    switch (builtin.os.tag) {
        .windows => {
            while (true) {
                const rc = std.os.windows.ws2_32.WSAPoll(fds.ptr, @intCast(fds.len), timeout);
                if (rc >= 0) {
                    return @intCast(rc);
                }
                const err = std.os.windows.ws2_32.WSAGetLastError();
                switch (err) {
                    .WSAEINTR => continue,
                    .WSAENOBUFS => return error.SystemResources,
                    .WSAEFAULT => unreachable,
                    .WSAEINVAL => {
                        log.err("WSAPoll returned WSAEINVAL - invalid parameter (fds.len={}, timeout={})", .{ fds.len, timeout });
                        return unexpectedWSAError(err);
                    },
                    else => return unexpectedWSAError(err),
                }
            }
        },
        else => {
            while (true) {
                const rc = posix.system.poll(fds.ptr, @intCast(fds.len), timeout);
                switch (posix.errno(rc)) {
                    .SUCCESS => return @intCast(rc),
                    .FAULT => unreachable,
                    .INTR => continue,
                    .INVAL => return error.SystemResources,
                    .NOMEM => return error.SystemResources,
                    else => |err| return posix.unexpectedErrno(err),
                }
            }
        },
    }
}

pub fn close(fd: fd_t) void {
    switch (builtin.os.tag) {
        .windows => {
            _ = std.os.windows.ws2_32.closesocket(fd);
        },
        else => {
            while (true) {
                const rc = posix.system.close(fd);
                switch (posix.errno(rc)) {
                    .SUCCESS => return,
                    .INTR => continue,
                    .BADF => unreachable, // sockfd is not a valid file descriptor - would be a bug
                    // Note: EIO, ENOSPC, EDQUOT can occur but are rare; we treat them as unexpected
                    else => |err| {
                        posix.unexpectedErrno(err) catch {};
                        return;
                    },
                }
            }
        },
    }
}

pub const ShutdownHow = enum {
    receive,
    send,
    both,
};

pub const ShutdownError = error{
    NotConnected,
    NotSocket,
    Unexpected,
};

pub fn shutdown(fd: fd_t, how: ShutdownHow) ShutdownError!void {
    switch (builtin.os.tag) {
        .windows => {
            const system_how: i32 = switch (how) {
                .receive => std.os.windows.ws2_32.SD_RECEIVE,
                .send => std.os.windows.ws2_32.SD_SEND,
                .both => std.os.windows.ws2_32.SD_BOTH,
            };
            const rc = std.os.windows.ws2_32.shutdown(fd, system_how);
            if (rc == std.os.windows.ws2_32.SOCKET_ERROR) {
                const err = std.os.windows.ws2_32.WSAGetLastError();
                return switch (err) {
                    .WSAENOTCONN => error.NotConnected,
                    .WSAENOTSOCK => error.NotSocket,
                    else => unexpectedWSAError(err),
                };
            }
        },
        else => {
            const system_how: c_int = switch (how) {
                .receive => posix.system.SHUT.RD,
                .send => posix.system.SHUT.WR,
                .both => posix.system.SHUT.RDWR,
            };
            while (true) {
                const rc = posix.system.shutdown(fd, system_how);
                switch (posix.errno(rc)) {
                    .SUCCESS => return,
                    .INTR => continue,
                    .BADF => unreachable, // sockfd is not a valid file descriptor - would be a bug
                    .INVAL => unreachable, // Invalid value specified in how - would be a bug
                    .NOTCONN => return error.NotConnected,
                    .NOTSOCK => return error.NotSocket,
                    else => |err| return posix.unexpectedErrno(err),
                }
            }
        },
    }
}

pub const Domain = enum(c_int) {
    ipv4 = posix.system.AF.INET,
    ipv6 = posix.system.AF.INET6,
    unix = posix.system.AF.UNIX,
};

pub const Type = enum(c_int) {
    stream = posix.system.SOCK.STREAM,
    dgram = posix.system.SOCK.DGRAM,
    seqpacket = posix.system.SOCK.SEQPACKET,
};

pub const Protocol = enum(c_int) {
    default = 0,
    tcp = posix.system.IPPROTO.TCP,
    udp = posix.system.IPPROTO.UDP,
};

pub const OpenFlags = packed struct {
    nonblocking: bool = false,
    cloexec: bool = true,
};

pub const OpenError = error{
    AddressFamilyNotSupported,
    ProtocolNotSupported,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    SystemResources,
    PermissionDenied,
    Unexpected,
};

pub fn socket(domain: Domain, socket_type: Type, protocol: Protocol, flags: OpenFlags) OpenError!fd_t {
    switch (builtin.os.tag) {
        .windows => {
            const sock = std.os.windows.ws2_32.WSASocketW(
                @intFromEnum(domain),
                @intFromEnum(socket_type),
                @intFromEnum(protocol),
                null,
                0,
                std.os.windows.ws2_32.WSA_FLAG_OVERLAPPED,
            );
            if (sock == std.os.windows.ws2_32.INVALID_SOCKET) {
                const err = std.os.windows.ws2_32.WSAGetLastError();
                return switch (err) {
                    .WSAEAFNOSUPPORT => error.AddressFamilyNotSupported,
                    .WSAEPROTONOSUPPORT => error.ProtocolNotSupported,
                    .WSAEMFILE => error.ProcessFdQuotaExceeded,
                    .WSAENOBUFS => error.SystemResources,
                    else => unexpectedWSAError(err),
                };
            }
            if (flags.nonblocking) {
                var mode: c_ulong = 1;
                _ = std.os.windows.ws2_32.ioctlsocket(sock, std.os.windows.ws2_32.FIONBIO, &mode);
            }
            return sock;
        },
        else => {
            var sock_flags: c_int = @intFromEnum(socket_type);
            // Linux supports SOCK_NONBLOCK and SOCK_CLOEXEC flags in socket()
            // BSD (macOS, FreeBSD, etc.) requires fcntl() instead
            if (builtin.os.tag == .linux) {
                if (flags.nonblocking) {
                    sock_flags |= posix.system.SOCK.NONBLOCK;
                }
                if (flags.cloexec) {
                    sock_flags |= posix.system.SOCK.CLOEXEC;
                }
            }

            while (true) {
                const rc = posix.system.socket(
                    @intCast(@intFromEnum(domain)),
                    @intCast(sock_flags),
                    @intCast(@intFromEnum(protocol)),
                );
                switch (posix.errno(rc)) {
                    .SUCCESS => {
                        const fd: fd_t = @intCast(rc);

                        // On non-Linux systems, set flags using fcntl
                        if (builtin.os.tag != .linux) {
                            if (flags.nonblocking) {
                                try posix.setNonblocking(fd);
                            }
                            if (flags.cloexec) {
                                try posix.setCloexec(fd);
                            }
                        }

                        return fd;
                    },
                    .INTR => continue,
                    .ACCES => return error.PermissionDenied,
                    .AFNOSUPPORT => return error.AddressFamilyNotSupported,
                    .INVAL => unreachable, // Invalid flags in type - we always pass valid flags
                    .MFILE => return error.ProcessFdQuotaExceeded,
                    .NFILE => return error.SystemFdQuotaExceeded,
                    .NOBUFS, .NOMEM => return error.SystemResources,
                    .PROTONOSUPPORT => return error.ProtocolNotSupported,
                    else => |err| return posix.unexpectedErrno(err),
                }
            }
        },
    }
}

pub const BindError = error{
    AddressInUse,
    AddressNotAvailable,
    AddressFamilyNotSupported,
    PermissionDenied,
    SymLinkLoop,
    NameTooLong,
    FileNotFound,
    NotDir,
    ReadOnlyFileSystem,
    SystemResources,
    Unexpected,
};

pub fn bind(fd: fd_t, addr: *const sockaddr, addr_len: socklen_t) BindError!void {
    switch (builtin.os.tag) {
        .windows => {
            const rc = std.os.windows.ws2_32.bind(fd, @ptrCast(addr), @intCast(addr_len));
            if (rc == std.os.windows.ws2_32.SOCKET_ERROR) {
                const err = std.os.windows.ws2_32.WSAGetLastError();
                return switch (err) {
                    .WSAEADDRINUSE => error.AddressInUse,
                    .WSAEADDRNOTAVAIL => error.AddressNotAvailable,
                    .WSAEAFNOSUPPORT => error.AddressFamilyNotSupported,
                    .WSAEACCES => error.PermissionDenied,
                    else => unexpectedWSAError(err),
                };
            }
        },
        else => {
            while (true) {
                const rc = posix.system.bind(fd, addr, addr_len);
                switch (posix.errno(rc)) {
                    .SUCCESS => return,
                    .INTR => continue,
                    .ACCES, .PERM => return error.PermissionDenied,
                    .ADDRINUSE => return error.AddressInUse,
                    .BADF => unreachable, // sockfd is not a valid file descriptor - would be a bug
                    .INVAL => unreachable, // Socket already bound or invalid addrlen - would be a bug
                    .NOTSOCK => unreachable, // sockfd doesn't refer to a socket - would be a bug
                    .AFNOSUPPORT => return error.AddressFamilyNotSupported,
                    .ADDRNOTAVAIL => return error.AddressNotAvailable,
                    .FAULT => unreachable, // addr points outside accessible address space - would be a bug
                    .LOOP => return error.SymLinkLoop,
                    .NAMETOOLONG => return error.NameTooLong,
                    .NOENT => return error.FileNotFound,
                    .NOMEM => return error.SystemResources,
                    .NOTDIR => return error.NotDir,
                    .ROFS => return error.ReadOnlyFileSystem,
                    else => |err| return posix.unexpectedErrno(err),
                }
            }
        },
    }
}

pub const ListenError = error{
    AddressInUse,
    OperationNotSupported,
    Unexpected,
};

pub fn listen(fd: fd_t, backlog: u31) ListenError!void {
    switch (builtin.os.tag) {
        .windows => {
            const rc = std.os.windows.ws2_32.listen(fd, backlog);
            if (rc == std.os.windows.ws2_32.SOCKET_ERROR) {
                const err = std.os.windows.ws2_32.WSAGetLastError();
                return switch (err) {
                    .WSAEADDRINUSE => error.AddressInUse,
                    .WSAEOPNOTSUPP => error.OperationNotSupported,
                    else => unexpectedWSAError(err),
                };
            }
        },
        else => {
            while (true) {
                const rc = posix.system.listen(fd, backlog);
                switch (posix.errno(rc)) {
                    .SUCCESS => return,
                    .INTR => continue,
                    .ADDRINUSE => return error.AddressInUse,
                    .BADF => unreachable, // sockfd is not a valid file descriptor - would be a bug
                    .NOTSOCK => unreachable, // sockfd doesn't refer to a socket - would be a bug
                    .OPNOTSUPP => return error.OperationNotSupported,
                    else => |err| return posix.unexpectedErrno(err),
                }
            }
        },
    }
}

pub const ConnectError = error{
    AccessDenied,
    AddressInUse,
    AddressNotAvailable,
    AddressFamilyNotSupported,
    WouldBlock,
    AlreadyConnected,
    ConnectionPending,
    ConnectionRefused,
    FileNotFound,
    PermissionDenied,
    NetworkUnreachable,
    Unexpected,
};

pub fn connect(fd: fd_t, addr: *const sockaddr, addr_len: socklen_t) ConnectError!void {
    switch (builtin.os.tag) {
        .windows => {
            const rc = std.os.windows.ws2_32.connect(fd, @ptrCast(addr), @intCast(addr_len));
            if (rc == std.os.windows.ws2_32.SOCKET_ERROR) {
                const err = std.os.windows.ws2_32.WSAGetLastError();
                return switch (err) {
                    .WSAEACCES => error.AccessDenied,
                    .WSAEADDRINUSE => error.AddressInUse,
                    .WSAEADDRNOTAVAIL => error.AddressNotAvailable,
                    .WSAEAFNOSUPPORT => error.AddressFamilyNotSupported,
                    .WSAEWOULDBLOCK => error.WouldBlock,
                    .WSAEISCONN => error.AlreadyConnected,
                    .WSAEALREADY => error.ConnectionPending,
                    .WSAECONNREFUSED => error.ConnectionRefused,
                    .WSAETIMEDOUT => error.ConnectionRefused,
                    .WSAENETUNREACH => error.NetworkUnreachable,
                    else => unexpectedWSAError(err),
                };
            }
        },
        else => {
            while (true) {
                const rc = posix.system.connect(fd, addr, addr_len);
                switch (posix.errno(rc)) {
                    .SUCCESS => return,
                    .INTR => continue,
                    .ACCES, .PERM => return error.PermissionDenied,
                    .ADDRINUSE => return error.AddressInUse,
                    .ADDRNOTAVAIL => return error.AddressNotAvailable,
                    .AFNOSUPPORT => return error.AddressFamilyNotSupported,
                    .AGAIN, .INPROGRESS => return error.WouldBlock,
                    .ALREADY => return error.ConnectionPending,
                    .BADF => unreachable, // sockfd is not a valid file descriptor - would be a bug
                    .CONNREFUSED => return error.ConnectionRefused,
                    .FAULT => unreachable, // Socket structure address outside user's address space - would be a bug
                    .ISCONN => return error.AlreadyConnected,
                    .NETUNREACH => return error.NetworkUnreachable,
                    .NOTSOCK => unreachable, // sockfd doesn't refer to a socket - would be a bug
                    .PROTOTYPE => unreachable, // Socket type doesn't support requested protocol - would be a bug
                    .TIMEDOUT => return error.ConnectionRefused,
                    .NOENT => return error.FileNotFound,
                    else => |err| return posix.unexpectedErrno(err),
                }
            }
        },
    }
}

pub const AcceptError = error{
    WouldBlock,
    ConnectionAborted,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    SystemResources,
    PermissionDenied,
    ProtocolFailure,
    BlockedByFirewall,
    Unexpected,
};

pub fn accept(fd: fd_t, addr: ?*sockaddr, addr_len: ?*socklen_t, flags: OpenFlags) AcceptError!fd_t {
    switch (builtin.os.tag) {
        .windows => {
            const sock = std.os.windows.ws2_32.accept(
                fd,
                if (addr) |a| @ptrCast(a) else null,
                addr_len,
            );
            if (sock == std.os.windows.ws2_32.INVALID_SOCKET) {
                const err = std.os.windows.ws2_32.WSAGetLastError();
                return switch (err) {
                    .WSAEWOULDBLOCK => error.WouldBlock,
                    .WSAECONNABORTED => error.ConnectionAborted,
                    .WSAEMFILE => error.ProcessFdQuotaExceeded,
                    .WSAENOBUFS => error.SystemResources,
                    else => unexpectedWSAError(err),
                };
            }
            if (flags.nonblocking) {
                var mode: c_ulong = 1;
                _ = std.os.windows.ws2_32.ioctlsocket(sock, std.os.windows.ws2_32.FIONBIO, &mode);
            }
            return sock;
        },
        else => {
            // Linux supports accept4 with SOCK_NONBLOCK and SOCK_CLOEXEC flags
            // BSD (macOS, FreeBSD, etc.) requires fcntl() instead
            var accept_flags: c_int = 0;
            if (builtin.os.tag == .linux) {
                if (flags.nonblocking) {
                    accept_flags |= posix.system.SOCK.NONBLOCK;
                }
                if (flags.cloexec) {
                    accept_flags |= posix.system.SOCK.CLOEXEC;
                }
            }

            while (true) {
                var addr_len_tmp: posix.system.socklen_t = if (addr_len) |len| len.* else 0;
                const rc = if (builtin.os.tag == .linux)
                    posix.system.accept4(
                        fd,
                        if (addr) |a| @ptrCast(@alignCast(a)) else null,
                        if (addr_len != null) &addr_len_tmp else null,
                        @intCast(accept_flags),
                    )
                else
                    posix.system.accept(
                        fd,
                        if (addr) |a| @ptrCast(@alignCast(a)) else null,
                        if (addr_len != null) &addr_len_tmp else null,
                    );

                switch (posix.errno(rc)) {
                    .SUCCESS => {
                        if (addr_len) |len| {
                            len.* = addr_len_tmp;
                        }
                        const sock: fd_t = @intCast(rc);

                        // On non-Linux systems, set flags using fcntl
                        if (builtin.os.tag != .linux) {
                            if (flags.nonblocking) {
                                try posix.setNonblocking(sock);
                            }
                            if (flags.cloexec) {
                                try posix.setCloexec(sock);
                            }
                        }

                        return sock;
                    },
                    .INTR => continue,
                    .AGAIN => return error.WouldBlock,
                    .BADF => unreachable, // sockfd is not a valid file descriptor - would be a bug
                    .CONNABORTED => return error.ConnectionAborted,
                    .FAULT => unreachable, // addr argument not in writable part of address space - would be a bug
                    .INVAL => unreachable, // Socket not listening, invalid addrlen, or invalid flags - would be a bug
                    .MFILE => return error.ProcessFdQuotaExceeded,
                    .NFILE => return error.SystemFdQuotaExceeded,
                    .NOBUFS, .NOMEM => return error.SystemResources,
                    .NOTSOCK => unreachable, // sockfd doesn't refer to a socket - would be a bug
                    .OPNOTSUPP => unreachable, // Socket is not SOCK_STREAM - would be a bug
                    .PERM => return error.PermissionDenied,
                    .PROTO => return error.ProtocolFailure,
                    else => |err| return posix.unexpectedErrno(err),
                }
            }
        },
    }
}

pub const GetSockNameError = error{Unexpected};

pub fn getsockname(fd: fd_t, addr: *sockaddr, addr_len: *socklen_t) GetSockNameError!void {
    switch (builtin.os.tag) {
        .windows => {
            const rc = std.os.windows.ws2_32.getsockname(fd, @ptrCast(addr), @ptrCast(addr_len));
            if (rc != 0) {
                return unexpectedWSAError(std.os.windows.ws2_32.WSAGetLastError());
            }
        },
        else => {
            const rc = posix.system.getsockname(fd, addr, addr_len);
            if (rc != 0) {
                return posix.unexpectedErrno(posix.errno(rc));
            }
        },
    }
}

pub const GetSockErrorError = error{Unexpected};

pub fn getSockError(fd: fd_t) GetSockErrorError!i32 {
    switch (builtin.os.tag) {
        .windows => {
            var err: i32 = 0;
            var len: i32 = @sizeOf(i32);
            const rc = std.os.windows.ws2_32.getsockopt(fd, SOL.SOCKET, SO.ERROR, @ptrCast(&err), &len);
            if (rc != 0) {
                return unexpectedWSAError(std.os.windows.ws2_32.WSAGetLastError());
            }
            return err;
        },
        else => {
            var err: i32 = 0;
            var len: socklen_t = @sizeOf(i32);
            const rc = posix.system.getsockopt(fd, SOL.SOCKET, SO.ERROR, @ptrCast(&err), &len);
            if (rc != 0) {
                return posix.unexpectedErrno(posix.errno(rc));
            }
            return err;
        },
    }
}

pub fn errnoToConnectError(err: i32) ConnectError {
    switch (builtin.os.tag) {
        .windows => {
            const wsa_err: std.os.windows.ws2_32.WinsockError = @enumFromInt(@as(u16, @intCast(err)));
            return switch (wsa_err) {
                .WSAECONNREFUSED => error.ConnectionRefused,
                .WSAEHOSTUNREACH, .WSAENETUNREACH => error.NetworkUnreachable,
                .WSAEACCES => error.AccessDenied,
                .WSAEADDRINUSE => error.AddressInUse,
                .WSAEADDRNOTAVAIL => error.AddressNotAvailable,
                .WSAEAFNOSUPPORT => error.AddressFamilyNotSupported,
                .WSAEISCONN => error.AlreadyConnected,
                .WSAEALREADY => error.ConnectionPending,
                else => unexpectedWSAError(wsa_err),
            };
        },
        else => {
            const errno_val: posix.system.E = @enumFromInt(err);
            return switch (errno_val) {
                .CONNREFUSED => error.ConnectionRefused,
                .HOSTUNREACH, .NETUNREACH => error.NetworkUnreachable,
                .ACCES, .PERM => error.AccessDenied,
                .ADDRINUSE => error.AddressInUse,
                .ADDRNOTAVAIL => error.AddressNotAvailable,
                .AFNOSUPPORT => error.AddressFamilyNotSupported,
                .ISCONN => error.AlreadyConnected,
                .ALREADY => error.ConnectionPending,
                else => posix.unexpectedErrno(errno_val),
            };
        },
    }
}

pub fn errnoToAcceptError(err: i32) AcceptError {
    switch (builtin.os.tag) {
        .windows => {
            const wsa_err: std.os.windows.ws2_32.WinsockError = @enumFromInt(@as(u16, @intCast(err)));
            return switch (wsa_err) {
                .WSAECONNABORTED => error.ConnectionAborted,
                .WSAEACCES => error.PermissionDenied,
                .WSAEPROTONOSUPPORT => error.ProtocolFailure,
                else => unexpectedWSAError(wsa_err),
            };
        },
        else => {
            const errno_val: posix.system.E = @enumFromInt(err);
            return switch (errno_val) {
                .CONNABORTED => error.ConnectionAborted,
                .ACCES, .PERM => error.PermissionDenied,
                .PROTO => error.ProtocolFailure,
                else => posix.unexpectedErrno(errno_val),
            };
        },
    }
}

pub fn errnoToRecvError(err: i32) RecvError {
    switch (builtin.os.tag) {
        .windows => {
            const wsa_err: std.os.windows.ws2_32.WinsockError = @enumFromInt(@as(u16, @intCast(err)));
            return switch (wsa_err) {
                .WSAECONNRESET, .WSAENETRESET => error.ConnectionResetByPeer,
                .WSAECONNREFUSED => error.ConnectionRefused,
                else => unexpectedWSAError(wsa_err),
            };
        },
        else => {
            const errno_val: posix.system.E = @enumFromInt(err);
            return switch (errno_val) {
                .CONNRESET => error.ConnectionResetByPeer,
                .CONNREFUSED => error.ConnectionRefused,
                else => posix.unexpectedErrno(errno_val),
            };
        },
    }
}

pub fn errnoToSendError(err: i32) SendError {
    switch (builtin.os.tag) {
        .windows => {
            const wsa_err: std.os.windows.ws2_32.WinsockError = @enumFromInt(@as(u16, @intCast(err)));
            return switch (wsa_err) {
                .WSAECONNRESET, .WSAENETRESET => error.ConnectionResetByPeer,
                .WSAESHUTDOWN => error.BrokenPipe,
                .WSAEACCES => error.AccessDenied,
                .WSAEMSGSIZE => error.MessageTooBig,
                else => unexpectedWSAError(wsa_err),
            };
        },
        else => {
            const errno_val: posix.system.E = @enumFromInt(err);
            return switch (errno_val) {
                .CONNRESET => error.ConnectionResetByPeer,
                .PIPE => error.BrokenPipe,
                .ACCES => error.AccessDenied,
                .MSGSIZE => error.MessageTooBig,
                else => posix.unexpectedErrno(errno_val),
            };
        },
    }
}

pub const RecvFlags = packed struct {
    peek: bool = false,
    waitall: bool = false,
};

pub const RecvError = error{
    WouldBlock,
    ConnectionRefused,
    ConnectionResetByPeer,
    SystemResources,
    Unexpected,
};

pub fn recv(fd: fd_t, buffers: []iovec, flags: RecvFlags) RecvError!usize {
    if (buffers.len == 0) return 0;

    var sys_flags: c_int = 0;
    if (flags.peek) sys_flags |= posix.system.MSG.PEEK;
    if (flags.waitall) sys_flags |= posix.system.MSG.WAITALL;

    switch (builtin.os.tag) {
        .windows => {
            var bytes_received: std.os.windows.DWORD = 0;
            var win_flags: std.os.windows.DWORD = @intCast(sys_flags);
            const rc = std.os.windows.ws2_32.WSARecv(
                fd,
                @ptrCast(buffers.ptr),
                @intCast(buffers.len),
                &bytes_received,
                &win_flags,
                null,
                null,
            );
            if (rc == std.os.windows.ws2_32.SOCKET_ERROR) {
                const err = std.os.windows.ws2_32.WSAGetLastError();
                return switch (err) {
                    .WSAEWOULDBLOCK => error.WouldBlock,
                    .WSAECONNREFUSED => error.ConnectionRefused,
                    .WSAECONNRESET => error.ConnectionResetByPeer,
                    else => unexpectedWSAError(err),
                };
            }
            return bytes_received;
        },
        else => {
            if (buffers.len == 1) {
                // Single buffer - use recv/recvfrom
                const buffer = buffers[0];
                while (true) {
                    const rc = if (builtin.os.tag == .linux)
                        posix.system.recvfrom(fd, buffer.base, buffer.len, @intCast(sys_flags), null, null)
                    else
                        posix.system.recv(fd, buffer.base, buffer.len, @intCast(sys_flags));

                    if (rc >= 0) {
                        return @intCast(rc);
                    }
                    switch (posix.errno(rc)) {
                        .INTR => continue,
                        .AGAIN => return error.WouldBlock,
                        .BADF => unreachable,
                        .CONNREFUSED => return error.ConnectionRefused,
                        .FAULT => unreachable,
                        .INVAL => unreachable,
                        .NOMEM => return error.SystemResources,
                        .NOTCONN => unreachable,
                        .NOTSOCK => unreachable,
                        .CONNRESET => return error.ConnectionResetByPeer,
                        else => |err| return posix.unexpectedErrno(err),
                    }
                }
            } else {
                // Multiple buffers - use recvmsg
                var msg: posix.system.msghdr = .{
                    .name = null,
                    .namelen = 0,
                    .iov = buffers.ptr,
                    .iovlen = @intCast(buffers.len),
                    .control = null,
                    .controllen = 0,
                    .flags = 0,
                };

                while (true) {
                    const rc = posix.system.recvmsg(fd, &msg, @intCast(sys_flags));

                    if (rc >= 0) {
                        return @intCast(rc);
                    }
                    switch (posix.errno(rc)) {
                        .INTR => continue,
                        .AGAIN => return error.WouldBlock,
                        .BADF => unreachable,
                        .CONNREFUSED => return error.ConnectionRefused,
                        .FAULT => unreachable,
                        .INVAL => unreachable,
                        .NOMEM => return error.SystemResources,
                        .NOTCONN => unreachable,
                        .NOTSOCK => unreachable,
                        .CONNRESET => return error.ConnectionResetByPeer,
                        else => |err| return posix.unexpectedErrno(err),
                    }
                }
            }
        },
    }
}

pub const SendFlags = packed struct {
    no_signal: bool = true,
};

pub const SendError = error{
    WouldBlock,
    AccessDenied,
    ConnectionResetByPeer,
    MessageTooBig,
    BrokenPipe,
    SystemResources,
    Unexpected,
};

pub fn send(fd: fd_t, buffers: []const iovec_const, flags: SendFlags) SendError!usize {
    if (buffers.len == 0) return 0;

    var sys_flags: c_int = 0;
    if (flags.no_signal and builtin.os.tag != .windows) {
        sys_flags |= posix.system.MSG.NOSIGNAL;
    }

    switch (builtin.os.tag) {
        .windows => {
            var bytes_sent: std.os.windows.DWORD = 0;
            const rc = std.os.windows.ws2_32.WSASend(
                fd,
                @ptrCast(@constCast(buffers.ptr)),
                @intCast(buffers.len),
                &bytes_sent,
                @intCast(sys_flags),
                null,
                null,
            );
            if (rc == std.os.windows.ws2_32.SOCKET_ERROR) {
                const err = std.os.windows.ws2_32.WSAGetLastError();
                return switch (err) {
                    .WSAEWOULDBLOCK => error.WouldBlock,
                    .WSAEACCES => error.AccessDenied,
                    .WSAECONNRESET => error.ConnectionResetByPeer,
                    .WSAEMSGSIZE => error.MessageTooBig,
                    else => unexpectedWSAError(err),
                };
            }
            return bytes_sent;
        },
        else => {
            if (buffers.len == 1) {
                // Single buffer - use send/sendto
                const buffer = buffers[0];
                while (true) {
                    const rc = if (builtin.os.tag == .linux)
                        posix.system.sendto(fd, buffer.base, buffer.len, @intCast(sys_flags), null, 0)
                    else
                        posix.system.send(fd, buffer.base, buffer.len, @intCast(sys_flags));

                    if (rc >= 0) {
                        return @intCast(rc);
                    }
                    switch (posix.errno(rc)) {
                        .INTR => continue,
                        .AGAIN => return error.WouldBlock,
                        .ACCES => return error.AccessDenied,
                        .ALREADY => unreachable,
                        .BADF => unreachable,
                        .CONNRESET => return error.ConnectionResetByPeer,
                        .DESTADDRREQ => unreachable,
                        .FAULT => unreachable,
                        .INVAL => unreachable,
                        .ISCONN => unreachable,
                        .MSGSIZE => return error.MessageTooBig,
                        .NOBUFS => return error.SystemResources,
                        .NOMEM => return error.SystemResources,
                        .NOTCONN => unreachable,
                        .NOTSOCK => unreachable,
                        .OPNOTSUPP => unreachable,
                        .PIPE => return error.BrokenPipe,
                        else => |err| return posix.unexpectedErrno(err),
                    }
                }
            } else {
                // Multiple buffers - use sendmsg
                var msg: posix.system.msghdr_const = .{
                    .name = null,
                    .namelen = 0,
                    .iov = buffers.ptr,
                    .iovlen = @intCast(buffers.len),
                    .control = null,
                    .controllen = 0,
                    .flags = 0,
                };

                while (true) {
                    const rc = posix.system.sendmsg(fd, &msg, @intCast(sys_flags));

                    if (rc >= 0) {
                        return @intCast(rc);
                    }
                    switch (posix.errno(rc)) {
                        .INTR => continue,
                        .AGAIN => return error.WouldBlock,
                        .ACCES => return error.AccessDenied,
                        .ALREADY => unreachable,
                        .BADF => unreachable,
                        .CONNRESET => return error.ConnectionResetByPeer,
                        .DESTADDRREQ => unreachable,
                        .FAULT => unreachable,
                        .INVAL => unreachable,
                        .ISCONN => unreachable,
                        .MSGSIZE => return error.MessageTooBig,
                        .NOBUFS => return error.SystemResources,
                        .NOMEM => return error.SystemResources,
                        .NOTCONN => unreachable,
                        .NOTSOCK => unreachable,
                        .OPNOTSUPP => unreachable,
                        .PIPE => return error.BrokenPipe,
                        else => |err| return posix.unexpectedErrno(err),
                    }
                }
            }
        },
    }
}

pub fn recvfrom(
    fd: fd_t,
    buffers: []iovec,
    flags: RecvFlags,
    addr: ?*sockaddr,
    addr_len: ?*socklen_t,
) RecvError!usize {
    if (buffers.len == 0) return 0;

    var sys_flags: c_int = 0;
    if (flags.peek) {
        sys_flags |= if (builtin.os.tag == .windows)
            std.os.windows.ws2_32.MSG.PEEK
        else
            posix.system.MSG.PEEK;
    }
    if (flags.waitall) {
        sys_flags |= if (builtin.os.tag == .windows)
            std.os.windows.ws2_32.MSG.WAITALL
        else
            posix.system.MSG.WAITALL;
    }

    switch (builtin.os.tag) {
        .windows => {
            var bytes_received: std.os.windows.DWORD = 0;
            var from_len: c_int = if (addr_len) |len| @intCast(len.*) else 0;
            const rc = std.os.windows.ws2_32.WSARecvFrom(
                fd,
                @ptrCast(buffers.ptr),
                @intCast(buffers.len),
                &bytes_received,
                @ptrCast(&sys_flags),
                addr,
                if (addr_len != null) &from_len else null,
                null,
                null,
            );
            if (addr_len) |len| len.* = @intCast(from_len);
            if (rc == std.os.windows.ws2_32.SOCKET_ERROR) {
                const err = std.os.windows.ws2_32.WSAGetLastError();
                return switch (err) {
                    .WSAEWOULDBLOCK => error.WouldBlock,
                    .WSAECONNREFUSED => error.ConnectionRefused,
                    .WSAECONNRESET => error.ConnectionResetByPeer,
                    else => unexpectedWSAError(err),
                };
            }
            return bytes_received;
        },
        else => {
            if (buffers.len == 1) {
                // Single buffer: use recvfrom directly
                const buffer = buffers[0];
                while (true) {
                    const rc = posix.system.recvfrom(
                        fd,
                        buffer.base,
                        buffer.len,
                        @intCast(sys_flags),
                        addr,
                        addr_len,
                    );

                    if (rc >= 0) {
                        return @intCast(rc);
                    }
                    switch (posix.errno(rc)) {
                        .INTR => continue,
                        .AGAIN => return error.WouldBlock,
                        .BADF => unreachable,
                        .CONNREFUSED => return error.ConnectionRefused,
                        .FAULT => unreachable,
                        .INVAL => unreachable,
                        .NOMEM => return error.SystemResources,
                        .NOTCONN => unreachable,
                        .NOTSOCK => unreachable,
                        .CONNRESET => return error.ConnectionResetByPeer,
                        else => |err| return posix.unexpectedErrno(err),
                    }
                }
            } else {
                // Multiple buffers: use recvmsg
                var msg: posix.system.msghdr = .{
                    .name = addr,
                    .namelen = if (addr_len) |len| len.* else 0,
                    .iov = buffers.ptr,
                    .iovlen = @intCast(buffers.len),
                    .control = null,
                    .controllen = 0,
                    .flags = 0,
                };

                while (true) {
                    const rc = posix.system.recvmsg(fd, &msg, @intCast(sys_flags));

                    if (rc >= 0) {
                        if (addr_len) |len| len.* = msg.namelen;
                        return @intCast(rc);
                    }
                    switch (posix.errno(rc)) {
                        .INTR => continue,
                        .AGAIN => return error.WouldBlock,
                        .BADF => unreachable,
                        .CONNREFUSED => return error.ConnectionRefused,
                        .FAULT => unreachable,
                        .INVAL => unreachable,
                        .NOMEM => return error.SystemResources,
                        .NOTCONN => unreachable,
                        .NOTSOCK => unreachable,
                        .CONNRESET => return error.ConnectionResetByPeer,
                        else => |err| return posix.unexpectedErrno(err),
                    }
                }
            }
        },
    }
}

pub fn sendto(
    fd: fd_t,
    buffers: []const iovec_const,
    flags: SendFlags,
    addr: *const sockaddr,
    addr_len: socklen_t,
) SendError!usize {
    if (buffers.len == 0) return 0;

    var sys_flags: c_int = 0;
    if (flags.no_signal and builtin.os.tag != .windows) {
        sys_flags |= posix.system.MSG.NOSIGNAL;
    }

    switch (builtin.os.tag) {
        .windows => {
            var bytes_sent: std.os.windows.DWORD = 0;
            const rc = std.os.windows.ws2_32.WSASendTo(
                fd,
                @ptrCast(@constCast(buffers.ptr)),
                @intCast(buffers.len),
                &bytes_sent,
                @intCast(sys_flags),
                addr,
                @intCast(addr_len),
                null,
                null,
            );
            if (rc == std.os.windows.ws2_32.SOCKET_ERROR) {
                const err = std.os.windows.ws2_32.WSAGetLastError();
                return switch (err) {
                    .WSAEWOULDBLOCK => error.WouldBlock,
                    .WSAEACCES => error.AccessDenied,
                    .WSAECONNRESET => error.ConnectionResetByPeer,
                    .WSAEMSGSIZE => error.MessageTooBig,
                    else => unexpectedWSAError(err),
                };
            }
            return bytes_sent;
        },
        else => {
            if (buffers.len == 1) {
                // Single buffer - use sendto
                const buffer = buffers[0];
                while (true) {
                    const rc = posix.system.sendto(
                        fd,
                        buffer.base,
                        buffer.len,
                        @intCast(sys_flags),
                        addr,
                        addr_len,
                    );

                    if (rc >= 0) {
                        return @intCast(rc);
                    }
                    switch (posix.errno(rc)) {
                        .INTR => continue,
                        .AGAIN => return error.WouldBlock,
                        .ACCES => return error.AccessDenied,
                        .ALREADY => unreachable,
                        .BADF => unreachable,
                        .CONNRESET => return error.ConnectionResetByPeer,
                        .DESTADDRREQ => unreachable,
                        .FAULT => unreachable,
                        .INVAL => unreachable,
                        .ISCONN => unreachable,
                        .MSGSIZE => return error.MessageTooBig,
                        .NOBUFS => return error.SystemResources,
                        .NOMEM => return error.SystemResources,
                        .NOTCONN => unreachable,
                        .NOTSOCK => unreachable,
                        .OPNOTSUPP => unreachable,
                        .PIPE => return error.BrokenPipe,
                        else => |err| return posix.unexpectedErrno(err),
                    }
                }
            } else {
                // Multiple buffers - use sendmsg
                var msg: posix.system.msghdr_const = .{
                    .name = addr,
                    .namelen = addr_len,
                    .iov = buffers.ptr,
                    .iovlen = @intCast(buffers.len),
                    .control = null,
                    .controllen = 0,
                    .flags = 0,
                };

                while (true) {
                    const rc = posix.system.sendmsg(fd, &msg, @intCast(sys_flags));

                    if (rc >= 0) {
                        return @intCast(rc);
                    }
                    switch (posix.errno(rc)) {
                        .INTR => continue,
                        .AGAIN => return error.WouldBlock,
                        .ACCES => return error.AccessDenied,
                        .ALREADY => unreachable,
                        .BADF => unreachable,
                        .CONNRESET => return error.ConnectionResetByPeer,
                        .DESTADDRREQ => unreachable,
                        .FAULT => unreachable,
                        .INVAL => unreachable,
                        .ISCONN => unreachable,
                        .MSGSIZE => return error.MessageTooBig,
                        .NOBUFS => return error.SystemResources,
                        .NOMEM => return error.SystemResources,
                        .NOTCONN => unreachable,
                        .NOTSOCK => unreachable,
                        .OPNOTSUPP => unreachable,
                        .PIPE => return error.BrokenPipe,
                        else => |err| return posix.unexpectedErrno(err),
                    }
                }
            }
        },
    }
}

/// Creates a connected socket pair using loopback connection (for Windows async wakeup)
/// Returns [read_socket, write_socket] - writing to write_socket wakes up poll on read_socket
pub const CreateLoopbackSocketPairError = OpenError || BindError || ListenError || ConnectError || AcceptError || GetSockNameError;

pub fn createLoopbackSocketPair() CreateLoopbackSocketPairError![2]fd_t {
    ensureWSAInitialized();

    // Create a listening socket on loopback
    const listen_sock = try socket(.ipv4, .stream, .tcp, .{ .nonblocking = true });
    errdefer close(listen_sock);

    // Bind to 127.0.0.1:0 (any available port)
    var bind_addr: sockaddr = @bitCast(std.posix.sockaddr.in{
        .family = AF.INET,
        .port = 0, // Let OS choose port
        .addr = 0x0100007F, // 127.0.0.1 in network byte order (little-endian)
        .zero = [_]u8{0} ** 8,
    });
    try bind(listen_sock, &bind_addr, @sizeOf(std.posix.sockaddr.in));

    // Listen for connections
    try listen(listen_sock, 1);

    // Get the actual bound address
    var actual_addr: sockaddr = undefined;
    var addr_len: socklen_t = @sizeOf(sockaddr);
    try getsockname(listen_sock, &actual_addr, &addr_len);

    // Create connecting socket
    const write_sock = try socket(.ipv4, .stream, .tcp, .{ .nonblocking = true });
    errdefer close(write_sock);

    // Connect to the listening socket
    connect(write_sock, &actual_addr, addr_len) catch |err| {
        if (err != error.WouldBlock) return err;
        // WouldBlock is expected for non-blocking connect
    };

    // Accept the connection
    const read_sock = try accept(listen_sock, null, null, .{ .nonblocking = true });
    errdefer close(read_sock);

    // Close the listening socket - no longer needed
    close(listen_sock);

    return .{ read_sock, write_sock };
}
