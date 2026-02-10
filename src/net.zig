// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");
const ev = @import("ev/root.zig");
const os = @import("os/root.zig");
const runtime_mod = @import("runtime.zig");
const Runtime = runtime_mod.Runtime;
const getCurrentTask = runtime_mod.getCurrentTask;
const Channel = @import("sync/channel.zig").Channel;
const Group = @import("runtime/group.zig").Group;

const common = @import("common.zig");
const waitForIo = common.waitForIo;
const waitForIoUncancelable = common.waitForIoUncancelable;
const timedWaitForIo = common.timedWaitForIo;
const blockInPlace = common.blockInPlace;
const Timeout = @import("time.zig").Timeout;
const fillBuf = @import("utils/writer.zig").fillBuf;

const Handle = ev.Backend.NetHandle;

pub const max_vecs = 16;

pub const has_unix_sockets = switch (builtin.os.tag) {
    .windows => builtin.os.version_range.windows.isAtLeast(.win10_rs4) orelse false,
    .wasi => false,
    else => true,
};

pub const default_kernel_backlog = 128;

/// A validated hostname according to RFC 1123.
/// * Has length less than or equal to `max_len`.
/// * Labels are 1-63 characters, separated by dots.
/// * Labels start and end with alphanumeric characters.
/// * Labels can contain alphanumeric characters and hyphens.
pub const HostName = struct {
    /// Externally managed memory. Already checked to be valid.
    bytes: []const u8,

    pub const max_len = 255;

    pub const ValidateError = error{
        NameTooLong,
        InvalidHostName,
    };

    /// Validates a hostname according to RFC 1123.
    pub fn validate(bytes: []const u8) ValidateError!void {
        if (bytes.len == 0) return error.InvalidHostName;
        if (bytes[0] == '.') return error.InvalidHostName;

        // Ignore trailing dot (FQDN). It doesn't count toward our length.
        const end = if (bytes[bytes.len - 1] == '.') end: {
            if (bytes.len == 1) return error.InvalidHostName;
            break :end bytes.len - 1;
        } else bytes.len;

        if (end > max_len) return error.NameTooLong;

        // Hostnames are divided into dot-separated "labels", which:
        // - Start with a letter or digit
        // - Can contain letters, digits, or hyphens
        // - Must end with a letter or digit
        // - Have a minimum of 1 character and a maximum of 63
        var label_start: usize = 0;
        var label_len: usize = 0;
        for (bytes[0..end], 0..) |c, i| {
            switch (c) {
                '.' => {
                    if (label_len == 0 or label_len > 63) return error.InvalidHostName;
                    if (!std.ascii.isAlphanumeric(bytes[label_start])) return error.InvalidHostName;
                    if (!std.ascii.isAlphanumeric(bytes[i - 1])) return error.InvalidHostName;

                    label_start = i + 1;
                    label_len = 0;
                },
                '-' => {
                    label_len += 1;
                },
                else => {
                    if (!std.ascii.isAlphanumeric(c)) return error.InvalidHostName;
                    label_len += 1;
                },
            }
        }

        // Validate the final label
        if (label_len == 0 or label_len > 63) return error.InvalidHostName;
        if (!std.ascii.isAlphanumeric(bytes[label_start])) return error.InvalidHostName;
        if (!std.ascii.isAlphanumeric(bytes[end - 1])) return error.InvalidHostName;
    }

    pub fn init(bytes: []const u8) ValidateError!HostName {
        try validate(bytes);
        return .{ .bytes = bytes };
    }

    /// Domain names are case-insensitive (RFC 5890, Section 2.3.2.4)
    pub fn eql(a: HostName, b: HostName) bool {
        return std.ascii.eqlIgnoreCase(a.bytes, b.bytes);
    }

    pub const LookupOptions = struct {
        /// Port number for the returned addresses.
        port: u16,
        /// Filter by address family. `null` means either.
        family: ?IpAddress.Family = null,
        /// Request canonical name from DNS.
        canonical_name: bool = false,
    };

    pub const LookupResult = union(enum) {
        address: IpAddress,
        canonical_name: HostName,
    };

    pub const LookupError = LookupHostError;

    pub const LookupResultIterator = struct {
        head: ?*os.net.addrinfo,
        current: ?*os.net.addrinfo,
        return_canonical_name: bool,

        pub fn next(self: *LookupResultIterator) ?LookupResult {
            // Return canonical name first if requested
            if (self.return_canonical_name) {
                self.return_canonical_name = false;
                if (self.head) |head| {
                    if (head.canonname) |name| {
                        return .{ .canonical_name = .{ .bytes = std.mem.sliceTo(name, 0) } };
                    }
                }
            }

            // Then return addresses
            while (self.current) |info| {
                self.current = @ptrCast(info.next);
                const addr = info.addr orelse continue;
                if (addr.family != os.net.AF.INET and addr.family != os.net.AF.INET6) continue;
                return .{ .address = IpAddress.initPosix(@ptrCast(addr), @intCast(info.addrlen)) };
            }
            return null;
        }

        pub fn deinit(self: *LookupResultIterator) void {
            if (self.head) |head| {
                os.net.freeaddrinfo(head);
            }
        }
    };

    /// Resolves the hostname to IP addresses.
    /// Returns an iterator over the results. Call `deinit()` when done.
    pub fn lookup(
        self: HostName,
        options: LookupOptions,
    ) LookupError!LookupResultIterator {
        const res = try blockInPlace(
            lookupHostBlocking,
            .{ self.bytes, options.port, options.family, options.canonical_name },
        );
        return .{
            .head = res,
            .current = res,
            .return_canonical_name = options.canonical_name,
        };
    }

    /// Resolves the hostname and connects to the first successful address.
    pub fn connect(self: HostName, port: u16, options: IpAddress.ConnectOptions) !Stream {
        var iter = try self.lookup(.{ .port = port });
        defer iter.deinit();

        var last_err: ?anyerror = null;
        while (iter.next()) |result| {
            switch (result) {
                .address => |addr| {
                    return addr.connect(.{ .timeout = options.timeout }) catch |err| {
                        last_err = err;
                        continue;
                    };
                },
                .canonical_name => {},
            }
        }
        if (last_err) |err| return err;
        return error.UnknownHostName;
    }
};

pub const ShutdownHow = os.net.ShutdownHow;

/// Get the socket address length for a given sockaddr.
/// Determines the appropriate length based on the address family.
fn getSockAddrLen(addr: *const os.net.sockaddr) os.net.socklen_t {
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

    pub const Family = enum { ipv4, ipv6 };

    pub fn getFamily(self: IpAddress) Family {
        return switch (self.any.family) {
            os.net.AF.INET => .ipv4,
            os.net.AF.INET6 => .ipv6,
            else => unreachable,
        };
    }

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

    pub const ConnectOptions = struct {
        timeout: Timeout = .none,
    };

    pub fn bind(self: IpAddress, options: BindOptions) !Socket {
        var socket = try Socket.open(.dgram, .fromPosix(self.any.family), .ip);
        errdefer socket.close();

        if (options.reuse_address) {
            try socket.setReuseAddress(true);
        }

        try socket.bind(.{ .ip = self });

        return socket;
    }

    pub fn listen(self: IpAddress, options: ListenOptions) !Server {
        var socket = try Socket.open(.stream, .fromPosix(self.any.family), .ip);
        errdefer socket.close();

        if (options.reuse_address) {
            try socket.setReuseAddress(true);
        }

        try socket.bind(.{ .ip = self });
        try socket.listen(options.kernel_backlog);

        return .{ .socket = socket };
    }

    pub fn connect(self: IpAddress, options: ConnectOptions) !Stream {
        var socket = try Socket.open(.stream, .fromPosix(self.any.family), .ip);
        errdefer socket.close();

        try socket.connect(.{ .ip = self }, .{ .timeout = options.timeout });
        return .{ .socket = socket };
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

    pub const ConnectOptions = struct {
        timeout: Timeout = .none,
    };

    pub fn format(self: UnixAddress, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (!has_unix_sockets) unreachable;
        switch (self.any.family) {
            os.net.AF.UNIX => try w.writeAll(std.mem.sliceTo(&self.un.path, 0)),
            else => unreachable,
        }
    }

    pub fn bind(self: UnixAddress, options: BindOptions) !Socket {
        if (!has_unix_sockets) unreachable;

        var socket = try Socket.open(.dgram, .unix, .ip);
        errdefer socket.close();

        if (options.reuse_address) {
            try socket.setReuseAddress(true);
        }

        try socket.bind(.{ .unix = self });

        return socket;
    }

    pub fn listen(self: UnixAddress, options: ListenOptions) !Server {
        if (!has_unix_sockets) unreachable;

        var socket = try Socket.open(.stream, .unix, .ip);
        errdefer socket.close();

        try socket.bind(.{ .unix = self });
        try socket.listen(options.kernel_backlog);

        return .{ .socket = socket };
    }

    pub fn connect(self: UnixAddress, options: ConnectOptions) !Stream {
        if (!has_unix_sockets) unreachable;

        var socket = try Socket.open(.stream, .unix, .ip);
        errdefer socket.close();

        try socket.connect(.{ .unix = self }, .{ .timeout = options.timeout });
        return .{ .socket = socket };
    }
};

pub const Address = extern union {
    any: os.net.sockaddr,
    ip: IpAddress,
    unix: UnixAddress,

    pub const Type = enum { ip, unix };
    pub const Family = enum { ipv4, ipv6, unix };

    pub fn getType(self: Address) Type {
        return switch (self.any.family) {
            os.net.AF.INET, os.net.AF.INET6 => .ip,
            os.net.AF.UNIX => .unix,
            else => unreachable,
        };
    }

    pub fn getFamily(self: Address) Family {
        return switch (self.any.family) {
            os.net.AF.INET => .ipv4,
            os.net.AF.INET6 => .ipv6,
            os.net.AF.UNIX => .unix,
            else => unreachable,
        };
    }

    /// Convert to std.net.Address
    pub fn toStd(self: *const Address) std.net.Address {
        return switch (self.any.family) {
            os.net.AF.INET => .{ .in = .{ .sa = self.ip.in } },
            os.net.AF.INET6 => .{ .in6 = .{ .sa = self.ip.in6 } },
            os.net.AF.UNIX => if (has_unix_sockets) .{ .un = self.unix.un } else unreachable,
            else => unreachable,
        };
    }

    /// Convert from std.net.Address
    pub fn fromStd(addr: std.net.Address) Address {
        return switch (addr.any.family) {
            os.net.AF.INET => .{ .ip = .{ .in = addr.in.sa } },
            os.net.AF.INET6 => .{ .ip = .{ .in6 = addr.in6.sa } },
            os.net.AF.UNIX => if (has_unix_sockets) .{ .unix = .{ .un = addr.un } } else unreachable,
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
            os.net.AF.INET, os.net.AF.INET6 => .{ .ip = fromStorageIp(data) },
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

    pub const ConnectOptions = struct {
        timeout: Timeout = .none,
    };

    pub fn format(self: Address, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self.getType()) {
            .ip => return self.ip.format(w),
            .unix => return self.unix.format(w),
        }
    }

    pub fn connect(self: Address, options: ConnectOptions) !Stream {
        switch (self.getType()) {
            .ip => return self.ip.connect(.{ .timeout = options.timeout }),
            .unix => return self.unix.connect(.{ .timeout = options.timeout }),
        }
    }

    /// Parse an IP address string with a separate port parameter.
    /// Supports both IPv4 and IPv6 addresses.
    /// Examples: parseIp("127.0.0.1", 8080), parseIp("::1", 8080)
    pub fn parseIp(ip: []const u8, port: u16) !Address {
        return .{ .ip = try .parseIp(ip, port) };
    }

    /// Parse an IP address with port from a single string.
    /// IPv4 format: "127.0.0.1:8080"
    /// IPv6 format: "[::1]:8080"
    pub fn parseIpAndHost(addr: []const u8) !Address {
        return .{ .ip = try .parseIpAndPort(addr) };
    }
};

pub const ReceiveFromResult = struct {
    from: Address,
    len: usize,
};

pub const ReceiveMsgResult = struct {
    from: Address,
    len: usize,
    flags: u32,
};

pub const Socket = struct {
    handle: Handle,
    address: Address,

    pub fn open(sock_type: os.net.Type, domain: os.net.Domain, protocol: os.net.Protocol) !Socket {
        var op = ev.NetOpen.init(domain, sock_type, protocol, .{});
        try waitForIo(&op.c);
        const handle = try op.getResult();
        return .{ .handle = handle, .address = undefined };
    }

    pub fn close(self: Socket) void {
        var op = ev.NetClose.init(self.handle);
        waitForIoUncancelable(&op.c);
        _ = op.getResult() catch {};
    }

    /// Enable or disable address reuse (SO_REUSEADDR)
    /// Allows binding to an address in TIME_WAIT state
    pub fn setReuseAddress(self: Socket, enabled: bool) !void {
        try self.setBoolOption(os.posix.SOL.SOCKET, os.posix.SO.REUSEADDR, enabled);
    }

    /// Enable or disable port reuse (SO_REUSEPORT)
    /// Allows multiple sockets to bind to the same port for load balancing
    /// Note: Not supported on Windows
    pub fn setReusePort(self: Socket, enabled: bool) !void {
        if (builtin.os.tag == .windows) {
            return error.Unsupported;
        }
        try self.setBoolOption(os.posix.SOL.SOCKET, os.posix.SO.REUSEPORT, enabled);
    }

    /// Enable or disable TCP keepalive (SO_KEEPALIVE)
    /// Periodically sends keepalive probes to detect dead connections
    pub fn setKeepAlive(self: Socket, enabled: bool) !void {
        try self.setBoolOption(os.posix.SOL.SOCKET, os.posix.SO.KEEPALIVE, enabled);
    }

    /// Enable or disable Nagle's algorithm (TCP_NODELAY)
    /// When enabled (true), disables buffering for low-latency communication
    pub fn setNoDelay(self: Socket, enabled: bool) !void {
        try self.setBoolOption(os.posix.IPPROTO.TCP, os.posix.TCP.NODELAY, enabled);
    }

    /// Set the system-level send buffer size (SO_SNDBUF)
    /// Note: The kernel may not grant the full requested size due to system limits.
    /// Use getSendBufferSize() to verify the actual buffer size allocated.
    /// Larger buffers can improve throughput, especially for UDP to prevent packet loss.
    pub fn setSendBufferSize(self: Socket, size: usize) !void {
        try self.setIntOption(os.posix.SOL.SOCKET, os.posix.SO.SNDBUF, size);
    }

    /// Set the system-level receive buffer size (SO_RCVBUF)
    /// Note: The kernel may not grant the full requested size due to system limits.
    /// Use getReceiveBufferSize() to verify the actual buffer size allocated.
    /// Larger buffers can improve throughput, especially for UDP to prevent packet loss.
    pub fn setReceiveBufferSize(self: Socket, size: usize) !void {
        try self.setIntOption(os.posix.SOL.SOCKET, os.posix.SO.RCVBUF, size);
    }

    /// Get the current system-level send buffer size (SO_SNDBUF)
    /// Returns the actual buffer size allocated by the kernel, which may differ
    /// from the requested size due to kernel limits and internal overhead.
    pub fn getSendBufferSize(self: Socket) !usize {
        return self.getIntOption(os.posix.SOL.SOCKET, os.posix.SO.SNDBUF);
    }

    /// Get the current system-level receive buffer size (SO_RCVBUF)
    /// Returns the actual buffer size allocated by the kernel, which may differ
    /// from the requested size due to kernel limits and internal overhead.
    pub fn getReceiveBufferSize(self: Socket) !usize {
        return self.getIntOption(os.posix.SOL.SOCKET, os.posix.SO.RCVBUF);
    }

    /// Helper function to set a boolean socket option (POSIX)
    fn setBoolOption(self: Socket, level: i32, optname: u32, enabled: bool) !void {
        if (builtin.os.tag == .windows) {
            const value: c_int = if (enabled) 1 else 0;
            const rc = os.windows.setsockopt(self.handle, level, optname, std.mem.asBytes(&value).ptr, @sizeOf(c_int));
            if (rc == os.windows.SOCKET_ERROR) {
                return error.Unexpected;
            }
        } else {
            const value: c_int = if (enabled) 1 else 0;
            const bytes = std.mem.asBytes(&value);
            try std.posix.setsockopt(self.handle, level, optname, bytes);
        }
    }

    /// Helper function to set an integer socket option
    fn setIntOption(self: Socket, level: i32, optname: u32, value: usize) !void {
        const int_value: c_int = @intCast(value);
        if (builtin.os.tag == .windows) {
            const rc = os.windows.setsockopt(self.handle, level, optname, std.mem.asBytes(&int_value).ptr, @sizeOf(c_int));
            if (rc == os.windows.SOCKET_ERROR) {
                return error.Unexpected;
            }
        } else {
            const bytes = std.mem.asBytes(&int_value);
            try std.posix.setsockopt(self.handle, level, optname, bytes);
        }
    }

    /// Helper function to get an integer socket option
    fn getIntOption(self: Socket, level: i32, optname: u32) !usize {
        var int_value: c_int = undefined;
        if (builtin.os.tag == .windows) {
            var len: c_int = @sizeOf(c_int);
            const rc = os.windows.getsockopt(self.handle, level, @intCast(optname), std.mem.asBytes(&int_value).ptr, &len);
            if (rc == os.windows.SOCKET_ERROR) {
                return error.Unexpected;
            }
        } else {
            try std.posix.getsockopt(self.handle, level, optname, std.mem.asBytes(&int_value));
        }
        return @intCast(int_value);
    }

    /// Bind the socket to an address
    pub fn bind(self: *Socket, addr: Address) !void {
        // Copy addr to self.address so NetBind can update it with actual bound address
        self.address = addr;
        var addr_len = getSockAddrLen(&self.address.any);

        var op = ev.NetBind.init(self.handle, &self.address.any, &addr_len);
        try waitForIo(&op.c);
        try op.getResult();
    }

    /// Mark the socket as a listening socket
    pub fn listen(self: *Socket, backlog: u31) !void {
        var op = ev.NetListen.init(self.handle, backlog);
        try waitForIo(&op.c);
        try op.getResult();
    }

    pub const ConnectOptions = struct {
        timeout: Timeout = .none,
    };

    /// Connect the socket to a remote address
    pub fn connect(self: *Socket, addr: Address, options: ConnectOptions) !void {
        self.address = addr;
        const addr_len = getSockAddrLen(&self.address.any);

        var op = ev.NetConnect.init(self.handle, &self.address.any, addr_len);
        try timedWaitForIo(&op.c, options.timeout);
        try op.getResult();
    }

    /// Receives data from the socket into the provided buffer.
    /// Returns the number of bytes received, which may be less than buf.len.
    /// A return value of 0 indicates the socket has been shut down.
    pub fn receive(self: Socket, buf: []u8, timeout: Timeout) !usize {
        var storage: [1]os.iovec = undefined;
        return self.receiveBuf(.fromSlice(buf, &storage), timeout);
    }

    /// Low-level receive function that accepts ev.ReadBuf directly.
    pub fn receiveBuf(self: Socket, buf: ev.ReadBuf, timeout: Timeout) !usize {
        var op = ev.NetRecv.init(self.handle, buf, .{});
        try timedWaitForIo(&op.c, timeout);
        return try op.getResult();
    }

    /// Sends data from the provided buffer to the socket.
    /// Returns the number of bytes sent, which may be less than buf.len.
    pub fn send(self: Socket, buf: []const u8, timeout: Timeout) !usize {
        var storage: [1]os.iovec_const = undefined;
        return self.sendBuf(.fromSlice(buf, &storage), timeout);
    }

    /// Low-level send function that accepts ev.WriteBuf directly.
    pub fn sendBuf(self: Socket, buf: ev.WriteBuf, timeout: Timeout) !usize {
        var op = ev.NetSend.init(self.handle, buf, .{});
        try timedWaitForIo(&op.c, timeout);
        return try op.getResult();
    }

    /// Receives a datagram from the socket, returning the sender's address and bytes read.
    /// Used for UDP and other datagram-based protocols.
    pub fn receiveFrom(self: Socket, buf: []u8, timeout: Timeout) !ReceiveFromResult {
        var storage: [1]os.iovec = undefined;
        var result: ReceiveFromResult = undefined;
        var peer_addr_len: os.net.socklen_t = @sizeOf(@TypeOf(result.from));
        var op = ev.NetRecvFrom.init(self.handle, .fromSlice(buf, &storage), .{}, &result.from.any, &peer_addr_len);
        try timedWaitForIo(&op.c, timeout);
        result.len = try op.getResult();
        return result;
    }

    /// Sends a datagram to the specified address.
    /// Used for UDP and other datagram-based protocols.
    pub fn sendTo(self: Socket, addr: Address, data: []const u8, timeout: Timeout) !usize {
        var storage: [1]os.iovec_const = undefined;
        const addr_len = getSockAddrLen(&addr.any);
        var op = ev.NetSendTo.init(self.handle, .fromSlice(data, &storage), .{}, &addr.any, addr_len);
        try timedWaitForIo(&op.c, timeout);
        return try op.getResult();
    }

    /// Receives a message with sender address and ancillary data (control messages).
    /// The control buffer receives ancillary data (e.g., credentials, file descriptors).
    /// Returns sender address, bytes read, and message flags.
    pub fn receiveMsg(
        self: Socket,
        buf: ev.ReadBuf,
        control: ?[]u8,
        timeout: Timeout,
    ) !ReceiveMsgResult {
        var result: ReceiveMsgResult = undefined;
        var addr_len: os.net.socklen_t = @sizeOf(Address);
        var op = ev.NetRecvMsg.init(self.handle, buf, .{}, &result.from.any, &addr_len, control);
        try timedWaitForIo(&op.c, timeout);
        const os_result = try op.getResult();
        result.len = os_result.len;
        result.flags = os_result.flags;
        return result;
    }

    /// Sends a message with optional destination address and ancillary data (control messages).
    /// If addr is null, the socket must be connected. If addr is provided, sends to that address.
    /// The control buffer contains ancillary data to send (e.g., credentials, file descriptors).
    /// Returns the number of bytes sent.
    pub fn sendMsg(
        self: Socket,
        buf: ev.WriteBuf,
        addr: ?Address,
        control: ?[]const u8,
        timeout: Timeout,
    ) !usize {
        const addr_ptr = if (addr) |a| &a.any else null;
        const addr_len = if (addr) |a| getSockAddrLen(&a.any) else 0;
        var op = ev.NetSendMsg.init(self.handle, buf, .{}, addr_ptr, addr_len, control);
        try timedWaitForIo(&op.c, timeout);
        return try op.getResult();
    }

    pub fn shutdown(self: Socket, how: ShutdownHow) !void {
        var op = ev.NetShutdown.init(self.handle, how);
        try waitForIo(&op.c);
        try op.getResult();
    }
};

pub const Server = struct {
    socket: Socket,

    pub fn accept(self: Server) !Stream {
        var peer_addr: Address = undefined;
        var peer_addr_len: os.net.socklen_t = @sizeOf(Address);

        var op = ev.NetAccept.init(self.socket.handle, &peer_addr.any, &peer_addr_len);
        try waitForIo(&op.c);
        const handle = try op.getResult();
        return .{ .socket = .{ .handle = handle, .address = peer_addr } };
    }

    pub fn shutdown(self: Server, how: ShutdownHow) !void {
        return self.socket.shutdown(how);
    }

    pub fn close(self: Server) void {
        return self.socket.close();
    }
};

pub const Stream = struct {
    socket: Socket,

    /// Reads data from the stream into the provided buffer.
    /// Returns the number of bytes read, which may be less than buf.len.
    /// A return value of 0 indicates end-of-stream.
    pub fn read(self: Stream, buf: []u8, timeout: Timeout) !usize {
        var storage: [1]os.iovec = undefined;
        return self.readBuf(.fromSlice(buf, &storage), timeout);
    }

    /// Reads data from the stream into the provided buffer until it is full or the stream is closed.
    /// A return value of 0 indicates end-of-stream.
    pub fn readAll(self: Stream, buf: []u8, timeout: Timeout) !void {
        var offset: usize = 0;
        while (offset < buf.len) {
            const n = try self.read(buf[offset..], timeout);
            if (n == 0) break;
            offset += n;
        }
    }

    /// Reads data from the stream into multiple buffers using vectored I/O.
    /// Returns the number of bytes read across all buffers, which may be less than the total capacity.
    /// A return value of 0 indicates end-of-stream.
    pub fn readVec(self: Stream, bufs: [][]u8, timeout: Timeout) !usize {
        var storage: [max_vecs]os.iovec = undefined;
        return self.readBuf(.fromSlices(bufs, &storage), timeout);
    }

    /// Low-level read function that accepts ev.ReadBuf directly.
    /// Returns the number of bytes read, which may be less than requested.
    /// A return value of 0 indicates end-of-stream.
    pub fn readBuf(self: Stream, buf: ev.ReadBuf, timeout: Timeout) !usize {
        return self.socket.receiveBuf(buf, timeout);
    }

    /// Writes data from the provided buffer to the stream.
    /// Returns the number of bytes written, which may be less than buf.len.
    pub fn write(self: Stream, buf: []const u8, timeout: Timeout) !usize {
        var storage: [1]os.iovec_const = undefined;
        return self.writeBuf(.fromSlice(buf, &storage), timeout);
    }

    /// Writes data from the provided buffer to the stream until it is empty.
    /// Returns an error if the stream is closed or if the write fails.
    pub fn writeAll(self: Stream, buf: []const u8, timeout: Timeout) !void {
        var offset: usize = 0;
        while (offset < buf.len) {
            const n = try self.write(buf[offset..], timeout);
            offset += n;
        }
    }

    /// Writes data from multiple buffers to the stream using vectored I/O.
    /// Returns the number of bytes written across all buffers, which may be less than the total.
    pub fn writeVec(self: Stream, bufs: []const []const u8, timeout: Timeout) !usize {
        var storage: [max_vecs]os.iovec_const = undefined;
        return self.writeBuf(.fromSlices(bufs, &storage), timeout);
    }

    /// Writes header followed by data slices, with optional splat (repeat) of the last slice.
    /// Used internally by the buffered Writer.
    pub fn writeSplatHeader(self: Stream, header: []const u8, data: []const []const u8, splat: usize, timeout: Timeout) !usize {
        var splat_buf: [64]u8 = undefined;
        var slices: [max_vecs][]const u8 = undefined;
        const buf_len = fillBuf(&slices, header, data, splat, &splat_buf);

        var storage: [max_vecs]os.iovec_const = undefined;
        return self.writeBuf(.fromSlices(slices[0..buf_len], &storage), timeout);
    }

    /// Low-level write function that accepts ev.WriteBuf directly.
    pub fn writeBuf(self: Stream, buf: ev.WriteBuf, timeout: Timeout) !usize {
        return self.socket.sendBuf(buf, timeout);
    }

    /// Shuts down all or part of a full-duplex connection.
    pub fn shutdown(self: Stream, how: ShutdownHow) !void {
        return self.socket.shutdown(how);
    }

    /// Closes the stream.
    pub fn close(self: Stream) void {
        self.socket.close();
    }

    pub const Reader = struct {
        stream: Stream,
        interface: std.Io.Reader,
        timeout: Timeout = .none,
        err: ?(ev.NetRecv.Error || common.Timeoutable) = null,

        pub fn init(stream: Stream, buffer: []u8) Reader {
            return .{
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

        pub fn setTimeout(self: *Reader, timeout: Timeout) void {
            self.timeout = timeout;
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
            var storage: [1 + max_vecs]os.iovec = undefined;
            const dest_n, const data_size = if (builtin.os.tag == .windows)
                try io_r.writableVectorWsa(&storage, data)
            else
                try io_r.writableVectorPosix(&storage, data);
            if (dest_n == 0) return 0;

            const n = r.stream.readBuf(.{ .iovecs = storage[0..dest_n] }, r.timeout) catch |err| {
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
        stream: Stream,
        interface: std.Io.Writer,
        timeout: Timeout = .none,
        err: ?(ev.NetSend.Error || common.Timeoutable) = null,

        pub fn init(stream: Stream, buffer: []u8) Writer {
            return .{
                .stream = stream,
                .interface = .{
                    .vtable = &.{
                        .drain = drainImpl,
                    },
                    .buffer = buffer,
                },
            };
        }

        pub fn setTimeout(self: *Writer, timeout: Timeout) void {
            self.timeout = timeout;
        }

        fn drainImpl(io_w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
            const w: *Writer = @alignCast(@fieldParentPtr("interface", io_w));
            const buffered = io_w.buffered();
            const n = w.stream.writeSplatHeader(buffered, data, splat, w.timeout) catch |err| {
                w.err = err;
                return error.WriteFailed;
            };
            return io_w.consume(n);
        }
    };

    /// Creates a buffered reader for the given stream.
    pub fn reader(stream: Stream, buffer: []u8) Reader {
        return .init(stream, buffer);
    }

    /// Creates a buffered writer for the given stream.
    pub fn writer(stream: Stream, buffer: []u8) Writer {
        return .init(stream, buffer);
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

fn lookupHostBlocking(
    name: []const u8,
    port: u16,
    family: ?IpAddress.Family,
    canonical_name: bool,
) LookupHostError!?*os.net.addrinfo {
    // Use stack buffer for temporary allocations
    var buf: [512]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const allocator = fba.allocator();

    const name_c = try allocator.dupeZ(u8, name);
    const port_c = try std.fmt.allocPrintSentinel(allocator, "{d}", .{port}, 0);

    var hints: os.net.addrinfo = std.mem.zeroes(os.net.addrinfo);
    hints.family = if (family) |f| switch (f) {
        .ipv4 => os.net.AF.INET,
        .ipv6 => os.net.AF.INET6,
    } else os.net.AF.UNSPEC;
    hints.socktype = std.posix.SOCK.STREAM;
    hints.protocol = std.posix.IPPROTO.TCP;
    if (canonical_name) {
        hints.flags.CANONNAME = true;
    }

    var res: ?*os.net.addrinfo = null;

    os.net.getaddrinfo(name_c.ptr, port_c.ptr, &hints, &res) catch |err| {
        return switch (err) {
            error.ServiceNotAvailable => error.ServiceUnavailable,
            error.InvalidFlags => unreachable,
            error.SocketTypeNotSupported => unreachable,
            else => |e| e,
        };
    };

    return res;
}

pub fn tcpConnectToHost(
    name: []const u8,
    port: u16,
    options: IpAddress.ConnectOptions,
) !Stream {
    const host = try HostName.init(name);
    return host.connect(port, options);
}

pub fn tcpConnectToAddress(addr: IpAddress, options: IpAddress.ConnectOptions) !Stream {
    return addr.connect(options);
}

test {
    std.testing.refAllDecls(@This());
}

test "HostName: validate" {
    // Valid hostnames
    try HostName.validate("example");
    try HostName.validate("example.com");
    try HostName.validate("www.example.com");
    try HostName.validate("sub.domain.example.com");
    try HostName.validate("example.com.");
    try HostName.validate("host-name.example.com.");
    try HostName.validate("123.example.com.");
    try HostName.validate("a-b.com");
    try HostName.validate("a.b.c.d.e.f.g");
    try HostName.validate("127.0.0.1"); // Also a valid hostname
    try HostName.validate("a" ** 63 ++ ".com"); // Label exactly 63 chars (valid)
    try HostName.validate("a." ** 127 ++ "a"); // Total length 255 (valid)

    // Invalid hostnames
    try std.testing.expectError(error.InvalidHostName, HostName.validate(""));
    try std.testing.expectError(error.InvalidHostName, HostName.validate(".example.com"));
    try std.testing.expectError(error.InvalidHostName, HostName.validate("example.com.."));
    try std.testing.expectError(error.InvalidHostName, HostName.validate("host..domain"));
    try std.testing.expectError(error.InvalidHostName, HostName.validate("-hostname"));
    try std.testing.expectError(error.InvalidHostName, HostName.validate("hostname-"));
    try std.testing.expectError(error.InvalidHostName, HostName.validate("a.-.b"));
    try std.testing.expectError(error.InvalidHostName, HostName.validate("host_name.com"));
    try std.testing.expectError(error.InvalidHostName, HostName.validate("."));
    try std.testing.expectError(error.InvalidHostName, HostName.validate(".."));
    try std.testing.expectError(error.InvalidHostName, HostName.validate("a" ** 64 ++ ".com")); // Label length 64 (too long)
    try std.testing.expectError(error.NameTooLong, HostName.validate("a." ** 127 ++ "ab")); // Total length 256 (too long)
}

test "HostName: eql" {
    const a = try HostName.init("Example.COM");
    const b = try HostName.init("example.com");
    const c = try HostName.init("other.com");

    try std.testing.expect(a.eql(b));
    try std.testing.expect(b.eql(a));
    try std.testing.expect(!a.eql(c));
}

test "HostName: lookup" {
    const rt = try Runtime.init(std.testing.allocator, .{ .thread_pool = .{} });
    defer rt.deinit();

    const host = try HostName.init("localhost");
    var iter = try host.lookup(.{ .port = 80 });
    defer iter.deinit();

    var has_address = false;
    while (iter.next()) |result| {
        switch (result) {
            .address => |addr| {
                try std.testing.expectEqual(80, addr.getPort());
                has_address = true;
            },
            .canonical_name => unreachable,
        }
    }
    try std.testing.expect(has_address);
}

test "HostName: lookup with family filter" {
    const rt = try Runtime.init(std.testing.allocator, .{ .thread_pool = .{} });
    defer rt.deinit();

    const host = try HostName.init("localhost");
    var iter = try host.lookup(.{ .port = 80, .family = .ipv4 });
    defer iter.deinit();

    while (iter.next()) |result| {
        switch (result) {
            .address => |addr| {
                try std.testing.expectEqual(IpAddress.Family.ipv4, addr.getFamily());
            },
            .canonical_name => unreachable,
        }
    }
}

test "HostName: lookup with canonical name" {
    const rt = try Runtime.init(std.testing.allocator, .{ .thread_pool = .{} });
    defer rt.deinit();

    const host = try HostName.init("localhost");
    var iter = try host.lookup(.{ .port = 80, .canonical_name = true });
    defer iter.deinit();

    var has_canonical_name = false;
    var has_address = false;
    while (iter.next()) |result| {
        switch (result) {
            .address => {
                has_address = true;
            },
            .canonical_name => |name| {
                has_canonical_name = true;
                try std.testing.expect(name.bytes.len > 0);
            },
        }
    }
    try std.testing.expect(has_canonical_name);
    try std.testing.expect(has_address);
}

test "HostName: connect" {
    if (builtin.os.tag == .macos) return error.SkipZigTest;

    const rt = try Runtime.init(std.testing.allocator, .{ .thread_pool = .{} });
    defer rt.deinit();

    const Test = struct {
        fn run() !void {
            // Start a server
            const server_addr = try IpAddress.parseIp4("127.0.0.1", 0);
            const server = try server_addr.listen(.{});
            defer server.close();

            const port = server.socket.address.ip.getPort();

            // Connect via HostName
            const host = try HostName.init("localhost");
            var stream = try host.connect(port, .{});
            defer stream.close();

            try stream.writeAll("hello", .none);
        }
    };

    var task = try rt.spawn(Test.run, .{});
    defer task.cancel();
    try task.join();
}

test "IpAddress: getFamily" {
    const ipv4 = try IpAddress.parseIp4("127.0.0.1", 80);
    try std.testing.expectEqual(IpAddress.Family.ipv4, ipv4.getFamily());

    const ipv6 = try IpAddress.parseIp6("::1", 80);
    try std.testing.expectEqual(IpAddress.Family.ipv6, ipv6.getFamily());
}

test "HostName: lookup localhost" {
    const rt = try Runtime.init(std.testing.allocator, .{ .thread_pool = .{} });
    defer rt.deinit();

    const host = try HostName.init("localhost");
    var iter = try host.lookup(.{ .port = 80 });
    defer iter.deinit();

    var count: usize = 0;
    while (iter.next()) |_| {
        count += 1;
    }
    try std.testing.expect(count > 0);
}

test "HostName: lookup numeric IP" {
    const rt = try Runtime.init(std.testing.allocator, .{ .thread_pool = .{} });
    defer rt.deinit();

    const host = try HostName.init("127.0.0.1");
    var iter = try host.lookup(.{ .port = 8080 });
    defer iter.deinit();

    var count: usize = 0;
    var first_addr: ?IpAddress = null;
    while (iter.next()) |result| {
        switch (result) {
            .address => |addr| {
                if (first_addr == null) first_addr = addr;
                count += 1;
            },
            .canonical_name => unreachable,
        }
    }
    try std.testing.expectEqual(1, count);
    try std.testing.expectEqual(8080, first_addr.?.getPort());
}

test "tcpConnectToAddress: basic" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    const ServerTask = struct {
        fn run(server_port: *Channel(u16)) !void {
            const addr = try IpAddress.parseIp4("127.0.0.1", 0);
            const server = try addr.listen(.{});
            defer server.close();

            try server_port.send(server.socket.address.ip.getPort());

            var stream = try server.accept();
            defer stream.close();

            var read_buffer: [256]u8 = undefined;
            var reader = stream.reader(&read_buffer);

            const msg = try reader.interface.takeDelimiterExclusive('\n');
            try std.testing.expectEqualStrings("hello", msg);
        }
    };

    const ClientTask = struct {
        fn run(server_port: *Channel(u16)) !void {
            const port = try server_port.receive();
            const addr = try IpAddress.parseIp4("127.0.0.1", port);

            var stream = try tcpConnectToAddress(addr, .{});
            defer stream.close();

            var write_buffer: [256]u8 = undefined;
            var writer = stream.writer(&write_buffer);

            try writer.interface.writeAll("hello\n");
            try writer.interface.flush();

            stream.shutdown(.both) catch {};
        }
    };

    var server_port_buf: [1]u16 = undefined;
    var server_port_ch = Channel(u16).init(&server_port_buf);

    var group: Group = .init;
    defer group.cancel();

    try group.spawn(ServerTask.run, .{&server_port_ch});
    try group.spawn(ClientTask.run, .{&server_port_ch});

    try group.wait();
}

test "tcpConnectToHost: basic" {
    if (builtin.os.tag == .macos) return error.SkipZigTest;

    const ServerTask = struct {
        fn run(server_port: *Channel(u16)) !void {
            const addr = try IpAddress.parseIp4("127.0.0.1", 0);
            const server = try addr.listen(.{});
            defer server.close();

            std.log.info("Server listening on port {}\n", .{server.socket.address.ip.getPort()});

            try server_port.send(server.socket.address.ip.getPort());

            var stream = try server.accept();
            defer stream.close();

            var read_buffer: [256]u8 = undefined;
            var reader = stream.reader(&read_buffer);

            const msg = try reader.interface.takeDelimiterExclusive('\n');
            try std.testing.expectEqualStrings("hello", msg);
        }
    };

    const ClientTask = struct {
        fn run(server_port: *Channel(u16)) !void {
            const port = try server_port.receive();
            std.log.info("Client connecting to port {}\n", .{port});

            var stream = try tcpConnectToHost("localhost", port, .{});
            defer stream.close();

            var write_buffer: [256]u8 = undefined;
            var writer = stream.writer(&write_buffer);

            try writer.interface.writeAll("hello\n");
            try writer.interface.flush();

            try stream.shutdown(.both);
        }
    };

    const runtime = try Runtime.init(std.testing.allocator, .{ .thread_pool = .{} });
    defer runtime.deinit();

    var server_port_buf: [1]u16 = undefined;
    var server_port_ch = Channel(u16).init(&server_port_buf);

    var group: Group = .init;
    defer group.cancel();

    try group.spawn(ServerTask.run, .{&server_port_ch});
    try group.spawn(ClientTask.run, .{&server_port_ch});

    try group.wait();
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
        pub fn mainFn(addr_inner: @TypeOf(addr), options_inner: @TypeOf(options), write_buffer_inner: []u8) !void {
            const server = try addr_inner.listen(options_inner);
            defer server.close();

            var group: Group = .init;
            defer group.cancel();

            try group.spawn(serverFn, .{server});
            try group.spawn(clientFn, .{ server, write_buffer_inner });

            try group.wait();
        }

        pub fn serverFn(server: Server) !void {
            const client = try server.accept();
            defer client.close();

            var buf: [32]u8 = undefined;
            var reader = client.reader(&buf);

            const line = try reader.interface.takeDelimiterExclusive('\n');
            try std.testing.expectEqualStrings("hello", line);

            client.shutdown(.both) catch {};
        }

        pub fn clientFn(server: Server, write_buffer_inner: []u8) !void {
            const client = try server.socket.address.connect(.{});
            defer client.close();

            var writer = client.writer(write_buffer_inner);

            try writer.interface.writeAll("hello\n");
            try writer.interface.flush();

            client.shutdown(.both) catch {};
        }
    };

    const runtime = try Runtime.init(std.testing.allocator, .{ .thread_pool = .{} });
    defer runtime.deinit();

    var handle = try runtime.spawn(Test.mainFn, .{ addr, options, write_buffer });
    try handle.join();
}

pub fn checkBind(server_addr: anytype, client_addr: anytype) !void {
    const Test = struct {
        pub fn mainFn(server_addr_inner: @TypeOf(server_addr), client_addr_inner: @TypeOf(client_addr)) !void {
            const socket = try server_addr_inner.bind(.{});
            defer socket.close();

            var group: Group = .init;
            defer group.cancel();

            try group.spawn(serverFn, .{socket});
            try group.spawn(clientFn, .{ socket, client_addr_inner });

            try group.wait();
        }

        pub fn serverFn(socket: Socket) !void {
            var buf: [1024]u8 = undefined;
            const result = try socket.receiveFrom(&buf, .none);

            try std.testing.expectEqualStrings("hello", buf[0..result.len]);

            const bytes_sent = try socket.sendTo(result.from, buf[0..result.len], .none);
            try std.testing.expectEqual(result.len, bytes_sent);
        }

        pub fn clientFn(server_socket: Socket, client_addr_inner: @TypeOf(client_addr)) !void {
            const client_socket = try client_addr_inner.bind(.{});
            defer client_socket.close();

            const test_data = "hello";
            const bytes_sent = try client_socket.sendTo(server_socket.address, test_data, .none);
            try std.testing.expectEqual(test_data.len, bytes_sent);

            var buf: [1024]u8 = undefined;
            const result = try client_socket.receiveFrom(&buf, .none);
            try std.testing.expectEqualStrings(test_data, buf[0..result.len]);
        }
    };

    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    var handle = try runtime.spawn(Test.mainFn, .{ server_addr, client_addr });
    try handle.join();
}

pub fn checkShutdown(addr: anytype, options: anytype) !void {
    const Test = struct {
        pub fn mainFn(addr_inner: @TypeOf(addr), options_inner: @TypeOf(options)) !void {
            const server = try addr_inner.listen(options_inner);
            defer server.close();

            var group: Group = .init;
            defer group.cancel();

            try group.spawn(serverFn, .{server});
            try group.spawn(clientFn, .{server});

            try group.wait();
        }

        pub fn serverFn(server: Server) !void {
            const client = try server.accept();
            defer client.close();
            client.shutdown(.send) catch {};
        }

        pub fn clientFn(server: Server) !void {
            const client = try server.socket.address.connect(.{});
            defer client.close();

            var buf: [32]u8 = undefined;
            var reader = client.reader(&buf);

            try std.testing.expectError(error.EndOfStream, reader.interface.takeByte());

            client.shutdown(.both) catch {};
        }
    };

    const runtime = try Runtime.init(std.testing.allocator, .{ .thread_pool = .{} });
    defer runtime.deinit();

    var handle = try runtime.spawn(Test.mainFn, .{ addr, options });
    try handle.join();
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

test "Socket: buffer size get/set" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    // Create a UDP socket for testing
    const socket = try Socket.open(.dgram, .ipv4, .udp);
    defer socket.close();

    // Test send buffer size
    const desired_send_size: usize = 32 * 1024; // 32 KB
    try socket.setSendBufferSize(desired_send_size);
    const actual_send_size = try socket.getSendBufferSize();
    // The kernel may grant a different size, but it should be > 0
    try std.testing.expect(actual_send_size > 0);

    // Test receive buffer size
    const desired_recv_size: usize = 64 * 1024; // 64 KB
    try socket.setReceiveBufferSize(desired_recv_size);
    const actual_recv_size = try socket.getReceiveBufferSize();
    // The kernel may grant a different size, but it should be > 0
    try std.testing.expect(actual_recv_size > 0);

    // Verify that setting different sizes results in different values
    // (though kernel may adjust them)
    const new_send_size: usize = 16 * 1024; // 16 KB
    try socket.setSendBufferSize(new_send_size);
    const updated_send_size = try socket.getSendBufferSize();
    try std.testing.expect(updated_send_size > 0);
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
