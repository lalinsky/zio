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
const Group = @import("group.zig").Group;

const dns = @import("dns/root.zig");

const common = @import("common.zig");
const waitForIo = common.waitForIo;
const waitForIoUncancelable = common.waitForIoUncancelable;
const timedWaitForIo = common.timedWaitForIo;
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

fn stdIoHandleToZio(h: std.Io.net.Socket.Handle) Handle {
    return if (@typeInfo(Handle) == .pointer) @ptrCast(h) else h;
}

fn stdIoFileHandleToZio(h: std.Io.File.Handle) os.fs.fd_t {
    return if (@typeInfo(os.fs.fd_t) == .pointer) @ptrCast(h) else h;
}

pub fn readBuf(handle: Handle, buf: ev.ReadBuf, timeout: Timeout) (ev.NetRecv.Error || common.Timeoutable)!usize {
    var op = ev.NetRecv.init(handle, buf, .{});
    try timedWaitForIo(&op.c, timeout);
    return try op.getResult();
}

pub fn writeBuf(handle: Handle, buf: ev.WriteBuf, timeout: Timeout) (ev.NetSend.Error || common.Timeoutable)!usize {
    var op = ev.NetSend.init(handle, buf, .{});
    try timedWaitForIo(&op.c, timeout);
    return try op.getResult();
}

pub fn writeSplatHeader(handle: Handle, header: []const u8, data: []const []const u8, splat: usize, timeout: Timeout) (ev.NetSend.Error || common.Timeoutable)!usize {
    var splat_buf: [64]u8 = undefined;
    var slices: [max_vecs][]const u8 = undefined;
    const buf_len = fillBuf(&slices, header, data, splat, &splat_buf);

    var storage: [max_vecs]os.iovec_const = undefined;
    return writeBuf(handle, .fromSlices(slices[0..buf_len], &storage), timeout);
}

/// A validated hostname or numeric IP address.
/// Hostnames follow RFC 1123:
/// * Has length less than or equal to `max_len`.
/// * Labels are 1-63 characters, separated by dots.
/// * Labels start and end with alphanumeric characters.
/// * Labels can contain alphanumeric characters and hyphens.
/// Numeric IPv4 and IPv6 addresses are also accepted.
pub const HostName = struct {
    /// Externally managed memory. Already checked to be valid.
    bytes: []const u8,

    pub const max_len = 255;

    pub const ValidateError = error{
        NameTooLong,
        InvalidHostName,
    };

    /// Validates a hostname according to RFC 1123, or a numeric IP address.
    pub fn validate(bytes: []const u8) ValidateError!void {
        if (bytes.len == 0) return error.InvalidHostName;
        if (IpAddress.parseIp(bytes, 0)) |_| return else |_| {}
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
        /// If non-null, the canonical name will be copied into this buffer.
        canonical_name_buffer: ?*[max_len]u8 = null,
    };

    pub const LookupResult = dns.LookupResult;
    pub const LookupError = dns.LookupError;

    /// Resolves the hostname to IP addresses.
    /// Fills `storage` with up to `storage.len` results.
    /// Returns the number of entries written.
    pub fn lookup(
        self: HostName,
        storage: []LookupResult,
        options: LookupOptions,
    ) LookupError!usize {
        return dns.lookup(storage, .{
            .name = self.bytes,
            .port = options.port,
            .family = options.family,
            .canonical_name_buffer = options.canonical_name_buffer,
        });
    }

    /// Resolves the hostname and connects to the first successful address.
    pub fn connect(self: HostName, port: u16, options: IpAddress.ConnectOptions) !Stream {
        var storage: [32]LookupResult = undefined;
        const count = self.lookup(&storage, .{ .port = port }) catch |err| switch (err) {
            error.TooManyAddresses => storage.len,
            else => return err,
        };

        var last_err: ?anyerror = null;
        for (storage[0..count]) |entry| {
            switch (entry) {
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
        os.net.AF.UNIX => if (has_unix_sockets) getUnixSockAddrLen(@ptrCast(addr)) else unreachable,
        else => unreachable,
    };
}

/// Compute the address length to pass to bind()/connect() for a Unix socket.
///
/// The kernel derives the socket name from this length, so it must cover
/// exactly the meaningful bytes. Using the full struct size folds the trailing
/// zero padding into the name. For pathname sockets that's harmless (the kernel
/// stops at the NUL terminator), but abstract sockets (Linux) — whose name
/// starts with a NUL byte and is matched verbatim — would gain a tail of NUL
/// bytes, which breaks interoperability with every other peer.
///
/// We follow the same convention as Go and the Linux unix(7) man page:
///   - pathname socket: offsetof(path) + strlen(path) + 1  (NUL terminated)
///   - abstract socket: offsetof(path) + name length       (no terminator)
///
/// `UnixAddress` doesn't store the original name length, so for abstract
/// sockets we recover it by trimming the trailing NUL padding that init() left
/// behind. This can't represent an abstract name that intentionally ends in NUL
/// bytes, but such names don't occur in practice.
fn getUnixSockAddrLen(un: *const os.net.sockaddr.un) os.net.socklen_t {
    const path_off = @offsetOf(os.net.sockaddr.un, "path");
    // The abstract namespace is Linux-only: only there does a leading NUL select
    // an abstract (or unnamed/autobind) name whose length must exclude the
    // trailing NUL padding. Everywhere else a name is always a pathname.
    if (builtin.os.tag == .linux and un.path[0] == 0) {
        var len = un.path.len;
        while (len > 0 and un.path[len - 1] == 0) len -= 1;
        return @intCast(path_off + len);
    }
    // Pathname socket: NUL-terminated string; the terminator is part of the length.
    return @intCast(path_off + std.mem.sliceTo(&un.path, 0).len + 1);
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
                const zeros: [16]u8 = @splat(0);
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

    // Derive the limit from the platform's actual sun_path size, reserving one
    // byte for the NUL terminator that pathname sockets and format() rely on.
    pub const max_len = if (has_unix_sockets)
        @typeInfo(@FieldType(os.net.sockaddr.un, "path")).array.len - 1
    else
        0;

    pub fn init(path: []const u8) !UnixAddress {
        if (!has_unix_sockets) unreachable;
        if (path.len > max_len) return error.NameTooLong;
        var un: os.net.sockaddr.un = .{ .family = os.net.AF.UNIX, .path = @splat(0) };
        @memcpy(un.path[0..path.len], path);
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
            os.net.AF.UNIX => {
                // Abstract sockets (Linux) start with a NUL byte, so sliceTo()
                // would stop immediately and print nothing. Render the leading
                // NUL as '@' (the ss(8)/Go convention) and emit the rest of the
                // name, which has no terminator — see getUnixSockAddrLen().
                if (builtin.os.tag == .linux and self.un.path[0] == 0) {
                    var len = self.un.path.len;
                    while (len > 0 and self.un.path[len - 1] == 0) len -= 1;
                    try w.writeByte('@');
                    if (len > 1) try w.writeAll(self.un.path[1..len]);
                } else {
                    try w.writeAll(std.mem.sliceTo(&self.un.path, 0));
                }
            },
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

    /// Build an Address from a raw OS sockaddr and the length the kernel
    /// reported, as returned by accept(), recvfrom(), recvmsg(), etc. This is
    /// the single path for turning kernel-provided address bytes into an
    /// Address.
    ///
    /// For Unix sockets it zero-fills the name buffer and copies only the bytes
    /// the kernel actually wrote, so the trailing padding is always well-defined
    /// and later format()/getSockAddrLen() never read uninitialized memory. A
    /// length too short to even hold the address family means the kernel didn't
    /// provide an address (e.g. recvmsg on a connected socket); report that as
    /// an unspecified address rather than reading garbage.
    pub fn fromPosix(addr: *const os.net.sockaddr, len: os.net.socklen_t) Address {
        if (len < @sizeOf(@FieldType(os.net.sockaddr, "family"))) return .{ .ip = .unspecified(0) };
        switch (addr.family) {
            os.net.AF.INET => {
                if (len < @sizeOf(os.net.sockaddr.in)) return .{ .ip = .unspecified(0) };
                return .{ .ip = .initPosix(addr, len) };
            },
            os.net.AF.INET6 => {
                if (len < @sizeOf(os.net.sockaddr.in6)) return .{ .ip = .unspecified(0) };
                return .{ .ip = .initPosix(addr, len) };
            },
            os.net.AF.UNIX => {
                if (!has_unix_sockets) unreachable;
                const path_off = @offsetOf(os.net.sockaddr.un, "path");
                var result: Address = .{ .unix = .{ .un = .{ .family = os.net.AF.UNIX, .path = @splat(0) } } };
                const total: usize = @intCast(len);
                const name_len = if (total > path_off) @min(total - path_off, result.unix.un.path.len) else 0;
                const src: *align(1) const os.net.sockaddr.un = @ptrCast(addr);
                @memcpy(result.unix.un.path[0..name_len], src.path[0..name_len]);
                return result;
            },
            else => unreachable,
        }
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
        var op = ev.NetOpen.init(domain, sock_type, protocol, .{ .nonblocking = true });
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
            try os.net.setsockopt(self.handle, level, optname, bytes);
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
            try os.net.setsockopt(self.handle, level, optname, bytes);
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
            try os.net.getsockopt(self.handle, level, optname, std.mem.asBytes(&int_value));
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
        return readBuf(self.handle, .fromSlice(buf, &storage), timeout);
    }

    /// Sends data from the provided buffer to the socket.
    /// Returns the number of bytes sent, which may be less than buf.len.
    pub fn send(self: Socket, buf: []const u8, timeout: Timeout) !usize {
        var storage: [1]os.iovec_const = undefined;
        return writeBuf(self.handle, .fromSlice(buf, &storage), timeout);
    }

    /// Receives a datagram from the socket, returning the sender's address and bytes read.
    /// Used for UDP and other datagram-based protocols.
    pub fn receiveFrom(self: Socket, buf: []u8, timeout: Timeout) !ReceiveFromResult {
        var iovecs: [1]os.iovec = undefined;
        var peer_addr: Address = undefined;
        var peer_addr_len: os.net.socklen_t = @sizeOf(Address);
        var op = ev.NetRecvFrom.init(self.handle, .fromSlice(buf, &iovecs), .{}, &peer_addr.any, &peer_addr_len);
        try timedWaitForIo(&op.c, timeout);
        const len = try op.getResult();
        return .{ .from = .fromPosix(&peer_addr.any, peer_addr_len), .len = len };
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
        var peer_addr: Address = undefined;
        var addr_len: os.net.socklen_t = @sizeOf(Address);
        var op = ev.NetRecvMsg.init(self.handle, buf, .{}, &peer_addr.any, &addr_len, control);
        try timedWaitForIo(&op.c, timeout);
        const os_result = try op.getResult();
        return .{
            .from = .fromPosix(&peer_addr.any, addr_len),
            .len = os_result.len,
            .flags = os_result.flags,
        };
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

    pub const AcceptOptions = struct {
        timeout: Timeout = .none,
    };

    pub fn accept(self: Server, options: AcceptOptions) !Stream {
        var peer_addr: Address = undefined;
        var peer_addr_len: os.net.socklen_t = @sizeOf(Address);

        var op = ev.NetAccept.init(self.socket.handle, &peer_addr.any, &peer_addr_len);
        try timedWaitForIo(&op.c, options.timeout);
        const handle = try op.getResult();
        return .{ .socket = .{ .handle = handle, .address = .fromPosix(&peer_addr.any, peer_addr_len) } };
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
        return readBuf(self.socket.handle, .fromSlice(buf, &storage), timeout);
    }

    /// Reads data from the stream into multiple buffers using vectored I/O.
    /// Returns the number of bytes read across all buffers, which may be less than the total capacity.
    /// A return value of 0 indicates end-of-stream.
    pub fn readVec(self: Stream, bufs: [][]u8, timeout: Timeout) !usize {
        var storage: [max_vecs]os.iovec = undefined;
        return readBuf(self.socket.handle, .fromSlices(bufs, &storage), timeout);
    }

    /// Writes data from the provided buffer to the stream.
    /// Returns the number of bytes written, which may be less than buf.len.
    pub fn write(self: Stream, buf: []const u8, timeout: Timeout) !usize {
        var storage: [1]os.iovec_const = undefined;
        return writeBuf(self.socket.handle, .fromSlice(buf, &storage), timeout);
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
        return writeBuf(self.socket.handle, .fromSlices(bufs, &storage), timeout);
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
        handle: Handle,
        interface: std.Io.Reader,
        timeout: Timeout = .none,
        err: ?(ev.NetRecv.Error || common.Timeoutable) = null,

        pub fn init(handle: Handle, buffer: []u8) Reader {
            return .{
                .handle = handle,
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

        pub fn fromStd(stream: std.Io.net.Stream, io: std.Io, buffer: []u8) Reader {
            _ = Runtime.fromIo(io);
            return init(stdIoHandleToZio(stream.socket.handle), buffer);
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

            const n = readBuf(r.handle, .{ .iovecs = storage[0..dest_n] }, r.timeout) catch |err| {
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
        handle: Handle,
        interface: std.Io.Writer,
        timeout: Timeout = .none,
        err: ?(ev.NetSend.Error || common.Timeoutable) = null,

        pub fn init(handle: Handle, buffer: []u8) Writer {
            return .{
                .handle = handle,
                .interface = .{
                    .vtable = &.{
                        .drain = drainImpl,
                        .sendFile = sendFileImpl,
                    },
                    .buffer = buffer,
                },
            };
        }

        pub fn fromStd(stream: std.Io.net.Stream, io: std.Io, buffer: []u8) Writer {
            _ = Runtime.fromIo(io);
            return init(stdIoHandleToZio(stream.socket.handle), buffer);
        }

        pub fn setTimeout(self: *Writer, timeout: Timeout) void {
            self.timeout = timeout;
        }

        fn drainImpl(io_w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
            const w: *Writer = @alignCast(@fieldParentPtr("interface", io_w));
            const buffered = io_w.buffered();
            const n = writeSplatHeader(w.handle, buffered, data, splat, w.timeout) catch |err| {
                w.err = err;
                return error.WriteFailed;
            };
            return io_w.consume(n);
        }

        /// `std.Io.Writer` vtable `sendFile`: zero(ish)-copy file-to-socket
        /// transfer via `ev.NetSendFile`. The writer's own buffered bytes act as
        /// the header and must precede the file body; `limit` caps only the
        /// file-origin bytes (header excluded), per the std contract.
        fn sendFileImpl(io_w: *std.Io.Writer, file_reader: *std.Io.File.Reader, limit: std.Io.Limit) std.Io.Writer.FileError!usize {
            const w: *Writer = @alignCast(@fieldParentPtr("interface", io_w));

            const header = io_w.buffered();
            const reader_buffered = limit.slice(file_reader.interface.buffered());

            // First flush the writer's buffered bytes and/or the reader's
            // already-buffered bytes before touching the file. Returns partial
            // progress; std's sendFileAll loops back for the file body.
            if (header.len != 0 or reader_buffered.len != 0) {
                var iovs: [2]os.iovec_const = undefined;
                const parts = [_][]const u8{ header, reader_buffered };
                var op = ev.NetSend.init(w.handle, ev.WriteBuf.fromSlices(&parts, &iovs), .{});
                waitForIo(&op.c) catch {
                    w.err = error.Canceled;
                    return error.WriteFailed;
                };
                const n = op.getResult() catch |err| {
                    w.err = err;
                    return error.WriteFailed;
                };
                file_reader.interface.toss(n -| header.len);
                return io_w.consume(n);
            }

            // Lend both the writer's and the reader's buffers to the fallback
            // loop; both are free here (any buffered bytes were flushed above).
            // The ev layer decides how to use them (double-buffer / split /
            // serial). If neither is usable, defer to std's read/drain fallback.
            const bufs: [2][]u8 = .{ io_w.buffer, file_reader.interface.buffer };
            if (bufs[0].len == 0 and bufs[1].len == 0) return error.Unimplemented;

            // Stream the file body directly from the current read position.
            const want = @intFromEnum(limit);
            if (want == 0) return 0;

            var op = ev.NetSendFile.init(
                w.handle,
                stdIoFileHandleToZio(file_reader.file.handle),
                file_reader.pos,
                want,
                bufs,
            );
            waitForIo(&op.c) catch {
                w.err = error.Canceled;
                return error.WriteFailed;
            };
            const sent = op.getResult() catch |err| switch (err) {
                error.Canceled => {
                    w.err = error.Canceled;
                    return error.WriteFailed;
                },
                // Errors unique to the file-read side; surface as ReadFailed.
                error.InputOutput, error.IsDir, error.NotOpenForReading, error.Unseekable => return error.ReadFailed,
                // Remaining errors are all part of the send-side set.
                else => |e| {
                    w.err = @errorCast(e);
                    return error.WriteFailed;
                },
            };
            if (sent == 0) return error.EndOfStream;
            file_reader.pos += sent;
            return io_w.consume(sent); // header is empty here, so this returns `sent`
        }
    };

    /// Creates a buffered reader for the given stream.
    pub fn reader(stream: Stream, buffer: []u8) Reader {
        return .init(stream.socket.handle, buffer);
    }

    /// Creates a buffered writer for the given stream.
    pub fn writer(stream: Stream, buffer: []u8) Writer {
        return .init(stream.socket.handle, buffer);
    }
};

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

test "IpAddress: getFamily" {
    const ipv4 = try IpAddress.parseIp4("127.0.0.1", 80);
    try std.testing.expectEqual(IpAddress.Family.ipv4, ipv4.getFamily());

    const ipv6 = try IpAddress.parseIp6("::1", 80);
    try std.testing.expectEqual(IpAddress.Family.ipv6, ipv6.getFamily());
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

            var stream = try server.accept(.{});
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
    if (builtin.os.tag == .macos or builtin.os.tag == .netbsd) return error.SkipZigTest;

    const ServerTask = struct {
        fn run(server_port: *Channel(u16)) !void {
            const addr = try IpAddress.parseIp4("127.0.0.1", 0);
            const server = try addr.listen(.{});
            defer server.close();

            std.log.info("Server listening on port {}\n", .{server.socket.address.ip.getPort()});

            try server_port.send(server.socket.address.ip.getPort());

            var stream = try server.accept(.{});
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

test "Stream.Writer.sendFile transfers a file over a socket" {
    const Io = std.Io;
    const path = "test-native-sendfile";
    const total = 40_000;

    const runtime = try Runtime.init(std.testing.allocator, .{ .thread_pool = .{} });
    defer runtime.deinit();
    const io = runtime.io();

    const ServerTask = struct {
        fn run(server_port: *Channel(u16)) !void {
            const addr = try IpAddress.parseIp4("127.0.0.1", 0);
            const server = try addr.listen(.{});
            defer server.close();

            try server_port.send(server.socket.address.ip.getPort());

            var stream = try server.accept(.{});
            defer stream.close();

            var received: usize = 0;
            var buf: [4096]u8 = undefined;
            while (received < total) {
                const n = stream.read(&buf, .none) catch break;
                if (n == 0) break;
                for (buf[0..n], received..) |b, i| {
                    try std.testing.expectEqual(@as(u8, @intCast(i % 251)), b);
                }
                received += n;
            }
            try std.testing.expectEqual(@as(usize, total), received);
        }
    };

    const ClientTask = struct {
        fn run(client_io: Io, server_port: *Channel(u16)) !void {
            // Create the source file with a known pattern.
            {
                var f = try Io.Dir.cwd().createFile(client_io, path, .{ .truncate = true });
                defer f.close(client_io);
                var fw_buf: [4096]u8 = undefined;
                var fw = f.writer(client_io, &fw_buf);
                var i: usize = 0;
                while (i < total) : (i += 1) {
                    try fw.interface.writeByte(@intCast(i % 251));
                }
                try fw.interface.flush();
            }
            defer Io.Dir.cwd().deleteFile(client_io, path) catch {};

            var f = try Io.Dir.cwd().openFile(client_io, path, .{});
            defer f.close(client_io);
            var fr_buf: [4096]u8 = undefined;
            var fr = f.reader(client_io, &fr_buf);

            const port = try server_port.receive();
            const addr = try IpAddress.parseIp4("127.0.0.1", port);
            var stream = try tcpConnectToAddress(addr, .{});
            defer stream.close();

            var write_buffer: [4096]u8 = undefined;
            var writer = stream.writer(&write_buffer);

            const sent = try writer.interface.sendFileAll(&fr, .unlimited);
            try std.testing.expectEqual(@as(usize, total), sent);
            try writer.interface.flush();

            stream.shutdown(.both) catch {};
        }
    };

    var server_port_buf: [1]u16 = undefined;
    var server_port_ch = Channel(u16).init(&server_port_buf);

    var group: Group = .init;
    defer group.cancel();

    try group.spawn(ServerTask.run, .{&server_port_ch});
    try group.spawn(ClientTask.run, .{ io, &server_port_ch });

    try group.wait();
}

test "Stream.Writer.sendFile honors a byte limit" {
    const Io = std.Io;
    const path = "test-native-sendfile-limit";
    const total = 40_000;
    const limit = 10_000;

    const runtime = try Runtime.init(std.testing.allocator, .{ .thread_pool = .{} });
    defer runtime.deinit();
    const io = runtime.io();

    const ServerTask = struct {
        fn run(server_port: *Channel(u16)) !void {
            const addr = try IpAddress.parseIp4("127.0.0.1", 0);
            const server = try addr.listen(.{});
            defer server.close();

            try server_port.send(server.socket.address.ip.getPort());

            var stream = try server.accept(.{});
            defer stream.close();

            // Read until the sender closes; it must deliver exactly `limit`
            // bytes of the file pattern and nothing more.
            var received: usize = 0;
            var buf: [4096]u8 = undefined;
            while (true) {
                const n = stream.read(&buf, .none) catch break;
                if (n == 0) break;
                for (buf[0..n], received..) |b, i| {
                    try std.testing.expectEqual(@as(u8, @intCast(i % 251)), b);
                }
                received += n;
            }
            try std.testing.expectEqual(@as(usize, limit), received);
        }
    };

    const ClientTask = struct {
        fn run(client_io: Io, server_port: *Channel(u16)) !void {
            // Create a source file larger than the limit.
            {
                var f = try Io.Dir.cwd().createFile(client_io, path, .{ .truncate = true });
                defer f.close(client_io);
                var fw_buf: [4096]u8 = undefined;
                var fw = f.writer(client_io, &fw_buf);
                var i: usize = 0;
                while (i < total) : (i += 1) {
                    try fw.interface.writeByte(@intCast(i % 251));
                }
                try fw.interface.flush();
            }
            defer Io.Dir.cwd().deleteFile(client_io, path) catch {};

            var f = try Io.Dir.cwd().openFile(client_io, path, .{});
            defer f.close(client_io);
            var fr_buf: [4096]u8 = undefined;
            var fr = f.reader(client_io, &fr_buf);

            const port = try server_port.receive();
            const addr = try IpAddress.parseIp4("127.0.0.1", port);
            var stream = try tcpConnectToAddress(addr, .{});
            defer stream.close();

            var write_buffer: [4096]u8 = undefined;
            var writer = stream.writer(&write_buffer);

            // Only `limit` file bytes are sent, even though the file is larger.
            const sent = try writer.interface.sendFileAll(&fr, .limited(limit));
            try std.testing.expectEqual(@as(usize, limit), sent);
            try writer.interface.flush();

            stream.shutdown(.both) catch {};
        }
    };

    var server_port_buf: [1]u16 = undefined;
    var server_port_ch = Channel(u16).init(&server_port_buf);

    var group: Group = .init;
    defer group.cancel();

    try group.spawn(ServerTask.run, .{&server_port_ch});
    try group.spawn(ClientTask.run, .{ io, &server_port_ch });

    try group.wait();
}

test "Stream.Writer.sendFile cancellation unblocks a stalled transfer" {
    const Io = std.Io;
    const path = "test-native-sendfile-cancel";

    const runtime = try Runtime.init(std.testing.allocator, .{ .thread_pool = .{} });
    defer runtime.deinit();
    const io = runtime.io();

    // A file much larger than any socket buffer, so the send stalls once the
    // buffers fill and the peer never reads.
    const total = 4 * 1024 * 1024;
    {
        var f = try Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
        defer f.close(io);
        var fw_buf: [4096]u8 = undefined;
        var fw = f.writer(io, &fw_buf);
        const zeros = [_]u8{0} ** 4096;
        var written: usize = 0;
        while (written < total) : (written += zeros.len) {
            try fw.interface.writeAll(&zeros);
        }
        try fw.interface.flush();
    }
    defer Io.Dir.cwd().deleteFile(io, path) catch {};

    const Outcome = struct {
        completed: bool = false,
        send_err: ?anyerror = null, // error returned by sendFileAll (null = succeeded)
        writer_err: ?anyerror = null, // diagnostic stashed on the writer
    };

    // Accepts a connection and then sits idle without reading, so the sender's
    // socket buffers fill and the transfer stalls. Held open until canceled.
    const ServerTask = struct {
        fn run(server_port: *Channel(u16)) void {
            const addr = IpAddress.parseIp4("127.0.0.1", 0) catch return;
            const server = addr.listen(.{}) catch return;
            defer server.close();
            server_port.send(server.socket.address.ip.getPort()) catch return;
            var stream = server.accept(.{}) catch return;
            defer stream.close();
            runtime_mod.sleep(.fromMilliseconds(60_000)) catch {}; // until canceled
        }
    };

    const Sender = struct {
        fn run(client_io: Io, server_port: *Channel(u16), out: *Outcome) void {
            defer out.completed = true;
            const port = server_port.receive() catch |e| {
                out.send_err = e;
                return;
            };
            var f = Io.Dir.cwd().openFile(client_io, path, .{}) catch |e| {
                out.send_err = e;
                return;
            };
            defer f.close(client_io);
            var fr_buf: [4096]u8 = undefined;
            var fr = f.reader(client_io, &fr_buf);

            const addr = IpAddress.parseIp4("127.0.0.1", port) catch |e| {
                out.send_err = e;
                return;
            };
            var stream = tcpConnectToAddress(addr, .{}) catch |e| {
                out.send_err = e;
                return;
            };
            defer stream.close();

            var wbuf: [4096]u8 = undefined;
            var writer = stream.writer(&wbuf);
            // Stalls once the socket buffers are full; cancellation makes it return.
            if (writer.interface.sendFileAll(&fr, .unlimited)) |_| {} else |err| {
                out.send_err = err;
                out.writer_err = writer.err;
            }
        }
    };

    // The test body runs as the runtime's main task, so we can spawn/sleep/cancel
    // directly. Spawn the server and sender independently so we can cancel *only*
    // the sender: the server's connection stays open, making the sender's own
    // cancellation the unambiguous reason the stalled send returns (if the server
    // were canceled too, its socket close could reset the send first and surface
    // a connection error instead of Canceled). sender.cancel() blocks until the
    // sender finishes, which only happens if cancellation unblocks the send (a
    // hang here means it did not).
    var server_port_buf: [1]u16 = undefined;
    var server_port_ch = Channel(u16).init(&server_port_buf);

    var outcome: Outcome = .{};
    var server = try runtime.spawn(ServerTask.run, .{&server_port_ch});
    defer server.cancel();
    var sender = try runtime.spawn(Sender.run, .{ io, &server_port_ch, &outcome });
    defer sender.cancel();
    // Let the sender connect and fill the socket buffers, then block in the send.
    try runtime_mod.sleep(.fromMilliseconds(100));
    sender.cancel();

    // The stalled send was interrupted, and the cancellation propagated out
    // through the std.Io.Writer sendFile path as WriteFailed + writer.err.
    try std.testing.expect(outcome.completed);
    try std.testing.expectEqual(error.WriteFailed, outcome.send_err.?);
    try std.testing.expectEqual(error.Canceled, outcome.writer_err.?);
}

test "IpAddress: initIp4" {
    const addr = IpAddress.initIp4(@splat(0), 8080);
    try std.testing.expectEqual(os.net.AF.INET, addr.any.family);
}

test "IpAddress: initIp6" {
    const addr = IpAddress.initIp6(@splat(0), 8080, 0, 0);
    try std.testing.expectEqual(os.net.AF.INET6, addr.any.family);
}

test "IpAddress: setPort/v4" {
    var addr = IpAddress.initIp4(@splat(0), 0);
    addr.setPort(8080);
    try std.testing.expectEqual(8080, addr.getPort());
}

test "IpAddress: setPort/v6" {
    var addr = IpAddress.initIp6(@splat(0), 0, 0, 0);
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

test "getSockAddrLen: unix pathname includes NUL terminator" {
    if (!has_unix_sockets) return error.SkipZigTest;

    const path_off = @offsetOf(os.net.sockaddr.un, "path");
    const path = "/tmp/zio-test.sock";

    const addr = try UnixAddress.init(path);
    // Pathname sockets are NUL-terminated, so the length covers the string plus
    // the terminating NUL.
    const expected: os.net.socklen_t = @intCast(path_off + path.len + 1);
    try std.testing.expectEqual(expected, getSockAddrLen(&addr.any));
}

test "getSockAddrLen: unix abstract has no trailing padding" {
    if (!has_unix_sockets) return error.SkipZigTest;
    // The abstract namespace is a Linux-specific extension.
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const path_off = @offsetOf(os.net.sockaddr.un, "path");
    // Abstract names start with a NUL byte and are matched verbatim. The length
    // must cover exactly the name (leading NUL + the bytes after it) with no
    // terminator and no trailing zero padding.
    const name = "\x00zio-test-abstract";

    const addr = try UnixAddress.init(name);
    const expected: os.net.socklen_t = @intCast(path_off + name.len);
    try std.testing.expectEqual(expected, getSockAddrLen(&addr.any));
}

test "UnixAddress: format" {
    if (!has_unix_sockets) return error.SkipZigTest;

    var buf: [64]u8 = undefined;

    // Pathname socket prints the path as-is.
    {
        const addr = try UnixAddress.init("/tmp/zio-test.sock");
        try std.testing.expectEqualStrings("/tmp/zio-test.sock", try std.fmt.bufPrint(&buf, "{f}", .{addr}));
    }

    // Abstract socket renders its leading NUL as '@' (Linux only).
    if (builtin.os.tag == .linux) {
        const addr = try UnixAddress.init("\x00zio-test-abstract");
        try std.testing.expectEqualStrings("@zio-test-abstract", try std.fmt.bufPrint(&buf, "{f}", .{addr}));
    }
}

pub fn checkListen(addr: anytype, options: anytype, write_buffer: []u8) !void {
    const Test = struct {
        pub fn serverFn(server: Server) !void {
            const client = try server.accept(.{});
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

    const server = try addr.listen(options);
    defer server.close();

    var group: Group = .init;
    defer group.cancel();

    try group.spawn(Test.serverFn, .{server});
    try group.spawn(Test.clientFn, .{ server, write_buffer });

    try group.wait();
}

pub fn checkBind(server_addr: anytype, client_addr: anytype) !void {
    const Test = struct {
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

    const socket = try server_addr.bind(.{});
    defer socket.close();

    var group: Group = .init;
    defer group.cancel();

    try group.spawn(Test.serverFn, .{socket});
    try group.spawn(Test.clientFn, .{ socket, client_addr });

    try group.wait();
}

pub fn checkShutdown(addr: anytype, options: anytype) !void {
    const Test = struct {
        pub fn serverFn(server: Server) !void {
            const client = try server.accept(.{});
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

    const server = try addr.listen(options);
    defer server.close();

    var group: Group = .init;
    defer group.cancel();

    try group.spawn(Test.serverFn, .{server});
    try group.spawn(Test.clientFn, .{server});

    try group.wait();
}

test "UnixAddress: listen/accept/connect/read/write" {
    if (!has_unix_sockets) return error.SkipZigTest;

    const path = "zio-test-socket.sock";
    defer os.fs.dirDeleteFile(std.testing.allocator, os.fs.cwd(), path) catch {};

    var write_buffer: [32]u8 = undefined;
    const addr = try UnixAddress.init(path);
    try checkListen(addr, UnixAddress.ListenOptions{}, &write_buffer);
}

test "UnixAddress: listen/accept/connect/read/write abstract" {
    if (!has_unix_sockets) return error.SkipZigTest;
    // The abstract namespace is a Linux-specific extension.
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    // No filesystem entry to clean up: abstract sockets vanish when the last
    // reference is closed. The leading NUL selects the abstract namespace.
    var write_buffer: [32]u8 = undefined;
    const addr = try UnixAddress.init("\x00zio-test-abstract-stream");
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
        if (err == error.AddressUnavailable) return error.SkipZigTest;
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
        if (err == error.AddressUnavailable) return error.SkipZigTest;
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
        if (err == error.AddressUnavailable) return error.SkipZigTest;
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
        if (err == error.AddressUnavailable) return error.SkipZigTest;
        return err;
    };
}

test "Server: accept timeout" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    const addr = try IpAddress.parseIp4("127.0.0.1", 0);
    const server = try addr.listen(.{});
    defer server.close();

    const result = server.accept(.{ .timeout = Timeout.fromMilliseconds(10) });
    try std.testing.expectError(error.Timeout, result);
}

test "Stream.Reader/Writer.fromStd" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();
    const io = runtime.io();

    var server = try std.Io.net.IpAddress.listen(&.{ .ip4 = .loopback(0) }, io, .{});
    defer server.deinit(io);

    const stream = try std.Io.net.IpAddress.connect(&server.socket.address, io, .{ .mode = .stream });
    defer stream.close(io);

    var read_buf: [64]u8 = undefined;
    var write_buf: [64]u8 = undefined;
    const reader = Stream.Reader.fromStd(stream, io, &read_buf);
    const writer = Stream.Writer.fromStd(stream, io, &write_buf);

    try std.testing.expectEqual(stdIoHandleToZio(stream.socket.handle), reader.handle);
    try std.testing.expectEqual(stdIoHandleToZio(stream.socket.handle), writer.handle);
}

// Multi-executor socket stress: exercises exactly the cross-loop situations the
// single-owner registration model is built for, with byte-level verification on
// a runtime with several executors (task migration on):
//
//   * concurrent full-duplex - each connection's reader and writer run as
//     separate tasks that may land on different executors, so recv and send for
//     the same fd are driven from different loops at once;
//   * migration mid-connection - each echo handler spawns+joins a tiny task
//     every round, bouncing across executors, so one socket's reads/writes move
//     between loops over the connection's life;
//   * fd reuse across loops - many short connections in waves, so closed fd
//     numbers get reused by new sockets, possibly on different loops.
//
// A lost wakeup (the failure mode of a per-loop readiness backend on a fd whose
// loop changed) would stall the op until its finite timeout, which is counted as
// an error; std.testing.allocator also fails on any leak, exercising the shared
// table teardown.
test "multi-executor: cross-loop socket stress (full-duplex + migration + fd reuse)" {
    if (builtin.single_threaded) return error.SkipZigTest;

    const H = struct {
        const executors = 3;
        const waves = 5;
        const per_wave = 12;
        const total = 8 * 1024;
        const chunk = 2048;
        const io_timeout = Timeout.fromMilliseconds(5_000);

        const Shared = struct {
            conns: std.atomic.Value(u32) = .init(0),
            verified: std.atomic.Value(u32) = .init(0),
            errors: std.atomic.Value(u32) = .init(0),
            done: std.atomic.Value(bool) = .init(false),
        };

        fn pat(id: usize, i: usize) u8 {
            return @truncate(id *% 31 +% i);
        }

        fn nudge() void {}

        fn handler(stream: Stream, sh: *Shared) void {
            defer stream.close();
            var buf: [chunk]u8 = undefined;
            while (true) {
                const n = stream.read(&buf, io_timeout) catch {
                    _ = sh.errors.fetchAdd(1, .monotonic);
                    return;
                };
                if (n == 0) return; // peer closed its send side
                stream.writeAll(buf[0..n], io_timeout) catch {
                    _ = sh.errors.fetchAdd(1, .monotonic);
                    return;
                };
                // Spawning round-robins to another executor; joining wakes us
                // from there, migrating this handler (and the socket's next op)
                // to a different loop.
                var h = runtime_mod.spawn(nudge, .{}) catch return;
                h.join();
            }
        }

        fn server(port_ch: *Channel(u16), sh: *Shared) void {
            const addr = IpAddress.parseIp4("127.0.0.1", 0) catch {
                _ = sh.errors.fetchAdd(1, .monotonic);
                port_ch.send(0) catch {};
                return;
            };
            const srv = addr.listen(.{ .reuse_address = true }) catch {
                _ = sh.errors.fetchAdd(1, .monotonic);
                port_ch.send(0) catch {};
                return;
            };
            defer srv.close();
            port_ch.send(srv.socket.address.ip.getPort()) catch return;

            var handlers: Group = .init;
            defer handlers.wait() catch {};
            while (!sh.done.load(.acquire)) {
                const stream = srv.accept(.{ .timeout = Timeout.fromMilliseconds(50) }) catch |err| {
                    if (err == error.Timeout) continue; // re-check the done flag
                    break;
                };
                handlers.spawn(handler, .{ stream, sh }) catch {
                    stream.close();
                };
            }
        }

        fn writer(stream: Stream, id: usize, sh: *Shared) void {
            var buf: [chunk]u8 = undefined;
            var sent: usize = 0;
            while (sent < total) {
                const this = @min(chunk, total - sent);
                for (0..this) |i| buf[i] = pat(id, sent + i);
                stream.writeAll(buf[0..this], io_timeout) catch {
                    _ = sh.errors.fetchAdd(1, .monotonic);
                    return;
                };
                sent += this;
            }
        }

        fn reader(stream: Stream, id: usize, sh: *Shared) void {
            var buf: [chunk]u8 = undefined;
            var got: usize = 0;
            while (got < total) {
                const want = @min(chunk, total - got);
                var off: usize = 0;
                while (off < want) {
                    const n = stream.read(buf[off..want], io_timeout) catch {
                        _ = sh.errors.fetchAdd(1, .monotonic);
                        return;
                    };
                    if (n == 0) {
                        _ = sh.errors.fetchAdd(1, .monotonic); // premature EOF
                        return;
                    }
                    for (0..n) |k| {
                        if (buf[off + k] != pat(id, got + off + k)) {
                            _ = sh.errors.fetchAdd(1, .monotonic);
                            return;
                        }
                    }
                    off += n;
                }
                got += want;
            }
            _ = sh.verified.fetchAdd(1, .monotonic);
        }

        fn client(port: u16, id: usize, sh: *Shared) void {
            const addr = IpAddress.parseIp4("127.0.0.1", port) catch {
                _ = sh.errors.fetchAdd(1, .monotonic);
                return;
            };
            const stream = addr.connect(.{ .timeout = io_timeout }) catch {
                _ = sh.errors.fetchAdd(1, .monotonic);
                return;
            };
            defer stream.close();

            // Reader and writer on the same fd, on (likely) different executors.
            var dup: Group = .init;
            dup.spawn(writer, .{ stream, id, sh }) catch {
                _ = sh.errors.fetchAdd(1, .monotonic);
                return;
            };
            dup.spawn(reader, .{ stream, id, sh }) catch {
                _ = sh.errors.fetchAdd(1, .monotonic);
                dup.wait() catch {};
                return;
            };
            dup.wait() catch {};
            _ = sh.conns.fetchAdd(1, .monotonic);
        }
    };

    const runtime = try Runtime.init(std.testing.allocator, .{ .executors = .exact(H.executors) });
    defer runtime.deinit();

    var sh: H.Shared = .{};
    var port_buf: [1]u16 = undefined;
    var port_ch = Channel(u16).init(&port_buf);

    var server_group: Group = .init;
    try server_group.spawn(H.server, .{ &port_ch, &sh });
    // Signal the acceptor to stop *before* draining it, so an early return from
    // any `try` below can't leave it looping forever.
    defer {
        sh.done.store(true, .release);
        server_group.wait() catch {};
    }

    const port = try port_ch.receive();
    try std.testing.expect(port != 0);

    var id: usize = 0;
    for (0..H.waves) |_| {
        var clients: Group = .init;
        for (0..H.per_wave) |_| {
            try clients.spawn(H.client, .{ port, id, &sh });
            id += 1;
        }
        try clients.wait();
    }

    try std.testing.expectEqual(@as(u32, 0), sh.errors.load(.monotonic));
    try std.testing.expectEqual(@as(u32, H.waves * H.per_wave), sh.conns.load(.monotonic));
    try std.testing.expectEqual(@as(u32, H.waves * H.per_wave), sh.verified.load(.monotonic));
}
