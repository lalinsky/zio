const std = @import("std");
const builtin = @import("builtin");
const posix = @import("posix.zig");
const windows = @import("windows.zig");

const unexpectedError = @import("base.zig").unexpectedError;

const log = @import("../common.zig").log;

// Windows addrinfo definitions
const windows_addrinfo = if (builtin.os.tag == .windows) extern struct {
    flags: AI,
    family: i32,
    socktype: i32,
    protocol: i32,
    addrlen: usize,
    canonname: ?[*:0]u8,
    addr: ?*windows.sockaddr,
    next: ?*windows_addrinfo,
} else void;

const windows_extern = if (builtin.os.tag == .windows) struct {
    pub extern "ws2_32" fn getaddrinfo(
        pNodeName: ?[*:0]const u8,
        pServiceName: ?[*:0]const u8,
        pHints: ?*const windows_addrinfo,
        ppResult: *?*windows_addrinfo,
    ) callconv(.winapi) i32;

    pub extern "ws2_32" fn freeaddrinfo(
        pAddrInfo: *windows_addrinfo,
    ) callconv(.winapi) void;
} else struct {};

pub const has_unix_sockets = switch (builtin.os.tag) {
    .windows => builtin.os.version_range.windows.isAtLeast(.win10_rs4) orelse false,
    .wasi => false,
    else => true,
};

pub const has_unix_dgram_sockets = switch (builtin.os.tag) {
    .windows => false, // Windows only supports stream Unix sockets
    .wasi => false,
    else => true,
};

var wsa_init_once = std.once(wsaInit);

fn wsaInit() void {
    if (builtin.os.tag == .windows) {
        var wsa_data: windows.WSADATA = undefined;
        _ = windows.WSAStartup(2 << 8 | 2, &wsa_data);
    }
}

pub fn ensureWSAInitialized() void {
    wsa_init_once.call();
}

pub const fd_t = switch (builtin.os.tag) {
    .windows => windows.SOCKET,
    else => posix.system.fd_t,
};

pub const pollfd = switch (builtin.os.tag) {
    .windows => windows.pollfd,
    else => posix.system.pollfd,
};

pub const POLL = switch (builtin.os.tag) {
    .windows => windows.POLL,
    else => posix.system.POLL,
};

pub const sockaddr = posix.system.sockaddr;
pub const AF = posix.system.AF;
pub const SOCK = posix.system.SOCK;
pub const IPPROTO = posix.IPPROTO;
pub const socklen_t = if (builtin.os.tag == .windows) i32 else posix.system.socklen_t;
pub const SOL = posix.system.SOL;
pub const SO = posix.system.SO;

pub const E = if (builtin.os.tag == .windows) windows.WinsockError else posix.system.E;

pub const iovec = @import("base.zig").iovec;
pub const iovec_const = @import("base.zig").iovec_const;

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
                const rc = windows.WSAPoll(fds.ptr, @intCast(fds.len), timeout);
                if (rc >= 0) {
                    return @intCast(rc);
                }
                const err = windows.WSAGetLastError();
                switch (err) {
                    .EINTR => continue,
                    .ENOBUFS => return error.SystemResources,
                    .EFAULT => unreachable,
                    .EINVAL => {
                        log.err("WSAPoll returned WSAEINVAL - invalid parameter (fds.len={}, timeout={})", .{ fds.len, timeout });
                        return unexpectedError(err);
                    },
                    else => return unexpectedError(err),
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
                    else => |err| return unexpectedError(err),
                }
            }
        },
    }
}

pub fn close(fd: fd_t) void {
    switch (builtin.os.tag) {
        .windows => {
            _ = windows.closesocket(fd);
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
                        unexpectedError(err) catch {};
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
    SocketUnconnected,
    ConnectionAborted,
    ConnectionResetByPeer,
    NetworkDown,
    Canceled,
    Unexpected,
};

pub fn shutdown(fd: fd_t, how: ShutdownHow) ShutdownError!void {
    switch (builtin.os.tag) {
        .windows => {
            const system_how: i32 = switch (how) {
                .receive => windows.SD_RECEIVE,
                .send => windows.SD_SEND,
                .both => windows.SD_BOTH,
            };
            const rc = windows.shutdown(fd, system_how);
            if (rc == windows.SOCKET_ERROR) {
                const err = windows.WSAGetLastError();
                return errnoToShutdownError(err);
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
                    else => |err| return errnoToShutdownError(err),
                }
            }
        },
    }
}

pub const Domain = enum(c_int) {
    unspec = AF.UNSPEC,
    ipv4 = AF.INET,
    ipv6 = AF.INET6,
    unix = AF.UNIX,
    _,

    /// Convert from POSIX address family constant
    pub fn fromPosix(af: anytype) Domain {
        return @enumFromInt(af);
    }

    /// Convert to POSIX address family constant
    pub fn toPosix(self: Domain) c_int {
        return @intFromEnum(self);
    }
};

pub const Type = enum(c_int) {
    stream = SOCK.STREAM,
    dgram = SOCK.DGRAM,
    raw = SOCK.RAW,
    seqpacket = SOCK.SEQPACKET,
    _,

    /// Convert from POSIX socket type constant
    pub fn fromPosix(sock_type: anytype) Type {
        return @enumFromInt(sock_type);
    }

    /// Convert to POSIX socket type constant
    pub fn toPosix(self: Type) c_int {
        return @intFromEnum(self);
    }
};

pub const Protocol = enum(c_int) {
    ip = IPPROTO.IP,
    icmp = IPPROTO.ICMP,
    tcp = IPPROTO.TCP,
    udp = IPPROTO.UDP,
    ipv6 = IPPROTO.IPV6,
    icmpv6 = IPPROTO.ICMPV6,
    raw = IPPROTO.RAW,
    _,

    /// Convert from POSIX protocol constant
    pub fn fromPosix(protocol: anytype) Protocol {
        return @enumFromInt(protocol);
    }

    /// Convert to POSIX protocol constant
    pub fn toPosix(self: Protocol) c_int {
        return @intFromEnum(self);
    }
};

pub const OpenFlags = packed struct {
    nonblocking: bool = false,
    cloexec: bool = true,
};

pub const OpenError = error{
    AddressFamilyUnsupported,
    ProtocolNotSupported,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    SystemResources,
    PermissionDenied,
    Canceled,
    Unexpected,
};

pub fn socket(domain: Domain, socket_type: Type, protocol: Protocol, flags: OpenFlags) OpenError!fd_t {
    switch (builtin.os.tag) {
        .windows => {
            const sock = windows.WSASocketW(
                domain.toPosix(),
                socket_type.toPosix(),
                protocol.toPosix(),
                null,
                0,
                windows.WSA_FLAG_OVERLAPPED,
            );
            if (sock == windows.INVALID_SOCKET) {
                const err = windows.WSAGetLastError();
                return errnoToOpenError(err);
            }
            if (flags.nonblocking) {
                var mode: c_ulong = 1;
                _ = windows.ioctlsocket(sock, windows.FIONBIO, &mode);
            }
            return sock;
        },
        else => {
            var sock_flags: c_int = socket_type.toPosix();
            // Linux supports SOCK_NONBLOCK and SOCK_CLOEXEC flags in socket()
            // BSD (macOS, FreeBSD, etc.) requires fcntl() instead
            if (builtin.os.tag == .linux) {
                if (flags.nonblocking) {
                    sock_flags |= SOCK.NONBLOCK;
                }
                if (flags.cloexec) {
                    sock_flags |= SOCK.CLOEXEC;
                }
            }

            while (true) {
                const rc = posix.system.socket(
                    @intCast(domain.toPosix()),
                    @intCast(sock_flags),
                    @intCast(protocol.toPosix()),
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
                    else => |err| return errnoToOpenError(err),
                }
            }
        },
    }
}

pub const BindError = error{
    AddressInUse,
    AddressNotAvailable,
    AddressFamilyUnsupported,
    AccessDenied,
    FileDescriptorNotASocket,
    SymLinkLoop,
    NameTooLong,
    FileNotFound,
    NotDir,
    ReadOnlyFileSystem,
    NetworkDown,
    InputOutput,
    SystemResources,
    Unexpected,
};

pub fn errnoToBindError(err: E) BindError {
    switch (builtin.os.tag) {
        .windows => {
            return switch (err) {
                .EADDRINUSE => error.AddressInUse,
                .EADDRNOTAVAIL => error.AddressNotAvailable,
                .EAFNOSUPPORT => error.AddressFamilyUnsupported,
                .EACCES => error.AccessDenied,
                .ENOTSOCK => error.FileDescriptorNotASocket,
                .ENETDOWN => error.NetworkDown,
                .ENOBUFS => error.SystemResources,
                else => unexpectedError(err),
            };
        },
        else => {
            return switch (err) {
                .SUCCESS => unreachable,
                .ACCES, .PERM => error.AccessDenied,
                .ADDRINUSE => error.AddressInUse,
                .NOTSOCK => error.FileDescriptorNotASocket,
                .AFNOSUPPORT => error.AddressFamilyUnsupported,
                .ADDRNOTAVAIL => error.AddressNotAvailable,
                .LOOP => error.SymLinkLoop,
                .NAMETOOLONG => error.NameTooLong,
                .NOENT => error.FileNotFound,
                .NOMEM => error.SystemResources,
                .AGAIN => error.SystemResources, // Kernel resources temporarily unavailable (FreeBSD)
                .NOTDIR => error.NotDir,
                .ROFS => error.ReadOnlyFileSystem,
                .IO => error.InputOutput,
                .NETDOWN => error.NetworkDown,
                else => |e| unexpectedError(e),
            };
        },
    }
}

pub fn bind(fd: fd_t, addr: *const sockaddr, addr_len: socklen_t) BindError!void {
    switch (builtin.os.tag) {
        .windows => {
            const rc = windows.bind(fd, @ptrCast(addr), @intCast(addr_len));
            if (rc == windows.SOCKET_ERROR) {
                const err = windows.WSAGetLastError();
                return errnoToBindError(err);
            }
        },
        else => {
            while (true) {
                const rc = posix.system.bind(fd, addr, addr_len);
                switch (posix.errno(rc)) {
                    .SUCCESS => return,
                    .INTR => continue,
                    else => |err| return errnoToBindError(err),
                }
            }
        },
    }
}

pub const ListenError = error{
    AddressInUse,
    AlreadyConnected,
    OperationNotSupported,
    FileDescriptorNotASocket,
    NetworkDown,
    SystemResources,
    Unexpected,
};

pub fn errnoToListenError(err: E) ListenError {
    switch (builtin.os.tag) {
        .windows => {
            return switch (err) {
                .EADDRINUSE => error.AddressInUse,
                .EISCONN => error.AlreadyConnected,
                .EOPNOTSUPP => error.OperationNotSupported,
                .ENOTSOCK => error.FileDescriptorNotASocket,
                .ENETDOWN => error.NetworkDown,
                .ENOBUFS, .EMFILE => error.SystemResources,
                else => unexpectedError(err),
            };
        },
        else => {
            return switch (err) {
                .SUCCESS => unreachable,
                .ADDRINUSE => error.AddressInUse,
                .OPNOTSUPP => error.OperationNotSupported,
                .NOTSOCK => error.FileDescriptorNotASocket,
                .NETDOWN => error.NetworkDown,
                else => |e| unexpectedError(e),
            };
        },
    }
}

pub fn listen(fd: fd_t, backlog: u31) ListenError!void {
    switch (builtin.os.tag) {
        .windows => {
            const rc = windows.listen(fd, backlog);
            if (rc == windows.SOCKET_ERROR) {
                const err = windows.WSAGetLastError();
                return errnoToListenError(err);
            }
        },
        else => {
            while (true) {
                const rc = posix.system.listen(fd, backlog);
                switch (posix.errno(rc)) {
                    .SUCCESS => return,
                    .INTR => continue,
                    else => |err| return errnoToListenError(err),
                }
            }
        },
    }
}

pub const ConnectError = error{
    AccessDenied,
    AddressInUse,
    AddressNotAvailable,
    AddressFamilyUnsupported,
    WouldBlock,
    AlreadyConnected,
    ConnectionPending,
    ConnectionRefused,
    ConnectionResetByPeer,
    ConnectionTimedOut,
    NetworkUnreachable,
    FileDescriptorNotASocket,
    FileNotFound,
    SymLinkLoop,
    NameTooLong,
    NotDir,
    NetworkDown,
    SystemResources,
    Canceled,
    Unexpected,
};

pub fn connect(fd: fd_t, addr: *const sockaddr, addr_len: socklen_t) ConnectError!void {
    switch (builtin.os.tag) {
        .windows => {
            const rc = windows.connect(fd, @ptrCast(addr), @intCast(addr_len));
            if (rc == windows.SOCKET_ERROR) {
                const err = windows.WSAGetLastError();
                return errnoToConnectError(err);
            }
        },
        else => {
            while (true) {
                const rc = posix.system.connect(fd, addr, addr_len);
                switch (posix.errno(rc)) {
                    .SUCCESS => return,
                    .INTR => continue,
                    else => |err| return errnoToConnectError(err),
                }
            }
        },
    }
}

pub const AcceptError = error{
    WouldBlock,
    ConnectionAborted,
    ConnectionResetByPeer,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    SystemResources,
    FileDescriptorNotASocket,
    SocketNotListening,
    OperationNotSupported,
    ProtocolFailure,
    BlockedByFirewall,
    NetworkDown,
    Canceled,
    Unexpected,
};

pub fn accept(fd: fd_t, addr: ?*sockaddr, addr_len: ?*socklen_t, flags: OpenFlags) AcceptError!fd_t {
    switch (builtin.os.tag) {
        .windows => {
            const sock = windows.accept(
                fd,
                if (addr) |a| @ptrCast(a) else null,
                addr_len,
            );
            if (sock == windows.INVALID_SOCKET) {
                const err = windows.WSAGetLastError();
                return errnoToAcceptError(err);
            }
            if (flags.nonblocking) {
                var mode: c_ulong = 1;
                _ = windows.ioctlsocket(sock, windows.FIONBIO, &mode);
            }
            return sock;
        },
        else => {
            // Linux supports accept4 with SOCK_NONBLOCK and SOCK_CLOEXEC flags
            // BSD (macOS, FreeBSD, etc.) requires fcntl() instead
            var accept_flags: c_int = 0;
            if (builtin.os.tag == .linux) {
                if (flags.nonblocking) {
                    accept_flags |= SOCK.NONBLOCK;
                }
                if (flags.cloexec) {
                    accept_flags |= SOCK.CLOEXEC;
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
                    else => |err| return errnoToAcceptError(err),
                }
            }
        },
    }
}

pub const GetSockNameError = error{Unexpected};

pub fn getsockname(fd: fd_t, addr: *sockaddr, addr_len: *socklen_t) GetSockNameError!void {
    switch (builtin.os.tag) {
        .windows => {
            const rc = windows.getsockname(fd, @ptrCast(addr), @ptrCast(addr_len));
            if (rc != 0) {
                return unexpectedError(windows.WSAGetLastError());
            }
        },
        else => {
            const rc = posix.system.getsockname(fd, addr, addr_len);
            if (rc != 0) {
                return unexpectedError(posix.errno(rc));
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
            const rc = windows.getsockopt(fd, SOL.SOCKET, SO.ERROR, @ptrCast(&err), &len);
            if (rc != 0) {
                return unexpectedError(windows.WSAGetLastError());
            }
            return err;
        },
        else => {
            var err: i32 = 0;
            var len: socklen_t = @sizeOf(i32);
            const rc = posix.system.getsockopt(fd, SOL.SOCKET, SO.ERROR, @ptrCast(&err), &len);
            if (rc != 0) {
                return unexpectedError(posix.errno(rc));
            }
            return err;
        },
    }
}

pub fn errnoToConnectError(err: E) ConnectError {
    switch (builtin.os.tag) {
        .windows => {
            return switch (err) {
                .ECONNREFUSED => error.ConnectionRefused,
                .ETIMEDOUT => error.ConnectionTimedOut,
                .EHOSTUNREACH, .ENETUNREACH => error.NetworkUnreachable,
                .EACCES => error.AccessDenied,
                .EADDRINUSE => error.AddressInUse,
                .EADDRNOTAVAIL => error.AddressNotAvailable,
                .EAFNOSUPPORT => error.AddressFamilyUnsupported,
                .EISCONN => error.AlreadyConnected,
                .EALREADY => error.ConnectionPending,
                .EWOULDBLOCK => error.WouldBlock,
                .ENOTSOCK => error.FileDescriptorNotASocket,
                .ENETDOWN => error.NetworkDown,
                .ENOBUFS => error.SystemResources,
                .OPERATION_ABORTED => error.Canceled,
                else => unexpectedError(err),
            };
        },
        else => {
            return switch (err) {
                .SUCCESS => unreachable,
                .CONNREFUSED => error.ConnectionRefused,
                .CONNRESET => error.ConnectionResetByPeer,
                .TIMEDOUT => error.ConnectionTimedOut,
                .HOSTUNREACH, .NETUNREACH => error.NetworkUnreachable,
                .ACCES, .PERM => error.AccessDenied,
                .ADDRINUSE => error.AddressInUse,
                .ADDRNOTAVAIL => error.AddressNotAvailable,
                .AFNOSUPPORT => error.AddressFamilyUnsupported,
                .ISCONN => error.AlreadyConnected,
                .ALREADY, .INPROGRESS => error.ConnectionPending,
                .AGAIN => error.WouldBlock, // Also: insufficient routing cache or no auto-assigned ports
                .NOTSOCK => error.FileDescriptorNotASocket,
                .NOENT => error.FileNotFound,
                .LOOP => error.SymLinkLoop,
                .NAMETOOLONG => error.NameTooLong,
                .NOTDIR => error.NotDir,
                .CANCELED => error.Canceled,
                else => |e| unexpectedError(e),
            };
        },
    }
}

pub fn errnoToAcceptError(err: E) AcceptError {
    switch (builtin.os.tag) {
        .windows => {
            return switch (err) {
                .EWOULDBLOCK => error.WouldBlock,
                .ECONNABORTED => error.ConnectionAborted,
                .ECONNRESET => error.ConnectionResetByPeer,
                .EMFILE => error.ProcessFdQuotaExceeded,
                .ENOBUFS => error.SystemResources,
                .ENOTSOCK => error.FileDescriptorNotASocket,
                .EINVAL => error.SocketNotListening,
                .EOPNOTSUPP => error.ProtocolFailure,
                .EPROTONOSUPPORT => error.ProtocolFailure,
                .ENETDOWN => error.NetworkDown,
                .OPERATION_ABORTED => error.Canceled,
                else => unexpectedError(err),
            };
        },
        else => {
            return switch (err) {
                .SUCCESS => unreachable,
                .AGAIN => error.WouldBlock,
                .CONNABORTED => error.ConnectionAborted,
                .CONNRESET => error.ConnectionResetByPeer,
                .MFILE => error.ProcessFdQuotaExceeded,
                .NFILE => error.SystemFdQuotaExceeded,
                .NOMEM, .NOBUFS => error.SystemResources,
                .NOTSOCK => error.FileDescriptorNotASocket,
                .INVAL => error.SocketNotListening,
                .OPNOTSUPP => error.OperationNotSupported,
                .PROTO => error.ProtocolFailure,
                .PERM => error.BlockedByFirewall,
                .NETDOWN => error.NetworkDown,
                .CANCELED => error.Canceled,
                else => |e| unexpectedError(e),
            };
        },
    }
}

pub fn errnoToRecvError(err: E) RecvError {
    switch (builtin.os.tag) {
        .windows => {
            return switch (err) {
                .EWOULDBLOCK => error.WouldBlock,
                .ECONNREFUSED => error.ConnectionRefused,
                .ECONNRESET, .ENETRESET => error.ConnectionResetByPeer,
                .ECONNABORTED => error.ConnectionAborted,
                .ETIMEDOUT => error.ConnectionTimedOut,
                .ENOTCONN => error.SocketNotConnected,
                .ENOTSOCK => error.FileDescriptorNotASocket,
                .ESHUTDOWN => error.SocketShutdown,
                .EOPNOTSUPP => error.OperationNotSupported,
                .ENETDOWN => error.NetworkDown,
                .ENOBUFS, .EINVAL => error.SystemResources,
                .OPERATION_ABORTED => error.Canceled,
                else => unexpectedError(err),
            };
        },
        else => {
            return switch (err) {
                .SUCCESS => unreachable,
                .AGAIN => error.WouldBlock,
                .CONNREFUSED => error.ConnectionRefused,
                .CONNRESET => error.ConnectionResetByPeer,
                .NOTCONN => error.SocketNotConnected,
                .NOTSOCK => error.FileDescriptorNotASocket,
                .NOMEM => error.SystemResources,
                .CANCELED => error.Canceled,
                else => |e| unexpectedError(e),
            };
        },
    }
}

pub fn errnoToSendError(err: E) SendError {
    switch (builtin.os.tag) {
        .windows => {
            return switch (err) {
                .EWOULDBLOCK => error.WouldBlock,
                .EACCES => error.AccessDenied,
                .ECONNRESET, .ENETRESET => error.ConnectionResetByPeer,
                .ECONNABORTED => error.ConnectionAborted,
                .ETIMEDOUT => error.ConnectionTimedOut,
                .ENOTCONN => error.SocketNotConnected,
                .ENOTSOCK => error.FileDescriptorNotASocket,
                .EMSGSIZE => error.MessageTooBig,
                .ESHUTDOWN => error.BrokenPipe,
                .EHOSTUNREACH, .ENETDOWN => error.NetworkUnreachable,
                .EOPNOTSUPP => error.OperationNotSupported,
                .ENOBUFS => error.SystemResources,
                .OPERATION_ABORTED => error.Canceled,
                else => unexpectedError(err),
            };
        },
        else => {
            return switch (err) {
                .SUCCESS => unreachable,
                .AGAIN => error.WouldBlock,
                .ACCES => error.AccessDenied,
                .CONNRESET => error.ConnectionResetByPeer,
                .NOTCONN => error.SocketNotConnected,
                .NOTSOCK => error.FileDescriptorNotASocket,
                .MSGSIZE => error.MessageTooBig,
                .PIPE => error.BrokenPipe,
                .HOSTUNREACH, .HOSTDOWN, .NETDOWN => error.NetworkUnreachable,
                .NOBUFS => error.SystemResources,
                .CANCELED => error.Canceled,
                else => |e| unexpectedError(e),
            };
        },
    }
}

pub fn errnoToShutdownError(err: E) ShutdownError {
    switch (builtin.os.tag) {
        .windows => {
            return switch (err) {
                .ENOTCONN => error.SocketUnconnected,
                .ENOTSOCK => error.Unexpected,
                .ECONNABORTED => error.ConnectionAborted,
                .ECONNRESET => error.ConnectionResetByPeer,
                .ENETDOWN => error.NetworkDown,
                .OPERATION_ABORTED => error.Canceled,
                else => unexpectedError(err),
            };
        },
        else => {
            return switch (err) {
                .SUCCESS => unreachable,
                .NOTCONN => error.SocketUnconnected,
                .NOTSOCK => error.Unexpected,
                .CONNABORTED => error.ConnectionAborted,
                .CONNRESET => error.ConnectionResetByPeer,
                .NETDOWN => error.NetworkDown,
                .CANCELED => error.Canceled,
                else => |e| unexpectedError(e),
            };
        },
    }
}

pub fn errnoToOpenError(err: E) OpenError {
    switch (builtin.os.tag) {
        .windows => {
            return switch (err) {
                .EAFNOSUPPORT => error.AddressFamilyUnsupported,
                .EPROTONOSUPPORT => error.ProtocolNotSupported,
                .EMFILE => error.ProcessFdQuotaExceeded,
                .ENOBUFS => error.SystemResources,
                .OPERATION_ABORTED => error.Canceled,
                else => unexpectedError(err),
            };
        },
        else => {
            return switch (err) {
                .SUCCESS => unreachable,
                .ACCES => error.PermissionDenied,
                .AFNOSUPPORT => error.AddressFamilyUnsupported,
                .MFILE => error.ProcessFdQuotaExceeded,
                .NFILE => error.SystemFdQuotaExceeded,
                .NOBUFS, .NOMEM => error.SystemResources,
                .PROTONOSUPPORT => error.ProtocolNotSupported,
                .CANCELED => error.Canceled,
                else => |e| unexpectedError(e),
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
    ConnectionAborted,
    ConnectionTimedOut,
    SocketNotConnected,
    FileDescriptorNotASocket,
    SocketShutdown,
    OperationNotSupported,
    NetworkDown,
    SystemResources,
    Canceled,
    Unexpected,
};

pub fn recv(fd: fd_t, buffers: []iovec, flags: RecvFlags) RecvError!usize {
    if (buffers.len == 0) return 0;

    var sys_flags: c_int = 0;
    if (flags.peek) sys_flags |= posix.system.MSG.PEEK;
    if (flags.waitall) sys_flags |= posix.system.MSG.WAITALL;

    switch (builtin.os.tag) {
        .windows => {
            var bytes_received: windows.DWORD = 0;
            var win_flags: windows.DWORD = @intCast(sys_flags);
            const rc = windows.WSARecv(
                fd,
                @ptrCast(buffers.ptr),
                @intCast(buffers.len),
                &bytes_received,
                &win_flags,
                null,
                null,
            );
            if (rc == windows.SOCKET_ERROR) {
                const err = windows.WSAGetLastError();
                return errnoToRecvError(err);
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
                        else => |err| return errnoToRecvError(err),
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
                        else => |err| return errnoToRecvError(err),
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
    ConnectionAborted,
    ConnectionTimedOut,
    SocketNotConnected,
    FileDescriptorNotASocket,
    MessageTooBig,
    BrokenPipe,
    NetworkUnreachable,
    NetworkDown,
    OperationNotSupported,
    SystemResources,
    Canceled,
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
            var bytes_sent: windows.DWORD = 0;
            const rc = windows.WSASend(
                fd,
                @ptrCast(@constCast(buffers.ptr)),
                @intCast(buffers.len),
                &bytes_sent,
                @intCast(sys_flags),
                null,
                null,
            );
            if (rc == windows.SOCKET_ERROR) {
                const err = windows.WSAGetLastError();
                return errnoToSendError(err);
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
                        else => |err| return errnoToSendError(err),
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
                        else => |err| return errnoToSendError(err),
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
            windows.MSG.PEEK
        else
            posix.system.MSG.PEEK;
    }
    if (flags.waitall) {
        sys_flags |= if (builtin.os.tag == .windows)
            windows.MSG.WAITALL
        else
            posix.system.MSG.WAITALL;
    }

    switch (builtin.os.tag) {
        .windows => {
            var bytes_received: windows.DWORD = 0;
            var from_len: c_int = if (addr_len) |len| @intCast(len.*) else 0;
            const rc = windows.WSARecvFrom(
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
            if (rc == windows.SOCKET_ERROR) {
                const err = windows.WSAGetLastError();
                return errnoToRecvError(err);
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
                        else => |err| return errnoToRecvError(err),
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
                        else => |err| return errnoToRecvError(err),
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
            var bytes_sent: windows.DWORD = 0;
            const rc = windows.WSASendTo(
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
            if (rc == windows.SOCKET_ERROR) {
                const err = windows.WSAGetLastError();
                return errnoToSendError(err);
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
                        else => |err| return errnoToSendError(err),
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
                        else => |err| return errnoToSendError(err),
                    }
                }
            }
        },
    }
}

pub const RecvMsgResult = struct {
    len: usize,
    flags: u32,
};

pub fn recvmsg(
    fd: fd_t,
    buffers: []iovec,
    flags: RecvFlags,
    addr: ?*sockaddr,
    addr_len: ?*socklen_t,
    control: ?[]u8,
) RecvError!RecvMsgResult {
    if (buffers.len == 0) return .{ .len = 0, .flags = 0 };

    var sys_flags: c_int = 0;
    if (flags.peek) sys_flags |= posix.system.MSG.PEEK;
    if (flags.waitall) sys_flags |= posix.system.MSG.WAITALL;

    switch (builtin.os.tag) {
        .windows => {
            // Windows implementation should be handled in the backend
            @panic("recvmsg not supported on Windows - use backend implementation");
        },
        else => {
            var msg: posix.system.msghdr = .{
                .name = if (addr) |a| @ptrCast(a) else null,
                .namelen = if (addr_len) |len| len.* else 0,
                .iov = buffers.ptr,
                .iovlen = @intCast(buffers.len),
                .control = if (control) |ctl| ctl.ptr else null,
                .controllen = if (control) |ctl| @intCast(ctl.len) else 0,
                .flags = 0,
            };

            while (true) {
                const rc = posix.system.recvmsg(fd, &msg, @intCast(sys_flags));

                if (rc >= 0) {
                    if (addr_len) |len| len.* = msg.namelen;
                    return .{
                        .len = @intCast(rc),
                        .flags = @intCast(msg.flags),
                    };
                }
                switch (posix.errno(rc)) {
                    .INTR => continue,
                    else => |err| return errnoToRecvError(err),
                }
            }
        },
    }
}

pub fn sendmsg(
    fd: fd_t,
    buffers: []const iovec_const,
    flags: SendFlags,
    addr: ?*const sockaddr,
    addr_len: socklen_t,
    control: ?[]const u8,
) SendError!usize {
    if (buffers.len == 0) return 0;

    var sys_flags: c_int = 0;
    if (flags.no_signal and builtin.os.tag != .windows) {
        sys_flags |= posix.system.MSG.NOSIGNAL;
    }

    switch (builtin.os.tag) {
        .windows => {
            // Windows implementation should be handled in the backend
            @panic("sendmsg not supported on Windows - use backend implementation");
        },
        else => {
            var msg: posix.system.msghdr_const = .{
                .name = if (addr) |a| @ptrCast(a) else null,
                .namelen = addr_len,
                .iov = buffers.ptr,
                .iovlen = @intCast(buffers.len),
                .control = if (control) |ctl| ctl.ptr else null,
                .controllen = if (control) |ctl| @intCast(ctl.len) else 0,
                .flags = 0,
            };

            while (true) {
                const rc = posix.system.sendmsg(fd, &msg, @intCast(sys_flags));

                if (rc >= 0) {
                    return @intCast(rc);
                }
                switch (posix.errno(rc)) {
                    .INTR => continue,
                    else => |err| return errnoToSendError(err),
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
    const listen_sock = try socket(.ipv4, .stream, .ip, .{ .nonblocking = true });
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
    const write_sock = try socket(.ipv4, .stream, .ip, .{ .nonblocking = true });
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

pub const addrinfo = switch (builtin.os.tag) {
    .windows => windows_addrinfo,
    else => std.c.addrinfo,
};

pub const AI = switch (builtin.os.tag) {
    .windows => windows.AI,
    else => std.c.AI,
};

pub const GetAddrInfoError = error{
    AddressFamilyUnsupported,
    NameServerFailure,
    UnknownHostName,
    SystemResources,
    Unexpected,
};

pub fn getaddrinfo(
    node: ?[*:0]const u8,
    service: ?[*:0]const u8,
    hints: ?*const addrinfo,
    res: *?*addrinfo,
) GetAddrInfoError!void {
    switch (builtin.os.tag) {
        .windows => {
            const rc = windows_extern.getaddrinfo(node, service, hints, res);
            if (rc != 0) {
                return errnoToGetAddrInfoError(rc);
            }
        },
        else => {
            const rc = std.c.getaddrinfo(node, service, hints, res);
            const rc_int: c_int = @intFromEnum(rc);
            if (rc_int != 0) {
                return errnoToGetAddrInfoError(rc);
            }
        },
    }
}

pub fn freeaddrinfo(res: *addrinfo) void {
    switch (builtin.os.tag) {
        .windows => {
            windows_extern.freeaddrinfo(res);
        },
        else => {
            std.c.freeaddrinfo(res);
        },
    }
}

fn errnoToGetAddrInfoError(err: anytype) GetAddrInfoError {
    switch (builtin.os.tag) {
        .windows => {
            const wsa_err: windows.WinsockError = @enumFromInt(@as(u16, @intCast(err)));
            return switch (wsa_err) {
                .EAFNOSUPPORT => error.AddressFamilyUnsupported,
                .EINVAL => error.Unexpected,
                .ESOCKTNOSUPPORT => error.Unexpected,
                .NO_DATA => error.UnknownHostName,
                .NO_RECOVERY => error.NameServerFailure,
                .NOTINITIALISED => error.SystemResources,
                .TRY_AGAIN => error.NameServerFailure,
                .TYPE_NOT_FOUND => error.NameServerFailure,
                .NOT_ENOUGH_MEMORY => error.SystemResources,
                else => unexpectedError(wsa_err),
            };
        },
        else => {
            // EAI_* error codes - err is std.c.EAI
            return switch (err) {
                .ADDRFAMILY => error.AddressFamilyUnsupported,
                .AGAIN => error.NameServerFailure,
                .BADFLAGS => error.Unexpected,
                .FAIL => error.NameServerFailure,
                .FAMILY => error.AddressFamilyUnsupported,
                .MEMORY => error.SystemResources,
                .NODATA => error.UnknownHostName,
                .NONAME => error.UnknownHostName,
                .SERVICE => error.NameServerFailure,
                .SOCKTYPE => error.Unexpected,
                .SYSTEM => {
                    // EAI.SYSTEM means we need to check errno
                    const errno_val: posix.system.E = @enumFromInt(std.c._errno().*);
                    return switch (errno_val) {
                        .SUCCESS => unreachable,
                        .NOMEM => error.SystemResources,
                        else => |e| unexpectedError(e),
                    };
                },
                else => {
                    log.err("getaddrinfo returned unexpected EAI error: {}", .{err});
                    return error.Unexpected;
                },
            };
        },
    }
}

test "getaddrinfo - resolve example.com" {
    ensureWSAInitialized();

    // Set up hints for IPv4 stream socket
    var hints: addrinfo = std.mem.zeroes(addrinfo);
    hints.family = AF.INET;
    hints.socktype = std.c.SOCK.STREAM;

    var res: ?*addrinfo = null;
    try getaddrinfo("example.com", "80", &hints, &res);
    defer if (res) |r| freeaddrinfo(r);

    // Verify we got results
    try std.testing.expect(res != null);

    // Verify we can iterate through results
    var current = res;
    var count: usize = 0;
    while (current) |info| {
        count += 1;
        try std.testing.expect(info.family == AF.INET);
        try std.testing.expect(info.socktype == std.c.SOCK.STREAM);
        current = info.next;
    }
    try std.testing.expect(count > 0);
}

test "Domain, Type, and Protocol conversions" {
    // Test raw socket type
    const raw_type = Type.raw;
    try std.testing.expectEqual(SOCK.RAW, raw_type.toPosix());

    // Test unspec domain
    const unspec_domain = Domain.unspec;
    try std.testing.expectEqual(AF.UNSPEC, unspec_domain.toPosix());

    // Test ICMP protocol
    const icmp_proto = Protocol.icmp;
    try std.testing.expectEqual(IPPROTO.ICMP, icmp_proto.toPosix());

    // Test fromPosix roundtrip for Type
    const t1 = Type.fromPosix(SOCK.STREAM);
    const t2 = Type.fromPosix(SOCK.DGRAM);
    const t3 = Type.fromPosix(SOCK.RAW);
    try std.testing.expectEqual(Type.stream, t1);
    try std.testing.expectEqual(Type.dgram, t2);
    try std.testing.expectEqual(Type.raw, t3);

    // Test fromPosix roundtrip for Domain
    const d0 = Domain.fromPosix(AF.UNSPEC);
    const d2 = Domain.fromPosix(AF.INET);
    try std.testing.expectEqual(Domain.unspec, d0);
    try std.testing.expectEqual(Domain.ipv4, d2);

    // Test fromPosix roundtrip for Protocol
    const p0 = Protocol.fromPosix(IPPROTO.IP);
    const p1 = Protocol.fromPosix(IPPROTO.ICMP);
    const p6 = Protocol.fromPosix(IPPROTO.TCP);
    const p17 = Protocol.fromPosix(IPPROTO.UDP);
    try std.testing.expectEqual(Protocol.ip, p0);
    try std.testing.expectEqual(Protocol.icmp, p1);
    try std.testing.expectEqual(Protocol.tcp, p6);
    try std.testing.expectEqual(Protocol.udp, p17);

    // Test unknown value uses catch-all _
    const t_unknown = Type.fromPosix(999);
    try std.testing.expectEqual(999, t_unknown.toPosix());

    const d_unknown = Domain.fromPosix(999);
    try std.testing.expectEqual(999, d_unknown.toPosix());

    const p_unknown = Protocol.fromPosix(999);
    try std.testing.expectEqual(999, p_unknown.toPosix());
}
