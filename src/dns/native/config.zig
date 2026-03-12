// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

//! Parser for /etc/resolv.conf and DNS resolver configuration.

const std = @import("std");
const net = @import("../../net.zig");

/// Maximum number of nameservers (per resolv.conf man page).
pub const max_servers = 3;

/// Maximum number of search domains.
pub const max_search = 6;

/// Maximum length of a search domain.
pub const max_search_len = 256;

/// DNS resolver configuration.
pub const Config = struct {
    /// Nameserver addresses (host:port format).
    servers: Servers = .{},

    /// Search domains (rooted, with trailing dot).
    search: SearchDomains = .{},

    /// Number of dots in name to trigger absolute lookup first.
    ndots: u4 = 1,

    /// Timeout for each query attempt (seconds).
    timeout: u8 = 5,

    /// Number of attempts per server.
    attempts: u4 = 2,

    /// Rotate through nameservers.
    rotate: bool = false,

    /// Force TCP instead of UDP.
    use_tcp: bool = false,

    pub const Server = struct {
        addr: net.IpAddress,

        pub fn format(self: Server, writer: anytype) !void {
            try self.addr.format(writer);
        }
    };

    pub const SearchDomain = struct {
        data: [max_search_len]u8 = undefined,
        len: u16 = 0,

        pub fn init(domain: []const u8) SearchDomain {
            var sd: SearchDomain = .{};
            const copy_len: u16 = @intCast(@min(domain.len, max_search_len));
            @memcpy(sd.data[0..copy_len], domain[0..copy_len]);
            sd.len = copy_len;
            return sd;
        }

        pub fn slice(self: *const SearchDomain) []const u8 {
            return self.data[0..self.len];
        }
    };

    pub const Servers = struct {
        buffer: [max_servers]Server = undefined,
        len: usize = 0,

        pub fn appendAssumeCapacity(self: *Servers, server: Server) void {
            self.buffer[self.len] = server;
            self.len += 1;
        }

        pub fn slice(self: *const Servers) []const Server {
            return self.buffer[0..self.len];
        }
    };

    pub const SearchDomains = struct {
        buffer: [max_search]SearchDomain = undefined,
        len: usize = 0,

        pub fn appendAssumeCapacity(self: *SearchDomains, domain: SearchDomain) void {
            self.buffer[self.len] = domain;
            self.len += 1;
        }

        pub fn slice(self: *const SearchDomains) []const SearchDomain {
            return self.buffer[0..self.len];
        }
    };

    /// Create default configuration (localhost resolvers).
    pub fn default() Config {
        var config: Config = .{};
        config.servers.appendAssumeCapacity(.{ .addr = net.IpAddress.initIp4(.{ 127, 0, 0, 1 }, 53) });
        return config;
    }

    /// Parse resolv.conf content.
    pub fn parse(content: []const u8) Config {
        var config: Config = .{};

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            config.parseLine(line);
        }

        // Apply defaults if nothing configured
        if (config.servers.len == 0) {
            config.servers.appendAssumeCapacity(.{ .addr = net.IpAddress.initIp4(.{ 127, 0, 0, 1 }, 53) });
        }

        return config;
    }

    fn parseLine(self: *Config, line: []const u8) void {
        // Skip comments and empty lines
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#' or trimmed[0] == ';') return;

        var tokens = std.mem.tokenizeAny(u8, trimmed, " \t");
        const keyword = tokens.next() orelse return;

        if (std.mem.eql(u8, keyword, "nameserver")) {
            self.parseNameserver(tokens.next() orelse return);
        } else if (std.mem.eql(u8, keyword, "search")) {
            self.parseSearch(&tokens);
        } else if (std.mem.eql(u8, keyword, "domain")) {
            // "domain" is like "search" but with a single domain
            self.search.len = 0;
            if (tokens.next()) |domain| {
                self.addSearchDomain(domain);
            }
        } else if (std.mem.eql(u8, keyword, "options")) {
            self.parseOptions(&tokens);
        }
    }

    fn parseNameserver(self: *Config, addr_str: []const u8) void {
        if (self.servers.len >= max_servers) return;

        // Parse IP address, default port 53
        const addr = net.IpAddress.parseIp(addr_str, 53) catch return;
        self.servers.appendAssumeCapacity(.{ .addr = addr });
    }

    fn parseSearch(self: *Config, tokens: *std.mem.TokenIterator(u8, .any)) void {
        self.search.len = 0;
        while (tokens.next()) |token| {
            // Stop at comment
            if (token[0] == '#') break;
            // Handle inline comment (trim at #)
            const domain = if (std.mem.indexOfScalar(u8, token, '#')) |idx|
                token[0..idx]
            else
                token;
            if (domain.len > 0) {
                self.addSearchDomain(domain);
            }
        }
    }

    fn addSearchDomain(self: *Config, domain: []const u8) void {
        if (self.search.len >= max_search) return;
        if (domain.len == 0 or domain.len > max_search_len - 1) return;

        // Ensure domain is rooted (has trailing dot)
        var sd = SearchDomain.init(domain);
        if (domain[domain.len - 1] != '.') {
            if (sd.len < max_search_len) {
                sd.data[sd.len] = '.';
                sd.len += 1;
            }
        }
        self.search.appendAssumeCapacity(sd);
    }

    fn parseOptions(self: *Config, tokens: *std.mem.TokenIterator(u8, .any)) void {
        while (tokens.next()) |opt| {
            if (std.mem.startsWith(u8, opt, "ndots:")) {
                const ndots = std.fmt.parseInt(u8, opt[6..], 10) catch 1;
                self.ndots = @intCast(@min(ndots, @as(u8, std.math.maxInt(u4))));
            } else if (std.mem.startsWith(u8, opt, "timeout:")) {
                self.timeout = std.fmt.parseInt(u8, opt[8..], 10) catch 5;
                if (self.timeout < 1) self.timeout = 1;
            } else if (std.mem.startsWith(u8, opt, "attempts:")) {
                const attempts = std.fmt.parseInt(u8, opt[9..], 10) catch 2;
                self.attempts = @intCast(@max(@as(u8, 1), @min(attempts, @as(u8, std.math.maxInt(u4)))));
            } else if (std.mem.eql(u8, opt, "rotate")) {
                self.rotate = true;
            } else if (std.mem.eql(u8, opt, "use-vc") or
                std.mem.eql(u8, opt, "usevc") or
                std.mem.eql(u8, opt, "tcp"))
            {
                self.use_tcp = true;
            }
            // Note: single-request and single-request-reopen are intentionally
            // not supported - queries are always sequential in this implementation.
        }
    }

    /// Generate the list of FQDNs to try for a given hostname.
    /// Returns an iterator over names to query.
    pub fn nameList(self: *const Config, name: []const u8) NameListIterator {
        return NameListIterator.init(self, name);
    }
};

/// Iterator over FQDNs to try for a lookup.
pub const NameListIterator = struct {
    config: *const Config,
    name: []const u8,
    state: State,
    search_idx: usize,
    tried_absolute: bool,
    rooted: bool,

    const State = enum {
        absolute_first, // Try absolute name first (if enough dots or rooted)
        search, // Try search domains
        absolute_last, // Try absolute name last (if not enough dots)
        done,
    };

    pub fn init(config: *const Config, name: []const u8) NameListIterator {
        // Count dots in name
        var dots: usize = 0;
        for (name) |c| {
            if (c == '.') dots += 1;
        }

        // If name is rooted (ends with dot), only try that name
        const rooted = name.len > 0 and name[name.len - 1] == '.';
        if (rooted) {
            return .{
                .config = config,
                .name = name,
                .state = .absolute_first,
                .search_idx = 0,
                .tried_absolute = false,
                .rooted = true,
            };
        }

        // If enough dots, try absolute first
        const has_ndots = dots >= config.ndots;
        return .{
            .config = config,
            .name = name,
            .state = if (has_ndots) .absolute_first else .search,
            .search_idx = 0,
            .tried_absolute = false,
            .rooted = false,
        };
    }

    /// Get the next FQDN to try. Writes to the provided buffer.
    /// Returns null when no more names to try.
    pub fn next(self: *NameListIterator, buf: []u8) ?[]const u8 {
        switch (self.state) {
            .absolute_first => {
                self.tried_absolute = true;
                // For rooted names, go directly to done after returning the name
                self.state = if (self.rooted) .done else .search;
                return self.formatAbsolute(buf);
            },
            .search => {
                if (self.search_idx < self.config.search.len) {
                    const suffix = self.config.search.buffer[self.search_idx].slice();
                    self.search_idx += 1;
                    return self.formatWithSuffix(buf, suffix);
                }
                self.state = .absolute_last;
                return self.next(buf);
            },
            .absolute_last => {
                self.state = .done;
                // Only try absolute if we didn't already try it
                if (!self.tried_absolute) {
                    return self.formatAbsolute(buf);
                }
                return null;
            },
            .done => return null,
        }
    }

    fn formatAbsolute(self: *NameListIterator, buf: []u8) ?[]const u8 {
        // Name without trailing dot - add one
        const name = std.mem.trimRight(u8, self.name, ".");
        if (name.len + 1 > buf.len) return null;
        @memcpy(buf[0..name.len], name);
        buf[name.len] = '.';
        return buf[0 .. name.len + 1];
    }

    fn formatWithSuffix(self: *NameListIterator, buf: []u8, suffix: []const u8) ?[]const u8 {
        const name = std.mem.trimRight(u8, self.name, ".");
        const total = name.len + 1 + suffix.len;
        if (total > buf.len) return null;
        @memcpy(buf[0..name.len], name);
        buf[name.len] = '.';
        @memcpy(buf[name.len + 1 ..][0..suffix.len], suffix);
        return buf[0..total];
    }
};

// Tests

test "Config.parse basic" {
    const content =
        \\# Comment
        \\nameserver 8.8.8.8
        \\nameserver 8.8.4.4
        \\search example.com local.
        \\options ndots:2 timeout:3 rotate
    ;

    const config = Config.parse(content);

    try std.testing.expectEqual(@as(usize, 2), config.servers.len);
    try std.testing.expectEqual(@as(usize, 2), config.search.len);
    try std.testing.expectEqual(@as(u4, 2), config.ndots);
    try std.testing.expectEqual(@as(u8, 3), config.timeout);
    try std.testing.expect(config.rotate);
}

test "Config.parse IPv6" {
    const content =
        \\nameserver 2001:4860:4860::8888
        \\nameserver ::1
    ;

    const config = Config.parse(content);
    try std.testing.expectEqual(@as(usize, 2), config.servers.len);
}

test "Config.parse default" {
    const config = Config.parse("");
    try std.testing.expectEqual(@as(usize, 1), config.servers.len);
}

test "Config.nameList with ndots" {
    var config: Config = .{};
    config.ndots = 1;
    config.search.appendAssumeCapacity(Config.SearchDomain.init("example.com."));

    var buf: [256]u8 = undefined;
    var iter = config.nameList("host");

    // Not enough dots - search first
    try std.testing.expectEqualStrings("host.example.com.", iter.next(&buf).?);
    try std.testing.expectEqualStrings("host.", iter.next(&buf).?);
    try std.testing.expect(iter.next(&buf) == null);
}

test "Config.nameList with enough dots" {
    var config: Config = .{};
    config.ndots = 1;
    config.search.appendAssumeCapacity(Config.SearchDomain.init("example.com."));

    var buf: [256]u8 = undefined;
    var iter = config.nameList("www.host");

    // Enough dots - absolute first
    try std.testing.expectEqualStrings("www.host.", iter.next(&buf).?);
    try std.testing.expectEqualStrings("www.host.example.com.", iter.next(&buf).?);
    try std.testing.expect(iter.next(&buf) == null);
}

test "Config.nameList rooted name" {
    var config: Config = .{};
    config.search.appendAssumeCapacity(Config.SearchDomain.init("example.com."));

    var buf: [256]u8 = undefined;
    var iter = config.nameList("www.example.org.");

    // Rooted name - only try that
    try std.testing.expectEqualStrings("www.example.org.", iter.next(&buf).?);
    try std.testing.expect(iter.next(&buf) == null);
}
