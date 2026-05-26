// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

const std = @import("std");
const net = @import("../../net.zig");
const log = @import("../../common.zig").log;

/// /etc/hosts parser.
///
/// Parses the standard hosts file. All allocations are made from
/// an internal arena, cleaned up by `deinit()`.
pub const Hosts = struct {
    arena: std.heap.ArenaAllocator,
    by_name: std.StringHashMapUnmanaged([]net.IpAddress),

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

        while (try reader.takeDelimiter('\n')) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            var fields = std.mem.splitAny(u8, trimmed, " \t");
            const addr_str = fields.next() orelse continue;
            const addr = net.IpAddress.parseIp(addr_str, 0) catch |err| {
                log.warn("hosts: invalid address '{s}': {}", .{ addr_str, err });
                continue;
            };

            while (fields.next()) |name| {
                if (name.len == 0) continue;
                if (name[0] == '#') break;

                var lower_buf: [254]u8 = undefined;
                if (name.len > lower_buf.len) continue;
                const lower = std.ascii.lowerString(&lower_buf, name);
                const gop = try hosts.by_name.getOrPut(allocator, lower);
                if (!gop.found_existing) {
                    gop.key_ptr.* = try allocator.dupe(u8, lower);
                    gop.value_ptr.* = &.{};
                }

                const addrs = try allocator.alloc(net.IpAddress, gop.value_ptr.len + 1);
                @memcpy(addrs[0..gop.value_ptr.len], gop.value_ptr.*);
                addrs[gop.value_ptr.len] = addr;
                gop.value_ptr.* = addrs;
            }
        }

        return hosts;
    }

    /// Look up addresses for a hostname. Returns null if not found.
    pub fn lookupByName(self: *const Hosts, name: []const u8) ?[]net.IpAddress {
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

    const localhost_addrs = hosts.lookupByName("localhost").?;
    try std.testing.expectEqual(2, localhost_addrs.len);

    const google_addrs = hosts.lookupByName("dns.google").?;
    try std.testing.expectEqual(1, google_addrs.len);

    try std.testing.expect(hosts.lookupByName("nonexistent") == null);
}
