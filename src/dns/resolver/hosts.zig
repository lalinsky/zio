// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

const std = @import("std");
const net = @import("../../net.zig");
const log = @import("../../common.zig").log;
const takeLine = @import("../../utils/reader.zig").takeLine;

/// /etc/hosts parser.
///
/// Parses the standard hosts file. All allocations are made from
/// an internal arena, cleaned up by `deinit()`.
pub const Hosts = struct {
    arena: std.heap.ArenaAllocator,
    by_name: std.StringHashMapUnmanaged(Entry),

    pub const Entry = struct {
        addrs: []net.IpAddress,
        /// The first name on the first line that lists this name, null if
        /// that is not a valid host name.
        canonical_name: ?[]const u8,
    };

    pub fn deinit(self: *Hosts) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// Parse /etc/hosts from a reader.
    pub fn parse(parent_allocator: std.mem.Allocator, reader: *std.Io.Reader) !Hosts {
        var hosts: Hosts = .{
            .arena = std.heap.ArenaAllocator.init(parent_allocator),
            .by_name = .empty,
        };
        errdefer hosts.deinit();

        const allocator = hosts.arena.allocator();
        try hosts.by_name.ensureTotalCapacity(allocator, 32);

        while (try takeLine(reader)) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            var fields = std.mem.splitAny(u8, trimmed, " \t");
            const addr_str = fields.next() orelse continue;
            const addr = net.IpAddress.parseIp(addr_str, 0) catch |err| {
                log.warn("hosts: invalid address '{s}': {}", .{ addr_str, err });
                continue;
            };

            var first_name = true;
            var canonical_name: ?[]const u8 = null;
            while (fields.next()) |name| {
                if (name.len == 0) continue;
                if (name[0] == '#') break;
                if (first_name) {
                    first_name = false;
                    if (net.HostName.validate(name)) |_| {
                        canonical_name = try allocator.dupe(u8, name);
                    } else |_| {}
                }

                var lower_buf: [254]u8 = undefined;
                if (name.len > lower_buf.len) continue;
                const lower = std.ascii.lowerString(&lower_buf, name);
                const gop = try hosts.by_name.getOrPut(allocator, lower);
                if (!gop.found_existing) {
                    gop.key_ptr.* = try allocator.dupe(u8, lower);
                    gop.value_ptr.* = .{ .addrs = &.{}, .canonical_name = canonical_name };
                }

                const old_addrs = gop.value_ptr.addrs;
                const addrs = try allocator.alloc(net.IpAddress, old_addrs.len + 1);
                @memcpy(addrs[0..old_addrs.len], old_addrs);
                addrs[old_addrs.len] = addr;
                gop.value_ptr.addrs = addrs;
            }
        }

        return hosts;
    }

    /// Look up addresses for a hostname. Returns null if not found.
    pub fn lookupByName(self: *const Hosts, name: []const u8) ?Entry {
        var buf: [254]u8 = undefined;
        if (name.len > buf.len) return null;
        const lower = std.ascii.lowerString(&buf, name);
        return self.by_name.get(lower);
    }
};

test "basic parse" {
    const input =
        \\127.0.0.1 localhost
        \\::1       localhost ip6-localhost
        \\8.8.8.8   dns.google
    ;
    var reader = std.Io.Reader.fixed(input);
    var hosts = try Hosts.parse(std.testing.allocator, &reader);
    defer hosts.deinit();

    const localhost = hosts.lookupByName("localhost").?;
    try std.testing.expectEqual(2, localhost.addrs.len);

    const google = hosts.lookupByName("dns.google").?;
    try std.testing.expectEqual(1, google.addrs.len);

    try std.testing.expect(hosts.lookupByName("nonexistent") == null);
}

test "a line longer than the read buffer is skipped" {
    const input = "10.0.0.1 a.test\n10.0.0.2 " ++ @as([100]u8, @splat('b')) ++ "\n10.0.0.3 c.test\n";
    var buffer: [32]u8 = undefined;
    var reader: std.testing.Reader = .init(&buffer, &.{.{ .buffer = input }});
    var hosts = try Hosts.parse(std.testing.allocator, &reader.interface);
    defer hosts.deinit();

    try std.testing.expect(hosts.lookupByName("a.test") != null);
    try std.testing.expect(hosts.lookupByName("c.test") != null);
}

test "the canonical name is the first name on the first line" {
    const input =
        \\10.0.0.1 Main.Test alias.test # comment.test
        \\10.0.0.2 other.test ALIAS.test main.test
    ;
    var reader = std.Io.Reader.fixed(input);
    var hosts = try Hosts.parse(std.testing.allocator, &reader);
    defer hosts.deinit();

    const alias = hosts.lookupByName("alias.test").?;
    try std.testing.expectEqual(2, alias.addrs.len);
    try std.testing.expectEqualStrings("Main.Test", alias.canonical_name.?);
    try std.testing.expectEqualStrings("Main.Test", hosts.lookupByName("main.test").?.canonical_name.?);
    try std.testing.expectEqualStrings("other.test", hosts.lookupByName("other.test").?.canonical_name.?);
    try std.testing.expect(hosts.lookupByName("comment.test") == null);
}

test "an invalid first name is no canonical name" {
    var reader = std.Io.Reader.fixed("10.0.0.1 my_host alias.test\n");
    var hosts = try Hosts.parse(std.testing.allocator, &reader);
    defer hosts.deinit();

    try std.testing.expect(hosts.lookupByName("alias.test").?.canonical_name == null);
    try std.testing.expect(hosts.lookupByName("my_host").?.canonical_name == null);
}
