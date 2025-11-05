const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const linux = std.os.linux;
const native_os = builtin.target.os.tag;

// Struct aliases for convenience
pub const msghdr = posix.msghdr;
pub const msghdr_const = posix.msghdr_const;

/// Get the socket address length for a given sockaddr.
/// Determines the appropriate length based on the address family.
pub fn getSockAddrLen(addr: *const posix.sockaddr) posix.socklen_t {
    return switch (addr.family) {
        posix.AF.INET => @sizeOf(posix.sockaddr.in),
        posix.AF.INET6 => @sizeOf(posix.sockaddr.in6),
        posix.AF.UNIX => @sizeOf(posix.sockaddr.un),
        else => @sizeOf(posix.sockaddr.storage),
    };
}

/// Convert std.net.Address to posix.sockaddr.storage.
/// This allows storing any socket address type in a fixed-size buffer.
pub fn addressToStorage(addr: std.net.Address) posix.sockaddr.storage {
    var storage: posix.sockaddr.storage = undefined;
    @memcpy(@as([*]u8, @ptrCast(&storage))[0..@sizeOf(std.net.Address)], @as([*]const u8, @ptrCast(&addr))[0..@sizeOf(std.net.Address)]);
    return storage;
}

pub const RecvMsgError = error{
    /// The socket is marked nonblocking and the requested operation would block, and
    /// there is no global event loop configured.
    WouldBlock,

    /// The per-process limit on the number of open file descriptors has been reached.
    ProcessFdQuotaExceeded,

    /// The system-wide limit on the total number of open files has been reached.
    SystemFdQuotaExceeded,

    /// Could not allocate kernel memory.
    SystemResources,

    ConnectionResetByPeer,

    /// The message was too big for the buffer and part of it has been discarded
    MessageTooBig,

    /// The socket is not connected (connection-oriented sockets only).
    SocketNotConnected,

    /// The network subsystem has failed.
    NetworkSubsystemFailed,

    /// The local end has been shut down on a connection oriented socket.
    BrokenPipe,
} || posix.UnexpectedError;

/// Wrapper around recvmsg that properly handles errors including EINTR.
/// Similar to std.posix.recvfrom but for recvmsg.
/// On Linux, uses direct syscall instead of libc.
pub fn recvmsg(
    sockfd: posix.socket_t,
    msg: *msghdr,
    flags: u32,
) RecvMsgError!usize {
    if (native_os == .windows) {
        @compileError("recvmsg is not supported on Windows");
    }

    while (true) {
        const rc = if (native_os == .linux)
            linux.recvmsg(sockfd, msg, flags)
        else
            std.c.recvmsg(sockfd, msg, @intCast(flags));

        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .AGAIN => return error.WouldBlock,
            .BADF => unreachable, // always a race condition
            .NFILE => return error.SystemFdQuotaExceeded,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .INTR => continue,
            .FAULT => unreachable, // An invalid user space address was specified for an argument.
            .INVAL => unreachable, // Invalid argument passed.
            .ISCONN => unreachable, // connection-mode socket was connected already but a recipient was specified
            .NOBUFS => return error.SystemResources,
            .NOMEM => return error.SystemResources,
            .NOTCONN => return error.SocketNotConnected,
            .NOTSOCK => unreachable, // The file descriptor sockfd does not refer to a socket.
            .MSGSIZE => return error.MessageTooBig,
            .PIPE => return error.BrokenPipe,
            .OPNOTSUPP => unreachable, // Some bit in the flags argument is inappropriate for the socket type.
            .CONNRESET => return error.ConnectionResetByPeer,
            .NETDOWN => return error.NetworkSubsystemFailed,
            else => |err| return posix.unexpectedErrno(err),
        }
    }
}

/// Wrapper around accept/accept4 with correct error set for libxev usage.
/// The std.posix.accept function has an error set that's too restrictive for kqueue backend.
/// This version uses an inferred error set to allow all necessary errors.
pub fn accept(
    sock: posix.socket_t,
    addr: ?*posix.sockaddr,
    addr_size: ?*posix.socklen_t,
    flags: u32,
) !posix.socket_t {
    if (native_os == .windows) {
        @compileError("accept is not supported on Windows");
    }

    const have_accept4 = !(builtin.target.os.tag.isDarwin() or native_os == .haiku);
    std.debug.assert(0 == (flags & ~@as(u32, posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC))); // Unsupported flag(s)

    const accepted_sock: posix.socket_t = while (true) {
        const rc = if (have_accept4)
            std.os.linux.accept4(sock, addr, addr_size, flags)
        else
            std.c.accept(sock, addr, addr_size);

        switch (posix.errno(rc)) {
            .SUCCESS => break @intCast(rc),
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            .BADF => unreachable, // always a race condition
            .CONNABORTED => return error.ConnectionAborted,
            .FAULT => unreachable,
            .INVAL => return error.SocketNotListening,
            .NOTSOCK => unreachable,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            .NOBUFS => return error.SystemResources,
            .NOMEM => return error.SystemResources,
            .OPNOTSUPP => unreachable,
            .PROTO => return error.ProtocolFailure,
            .PERM => return error.BlockedByFirewall,
            else => |err| return posix.unexpectedErrno(err),
        }
    };

    errdefer posix.close(accepted_sock);

    if (!have_accept4) {
        try setSockFlags(accepted_sock, flags);
    }

    return accepted_sock;
}

fn setSockFlags(sock: posix.socket_t, flags: u32) !void {
    if ((flags & posix.SOCK.CLOEXEC) != 0) {
        var fd_flags = posix.fcntl(sock, posix.F.GETFD, 0) catch |err| switch (err) {
            error.FileBusy => unreachable,
            error.Locked => unreachable,
            error.PermissionDenied => unreachable,
            error.DeadLock => unreachable,
            error.LockedRegionLimitExceeded => unreachable,
            else => |e| return e,
        };
        fd_flags |= posix.FD_CLOEXEC;
        _ = posix.fcntl(sock, posix.F.SETFD, fd_flags) catch |err| switch (err) {
            error.FileBusy => unreachable,
            error.Locked => unreachable,
            error.PermissionDenied => unreachable,
            error.DeadLock => unreachable,
            error.LockedRegionLimitExceeded => unreachable,
            else => |e| return e,
        };
    }
    if ((flags & posix.SOCK.NONBLOCK) != 0) {
        var fl_flags = posix.fcntl(sock, posix.F.GETFL, 0) catch |err| switch (err) {
            error.FileBusy => unreachable,
            error.Locked => unreachable,
            error.PermissionDenied => unreachable,
            error.DeadLock => unreachable,
            error.LockedRegionLimitExceeded => unreachable,
            else => |e| return e,
        };
        fl_flags |= 1 << @bitOffsetOf(posix.O, "NONBLOCK");
        _ = posix.fcntl(sock, posix.F.SETFL, fl_flags) catch |err| switch (err) {
            error.FileBusy => unreachable,
            error.Locked => unreachable,
            error.PermissionDenied => unreachable,
            error.DeadLock => unreachable,
            error.LockedRegionLimitExceeded => unreachable,
            else => |e| return e,
        };
    }
}

/// Wrapper around connect with correct error set for libxev usage.
/// The std.posix.connect function has an error set that's too restrictive for kqueue backend.
/// This version uses an inferred error set to allow all necessary errors.
pub fn connect(
    sock: posix.socket_t,
    sock_addr: *const posix.sockaddr,
    len: posix.socklen_t,
) !void {
    if (native_os == .windows) {
        @compileError("connect is not supported on Windows");
    }

    while (true) {
        switch (posix.errno(std.c.connect(sock, sock_addr, len))) {
            .SUCCESS => return,
            .ACCES => return error.AccessDenied,
            .PERM => return error.PermissionDenied,
            .ADDRINUSE => return error.AddressInUse,
            .ADDRNOTAVAIL => return error.AddressUnavailable,
            .AFNOSUPPORT => return error.AddressFamilyUnsupported,
            .AGAIN, .INPROGRESS => return error.WouldBlock,
            .ALREADY => return error.ConnectionPending,
            .BADF => unreachable, // sockfd is not a valid open file descriptor.
            .CONNREFUSED => return error.ConnectionRefused,
            .CONNRESET => return error.ConnectionResetByPeer,
            .FAULT => unreachable, // The socket structure address is outside the user's address space.
            .INTR => continue,
            .ISCONN => @panic("AlreadyConnected"), // The socket is already connected.
            .HOSTUNREACH => return error.NetworkUnreachable,
            .NETUNREACH => return error.NetworkUnreachable,
            .NOTSOCK => unreachable, // The file descriptor sockfd does not refer to a socket.
            .PROTOTYPE => unreachable, // The socket type does not support the requested communications protocol.
            .TIMEDOUT => return error.Timeout,
            .NOENT => return error.FileNotFound, // Returned when socket is AF.UNIX and the given path does not exist.
            .CONNABORTED => unreachable, // Tried to reuse socket that previously received error.ConnectionRefused.
            else => |err| return posix.unexpectedErrno(err),
        }
    }
}

/// Wrapper around getsockopt for SO_ERROR with correct error set for libxev usage.
/// The std.posix.getsockoptError function has an error set that's too restrictive for kqueue backend.
/// This version uses an inferred error set to allow all necessary errors including AddressInUse.
pub fn getsockoptError(sockfd: posix.fd_t) !void {
    if (native_os == .windows) {
        @compileError("getsockoptError is not supported on Windows");
    }

    var err_code: i32 = undefined;
    var size: u32 = @sizeOf(u32);
    const rc = std.c.getsockopt(sockfd, posix.SOL.SOCKET, posix.SO.ERROR, @ptrCast(&err_code), &size);
    std.debug.assert(size == 4);
    switch (posix.errno(rc)) {
        .SUCCESS => switch (@as(posix.E, @enumFromInt(err_code))) {
            .SUCCESS => return,
            .ACCES => return error.AccessDenied,
            .PERM => return error.PermissionDenied,
            .ADDRINUSE => return error.AddressInUse,
            .ADDRNOTAVAIL => return error.AddressUnavailable,
            .AFNOSUPPORT => return error.AddressFamilyUnsupported,
            .AGAIN => return error.SystemResources,
            .ALREADY => return error.ConnectionPending,
            .BADF => unreachable, // sockfd is not a valid open file descriptor.
            .CONNREFUSED => return error.ConnectionRefused,
            .FAULT => unreachable, // The socket structure address is outside the user's address space.
            .ISCONN => return error.AlreadyConnected, // The socket is already connected.
            .HOSTUNREACH => return error.NetworkUnreachable,
            .NETUNREACH => return error.NetworkUnreachable,
            .NOTSOCK => unreachable, // The file descriptor sockfd does not refer to a socket.
            .PROTOTYPE => unreachable, // The socket type does not support the requested communications protocol.
            .TIMEDOUT => return error.Timeout,
            .CONNRESET => return error.ConnectionResetByPeer,
            else => |err| return posix.unexpectedErrno(err),
        },
        .BADF => unreachable, // The argument sockfd is not a valid file descriptor.
        .FAULT => unreachable, // The address pointed to by optval or optlen is not in a valid part of the process address space.
        .INVAL => unreachable,
        .NOPROTOOPT => unreachable, // The option is unknown at the level indicated.
        .NOTSOCK => unreachable, // The file descriptor sockfd does not refer to a socket.
        else => |err| return posix.unexpectedErrno(err),
    }
}
