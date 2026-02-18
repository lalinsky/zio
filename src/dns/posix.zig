// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

const std = @import("std");
const os_net = @import("../os/net.zig");
const common = @import("../common.zig");
const blockInPlace = common.blockInPlace;
const dns = @import("root.zig");

pub const Result = struct {
    head: ?*os_net.addrinfo,
    current: ?*os_net.addrinfo,
    return_canonical_name: bool,

    pub fn deinit(self: *Result) void {
        if (self.head) |head| {
            os_net.freeaddrinfo(head);
        }
    }

    pub fn next(self: *Result) ?dns.LookupResult {
        if (self.return_canonical_name) {
            self.return_canonical_name = false;
            if (self.head) |head| {
                if (head.canonname) |name| {
                    return .{ .canonical_name = .{ .bytes = std.mem.sliceTo(name, 0) } };
                }
            }
        }

        while (self.current) |info| {
            self.current = @ptrCast(info.next);
            const addr = info.addr orelse continue;
            if (addr.family != os_net.AF.INET and addr.family != os_net.AF.INET6) continue;
            return .{ .address = dns.IpAddress.initPosix(@ptrCast(addr), @intCast(info.addrlen)) };
        }
        return null;
    }
};

/// Resolves a hostname to addresses. Dispatches to the thread pool and
/// suspends the current task until the blocking getaddrinfo call completes.
pub fn lookup(options: dns.LookupOptions) dns.LookupError!Result {
    const head = try blockInPlace(lookupBlocking, .{options});
    return .{
        .head = head,
        .current = head,
        .return_canonical_name = options.canonical_name,
    };
}

fn lookupBlocking(options: dns.LookupOptions) dns.LookupError!?*os_net.addrinfo {
    var buf: [512]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const allocator = fba.allocator();

    const name_c = try allocator.dupeZ(u8, options.name);
    const port_c = try std.fmt.allocPrintSentinel(allocator, "{d}", .{options.port}, 0);

    var hints: os_net.addrinfo = std.mem.zeroes(os_net.addrinfo);
    hints.family = if (options.family) |f| switch (f) {
        .ipv4 => os_net.AF.INET,
        .ipv6 => os_net.AF.INET6,
    } else os_net.AF.UNSPEC;
    hints.socktype = std.posix.SOCK.STREAM;
    hints.protocol = std.posix.IPPROTO.TCP;
    if (options.canonical_name) {
        hints.flags.CANONNAME = true;
    }

    var res: ?*os_net.addrinfo = null;

    os_net.getaddrinfo(name_c.ptr, port_c.ptr, &hints, &res) catch |err| {
        return switch (err) {
            error.ServiceNotAvailable => error.ServiceUnavailable,
            error.InvalidFlags => unreachable,
            error.SocketTypeNotSupported => unreachable,
            else => |e| e,
        };
    };

    return res;
}
