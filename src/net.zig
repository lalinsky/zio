// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");
const ev = @import("ev/root.zig");
const os = @import("os/root.zig");
const Runtime = @import("runtime.zig").Runtime;
const Channel = @import("sync/channel.zig").Channel;

const runIo = @import("io.zig").runIo;
const fillBuf = @import("utils/writer.zig").fillBuf;

const Handle = ev.Backend.NetHandle;

pub const has_unix_sockets = switch (builtin.os.tag) {
    .windows => builtin.os.version_range.windows.isAtLeast(.win10_rs4) orelse false,
    .wasi => false,
    else => true,
};

pub const default_kernel_backlog = 128;

pub const ShutdownHow = os.net.ShutdownHow;

/// Get the socket address length for a given sockaddr.
/// Determines the appropriate length based on the address family.
fn getSockAddrLen(addr: *const os.net.sockaddr) usize {
    return switch (addr.family) {
        os.net.AF.INET => @sizeOf(os.net.sockaddr.in),
        os.net.AF.INET6 => @sizeOf(os.net.sockaddr.in6),
        os.net.AF.UNIX => @sizeOf(os.net.sockaddr.un),
        else => unreachable,
    };
}

pub const IpAddress = extern union {
    any: os.net.sockaddr,
    in: os.net.sockaddr.in,
    in6: os.net.sockaddr.in6,

    pub fn initIp4(addr: [4]u8, port: u16) IpAddress {
        return .{ .in = .{
            .family = os.net.AF.INET,
            .port = std.mem.nativeToBig(u16, port),
            .addr = @as(*align(1) const u32, @ptrCast(&addr)).*,
        } };
    }

    pub fn unspecified(port: u16) IpAddress {
        return initIp4([4]u8{ 0, 0, 0, 0 }, port);
    }

    pub fn fromStd(addr: std.net.Address) IpAddress {
        switch (addr.any.family) {
            os.net.AF.INET => return .{ .in = addr.in.sa },
            os.net.AF.INET6 => return .{ .in6 = addr.in6.sa },
            else => unreachable,
        }
    }

    pub fn initPosix(addr: *const os.net.sockaddr, len: os.net.socklen_t) IpAddress {
        return switch (addr.family) {
            os.net.AF.INET => blk: {
                std.debug.assert(len >= @sizeOf(os.net.sockaddr.in));
                var result: IpAddress = .{ .in = undefined };
                @memcpy(std.mem.asBytes(&result.in), @as([*]const u8, @ptrCast(addr))[0..@sizeOf(os.net.sockaddr.in)]);
                break :blk result;
            },
            os.net.AF.INET6 => blk: {
                std.debug.assert(len >= @sizeOf(os.net.sockaddr.in6));
                var result: IpAddress = .{ .in6 = undefined };
                @memcpy(std.mem.asBytes(&result.in6), @as([*]const u8, @ptrCast(addr))[0..@sizeOf(os.net.sockaddr.in6)]);
                break :blk result;
            },
            else => unreachable,
        };
    }

    pub fn initIp6(addr: [16]u8, port: u16, flowinfo: u32, scope_id: u32) IpAddress {
        return .{ .in6 = .{
            .family = os.net.AF.INET6,
            .port = std.mem.nativeToBig(u16, port),
            .flowinfo = flowinfo,
            .addr = addr,
            .scope_id = scope_id,
        } };
    }

    pub fn parseIp4(buf: []const u8, port: u16) !IpAddress {
        var addr: [4]u8 = undefined;
        var octets = std.mem.splitScalar(u8, buf, '.');
        var i: usize = 0;
        while (octets.next()) |octet| : (i += 1) {
            if (i >= 4) return error.InvalidIpAddress;
            addr[i] = std.fmt.parseInt(u8, octet, 10) catch return error.InvalidIpAddress;
        }
        if (i != 4) return error.InvalidIpAddress;
        return initIp4(addr, port);
    }

    pub fn parseIp6(buf: []const u8, port: u16) !IpAddress {
        var addr: [16]u8 = undefined;
        var tail: [16]u8 = undefined;
        var ip_slice: []u8 = addr[0..];

        var x: u16 = 0;
        var saw_any_digits = false;
        var index: usize = 0;
        var abbrv = false;

        for (buf, 0..) |c, i| {
            if (c == ':') {
                if (!saw_any_digits) {
                    if (abbrv) return error.InvalidIpAddress; // ':::'
                    if (i != 0) abbrv = true;
                    @memset(ip_slice[index..], 0);
                    ip_slice = tail[0..];
                    index = 0;
                    continue;
                }
                if (index == 14) return error.InvalidIpAddress;
                ip_slice[index] = @as(u8, @truncate(x >> 8));
                index += 1;
                ip_slice[index] = @as(u8, @truncate(x));
                index += 1;

                x = 0;
                saw_any_digits = false;
            } else {
                const digit = std.fmt.charToDigit(c, 16) catch return error.InvalidIpAddress;
                const ov = @mulWithOverflow(x, 16);
                if (ov[1] != 0) return error.InvalidIpAddress;
                x = ov[0];
                const ov2 = @addWithOverflow(x, digit);
                if (ov2[1] != 0) return error.InvalidIpAddress;
                x = ov2[0];
                saw_any_digits = true;
            }
        }

        if (!saw_any_digits and !abbrv) return error.InvalidIpAddress;
        if (!abbrv and index < 14) return error.InvalidIpAddress;

        if (index == 14) {
            ip_slice[14] = @as(u8, @truncate(x >> 8));
            ip_slice[15] = @as(u8, @truncate(x));
        } else {
            ip_slice[index] = @as(u8, @truncate(x >> 8));
            index += 1;
            ip_slice[index] = @as(u8, @truncate(x));
            index += 1;
            if (abbrv) {
                @memcpy(addr[16 - index ..][0..index], ip_slice[0..index]);
            }
        }

        return initIp6(addr, port, 0, 0);
    }

    pub fn parseIp(name: []const u8, port: u16) !IpAddress {
        // Try IPv4 first
        return parseIp4(name, port) catch {
            // Try IPv6
            return parseIp6(name, port);
        };
    }

    pub fn parseIpAndPort(name: []const u8) !IpAddress {
        // For IPv6: [addr]:port
        if (std.mem.indexOf(u8, name, "[")) |_| {
            const start = std.mem.indexOf(u8, name, "[") orelse return error.InvalidFormat;
            const end = std.mem.indexOf(u8, name, "]") orelse return error.InvalidFormat;
            const colon = std.mem.lastIndexOf(u8, name, ":") orelse return error.InvalidFormat;
            if (colon <= end) return error.InvalidFormat;
            const addr_str = name[start + 1 .. end];
            const port_str = name[colon + 1 ..];
            const port = try std.fmt.parseInt(u16, port_str, 10);
            return parseIp6(addr_str, port);
        }
        // For IPv4: addr:port
        const colon = std.mem.lastIndexOf(u8, name, ":") orelse return error.InvalidFormat;
        const addr_str = name[0..colon];
        const port_str = name[colon + 1 ..];
        const port = try std.fmt.parseInt(u16, port_str, 10);
        return parseIp4(addr_str, port);
    }

    /// Returns the port in native endian.
    /// Asserts that the address is ip4 or ip6.
    pub fn getPort(self: IpAddress) u16 {
        return switch (self.any.family) {
            os.net.AF.INET => std.mem.bigToNative(u16, self.in.port),
            os.net.AF.INET6 => std.mem.bigToNative(u16, self.in6.port),
            else => unreachable,
        };
    }

    /// `port` is native-endian.
    /// Asserts that the address is ip4 or ip6.
    pub fn setPort(self: *IpAddress, port: u16) void {
        switch (self.any.family) {
            os.net.AF.INET => self.in.port = std.mem.nativeToBig(u16, port),
            os.net.AF.INET6 => self.in6.port = std.mem.nativeToBig(u16, port),
            else => unreachable,
        }
    }

    pub fn format(self: IpAddress, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self.any.family) {
            os.net.AF.INET => {
                const bytes: *const [4]u8 = @ptrCast(&self.in.addr);
                try w.print("{d}.{d}.{d}.{d}:{d}", .{ bytes[0], bytes[1], bytes[2], bytes[3], self.getPort() });
            },
            os.net.AF.INET6 => {
                const port = self.getPort();
                const addr = self.in6.addr;

                // Check for IPv4-mapped IPv6 addresses (::ffff:x.x.x.x)
                if (std.mem.eql(u8, addr[0..12], &[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff })) {
                    try w.print("[::ffff:{d}.{d}.{d}.{d}]:{d}", .{
                        addr[12],
                        addr[13],
                        addr[14],
                        addr[15],
                        port,
                    });
                    return;
                }

                // Convert to native endian for compression detection
                const big_endian_parts: *align(1) const [8]u16 = @ptrCast(&addr);
                var native_endian_parts: [8]u16 = undefined;
                for (big_endian_parts, 0..) |part, i| {
                    native_endian_parts[i] = std.mem.bigToNative(u16, part);
                }

                // Find the longest zero run
                var longest_start: usize = 8;
                var longest_len: usize = 0;
                var current_start: usize = 0;
                var current_len: usize = 0;

                for (native_endian_parts, 0..) |part, i| {
                    if (part == 0) {
                        if (current_len == 0) {
                            current_start = i;
                        }
                        current_len += 1;
                        if (current_len > longest_len) {
                            longest_start = current_start;
                            longest_len = current_len;
                        }
                    } else {
                        current_len = 0;
                    }
                }

                // Only compress if the longest zero run is 2 or more
                if (longest_len < 2) {
                    longest_start = 8;
                    longest_len = 0;
                }

                try w.writeAll("[");
                var i: usize = 0;
                var abbrv = false;
                while (i < native_endian_parts.len) : (i += 1) {
                    if (i == longest_start) {
                        // Emit "::" for the longest zero run
                        if (!abbrv) {
                            try w.writeAll(if (i == 0) "::" else ":");
                            abbrv = true;
                        }
                        i += longest_len - 1; // Skip the compressed range
                        continue;
                    }
                    if (abbrv) {
                        abbrv = false;
                    }
                    try w.print("{x}", .{native_endian_parts[i]});
                    if (i != native_endian_parts.len - 1) {
                        try w.writeAll(":");
                    }
                }
                try w.print("]:{d}", .{port});
            },
            else => unreachable,
        }
    }

    /// Returns true if the IP address is a private address according to
    /// RFC 1918 (IPv4) or RFC 4193 (IPv6).
    /// IPv4: 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16
    /// IPv6: fc00::/7
    pub fn isPrivate(self: IpAddress) bool {
        return switch (self.any.family) {
            os.net.AF.INET => blk: {
                const bytes: *const [4]u8 = @ptrCast(&self.in.addr);
                break :blk bytes[0] == 10 or
                    (bytes[0] == 172 and (bytes[1] & 0xf0) == 16) or
                    (bytes[0] == 192 and bytes[1] == 168);
            },
            os.net.AF.INET6 => blk: {
                const addr = self.in6.addr;
                // fc00::/7 check: first byte should be 0xfc or 0xfd
                break :blk (addr[0] & 0xfe) == 0xfc;
            },
            else => unreachable,
        };
    }

    /// Returns true if the IP is a loopback address.
    /// IPv4: 127.0.0.0/8
    /// IPv6: ::1
    pub fn isLoopback(self: IpAddress) bool {
        return switch (self.any.family) {
            os.net.AF.INET => blk: {
                const bytes: *const [4]u8 = @ptrCast(&self.in.addr);
                break :blk bytes[0] == 127;
            },
            os.net.AF.INET6 => blk: {
                const addr = self.in6.addr;
                // ::1 check - compare all 16 bytes
                const loopback = [16]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
                break :blk std.mem.eql(u8, &addr, &loopback);
            },
            else => unreachable,
        };
    }

    /// Returns true if the IP is a link-local unicast address.
    /// IPv4: 169.254.0.0/16
    /// IPv6: fe80::/10
    pub fn isLinkLocalUnicast(self: IpAddress) bool {
        return switch (self.any.family) {
            os.net.AF.INET => blk: {
                const bytes: *const [4]u8 = @ptrCast(&self.in.addr);
                break :blk bytes[0] == 169 and bytes[1] == 254;
            },
            os.net.AF.INET6 => blk: {
                const addr = self.in6.addr;
                // fe80::/10 check
                break :blk addr[0] == 0xfe and (addr[1] & 0xc0) == 0x80;
            },
            else => unreachable,
        };
    }

    /// Returns true if the IP is an unspecified address.
    /// IPv4: 0.0.0.0
    /// IPv6: ::
    pub fn isUnspecified(self: IpAddress) bool {
        return switch (self.any.family) {
            os.net.AF.INET => self.in.addr == 0,
            os.net.AF.INET6 => blk: {
                const addr = self.in6.addr;
                const zeros = [_]u8{0} ** 16;
                break :blk std.mem.eql(u8, &addr, &zeros);
            },
            else => unreachable,
        };
    }

    /// Returns true if the IP is a multicast address.
    /// IPv4: 224.0.0.0/4
    /// IPv6: ff00::/8
    pub fn isMulticast(self: IpAddress) bool {
        return switch (self.any.family) {
            os.net.AF.INET => blk: {
                const bytes: *const [4]u8 = @ptrCast(&self.in.addr);
                break :blk (bytes[0] & 0xf0) == 224;
            },
            os.net.AF.INET6 => self.in6.addr[0] == 0xff,
            else => unreachable,
        };
    }

    /// Returns true if the IP is a broadcast address.
    /// IPv4: 255.255.255.255
    /// IPv6: (no broadcast concept, always returns false)
    pub fn isBroadcast(self: IpAddress) bool {
        return switch (self.any.family) {
            os.net.AF.INET => self.in.addr == 0xFFFFFFFF,
            os.net.AF.INET6 => false,
            else => unreachable,
        };
    }

    /// Returns true if the IP is a global unicast address.
    /// Per RFC 4291 (IPv6) and following Go's net.IP semantics, this is
    /// the complement of loopback, link-local, multicast, unspecified, and broadcast.
    /// Note: Private addresses (RFC 1918, RFC 4193) ARE included as global unicast.
    pub fn isGlobalUnicast(self: IpAddress) bool {
        return !self.isLoopback() and
            !self.isLinkLocalUnicast() and
            !self.isMulticast() and
            !self.isUnspecified() and
            !self.isBroadcast();
    }

    pub const ListenOptions = struct {
        kernel_backlog: u31 = default_kernel_backlog,
        reuse_address: bool = false,
    };

    pub const BindOptions = struct {
        reuse_address: bool = false,
    };

    pub fn bind(self: IpAddress, rt: *Runtime, options: BindOptions) !Socket {
        return netBindIp(rt, self, options);
    }

    pub fn listen(self: IpAddress, rt: *Runtime, options: ListenOptions) !Server {
        return netListenIp(rt, self, options);
    }

    pub fn connect(self: IpAddress, rt: *Runtime) !Stream {
        return netConnectIp(rt, self);
    }
};

pub const UnixAddress = extern union {
    any: os.net.sockaddr,
    un: if (has_unix_sockets) os.net.sockaddr.un else void,

    pub const max_len = 108;

    pub fn init(path: []const u8) !UnixAddress {
        if (!has_unix_sockets) unreachable;
        var un = os.net.sockaddr.un{ .family = os.net.AF.UNIX, .path = undefined };
        if (path.len > max_len) return error.NameTooLong;
        @memcpy(un.path[0..path.len], path);
        un.path[path.len] = 0;
        return .{ .un = un };
    }

    pub const ListenOptions = struct {
        kernel_backlog: u31 = default_kernel_backlog,
    };

    pub const BindOptions = struct {
        reuse_address: bool = false,
    };

    pub fn format(self: UnixAddress, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (!has_unix_sockets) unreachable;
        switch (self.any.family) {
            os.net.AF.UNIX => try w.writeAll(std.mem.sliceTo(&self.un.path, 0)),
            else => unreachable,
        }
    }

    pub fn bind(self: UnixAddress, rt: *Runtime, options: BindOptions) !Socket {
        return netBindUnix(rt, self, options);
    }

    pub fn listen(self: UnixAddress, rt: *Runtime, options: ListenOptions) !Server {
        return netListenUnix(rt, self, options);
    }

    pub fn connect(self: UnixAddress, rt: *Runtime) !Stream {
        return netConnectUnix(rt, self);
    }
};

pub const Address = extern union {
    any: os.net.sockaddr,
    ip: IpAddress,
    unix: UnixAddress,

    pub const Type = enum { ip, unix };

    pub fn getType(self: Address) Type {
        return switch (self.any.family) {
            os.net.AF.INET, os.net.AF.INET6 => .ip,
            os.net.AF.UNIX => .unix,
            else => unreachable,
        };
    }

    /// Convert to std.net.Address
    pub fn toStd(self: *const Address) std.net.Address {
        return switch (self.any.family) {
            os.net.AF.INET => std.net.Address{ .in = .{ .sa = self.ip.in } },
            os.net.AF.INET6 => std.net.Address{ .in6 = .{ .sa = self.ip.in6 } },
            os.net.AF.UNIX => if (has_unix_sockets) std.net.Address{ .un = self.unix.un } else unreachable,
            else => unreachable,
        };
    }

    /// Convert from std.net.Address
    pub fn fromStd(addr: std.net.Address) Address {
        return switch (addr.any.family) {
            os.net.AF.INET => Address{ .ip = .{ .in = addr.in.sa } },
            os.net.AF.INET6 => Address{ .ip = .{ .in6 = addr.in6.sa } },
            os.net.AF.UNIX => if (has_unix_sockets) Address{ .unix = .{ .un = addr.un } } else unreachable,
            else => unreachable,
        };
    }

    /// Convert sockaddr to IpAddress from raw bytes.
    /// This properly handles IPv4 and IPv6 addresses without alignment issues.
    fn fromStorageIp(data: []const u8) IpAddress {
        const sockaddr: *align(1) const os.net.sockaddr = @ptrCast(data.ptr);
        return switch (sockaddr.family) {
            os.net.AF.INET => blk: {
                var addr: IpAddress = .{ .in = undefined };
                @memcpy(std.mem.asBytes(&addr.in), data[0..@sizeOf(std.net.Ip4Address)]);
                break :blk addr;
            },
            os.net.AF.INET6 => blk: {
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
        const sockaddr: *align(1) const os.net.sockaddr = @ptrCast(data.ptr);
        return switch (sockaddr.family) {
            os.net.AF.INET, os.net.AF.INET6 => Address{ .ip = fromStorageIp(data) },
            os.net.AF.UNIX => blk: {
                if (!has_unix_sockets) unreachable;
                var addr: Address = .{ .unix = .{ .un = undefined } };
                const copy_len = @min(data.len, @sizeOf(os.net.sockaddr.un));
                @memcpy(std.mem.asBytes(&addr.unix.un)[0..copy_len], data[0..copy_len]);
                break :blk addr;
            },
            else => unreachable,
        };
    }

    pub fn format(self: Address, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self.getType()) {
            .ip => return self.ip.format(w),
            .unix => return self.unix.format(w),
        }
    }

    pub fn connect(self: Address, rt: *Runtime) !Stream {
        switch (self.getType()) {
            .ip => return self.ip.connect(rt),
            .unix => return self.unix.connect(rt),
        }
    }

    /// Parse an IP address string with a separate port parameter.
    /// Supports both IPv4 and IPv6 addresses.
    /// Examples: parseIp("127.0.0.1", 8080), parseIp("::1", 8080)
    pub fn parseIp(ip: []const u8, port: u16) !Address {
        return .{ .ip = try IpAddress.parseIp(ip, port) };
    }

    /// Parse an IP address with port from a single string.
    /// IPv4 format: "127.0.0.1:8080"
    /// IPv6 format: "[::1]:8080"
    pub fn parseIpAndHost(addr: []const u8) !Address {
        return .{ .ip = try IpAddress.parseIpAndPort(addr) };
    }
};

pub const ReceiveFromResult = struct {
    from: Address,
    len: usize,
};

pub const Socket = struct {
    handle: Handle,
    address: Address,

    /// Enable or disable address reuse (SO_REUSEADDR)
    /// Allows binding to an address in TIME_WAIT state
    pub fn setReuseAddress(self: Socket, enabled: bool) !void {
        if (builtin.os.tag == .windows) {
            try self.setBoolOptionWindows(os.windows.SOL.SOCKET, os.windows.SO.REUSEADDR, enabled);
        } else {
            try self.setBoolOption(std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, enabled);
        }
    }

    /// Enable or disable port reuse (SO_REUSEPORT)
    /// Allows multiple sockets to bind to the same port for load balancing
    /// Note: Not supported on Windows
    pub fn setReusePort(self: Socket, enabled: bool) !void {
        if (builtin.os.tag == .windows) {
            return error.Unsupported;
        }
        try self.setBoolOption(std.posix.SOL.SOCKET, std.posix.SO.REUSEPORT, enabled);
    }

    /// Enable or disable TCP keepalive (SO_KEEPALIVE)
    /// Periodically sends keepalive probes to detect dead connections
    pub fn setKeepAlive(self: Socket, enabled: bool) !void {
        if (builtin.os.tag == .windows) {
            try self.setBoolOptionWindows(os.windows.SOL.SOCKET, os.windows.SO.KEEPALIVE, enabled);
        } else {
            try self.setBoolOption(std.posix.SOL.SOCKET, std.posix.SO.KEEPALIVE, enabled);
        }
    }

    /// Enable or disable Nagle's algorithm (TCP_NODELAY)
    /// When enabled (true), disables buffering for low-latency communication
    pub fn setNoDelay(self: Socket, enabled: bool) !void {
        if (builtin.os.tag == .windows) {
            try self.setBoolOptionWindows(os.windows.IPPROTO.TCP, os.windows.TCP.NODELAY, enabled);
        } else {
            try self.setBoolOption(std.posix.IPPROTO.TCP, std.posix.TCP.NODELAY, enabled);
        }
    }

    /// Helper function to set a boolean socket option (POSIX)
    fn setBoolOption(self: Socket, level: i32, optname: u32, enabled: bool) !void {
        const value: c_int = if (enabled) 1 else 0;
        const bytes = std.mem.asBytes(&value);
        try std.posix.setsockopt(self.handle, level, optname, bytes);
    }

    /// Helper function to set a boolean socket option (Windows)
    fn setBoolOptionWindows(self: Socket, level: i32, optname: i32, enabled: bool) !void {
        const value: c_int = if (enabled) 1 else 0;
        const rc = os.windows.setsockopt(self.handle, level, optname, std.mem.asBytes(&value).ptr, @sizeOf(c_int));
        if (rc == os.windows.SOCKET_ERROR) {
            return error.Unexpected;
        }
    }

    /// Bind the socket to an address
    pub fn bind(self: *Socket, rt: *Runtime, addr: Address) !void {
        // Copy addr to self.address so NetBind can update it with actual bound address
        self.address = addr;
        var addr_len: os.net.socklen_t = @intCast(getSockAddrLen(&self.address.any));

        var op = ev.NetBind.init(self.handle, &self.address.any, &addr_len);
        try runIo(rt, &op.c);
        try op.getResult();
    }

    /// Mark the socket as a listening socket
    pub fn listen(self: *Socket, rt: *Runtime, backlog: u31) !void {
        var op = ev.NetListen.init(self.handle, backlog);
        try runIo(rt, &op.c);
        try op.getResult();
    }

    /// Connect the socket to a remote address
    pub fn connect(self: Socket, rt: *Runtime, addr: Address) !void {
        try netConnect(rt, self.handle, addr);
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
        // All backends use the same implementation with ev
        return try self.receiveFromRecvfrom(rt, buf);
    }

    fn receiveFromRecvfrom(self: Socket, rt: *Runtime, buf: []u8) !ReceiveFromResult {
        var storage: [1]os.iovec = undefined;
        var result: ReceiveFromResult = undefined;
        var peer_addr_len: os.net.socklen_t = @sizeOf(@TypeOf(result.from));

        var op = ev.NetRecvFrom.init(self.handle, .fromSlice(buf, &storage), .{}, &result.from.any, &peer_addr_len);
        try runIo(rt, &op.c);
        result.len = try op.getResult();
        return result;
    }

    fn receiveFromRecvmsg(self: Socket, rt: *Runtime, buf: []u8) !ReceiveFromResult {
        // ev handles this the same way as recvfrom
        return self.receiveFromRecvfrom(rt, buf);
    }

    /// Sends a datagram to the specified address.
    /// Used for UDP and other datagram-based protocols.
    pub fn sendTo(self: Socket, rt: *Runtime, addr: Address, data: []const u8) !usize {
        // All backends use the same implementation with ev
        return try self.sendToSendto(rt, addr, data);
    }

    fn sendToSendto(self: Socket, rt: *Runtime, addr: Address, data: []const u8) !usize {
        var storage: [1]os.iovec_const = undefined;
        const addr_len: os.net.socklen_t = @intCast(getSockAddrLen(&addr.any));
        var op = ev.NetSendTo.init(self.handle, .fromSlice(data, &storage), .{}, &addr.any, addr_len);
        try runIo(rt, &op.c);
        return try op.getResult();
    }

    fn sendToSendmsg(self: Socket, rt: *Runtime, addr: Address, data: []const u8) !usize {
        // ev handles this the same way as sendto
        return self.sendToSendto(rt, addr, data);
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

    /// Low-level read function that accepts ev.ReadBuf slice directly.
    /// Returns the number of bytes read, which may be less than requested.
    /// A return value of 0 indicates end-of-stream.
    pub fn readBuf(self: Stream, rt: *Runtime, buffers: []ev.ReadBuf) !usize {
        var op = ev.NetRecv.init(self.socket.handle, buffers, .{});
        try runIo(rt, &op.c);
        return op.getResult() catch |err| switch (err) {
            error.EOF => 0, // EOF is not an error for streams
            else => err,
        };
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

    /// Low-level write function that accepts ev.WriteBuf slice directly.
    /// Returns the number of bytes written, which may be less than requested.
    pub fn writeBuf(self: Stream, rt: *Runtime, buffers: []const ev.WriteBuf) !usize {
        var op = ev.NetSend.init(self.socket.handle, buffers, .{});
        try runIo(rt, &op.c);
        return try op.getResult();
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
        err: ?ev.NetRecv.Error = null,

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
        err: ?ev.NetSend.Error = null,

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

fn createStreamSocket(rt: *Runtime, family: std.posix.sa_family_t) !Handle {
    var op = ev.NetOpen.init(@enumFromInt(family), .stream, .{});
    try runIo(rt, &op.c);
    return try op.getResult();
}

fn createDatagramSocket(rt: *Runtime, family: std.posix.sa_family_t) !Handle {
    var op = ev.NetOpen.init(@enumFromInt(family), .dgram, .{});
    try runIo(rt, &op.c);
    return try op.getResult();
}

pub fn netListenIp(rt: *Runtime, addr: IpAddress, options: IpAddress.ListenOptions) !Server {
    const fd = try createStreamSocket(rt, addr.any.family);
    errdefer netClose(rt, fd);

    var socket: Socket = .{
        .handle = fd,
        .address = .{ .ip = addr },
    };

    if (options.reuse_address) {
        try socket.setReuseAddress(true);
    }

    try socket.bind(rt, .{ .ip = addr });
    try socket.listen(rt, options.kernel_backlog);

    return .{ .socket = socket };
}

pub fn netListenUnix(rt: *Runtime, addr: UnixAddress, options: UnixAddress.ListenOptions) !Server {
    if (!has_unix_sockets) unreachable;

    const fd = try createStreamSocket(rt, addr.any.family);
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
    const fd = try createStreamSocket(rt, addr.any.family);
    errdefer netClose(rt, fd);

    try netConnect(rt, fd, .{ .ip = addr });
    return .{ .socket = .{ .handle = fd, .address = .{ .ip = addr } } };
}

pub fn netConnectUnix(rt: *Runtime, addr: UnixAddress) !Stream {
    if (!has_unix_sockets) unreachable;

    const fd = try createStreamSocket(rt, addr.any.family);
    errdefer netClose(rt, fd);

    try netConnect(rt, fd, .{ .unix = addr });
    return .{ .socket = .{ .handle = fd, .address = .{ .unix = addr } } };
}

pub fn netBindIp(rt: *Runtime, addr: IpAddress, options: IpAddress.BindOptions) !Socket {
    const fd = try createDatagramSocket(rt, addr.any.family);
    errdefer netClose(rt, fd);

    var socket: Socket = .{
        .handle = fd,
        .address = .{ .ip = addr },
    };

    if (options.reuse_address) {
        try socket.setReuseAddress(true);
    }

    try socket.bind(rt, .{ .ip = addr });

    return socket;
}

pub fn netBindUnix(rt: *Runtime, addr: UnixAddress, options: UnixAddress.BindOptions) !Socket {
    if (!has_unix_sockets) unreachable;

    const fd = try createDatagramSocket(rt, addr.any.family);
    errdefer netClose(rt, fd);

    var socket: Socket = .{
        .handle = fd,
        .address = .{ .unix = addr },
    };

    if (options.reuse_address) {
        try socket.setReuseAddress(true);
    }

    try socket.bind(rt, .{ .unix = addr });

    return socket;
}

pub fn netRead(rt: *Runtime, fd: Handle, bufs: []const []u8) !usize {
    // Convert []const []u8 to ReadBuf
    var storage: [16]os.iovec = undefined;
    const read_bufs = ev.ReadBuf.fromSlices(bufs, &storage);

    var op = ev.NetRecv.init(fd, read_bufs, .{});
    try runIo(rt, &op.c);
    return try op.getResult();
}

pub fn netWrite(rt: *Runtime, fd: Handle, header: []const u8, data: []const []const u8, splat: usize) !usize {
    var splat_buf: [64]u8 = undefined;
    var slices: [16][]const u8 = undefined;
    const buf_len = fillBuf(&slices, header, data, splat, &splat_buf);

    var storage: [16]os.iovec_const = undefined;
    var op = ev.NetSend.init(fd, .fromSlices(slices[0..buf_len], &storage), .{});
    try runIo(rt, &op.c);
    return try op.getResult();
}

pub fn netAccept(rt: *Runtime, fd: Handle) !Stream {
    var peer_addr: Address = undefined;
    var peer_addr_len: os.net.socklen_t = @sizeOf(Address);

    var op = ev.NetAccept.init(fd, &peer_addr.any, &peer_addr_len);
    try runIo(rt, &op.c);
    const handle = try op.getResult();
    return .{ .socket = .{ .handle = handle, .address = peer_addr } };
}

pub fn netConnect(rt: *Runtime, fd: Handle, addr: Address) !void {
    var addr_copy = addr;
    const addr_len: os.net.socklen_t = @intCast(getSockAddrLen(&addr_copy.any));

    var op = ev.NetConnect.init(fd, &addr_copy.any, addr_len);
    try runIo(rt, &op.c);
    try op.getResult();
}

pub fn netShutdown(rt: *Runtime, fd: Handle, how: ShutdownHow) !void {
    var op = ev.NetShutdown.init(fd, how);
    try runIo(rt, &op.c);
    try op.getResult();
}

pub fn netClose(rt: *Runtime, fd: Handle) void {
    var op = ev.NetClose.init(fd);
    rt.beginShield();
    defer rt.endShield();
    runIo(rt, &op.c) catch {};
    _ = op.getResult() catch {};
}

pub const IpAddressIterator = struct {
    head: ?*os.net.addrinfo,
    current: ?*os.net.addrinfo,

    pub fn next(self: *IpAddressIterator) ?IpAddress {
        while (self.current) |info| {
            self.current = info.next;
            const addr = info.addr orelse continue;
            // Skip unsupported address families
            if (addr.family != os.net.AF.INET and addr.family != os.net.AF.INET6) continue;
            // Cast needed on Windows where we have our own sockaddr type
            return IpAddress.initPosix(@ptrCast(addr), @intCast(info.addrlen));
        }
        return null;
    }

    pub fn deinit(self: *IpAddressIterator) void {
        if (self.head) |head| {
            os.net.freeaddrinfo(head);
        }
    }
};

pub const LookupHostError = error{
    HostLacksNetworkAddresses,
    TemporaryNameServerFailure,
    NameServerFailure,
    AddressFamilyNotSupported,
    OutOfMemory,
    UnknownHostName,
    ServiceUnavailable,
    Unexpected,
    RuntimeShutdown,
    Closed,
    NoThreadPool,
    ProcessFdQuotaExceeded,
    SystemResources,
} || std.posix.UnexpectedError;

/// Async DNS resolution using the runtime's thread pool.
/// Performs DNS lookup in a blocking task to avoid blocking the event loop.
/// Call `IpAddressIterator.deinit()` on the result when done.
pub fn lookupHost(
    runtime: *Runtime,
    name: []const u8,
    port: u16,
) LookupHostError!IpAddressIterator {
    var task = runtime.spawnBlocking(
        lookupHostBlocking,
        .{ name, port },
    ) catch |err| switch (err) {
        error.ResultTooLarge, error.ContextTooLarge => unreachable,
        else => |e| return @as(LookupHostError, e),
    };
    defer task.cancel(runtime);

    return try task.join(runtime);
}

fn lookupHostBlocking(
    name: []const u8,
    port: u16,
) LookupHostError!IpAddressIterator {
    // Use stack buffer for temporary allocations
    var buf: [512]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const allocator = fba.allocator();

    const name_c = try allocator.dupeZ(u8, name);
    const port_c = try std.fmt.allocPrintSentinel(allocator, "{d}", .{port}, 0);

    var hints: os.net.addrinfo = std.mem.zeroes(os.net.addrinfo);
    hints.family = os.net.AF.UNSPEC;
    hints.socktype = std.posix.SOCK.STREAM;
    hints.protocol = std.posix.IPPROTO.TCP;

    var res: ?*os.net.addrinfo = null;

    os.net.getaddrinfo(name_c.ptr, port_c.ptr, &hints, &res) catch |err| {
        return switch (err) {
            error.ServiceNotAvailable => error.ServiceUnavailable,
            error.InvalidFlags => unreachable,
            error.SocketTypeNotSupported => unreachable,
            else => |e| e,
        };
    };

    return .{
        .head = res,
        .current = res,
    };
}

pub fn tcpConnectToHost(
    rt: *Runtime,
    name: []const u8,
    port: u16,
) !Stream {
    var iter = try lookupHost(rt, name, port);
    defer iter.deinit();

    var last_err: ?anyerror = null;
    while (iter.next()) |addr| {
        return addr.connect(rt) catch |err| {
            last_err = err;
            continue;
        };
    }
    if (last_err) |err| return err;
    return error.UnknownHostName;
}

pub fn tcpConnectToAddress(rt: *Runtime, addr: IpAddress) !Stream {
    return addr.connect(rt);
}

test {
    std.testing.refAllDecls(@This());
}

test "lookupHost: localhost" {
    const allocator = std.testing.allocator;

    const rt = try Runtime.init(allocator, .{ .thread_pool = .{} });
    defer rt.deinit();

    var iter = try lookupHost(rt, "localhost", 80);
    defer iter.deinit();

    var count: usize = 0;
    while (iter.next()) |_| {
        count += 1;
    }
    try std.testing.expect(count > 0);
}

test "lookupHost: numeric IP" {
    const allocator = std.testing.allocator;

    const rt = try Runtime.init(allocator, .{ .thread_pool = .{} });
    defer rt.deinit();

    var iter = try lookupHost(rt, "127.0.0.1", 8080);
    defer iter.deinit();

    var count: usize = 0;
    var first_addr: ?IpAddress = null;
    while (iter.next()) |addr| {
        if (first_addr == null) first_addr = addr;
        count += 1;
    }
    try std.testing.expectEqual(1, count);
    try std.testing.expectEqual(8080, first_addr.?.getPort());
}

test "tcpConnectToAddress: basic" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    const ServerTask = struct {
        fn run(rt: *Runtime, server_port: *Channel(u16)) !void {
            const addr = try IpAddress.parseIp4("127.0.0.1", 0);
            const server = try addr.listen(rt, .{});
            defer server.close(rt);

            try server_port.send(rt, server.socket.address.ip.getPort());

            var stream = try server.accept(rt);
            defer stream.close(rt);

            var read_buffer: [256]u8 = undefined;
            var reader = stream.reader(rt, &read_buffer);

            const msg = try reader.interface.takeDelimiterExclusive('\n');
            try std.testing.expectEqualStrings("hello", msg);
        }
    };

    const ClientTask = struct {
        fn run(rt: *Runtime, server_port: *Channel(u16)) !void {
            const port = try server_port.receive(rt);
            const addr = try IpAddress.parseIp4("127.0.0.1", port);

            var stream = try tcpConnectToAddress(rt, addr);
            defer stream.close(rt);

            var write_buffer: [256]u8 = undefined;
            var writer = stream.writer(rt, &write_buffer);

            try writer.interface.writeAll("hello\n");
            try writer.interface.flush();

            stream.shutdown(rt, .both) catch {};
        }
    };

    var server_port_buf: [1]u16 = undefined;
    var server_port_ch = Channel(u16).init(&server_port_buf);

    var server_task = try runtime.spawn(ServerTask.run, .{ runtime, &server_port_ch });
    defer server_task.cancel(runtime);

    var client_task = try runtime.spawn(ClientTask.run, .{ runtime, &server_port_ch });
    defer client_task.cancel(runtime);

    try server_task.join(runtime);
    try client_task.join(runtime);
}

test "tcpConnectToHost: basic" {
    if (builtin.os.tag == .macos) return error.SkipZigTest;

    const ServerTask = struct {
        fn run(rt: *Runtime, server_port: *Channel(u16)) !void {
            const addr = try IpAddress.parseIp4("127.0.0.1", 0);
            const server = try addr.listen(rt, .{});
            defer server.close(rt);

            std.log.info("Server listening on port {}\n", .{server.socket.address.ip.getPort()});

            try server_port.send(rt, server.socket.address.ip.getPort());

            var stream = try server.accept(rt);
            defer stream.close(rt);

            var read_buffer: [256]u8 = undefined;
            var reader = stream.reader(rt, &read_buffer);

            const msg = try reader.interface.takeDelimiterExclusive('\n');
            try std.testing.expectEqualStrings("hello", msg);
        }
    };

    const ClientTask = struct {
        fn run(rt: *Runtime, server_port: *Channel(u16)) !void {
            const port = try server_port.receive(rt);
            std.log.info("Client connecting to port {}\n", .{port});

            var stream = try tcpConnectToHost(rt, "localhost", port);
            defer stream.close(rt);

            var write_buffer: [256]u8 = undefined;
            var writer = stream.writer(rt, &write_buffer);

            try writer.interface.writeAll("hello\n");
            try writer.interface.flush();

            try stream.shutdown(rt, .both);
        }
    };

    const runtime = try Runtime.init(std.testing.allocator, .{ .thread_pool = .{} });
    defer runtime.deinit();

    var server_port_buf: [1]u16 = undefined;
    var server_port_ch = Channel(u16).init(&server_port_buf);

    var server_task = try runtime.spawn(ServerTask.run, .{ runtime, &server_port_ch });
    defer server_task.cancel(runtime);

    var client_task = try runtime.spawn(ClientTask.run, .{ runtime, &server_port_ch });
    defer client_task.cancel(runtime);

    try server_task.join(runtime);
    try client_task.join(runtime);
}

test "IpAddress: initIp4" {
    const addr = IpAddress.initIp4(.{0} ** 4, 8080);
    try std.testing.expectEqual(os.net.AF.INET, addr.any.family);
}

test "IpAddress: initIp6" {
    const addr = IpAddress.initIp6(.{0} ** 16, 8080, 0, 0);
    try std.testing.expectEqual(os.net.AF.INET6, addr.any.family);
}

test "IpAddress: setPort/v4" {
    var addr = IpAddress.initIp4(.{0} ** 4, 0);
    addr.setPort(8080);
    try std.testing.expectEqual(8080, addr.getPort());
}

test "IpAddress: setPort/v6" {
    var addr = IpAddress.initIp6(.{0} ** 16, 0, 0, 0);
    addr.setPort(8080);
    try std.testing.expectEqual(8080, addr.getPort());
}

test "IpAddress: parseIp4" {
    const addr = try IpAddress.parseIp4("127.0.0.1", 8080);
    try std.testing.expectEqual(os.net.AF.INET, addr.any.family);
    try std.testing.expectEqual(8080, addr.getPort());

    var buf: [32]u8 = undefined;
    const formatted = try std.fmt.bufPrint(&buf, "{f}", .{addr});
    try std.testing.expectEqualStrings("127.0.0.1:8080", formatted);
}

test "IpAddress: parseIp6" {
    const addr = try IpAddress.parseIp6("::1", 8080);
    try std.testing.expectEqual(os.net.AF.INET6, addr.any.family);
    try std.testing.expectEqual(8080, addr.getPort());

    var buf: [64]u8 = undefined;
    const formatted = try std.fmt.bufPrint(&buf, "{f}", .{addr});
    try std.testing.expectEqualStrings("[::1]:8080", formatted);
}

test "IpAddress: parseIp" {
    const addr1 = try IpAddress.parseIp("127.0.0.1", 8080);
    try std.testing.expectEqual(os.net.AF.INET, addr1.any.family);
    try std.testing.expectEqual(8080, addr1.getPort());

    const addr2 = try IpAddress.parseIp("::1", 8080);
    try std.testing.expectEqual(os.net.AF.INET6, addr2.any.family);
    try std.testing.expectEqual(8080, addr2.getPort());
}

test "IpAddress: parseIpAndPort" {
    const addr1 = try IpAddress.parseIpAndPort("127.0.0.1:8080");
    try std.testing.expectEqual(os.net.AF.INET, addr1.any.family);
    try std.testing.expectEqual(8080, addr1.getPort());

    var buf1: [32]u8 = undefined;
    const formatted1 = try std.fmt.bufPrint(&buf1, "{f}", .{addr1});
    try std.testing.expectEqualStrings("127.0.0.1:8080", formatted1);

    const addr2 = try IpAddress.parseIpAndPort("[::1]:8080");
    try std.testing.expectEqual(os.net.AF.INET6, addr2.any.family);
    try std.testing.expectEqual(8080, addr2.getPort());

    var buf2: [64]u8 = undefined;
    const formatted2 = try std.fmt.bufPrint(&buf2, "{f}", .{addr2});
    try std.testing.expectEqualStrings("[::1]:8080", formatted2);
}

test "Address: parseIp" {
    const addr1 = try Address.parseIp("127.0.0.1", 8080);
    try std.testing.expectEqual(os.net.AF.INET, addr1.any.family);
    try std.testing.expectEqual(8080, addr1.ip.getPort());

    const addr2 = try Address.parseIp("::1", 8080);
    try std.testing.expectEqual(os.net.AF.INET6, addr2.any.family);
    try std.testing.expectEqual(8080, addr2.ip.getPort());
}

test "Address: parseIpAndHost" {
    const addr1 = try Address.parseIpAndHost("127.0.0.1:8080");
    try std.testing.expectEqual(os.net.AF.INET, addr1.any.family);
    try std.testing.expectEqual(8080, addr1.ip.getPort());

    var buf1: [32]u8 = undefined;
    const formatted1 = try std.fmt.bufPrint(&buf1, "{f}", .{addr1});
    try std.testing.expectEqualStrings("127.0.0.1:8080", formatted1);

    const addr2 = try Address.parseIpAndHost("[::1]:8080");
    try std.testing.expectEqual(os.net.AF.INET6, addr2.any.family);
    try std.testing.expectEqual(8080, addr2.ip.getPort());

    var buf2: [64]u8 = undefined;
    const formatted2 = try std.fmt.bufPrint(&buf2, "{f}", .{addr2});
    try std.testing.expectEqualStrings("[::1]:8080", formatted2);
}

test "IpAddress: isPrivate IPv4" {
    // RFC 1918 private ranges
    try std.testing.expect((try IpAddress.parseIp4("10.0.0.0", 0)).isPrivate());
    try std.testing.expect((try IpAddress.parseIp4("10.0.0.1", 0)).isPrivate());
    try std.testing.expect((try IpAddress.parseIp4("10.255.255.255", 0)).isPrivate());

    try std.testing.expect((try IpAddress.parseIp4("172.16.0.0", 0)).isPrivate());
    try std.testing.expect((try IpAddress.parseIp4("172.16.0.1", 0)).isPrivate());
    try std.testing.expect((try IpAddress.parseIp4("172.31.255.255", 0)).isPrivate());

    try std.testing.expect((try IpAddress.parseIp4("192.168.0.0", 0)).isPrivate());
    try std.testing.expect((try IpAddress.parseIp4("192.168.1.1", 0)).isPrivate());
    try std.testing.expect((try IpAddress.parseIp4("192.168.255.255", 0)).isPrivate());

    // Public addresses
    try std.testing.expect(!(try IpAddress.parseIp4("8.8.8.8", 0)).isPrivate());
    try std.testing.expect(!(try IpAddress.parseIp4("1.1.1.1", 0)).isPrivate());
    try std.testing.expect(!(try IpAddress.parseIp4("9.255.255.255", 0)).isPrivate());
    try std.testing.expect(!(try IpAddress.parseIp4("11.0.0.0", 0)).isPrivate());
    try std.testing.expect(!(try IpAddress.parseIp4("172.15.255.255", 0)).isPrivate());
    try std.testing.expect(!(try IpAddress.parseIp4("172.32.0.0", 0)).isPrivate());
    try std.testing.expect(!(try IpAddress.parseIp4("192.167.255.255", 0)).isPrivate());
    try std.testing.expect(!(try IpAddress.parseIp4("192.169.0.0", 0)).isPrivate());

    // Loopback is not private
    try std.testing.expect(!(try IpAddress.parseIp4("127.0.0.1", 0)).isPrivate());
}

test "IpAddress: isPrivate IPv6" {
    // RFC 4193 Unique Local Addresses (fc00::/7)
    try std.testing.expect((try IpAddress.parseIp6("fc00::", 0)).isPrivate());
    try std.testing.expect((try IpAddress.parseIp6("fc00::1", 0)).isPrivate());
    try std.testing.expect((try IpAddress.parseIp6("fd00::", 0)).isPrivate());
    try std.testing.expect((try IpAddress.parseIp6("fd00::1", 0)).isPrivate());
    try std.testing.expect((try IpAddress.parseIp6("fdff:ffff:ffff:ffff:ffff:ffff:ffff:ffff", 0)).isPrivate());

    // Public addresses
    try std.testing.expect(!(try IpAddress.parseIp6("2001:db8::1", 0)).isPrivate());
    try std.testing.expect(!(try IpAddress.parseIp6("2606:4700:4700::1111", 0)).isPrivate());
    try std.testing.expect(!(try IpAddress.parseIp6("fe00::", 0)).isPrivate());

    // Loopback is not private
    try std.testing.expect(!(try IpAddress.parseIp6("::1", 0)).isPrivate());
}

test "IpAddress: isLoopback IPv4" {
    // Entire 127.0.0.0/8 range
    try std.testing.expect((try IpAddress.parseIp4("127.0.0.0", 0)).isLoopback());
    try std.testing.expect((try IpAddress.parseIp4("127.0.0.1", 0)).isLoopback());
    try std.testing.expect((try IpAddress.parseIp4("127.255.255.255", 0)).isLoopback());
    try std.testing.expect((try IpAddress.parseIp4("127.1.2.3", 0)).isLoopback());

    // Not loopback
    try std.testing.expect(!(try IpAddress.parseIp4("126.255.255.255", 0)).isLoopback());
    try std.testing.expect(!(try IpAddress.parseIp4("128.0.0.0", 0)).isLoopback());
    try std.testing.expect(!(try IpAddress.parseIp4("8.8.8.8", 0)).isLoopback());
}

test "IpAddress: isLoopback IPv6" {
    // Only ::1 is loopback for IPv6
    try std.testing.expect((try IpAddress.parseIp6("::1", 0)).isLoopback());

    // Not loopback
    try std.testing.expect(!(try IpAddress.parseIp6("::", 0)).isLoopback());
    try std.testing.expect(!(try IpAddress.parseIp6("::2", 0)).isLoopback());
    try std.testing.expect(!(try IpAddress.parseIp6("fe80::1", 0)).isLoopback());
    try std.testing.expect(!(try IpAddress.parseIp6("2001:db8::1", 0)).isLoopback());
}

test "IpAddress: isLinkLocalUnicast IPv4" {
    // 169.254.0.0/16 range
    try std.testing.expect((try IpAddress.parseIp4("169.254.0.0", 0)).isLinkLocalUnicast());
    try std.testing.expect((try IpAddress.parseIp4("169.254.0.1", 0)).isLinkLocalUnicast());
    try std.testing.expect((try IpAddress.parseIp4("169.254.255.255", 0)).isLinkLocalUnicast());
    try std.testing.expect((try IpAddress.parseIp4("169.254.123.45", 0)).isLinkLocalUnicast());

    // Not link-local
    try std.testing.expect(!(try IpAddress.parseIp4("169.253.255.255", 0)).isLinkLocalUnicast());
    try std.testing.expect(!(try IpAddress.parseIp4("169.255.0.0", 0)).isLinkLocalUnicast());
    try std.testing.expect(!(try IpAddress.parseIp4("8.8.8.8", 0)).isLinkLocalUnicast());
}

test "IpAddress: isLinkLocalUnicast IPv6" {
    // fe80::/10 range
    try std.testing.expect((try IpAddress.parseIp6("fe80::", 0)).isLinkLocalUnicast());
    try std.testing.expect((try IpAddress.parseIp6("fe80::1", 0)).isLinkLocalUnicast());
    try std.testing.expect((try IpAddress.parseIp6("fe80::1234:5678", 0)).isLinkLocalUnicast());
    try std.testing.expect((try IpAddress.parseIp6("febf:ffff:ffff:ffff:ffff:ffff:ffff:ffff", 0)).isLinkLocalUnicast());

    // Not link-local
    try std.testing.expect(!(try IpAddress.parseIp6("fec0::", 0)).isLinkLocalUnicast());
    try std.testing.expect(!(try IpAddress.parseIp6("fe7f::", 0)).isLinkLocalUnicast());
    try std.testing.expect(!(try IpAddress.parseIp6("2001:db8::1", 0)).isLinkLocalUnicast());
    try std.testing.expect(!(try IpAddress.parseIp6("::1", 0)).isLinkLocalUnicast());
}

test "IpAddress: isUnspecified IPv4" {
    // 0.0.0.0
    try std.testing.expect((try IpAddress.parseIp4("0.0.0.0", 0)).isUnspecified());

    // Not unspecified
    try std.testing.expect(!(try IpAddress.parseIp4("0.0.0.1", 0)).isUnspecified());
    try std.testing.expect(!(try IpAddress.parseIp4("8.8.8.8", 0)).isUnspecified());
}

test "IpAddress: isUnspecified IPv6" {
    // ::
    try std.testing.expect((try IpAddress.parseIp6("::", 0)).isUnspecified());

    // Not unspecified
    try std.testing.expect(!(try IpAddress.parseIp6("::1", 0)).isUnspecified());
    try std.testing.expect(!(try IpAddress.parseIp6("::2", 0)).isUnspecified());
    try std.testing.expect(!(try IpAddress.parseIp6("2001:db8::1", 0)).isUnspecified());
}

test "IpAddress: isMulticast IPv4" {
    // 224.0.0.0/4 range (224.0.0.0 - 239.255.255.255)
    try std.testing.expect((try IpAddress.parseIp4("224.0.0.0", 0)).isMulticast());
    try std.testing.expect((try IpAddress.parseIp4("224.0.0.1", 0)).isMulticast());
    try std.testing.expect((try IpAddress.parseIp4("239.255.255.255", 0)).isMulticast());
    try std.testing.expect((try IpAddress.parseIp4("230.1.2.3", 0)).isMulticast());

    // Not multicast
    try std.testing.expect(!(try IpAddress.parseIp4("223.255.255.255", 0)).isMulticast());
    try std.testing.expect(!(try IpAddress.parseIp4("240.0.0.0", 0)).isMulticast());
    try std.testing.expect(!(try IpAddress.parseIp4("8.8.8.8", 0)).isMulticast());
}

test "IpAddress: isMulticast IPv6" {
    // ff00::/8 range
    try std.testing.expect((try IpAddress.parseIp6("ff00::", 0)).isMulticast());
    try std.testing.expect((try IpAddress.parseIp6("ff01::1", 0)).isMulticast());
    try std.testing.expect((try IpAddress.parseIp6("ff02::1", 0)).isMulticast());
    try std.testing.expect((try IpAddress.parseIp6("ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff", 0)).isMulticast());

    // Not multicast
    try std.testing.expect(!(try IpAddress.parseIp6("fe00::", 0)).isMulticast());
    try std.testing.expect(!(try IpAddress.parseIp6("2001:db8::1", 0)).isMulticast());
    try std.testing.expect(!(try IpAddress.parseIp6("::1", 0)).isMulticast());
}

test "IpAddress: isBroadcast IPv4" {
    // Broadcast
    try std.testing.expect((try IpAddress.parseIp4("255.255.255.255", 0)).isBroadcast());

    // Not broadcast
    try std.testing.expect(!(try IpAddress.parseIp4("255.255.255.254", 0)).isBroadcast());
    try std.testing.expect(!(try IpAddress.parseIp4("8.8.8.8", 0)).isBroadcast());
    try std.testing.expect(!(try IpAddress.parseIp4("0.0.0.0", 0)).isBroadcast());
}

test "IpAddress: isBroadcast IPv6" {
    // IPv6 has no broadcast concept
    try std.testing.expect(!(try IpAddress.parseIp6("::", 0)).isBroadcast());
    try std.testing.expect(!(try IpAddress.parseIp6("ff02::1", 0)).isBroadcast());
    try std.testing.expect(!(try IpAddress.parseIp6("2001:db8::1", 0)).isBroadcast());
}

test "IpAddress: isGlobalUnicast IPv4" {
    // Global unicast addresses (including private per RFC)
    try std.testing.expect((try IpAddress.parseIp4("8.8.8.8", 0)).isGlobalUnicast());
    try std.testing.expect((try IpAddress.parseIp4("1.1.1.1", 0)).isGlobalUnicast());
    try std.testing.expect((try IpAddress.parseIp4("93.184.216.34", 0)).isGlobalUnicast());
    try std.testing.expect((try IpAddress.parseIp4("10.0.0.1", 0)).isGlobalUnicast()); // private but still global unicast
    try std.testing.expect((try IpAddress.parseIp4("172.16.0.1", 0)).isGlobalUnicast()); // private but still global unicast
    try std.testing.expect((try IpAddress.parseIp4("192.168.1.1", 0)).isGlobalUnicast()); // private but still global unicast

    // Not global unicast
    try std.testing.expect(!(try IpAddress.parseIp4("127.0.0.1", 0)).isGlobalUnicast()); // loopback
    try std.testing.expect(!(try IpAddress.parseIp4("169.254.1.1", 0)).isGlobalUnicast()); // link-local
    try std.testing.expect(!(try IpAddress.parseIp4("224.0.0.1", 0)).isGlobalUnicast()); // multicast
    try std.testing.expect(!(try IpAddress.parseIp4("0.0.0.0", 0)).isGlobalUnicast()); // unspecified
    try std.testing.expect(!(try IpAddress.parseIp4("255.255.255.255", 0)).isGlobalUnicast()); // broadcast
}

test "IpAddress: isGlobalUnicast IPv6" {
    // Global unicast addresses (including private per RFC)
    try std.testing.expect((try IpAddress.parseIp6("2001:db8::1", 0)).isGlobalUnicast());
    try std.testing.expect((try IpAddress.parseIp6("2606:4700:4700::1111", 0)).isGlobalUnicast());
    try std.testing.expect((try IpAddress.parseIp6("fc00::1", 0)).isGlobalUnicast()); // private but still global unicast
    try std.testing.expect((try IpAddress.parseIp6("fd00::1", 0)).isGlobalUnicast()); // private but still global unicast

    // Not global unicast
    try std.testing.expect(!(try IpAddress.parseIp6("::1", 0)).isGlobalUnicast()); // loopback
    try std.testing.expect(!(try IpAddress.parseIp6("fe80::1", 0)).isGlobalUnicast()); // link-local
    try std.testing.expect(!(try IpAddress.parseIp6("ff02::1", 0)).isGlobalUnicast()); // multicast
    try std.testing.expect(!(try IpAddress.parseIp6("::", 0)).isGlobalUnicast()); // unspecified
}

test "UnixAddress: init" {
    if (!has_unix_sockets) return error.SkipZigTest;

    const path = "zio-test-socket.sock";
    defer os.fs.dirDeleteFile(std.testing.allocator, os.fs.cwd(), path) catch {};

    const addr = try UnixAddress.init(path);
    try std.testing.expectEqual(os.net.AF.UNIX, addr.any.family);
}

pub fn checkListen(addr: anytype, options: anytype, write_buffer: []u8) !void {
    const Test = struct {
        pub fn mainFn(rt: *Runtime, addr_inner: @TypeOf(addr), options_inner: @TypeOf(options), write_buffer_inner: []u8) !void {
            const server = try addr_inner.listen(rt, options_inner);
            defer server.close(rt);

            var server_task = try rt.spawn(serverFn, .{ rt, server });
            defer server_task.cancel(rt);

            var client_task = try rt.spawn(clientFn, .{ rt, server, write_buffer_inner });
            defer client_task.cancel(rt);

            // TODO use TaskGroup

            try server_task.join(rt);
            try client_task.join(rt);
        }

        pub fn serverFn(rt: *Runtime, server: Server) !void {
            const client = try server.accept(rt);
            defer client.close(rt);

            var buf: [32]u8 = undefined;
            var reader = client.reader(rt, &buf);

            const line = try reader.interface.takeDelimiterExclusive('\n');
            try std.testing.expectEqualStrings("hello", line);

            client.shutdown(rt, .both) catch {};
        }

        pub fn clientFn(rt: *Runtime, server: Server, write_buffer_inner: []u8) !void {
            const client = try server.socket.address.connect(rt);
            defer client.close(rt);

            var writer = client.writer(rt, write_buffer_inner);

            try writer.interface.writeAll("hello\n");
            try writer.interface.flush();

            client.shutdown(rt, .both) catch {};
        }
    };

    const runtime = try Runtime.init(std.testing.allocator, .{ .thread_pool = .{} });
    defer runtime.deinit();

    var handle = try runtime.spawn(Test.mainFn, .{ runtime, addr, options, write_buffer });
    try handle.join(runtime);
}

pub fn checkBind(server_addr: anytype, client_addr: anytype) !void {
    const Test = struct {
        pub fn mainFn(rt: *Runtime, server_addr_inner: @TypeOf(server_addr), client_addr_inner: @TypeOf(client_addr)) !void {
            const socket = try server_addr_inner.bind(rt, .{});
            defer socket.close(rt);

            var server_task = try rt.spawn(serverFn, .{ rt, socket });
            defer server_task.cancel(rt);

            var client_task = try rt.spawn(clientFn, .{ rt, socket, client_addr_inner });
            defer client_task.cancel(rt);

            try server_task.join(rt);
            try client_task.join(rt);
        }

        pub fn serverFn(rt: *Runtime, socket: Socket) !void {
            var buf: [1024]u8 = undefined;
            const result = try socket.receiveFrom(rt, &buf);

            try std.testing.expectEqualStrings("hello", buf[0..result.len]);

            const bytes_sent = try socket.sendTo(rt, result.from, buf[0..result.len]);
            try std.testing.expectEqual(result.len, bytes_sent);
        }

        pub fn clientFn(rt: *Runtime, server_socket: Socket, client_addr_inner: @TypeOf(client_addr)) !void {
            const client_socket = try client_addr_inner.bind(rt, .{});
            defer client_socket.close(rt);

            const test_data = "hello";
            const bytes_sent = try client_socket.sendTo(rt, server_socket.address, test_data);
            try std.testing.expectEqual(test_data.len, bytes_sent);

            var buf: [1024]u8 = undefined;
            const result = try client_socket.receiveFrom(rt, &buf);
            try std.testing.expectEqualStrings(test_data, buf[0..result.len]);
        }
    };

    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    var handle = try runtime.spawn(Test.mainFn, .{ runtime, server_addr, client_addr });
    try handle.join(runtime);
}

pub fn checkShutdown(addr: anytype, options: anytype) !void {
    const Test = struct {
        pub fn mainFn(rt: *Runtime, addr_inner: @TypeOf(addr), options_inner: @TypeOf(options)) !void {
            const server = try addr_inner.listen(rt, options_inner);
            defer server.close(rt);

            var server_task = try rt.spawn(serverFn, .{ rt, server });
            defer server_task.cancel(rt);

            var client_task = try rt.spawn(clientFn, .{ rt, server });
            defer client_task.cancel(rt);

            // TODO use TaskGroup

            try server_task.join(rt);
            try client_task.join(rt);
        }

        pub fn serverFn(rt: *Runtime, server: Server) !void {
            const client = try server.accept(rt);
            defer client.close(rt);
            client.shutdown(rt, .send) catch {};
        }

        pub fn clientFn(rt: *Runtime, server: Server) !void {
            const client = try server.socket.address.connect(rt);
            defer client.close(rt);

            var buf: [32]u8 = undefined;
            var reader = client.reader(rt, &buf);

            try std.testing.expectError(error.EndOfStream, reader.interface.takeByte());

            client.shutdown(rt, .both) catch {};
        }
    };

    const runtime = try Runtime.init(std.testing.allocator, .{ .thread_pool = .{} });
    defer runtime.deinit();

    var handle = try runtime.spawn(Test.mainFn, .{ runtime, addr, options });
    try handle.join(runtime);
}

test "UnixAddress: listen/accept/connect/read/write" {
    if (!has_unix_sockets) return error.SkipZigTest;

    const path = "zio-test-socket.sock";
    defer os.fs.dirDeleteFile(std.testing.allocator, os.fs.cwd(), path) catch {};

    var write_buffer: [32]u8 = undefined;
    const addr = try UnixAddress.init(path);
    try checkListen(addr, UnixAddress.ListenOptions{}, &write_buffer);
}

test "IpAddress: listen/accept/connect/read/write IPv4" {
    var write_buffer: [32]u8 = undefined;
    const addr = try IpAddress.parseIp4("127.0.0.1", 0);
    try checkListen(addr, IpAddress.ListenOptions{}, &write_buffer);
}

test "IpAddress: listen/accept/connect/read/write IPv6" {
    var write_buffer: [32]u8 = undefined;
    const addr = try IpAddress.parseIp6("::1", 0);
    checkListen(addr, IpAddress.ListenOptions{}, &write_buffer) catch |err| {
        if (err == error.AddressNotAvailable) return error.SkipZigTest;
        return err;
    };
}

test "UnixAddress: listen/accept/connect/read/write unbuffered" {
    if (!has_unix_sockets) return error.SkipZigTest;

    const path = "zio-test-socket.sock";
    defer os.fs.dirDeleteFile(std.testing.allocator, os.fs.cwd(), path) catch {};

    const addr = try UnixAddress.init(path);
    try checkListen(addr, UnixAddress.ListenOptions{}, &.{});
}

test "IpAddress: listen/accept/connect/read/write unbuffered IPv4" {
    const addr = try IpAddress.parseIp4("127.0.0.1", 0);
    try checkListen(addr, IpAddress.ListenOptions{}, &.{});
}

test "IpAddress: listen/accept/connect/read/write unbuffered IPv6" {
    const addr = try IpAddress.parseIp6("::1", 0);
    checkListen(addr, IpAddress.ListenOptions{}, &.{}) catch |err| {
        if (err == error.AddressNotAvailable) return error.SkipZigTest;
        return err;
    };
}

test "IpAddress: bind/sendTo/receiveFrom IPv4" {
    const addr = try IpAddress.parseIp4("127.0.0.1", 0);
    try checkBind(addr, addr);
}

test "IpAddress: bind/sendTo/receiveFrom IPv6" {
    const addr = try IpAddress.parseIp6("::1", 0);
    checkBind(addr, addr) catch |err| {
        if (err == error.AddressNotAvailable) return error.SkipZigTest;
        return err;
    };
}

test "UnixAddress: bind/sendTo/receiveFrom" {
    if (!has_unix_sockets) return error.SkipZigTest;
    // Windows doesn't support UDP Unix sockets
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const server_path = "zio-test-udp-server.sock";
    defer os.fs.dirDeleteFile(std.testing.allocator, os.fs.cwd(), server_path) catch {};

    const client_path = "zio-test-udp-client.sock";
    defer os.fs.dirDeleteFile(std.testing.allocator, os.fs.cwd(), client_path) catch {};

    const server_addr = try UnixAddress.init(server_path);
    const client_addr = try UnixAddress.init(client_path);
    try checkBind(server_addr, client_addr);
}

test "UnixAddress: listen/accept/connect/read/EOF" {
    if (!has_unix_sockets) return error.SkipZigTest;

    const path = "zio-test-socket.sock";
    defer os.fs.dirDeleteFile(std.testing.allocator, os.fs.cwd(), path) catch {};

    const addr = try UnixAddress.init(path);
    try checkShutdown(addr, UnixAddress.ListenOptions{});
}

test "IpAddress: listen/accept/connect/read/EOF IPv4" {
    const addr = try IpAddress.parseIp4("127.0.0.1", 0);
    try checkShutdown(addr, IpAddress.ListenOptions{});
}

test "IpAddress: listen/accept/connect/read/EOF IPv6" {
    const addr = try IpAddress.parseIp6("::1", 0);
    checkShutdown(addr, IpAddress.ListenOptions{}) catch |err| {
        if (err == error.AddressNotAvailable) return error.SkipZigTest;
        return err;
    };
}
