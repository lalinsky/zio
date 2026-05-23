// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

const std = @import("std");
const os_net = @import("../os/net.zig");
const common = @import("../common.zig");
const blockInPlace = common.blockInPlace;
const dns = @import("root.zig");

/// Fills `storage` with canonical name (if requested) and addresses from
/// a `getaddrinfo` linked list. Returns the number of entries written.
pub fn fillResultsFromAddrinfo(
    storage: []dns.LookupResult,
    options: dns.LookupOptions,
    head: ?*os_net.addrinfo,
) usize {
    var i: usize = 0;

    if (options.canonical_name_buffer) |cname_buf| {
        if (head) |h| {
            if (h.canonname) |name_ptr| {
                const name_slice = std.mem.sliceTo(name_ptr, 0);
                @memcpy(cname_buf[0..name_slice.len], name_slice);
                cname_buf[name_slice.len] = 0;
                storage[i] = .{ .canonical_name = .{ .bytes = cname_buf[0..name_slice.len] } };
                i += 1;
            }
        }
    }

    var current: ?*os_net.addrinfo = head;
    while (current) |info| : (current = @ptrCast(info.next)) {
        if (i >= storage.len) break;
        const addr = info.addr orelse continue;
        if (addr.family != os_net.AF.INET and addr.family != os_net.AF.INET6) continue;
        storage[i] = .{ .address = dns.IpAddress.initPosix(@ptrCast(addr), @intCast(info.addrlen)) };
        i += 1;
    }

    return i;
}

/// Resolves a hostname to addresses. Dispatches to the thread pool and
/// suspends the current task until the blocking getaddrinfo call completes.
/// Returns the number of entries written to `storage`.
pub fn lookup(
    storage: []dns.LookupResult,
    options: dns.LookupOptions,
) dns.LookupError!usize {
    const head = try blockInPlace(lookupBlocking, .{options});
    defer if (head) |h| os_net.freeaddrinfo(h);

    return fillResultsFromAddrinfo(storage, options, head);
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
    hints.socktype = os_net.SOCK.STREAM;
    hints.protocol = os_net.IPPROTO.TCP;
    if (options.canonical_name_buffer != null) {
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
