// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");
const net = @import("../net.zig");
const HostName = net.HostName;
const IpAddress = net.IpAddress;
const Server = net.Server;
const Runtime = @import("../runtime.zig").Runtime;

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
    try HostName.validate("127.0.0.1");
    try HostName.validate("::1");
    try HostName.validate("2001:db8::1");
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
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const host = try HostName.init("localhost");
    var storage: [32]HostName.LookupResult = undefined;
    const count = try host.lookup(&storage, .{ .port = 80 });

    try std.testing.expect(count > 0);
    for (storage[0..count]) |entry| {
        switch (entry) {
            .address => |addr| {
                try std.testing.expectEqual(80, addr.getPort());
            },
            .canonical_name => unreachable,
        }
    }
}

test "HostName: lookup with family filter" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const host = try HostName.init("localhost");
    var storage: [32]HostName.LookupResult = undefined;
    const count = try host.lookup(&storage, .{ .port = 80, .family = .ipv4 });

    for (storage[0..count]) |entry| {
        switch (entry) {
            .address => |addr| {
                try std.testing.expectEqual(IpAddress.Family.ipv4, addr.getFamily());
            },
            .canonical_name => unreachable,
        }
    }
}

test "HostName: lookup with canonical name" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const host = try HostName.init("localhost");
    var storage: [32]HostName.LookupResult = undefined;
    var cname_buf: [HostName.max_len]u8 = undefined;
    const count = try host.lookup(&storage, .{ .port = 80, .canonical_name_buffer = &cname_buf });

    var has_canonical_name = false;
    var has_address = false;
    for (storage[0..count]) |entry| {
        switch (entry) {
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

test "HostName: lookup www.github.com follows CNAME" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const host = try HostName.init("www.github.com");
    var storage: [32]HostName.LookupResult = undefined;
    var cname_buf: [HostName.max_len]u8 = undefined;
    const count = try host.lookup(&storage, .{ .port = 80, .canonical_name_buffer = &cname_buf });

    var canonical_name: ?HostName = null;
    var has_address = false;
    for (storage[0..count]) |entry| {
        switch (entry) {
            .address => has_address = true,
            .canonical_name => |name| canonical_name = name,
        }
    }
    try std.testing.expect(has_address);
    const cname = canonical_name orelse return error.NoCanonicalName;
    try std.testing.expectEqualStrings("github.com", cname.bytes);
}

test "HostName: connect" {
    if (builtin.os.tag == .macos) return error.SkipZigTest;
    if (builtin.os.tag == .netbsd) return error.SkipZigTest;

    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const ServerTask = struct {
        fn run(server: Server) !void {
            const conn = try server.accept(.{});
            defer conn.close();
            var buf: [32]u8 = undefined;
            _ = try conn.read(&buf, .none);
        }
    };

    const server_addr = try IpAddress.parseIp4("127.0.0.1", 0);
    const server = try server_addr.listen(.{});
    defer server.close();

    const port = server.socket.address.ip.getPort();

    var server_task = try rt.spawn(ServerTask.run, .{server});
    defer server_task.cancel();

    const host = try HostName.init("localhost");
    var stream = try host.connect(port, .{});
    defer stream.close();

    try stream.writeAll("hello", .none);

    try server_task.join();
}

test "HostName: lookup with no storage" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const host = try HostName.init("localhost");
    var storage: [0]HostName.LookupResult = undefined;
    try std.testing.expectError(error.TooManyAddresses, host.lookup(&storage, .{ .port = 80 }));
}

test "HostName: lookup localhost" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const host = try HostName.init("localhost");
    var storage: [32]HostName.LookupResult = undefined;
    const count = try host.lookup(&storage, .{ .port = 80 });

    try std.testing.expect(count > 0);
}

test "HostName: lookup numeric IPv4" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const host = try HostName.init("127.0.0.1");
    var storage: [32]HostName.LookupResult = undefined;
    const count = try host.lookup(&storage, .{ .port = 8080 });

    try std.testing.expectEqual(1, count);
    try std.testing.expect(storage[0] == .address);
    try std.testing.expectEqual(IpAddress.Family.ipv4, storage[0].address.getFamily());
    try std.testing.expectEqual(8080, storage[0].address.getPort());
}

test "HostName: lookup numeric IPv6" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const host = try HostName.init("::1");
    var storage: [32]HostName.LookupResult = undefined;
    const count = try host.lookup(&storage, .{ .port = 8080 });

    try std.testing.expectEqual(1, count);
    try std.testing.expect(storage[0] == .address);
    try std.testing.expectEqual(IpAddress.Family.ipv6, storage[0].address.getFamily());
    try std.testing.expectEqual(8080, storage[0].address.getPort());
}

test "HostName: lookup numeric IPv4 with no storage" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const host = try HostName.init("127.0.0.1");
    var storage: [0]HostName.LookupResult = undefined;
    try std.testing.expectError(error.TooManyAddresses, host.lookup(&storage, .{ .port = 8080 }));
}

test "HostName: lookup numeric IPv6 with no storage" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const host = try HostName.init("::1");
    var storage: [0]HostName.LookupResult = undefined;
    try std.testing.expectError(error.TooManyAddresses, host.lookup(&storage, .{ .port = 8080 }));
}

test "HostName: lookup numeric IPv4 wrong family" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const host = try HostName.init("127.0.0.1");
    var storage: [32]HostName.LookupResult = undefined;
    try std.testing.expectError(error.AddressFamilyUnsupported, host.lookup(&storage, .{ .port = 8080, .family = .ipv6 }));
}

test "HostName: lookup numeric IPv6 wrong family" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const host = try HostName.init("::1");
    var storage: [32]HostName.LookupResult = undefined;
    try std.testing.expectError(error.AddressFamilyUnsupported, host.lookup(&storage, .{ .port = 8080, .family = .ipv4 }));
}

test "HostName: lookup google.com" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const host = try HostName.init("google.com");
    var storage: [32]HostName.LookupResult = undefined;
    const count = try host.lookup(&storage, .{ .port = 443 });

    try std.testing.expect(count > 0);
    for (storage[0..count]) |entry| {
        switch (entry) {
            .address => |addr| {
                try std.testing.expectEqual(443, addr.getPort());
            },
            .canonical_name => unreachable,
        }
    }
}
