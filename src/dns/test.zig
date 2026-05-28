// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

const std = @import("std");
const Runtime = @import("../runtime.zig").Runtime;
const net = @import("../net.zig");
const dns = @import("root.zig");
const HostName = net.HostName;

fn expectTag(comptime tag: std.meta.Tag(HostName.LookupResult), entry: HostName.LookupResult) !void {
    try std.testing.expectEqual(tag, std.meta.activeTag(entry));
}

test "dns: IPv4 literal" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const host = try HostName.init("127.0.0.1");
    var storage: [8]HostName.LookupResult = undefined;
    const count = try host.lookup(&storage, .{ .port = 80 });

    try std.testing.expectEqual(1, count);
    try expectTag(.address, storage[0]);
    try std.testing.expectEqual(net.IpAddress.Family.ipv4, storage[0].address.getFamily());
    try std.testing.expectEqual(@as(u16, 80), storage[0].address.getPort());
}

test "dns: IPv4 literal with canonical name" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const host = try HostName.init("127.0.0.1");
    var storage: [8]HostName.LookupResult = undefined;
    var canon_buf: [HostName.max_len]u8 = undefined;
    const count = try host.lookup(&storage, .{ .port = 80, .canonical_name_buffer = &canon_buf });

    try std.testing.expectEqual(2, count);
    try expectTag(.canonical_name, storage[0]);
    try std.testing.expectEqualStrings("127.0.0.1", storage[0].canonical_name.bytes);
    try expectTag(.address, storage[1]);
    try std.testing.expectEqual(net.IpAddress.Family.ipv4, storage[1].address.getFamily());
}

test "dns: IPv6 literal" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var storage: [8]dns.LookupResult = undefined;
    const count = try dns.lookup(&storage, .{ .name = "::1", .port = 80 });

    try std.testing.expectEqual(1, count);
    try expectTag(.address, storage[0]);
    try std.testing.expectEqual(net.IpAddress.Family.ipv6, storage[0].address.getFamily());
    try std.testing.expectEqual(@as(u16, 80), storage[0].address.getPort());
}

test "dns: IPv6 literal with canonical name" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var storage: [8]dns.LookupResult = undefined;
    var canon_buf: [HostName.max_len]u8 = undefined;
    const count = try dns.lookup(&storage, .{ .name = "::1", .port = 80, .canonical_name_buffer = &canon_buf });

    try std.testing.expectEqual(2, count);
    try expectTag(.canonical_name, storage[0]);
    try std.testing.expectEqualStrings("::1", storage[0].canonical_name.bytes);
    try expectTag(.address, storage[1]);
    try std.testing.expectEqual(net.IpAddress.Family.ipv6, storage[1].address.getFamily());
}

test "dns: IPv4 literal with IPv6 family filter" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var storage: [8]dns.LookupResult = undefined;
    const result = dns.lookup(&storage, .{ .name = "127.0.0.1", .port = 80, .family = .ipv6 });
    // Custom resolver returns 0; getaddrinfo returns AddressFamilyUnsupported.
    if (result) |count| {
        try std.testing.expectEqual(0, count);
    } else |err| {
        try std.testing.expectEqual(error.AddressFamilyUnsupported, err);
    }
}

test "dns: IPv6 literal with IPv4 family filter" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var storage: [8]dns.LookupResult = undefined;
    const result = dns.lookup(&storage, .{ .name = "::1", .port = 80, .family = .ipv4 });
    if (result) |count| {
        try std.testing.expectEqual(0, count);
    } else |err| {
        try std.testing.expectEqual(error.AddressFamilyUnsupported, err);
    }
}

test "dns: localhost" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const host = try HostName.init("localhost");
    var storage: [8]HostName.LookupResult = undefined;
    const count = try host.lookup(&storage, .{ .port = 80 });

    try std.testing.expect(count > 0);
    for (storage[0..count]) |entry| {
        try expectTag(.address, entry);
    }
}

test "dns: localhost with canonical name" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const host = try HostName.init("localhost");
    var storage: [8]HostName.LookupResult = undefined;
    var canon_buf: [HostName.max_len]u8 = undefined;
    const count = try host.lookup(&storage, .{ .port = 80, .canonical_name_buffer = &canon_buf });

    try std.testing.expect(count > 1);
    try expectTag(.canonical_name, storage[0]);
    try std.testing.expect(storage[0].canonical_name.bytes.len > 0);
    for (storage[1..count]) |entry| {
        try expectTag(.address, entry);
    }
}

test "dns: IPv4 literal with no storage" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var storage: [0]dns.LookupResult = undefined;
    try std.testing.expectError(
        error.TooManyAddresses,
        dns.lookup(&storage, .{ .name = "127.0.0.1", .port = 80 }),
    );
}

test "dns: IPv4 literal with canonical name and only one storage slot" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    // slot 0 is reserved for canonical_name, leaving no room for the address
    var storage: [1]dns.LookupResult = undefined;
    var canon_buf: [HostName.max_len]u8 = undefined;
    try std.testing.expectError(
        error.TooManyAddresses,
        dns.lookup(&storage, .{ .name = "127.0.0.1", .port = 80, .canonical_name_buffer = &canon_buf }),
    );
}
