// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

const std = @import("std");
const net = @import("../../net.zig");
const Duration = @import("../../time.zig").Duration;
const log = @import("../../common.zig").log;

/// /etc/resolv.conf parser.
///
/// Parses the standard resolver configuration file. All allocations
/// are made from an internal arena, cleaned up by `deinit()`.
pub const ResolvConf = struct {
    arena: std.heap.ArenaAllocator,
    servers: []net.IpAddress,
    search: [][]const u8,
    ndots: u8 = 1,
    timeout: Duration = .fromSeconds(5),
    attempts: u8 = 2,
    rotate: bool = false,

    pub fn deinit(self: *ResolvConf) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// Parse resolv.conf from a reader. All returned memory is owned by
    /// the struct and freed by `deinit()`.
    pub fn parse(parent_allocator: std.mem.Allocator, reader: *std.Io.Reader) !ResolvConf {
        var conf: ResolvConf = .{
            .arena = std.heap.ArenaAllocator.init(parent_allocator),
            .servers = &.{},
            .search = &.{},
        };
        errdefer conf.deinit();

        const allocator = conf.arena.allocator();

        var servers: std.ArrayList(net.IpAddress) = .empty;
        try servers.ensureTotalCapacity(allocator, 4);
        var search: std.ArrayList([]const u8) = .empty;
        try search.ensureTotalCapacity(allocator, 8);
        while (try reader.takeDelimiter('\n')) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == '#' or trimmed[0] == ';') continue;

            var fields = std.mem.splitAny(u8, trimmed, " \t");
            const keyword = fields.next() orelse continue;

            if (std.mem.eql(u8, keyword, "nameserver")) {
                const addr_str = fields.next() orelse continue;
                const addr = net.IpAddress.parseIp(addr_str, 53) catch |err| {
                    log.warn("resolv.conf: invalid nameserver '{s}': {}", .{ addr_str, err });
                    continue;
                };
                servers.append(allocator, addr) catch |err| {
                    log.warn("resolv.conf: failed to add nameserver: {}", .{err});
                    continue;
                };
            } else if (std.mem.eql(u8, keyword, "domain")) {
                const domain = fields.next() orelse continue;
                search.clearRetainingCapacity();
                const rooted = try ensureRooted(allocator, domain);
                search.append(allocator, rooted) catch |err| {
                    log.warn("resolv.conf: failed to add domain: {}", .{err});
                    continue;
                };
            } else if (std.mem.eql(u8, keyword, "search")) {
                search.clearRetainingCapacity();
                while (fields.next()) |domain| {
                    if (std.mem.eql(u8, domain, ".")) continue;
                    const rooted = try ensureRooted(allocator, domain);
                    search.append(allocator, rooted) catch |err| {
                        log.warn("resolv.conf: failed to add search domain: {}", .{err});
                        break;
                    };
                }
            } else if (std.mem.eql(u8, keyword, "options")) {
                while (fields.next()) |opt| {
                    if (std.mem.startsWith(u8, opt, "ndots:")) {
                        if (std.fmt.parseInt(u8, opt["ndots:".len..], 10)) |n| {
                            conf.ndots = @min(n, @as(u8, 15));
                        } else |_| {}
                    } else if (std.mem.startsWith(u8, opt, "timeout:")) {
                        const secs = std.fmt.parseInt(u16, opt["timeout:".len..], 10) catch |err| {
                            log.warn("resolv.conf: invalid timeout: {}", .{err});
                            continue;
                        };
                        conf.timeout = .fromSeconds(secs);
                    } else if (std.mem.startsWith(u8, opt, "attempts:")) {
                        if (std.fmt.parseInt(u8, opt["attempts:".len..], 10)) |n| {
                            conf.attempts = @max(n, 1);
                        } else |_| {}
                    } else if (std.mem.eql(u8, opt, "rotate")) {
                        conf.rotate = true;
                    }
                }
            }
        }

        if (servers.items.len == 0) {
            try servers.appendSlice(allocator, &.{
                try net.IpAddress.parseIp("127.0.0.1", 53),
                try net.IpAddress.parseIp("::1", 53),
            });
        }

        conf.servers = servers.items;
        conf.search = search.items;

        return conf;
    }
};

fn ensureRooted(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    if (s.len > 0 and s[s.len - 1] == '.') {
        const out = try allocator.alloc(u8, s.len);
        @memcpy(out[0..s.len], s);
        return out;
    }
    const out = try allocator.alloc(u8, s.len + 1);
    @memcpy(out[0..s.len], s);
    out[s.len] = '.';
    return out;
}

test "basic parse" {
    const input =
        \\# comment
        \\nameserver 8.8.8.8
        \\nameserver 1.1.1.1
        \\search example.com
        \\options ndots:2 timeout:3 rotate
    ;
    var reader = std.Io.Reader.fixed(input);
    var conf = try ResolvConf.parse(std.testing.allocator, &reader);
    defer conf.deinit();

    try std.testing.expectEqual(2, conf.servers.len);
    try std.testing.expectEqual(53, conf.servers[0].getPort());
    try std.testing.expectEqualStrings("example.com.", conf.search[0]);
    try std.testing.expectEqual(2, conf.ndots);
    try std.testing.expectEqual(3, conf.timeout.toSeconds());
    try std.testing.expect(conf.rotate);
}
