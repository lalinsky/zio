// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

const std = @import("std");
const net = @import("../../net.zig");
const os = @import("../../os/root.zig");
const Duration = @import("../../time.zig").Duration;
const log = @import("../../common.zig").log;
const takeLine = @import("../../utils/reader.zig").takeLine;

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

    pub fn default(parent_allocator: std.mem.Allocator) !ResolvConf {
        var conf: ResolvConf = .{
            .arena = .init(parent_allocator),
            .servers = &.{},
            .search = &.{},
        };
        const allocator = conf.arena.allocator();
        conf.servers = try allocator.dupe(net.IpAddress, &.{
            try net.IpAddress.parseIp4("127.0.0.1", 53),
            try net.IpAddress.parseIp6("::1", 53),
        });
        return conf;
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
        while (try takeLine(reader)) |line| {
            const content = line[0 .. std.mem.findAny(u8, line, "#;") orelse line.len];
            var fields = std.mem.tokenizeAny(u8, content, " \t\r");
            const keyword = fields.next() orelse continue;

            if (std.mem.eql(u8, keyword, "nameserver")) {
                const addr_str = fields.next() orelse continue;
                const addr = parseNameserver(addr_str) catch |err| switch (err) {
                    error.Canceled => |e| return e,
                    else => {
                        log.warn("resolv.conf: invalid nameserver '{s}': {}", .{ addr_str, err });
                        continue;
                    },
                };
                servers.append(allocator, addr) catch |err| {
                    log.warn("resolv.conf: failed to add nameserver: {}", .{err});
                    continue;
                };
            } else if (std.mem.eql(u8, keyword, "domain")) {
                const domain = fields.next() orelse continue;
                search.clearRetainingCapacity();
                if (std.mem.eql(u8, domain, ".")) continue;
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

/// Parses a nameserver address. An IPv6 one may carry a zone index after a
/// `%`, as an interface name or number.
fn parseNameserver(s: []const u8) !net.IpAddress {
    const percent = std.mem.findScalar(u8, s, '%') orelse return net.IpAddress.parseIp(s, 53);
    var addr = try net.IpAddress.parseIp6(s[0..percent], 53);
    const zone = s[percent + 1 ..];
    addr.in6.scope_id = std.fmt.parseInt(u32, zone, 10) catch try interfaceIndex(zone);
    return addr;
}

fn interfaceIndex(name: []const u8) !u32 {
    var buf: [os.net.IF_NAMESIZE]u8 = undefined;
    if (name.len == 0 or name.len >= buf.len) return error.InterfaceNotFound;
    @memcpy(buf[0..name.len], name);
    buf[name.len] = 0;
    return os.net.interfaceNameToIndex(buf[0..name.len :0]);
}

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

fn expectAddress(expected: []const u8, actual: net.IpAddress) !void {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings(expected, try std.fmt.bufPrint(&buf, "{f}", .{actual}));
}

test "fields separated by runs of whitespace" {
    const input = "nameserver  1.1.1.1\nnameserver\t\t8.8.8.8 \r\nsearch a.com  \t b.com\noptions  ndots:3\t rotate\n";
    var reader = std.Io.Reader.fixed(input);
    var conf = try ResolvConf.parse(std.testing.allocator, &reader);
    defer conf.deinit();

    try std.testing.expectEqual(2, conf.servers.len);
    try expectAddress("1.1.1.1:53", conf.servers[0]);
    try expectAddress("8.8.8.8:53", conf.servers[1]);
    try std.testing.expectEqual(2, conf.search.len);
    try std.testing.expectEqualStrings("a.com.", conf.search[0]);
    try std.testing.expectEqualStrings("b.com.", conf.search[1]);
    try std.testing.expectEqual(3, conf.ndots);
    try std.testing.expect(conf.rotate);
}

test "comments after the content of a line" {
    const input =
        \\nameserver 1.1.1.1 # primary
        \\nameserver 8.8.8.8;secondary
        \\search a.com # b.com
        \\  ; nameserver 9.9.9.9
    ;
    var reader = std.Io.Reader.fixed(input);
    var conf = try ResolvConf.parse(std.testing.allocator, &reader);
    defer conf.deinit();

    try std.testing.expectEqual(2, conf.servers.len);
    try expectAddress("8.8.8.8:53", conf.servers[1]);
    try std.testing.expectEqual(1, conf.search.len);
    try std.testing.expectEqualStrings("a.com.", conf.search[0]);
}

test "an invalid nameserver is skipped" {
    const input =
        \\nameserver 1.1.1.1
        \\nameserver not-an-address
        \\nameserver 8.8.8.8
    ;
    var reader = std.Io.Reader.fixed(input);
    var conf = try ResolvConf.parse(std.testing.allocator, &reader);
    defer conf.deinit();

    try std.testing.expectEqual(2, conf.servers.len);
    try expectAddress("1.1.1.1:53", conf.servers[0]);
    try expectAddress("8.8.8.8:53", conf.servers[1]);
}

test "a nameserver with a zone index" {
    var lo_name: [os.net.IF_NAMESIZE]u8 = undefined;
    const lo_len = os.net.interfaceIndexToName(1, &lo_name) catch return error.SkipZigTest;

    var input_buf: [128]u8 = undefined;
    const input = try std.fmt.bufPrint(&input_buf, "nameserver fe80::1%7\nnameserver fe80::2%{s}\nnameserver fe80::3%nonexistent0\nnameserver 1.1.1.1%1\n", .{lo_name[0..lo_len]});
    var reader = std.Io.Reader.fixed(input);
    var conf = try ResolvConf.parse(std.testing.allocator, &reader);
    defer conf.deinit();

    try std.testing.expectEqual(2, conf.servers.len);
    try std.testing.expectEqual(7, conf.servers[0].in6.scope_id);
    try std.testing.expectEqual(1, conf.servers[1].in6.scope_id);
    try std.testing.expectEqual(53, conf.servers[1].getPort());
}

test "a line longer than the read buffer is skipped" {
    const input = "nameserver 1.1.1.1\nsearch " ++ @as([100]u8, @splat('a')) ++ "\nnameserver 8.8.8.8\n";
    var buffer: [32]u8 = undefined;
    var reader: std.testing.Reader = .init(&buffer, &.{.{ .buffer = input }});
    var conf = try ResolvConf.parse(std.testing.allocator, &reader.interface);
    defer conf.deinit();

    try std.testing.expectEqual(2, conf.servers.len);
    try expectAddress("1.1.1.1:53", conf.servers[0]);
    try expectAddress("8.8.8.8:53", conf.servers[1]);
    try std.testing.expectEqual(0, conf.search.len);
}

test "an overlong last line without a newline is skipped" {
    const input = "nameserver 1.1.1.1\nsearch " ++ @as([100]u8, @splat('a'));
    var buffer: [32]u8 = undefined;
    var reader: std.testing.Reader = .init(&buffer, &.{.{ .buffer = input }});
    var conf = try ResolvConf.parse(std.testing.allocator, &reader.interface);
    defer conf.deinit();

    try std.testing.expectEqual(1, conf.servers.len);
    try std.testing.expectEqual(0, conf.search.len);
}
