// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

//! Parser for /etc/hosts file.

const std = @import("std");
const net = @import("../../net.zig");

/// Maximum number of addresses from hosts file per lookup.
const max_hosts_addresses = 8;

/// Hosts file lookup result.
pub const HostsResult = struct {
    addresses: [max_hosts_addresses]net.IpAddress = undefined,
    len: usize = 0,

    pub fn appendAssumeCapacity(self: *HostsResult, addr: net.IpAddress) void {
        if (self.len < max_hosts_addresses) {
            self.addresses[self.len] = addr;
            self.len += 1;
        }
    }

    pub fn slice(self: *const HostsResult) []const net.IpAddress {
        return self.addresses[0..self.len];
    }
};

/// Look up a hostname in /etc/hosts.
/// Returns null if the hostname is not found.
pub fn lookup(hostname: []const u8, family: ?net.IpAddress.Family) ?HostsResult {
    const content = std.fs.cwd().readFileAlloc(
        std.heap.page_allocator,
        "/etc/hosts",
        256 * 1024,
    ) catch return null;
    defer std.heap.page_allocator.free(content);

    return lookupInContent(content, hostname, family);
}

/// Look up a hostname in hosts file content (for testing).
pub fn lookupInContent(content: []const u8, hostname: []const u8, family: ?net.IpAddress.Family) ?HostsResult {
    var result: HostsResult = .{};

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        // Skip comments and empty lines
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        // Parse: IP_ADDRESS HOSTNAME [ALIASES...]
        var tokens = std.mem.tokenizeAny(u8, trimmed, " \t");
        const addr_str = tokens.next() orelse continue;

        // Parse IP address (with dummy port 0)
        const addr = net.IpAddress.parseIp(addr_str, 0) catch continue;

        // Check family filter
        if (family) |f| {
            if (addr.getFamily() != f) continue;
        }

        // Check each hostname/alias
        while (tokens.next()) |name| {
            // Stop at comments
            if (name[0] == '#') break;

            if (std.ascii.eqlIgnoreCase(name, hostname)) {
                result.appendAssumeCapacity(addr);
                break;
            }
        }
    }

    return if (result.len > 0) result else null;
}

test "hosts.lookupInContent basic" {
    const content =
        \\# Comment
        \\127.0.0.1 localhost localhost.localdomain
        \\::1 localhost ip6-localhost
        \\192.168.1.1 myhost
    ;

    // Lookup localhost - should get both IPv4 and IPv6
    const result1 = lookupInContent(content, "localhost", null).?;
    try std.testing.expectEqual(@as(usize, 2), result1.len);

    // Lookup localhost - IPv4 only
    const result2 = lookupInContent(content, "localhost", .ipv4).?;
    try std.testing.expectEqual(@as(usize, 1), result2.len);

    // Lookup localhost - IPv6 only
    const result3 = lookupInContent(content, "localhost", .ipv6).?;
    try std.testing.expectEqual(@as(usize, 1), result3.len);

    // Lookup alias
    const result4 = lookupInContent(content, "localhost.localdomain", null).?;
    try std.testing.expectEqual(@as(usize, 1), result4.len);

    // Lookup unknown host
    const result5 = lookupInContent(content, "unknown", null);
    try std.testing.expect(result5 == null);
}

test "hosts.lookupInContent case insensitive" {
    const content = "127.0.0.1 LocalHost\n";

    const result = lookupInContent(content, "LOCALHOST", null).?;
    try std.testing.expectEqual(@as(usize, 1), result.len);
}
