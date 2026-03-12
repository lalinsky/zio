// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

//! Native DNS resolver using UDP/TCP sockets directly.

const std = @import("std");
const fs = @import("../../fs.zig");
const net = @import("../../net.zig");
const os = @import("../../os/root.zig");
const time = @import("../../time.zig");
const message = @import("message.zig");
const config_mod = @import("config.zig");
const hosts = @import("hosts.zig");

const Config = config_mod.Config;
const Name = message.Name;
const Type = message.Type;
const Header = message.Header;
const RCode = message.RCode;
const ResponseParser = message.ResponseParser;

pub const LookupError = error{
    UnknownHostName,
    TemporaryNameServerFailure,
    NameServerFailure,
    HostLacksNetworkAddresses,
    InvalidResponse,
    Truncated,
    Timeout,
    NetworkUnreachable,
    ConnectionRefused,
    Canceled,
    OutOfMemory,
    Unexpected,
};

pub const LookupOptions = struct {
    /// Address family filter.
    family: ?net.IpAddress.Family = null,
    /// Query timeout per attempt (overrides config timeout if set).
    timeout: ?time.Timeout = null,
};

pub const LookupResult = struct {
    addresses: Addresses = .{},
    canonical_name: ?Name = null,

    pub const max_addresses = 32;

    pub const Addresses = struct {
        buffer: [max_addresses]net.IpAddress = undefined,
        len: usize = 0,

        pub fn appendAssumeCapacity(self: *Addresses, addr: net.IpAddress) void {
            std.debug.assert(self.len < max_addresses);
            self.buffer[self.len] = addr;
            self.len += 1;
        }

        pub fn slice(self: *Addresses) []net.IpAddress {
            return self.buffer[0..self.len];
        }

        pub fn constSlice(self: *const Addresses) []const net.IpAddress {
            return self.buffer[0..self.len];
        }

        pub fn capacity(self: *const Addresses) usize {
            _ = self;
            return max_addresses;
        }
    };
};

const resolv_conf_path = "/etc/resolv.conf";

/// How often to check if resolv.conf has changed (in seconds).
const config_reload_interval_s = 5;

/// Native DNS resolver.
pub const Resolver = struct {
    config: Config,
    /// Server rotation offset for load balancing.
    server_offset: usize = 0,
    /// Random state for query IDs.
    prng: std.Random.DefaultPrng,
    /// Last time we checked resolv.conf for changes.
    last_checked: time.Timestamp = .zero,
    /// Modification time of resolv.conf when we last loaded it.
    mtime: i64 = 0,

    pub fn init(cfg: Config) Resolver {
        var seed: u64 = undefined;
        std.posix.getrandom(std.mem.asBytes(&seed)) catch {
            seed = @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())));
        };
        return .{
            .config = cfg,
            .prng = std.Random.DefaultPrng.init(seed),
        };
    }

    /// Load configuration from /etc/resolv.conf.
    pub fn initFromSystem() error{Canceled}!Resolver {
        var resolver = try loadConfig();
        resolver.last_checked = time.Timestamp.now(.monotonic);
        resolver.mtime = try getResolvConfMtime();
        return resolver;
    }

    fn loadConfig() error{Canceled}!Resolver {
        const file = fs.openFile(resolv_conf_path) catch |err| {
            if (err == error.Canceled) return error.Canceled;
            return init(Config.default());
        };
        defer file.close();

        var read_buf: [512]u8 = undefined;
        var reader = file.reader(&read_buf);

        var buf: [4096]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buf);
        const len = reader.interface.streamRemaining(&writer) catch |err| {
            if (err == error.ReadFailed) {
                if (reader.err) |e| {
                    if (e == error.Canceled) return error.Canceled;
                }
            }
            return init(Config.default());
        };
        return init(Config.parse(buf[0..len]));
    }

    fn getResolvConfMtime() error{Canceled}!i64 {
        const stat_info = fs.stat(resolv_conf_path) catch |err| {
            if (err == error.Canceled) return error.Canceled;
            return 0;
        };
        return stat_info.mtime;
    }

    /// Check if resolv.conf has changed and reload if necessary.
    fn tryReloadConfig(self: *Resolver) error{Canceled}!void {
        const now = time.Timestamp.now(.monotonic);
        if (self.last_checked.durationTo(now).toSeconds() < config_reload_interval_s) {
            return;
        }
        self.last_checked = now;

        const new_mtime = try getResolvConfMtime();
        if (new_mtime == self.mtime) {
            return;
        }

        // Config changed, reload it
        const new_resolver = try loadConfig();
        self.config = new_resolver.config;
        self.mtime = new_mtime;
        // Keep server_offset and prng state
    }

    /// Look up IP addresses for a hostname.
    pub fn lookup(self: *Resolver, hostname: []const u8, port: u16, options: LookupOptions) LookupError!LookupResult {
        try self.tryReloadConfig();

        var result: LookupResult = .{};

        // Check if hostname is a numeric IP address - return directly without DNS
        if (net.IpAddress.parseIp(hostname, port)) |addr| {
            const family = addr.getFamily();
            if (options.family == null or options.family == family) {
                result.addresses.appendAssumeCapacity(addr);
                return result;
            }
            // Family mismatch - no addresses match the filter
            return error.HostLacksNetworkAddresses;
        } else |_| {}

        // Check /etc/hosts before DNS query
        if (hosts.lookup(hostname, options.family)) |hosts_result| {
            for (hosts_result.slice()) |addr| {
                var addr_with_port = addr;
                addr_with_port.setPort(port);
                if (result.addresses.len < LookupResult.max_addresses) {
                    result.addresses.appendAssumeCapacity(addr_with_port);
                }
            }
            if (result.addresses.len > 0) {
                // Set canonical name to the hostname itself for hosts file entries
                result.canonical_name = Name.fromString(hostname) catch null;
                return result;
            }
        }

        var last_err: ?LookupError = null;

        // Try each name in the search list
        var name_buf: [message.max_name_len + config_mod.max_search_len + 2]u8 = undefined;
        var name_iter = self.config.nameList(hostname);

        while (name_iter.next(&name_buf)) |fqdn| {
            const name = Name.fromString(fqdn) catch continue;

            // Query based on family filter
            const query_err = if (options.family) |family| switch (family) {
                .ipv4 => self.queryOne(&result, name, .A, options),
                .ipv6 => self.queryOne(&result, name, .AAAA, options),
            } else self.queryBoth(&result, name, options);

            if (query_err) |err| {
                last_err = err;
                // For NXDOMAIN, don't try other search suffixes
                if (err == error.UnknownHostName) {
                    continue;
                }
                // For temporary errors, try next name
                continue;
            }

            // Got results
            if (result.addresses.len > 0) {
                // Set port on all addresses
                for (result.addresses.slice()) |*addr| {
                    addr.setPort(port);
                }
                return result;
            }
        }

        return last_err orelse error.UnknownHostName;
    }

    /// Query for both A and AAAA records.
    /// Note: Queries are always sequential (matching single-request behavior).
    fn queryBoth(self: *Resolver, result: *LookupResult, name: Name, options: LookupOptions) ?LookupError {
        const err_a = self.queryOne(result, name, .A, options);
        if (err_a) |e| if (e == error.Canceled) return e;

        const err_aaaa = self.queryOne(result, name, .AAAA, options);
        if (err_aaaa) |e| if (e == error.Canceled) return e;

        // Return error only if both failed
        if (result.addresses.len > 0) return null;
        return err_a orelse err_aaaa;
    }

    /// Query for a single record type.
    fn queryOne(self: *Resolver, result: *LookupResult, name: Name, qtype: Type, options: LookupOptions) ?LookupError {
        var recv_buf: [message.max_packet_size]u8 = undefined;
        var attempt: usize = 0;
        const max_attempts = self.config.attempts;

        while (attempt < max_attempts) : (attempt += 1) {
            // Try each server
            const server_count = self.config.servers.len;
            var server_idx: usize = 0;

            while (server_idx < server_count) : (server_idx += 1) {
                const idx = if (self.config.rotate)
                    (self.server_offset + server_idx) % server_count
                else
                    server_idx;

                const server = self.config.servers.buffer[idx];

                const query_result = self.queryServer(server.addr, name, qtype, options, &recv_buf);

                if (query_result) |response| {
                    parseResponse(result, response) catch |err| {
                        // Propagate definitive errors, retry on parse failures
                        if (err == error.UnknownHostName) return err;
                        if (err == error.NameServerFailure) return err;
                        if (err == error.TemporaryNameServerFailure) return err;
                        continue; // Try next server on InvalidResponse
                    };

                    if (self.config.rotate) {
                        self.server_offset = (self.server_offset + 1) % server_count;
                    }

                    return null; // Success
                } else |err| {
                    if (err == error.Canceled) return err;
                    continue; // For any transport error, try next server
                }
            }
        }

        return error.TemporaryNameServerFailure;
    }

    /// Send query to a specific server.
    fn queryServer(
        self: *Resolver,
        server: net.IpAddress,
        name: Name,
        qtype: Type,
        options: LookupOptions,
        recv_buf: *[message.max_packet_size]u8,
    ) LookupError![]const u8 {
        const id = self.prng.random().int(u16);
        var query_buf: [512]u8 = undefined;
        const query = message.buildQuery(&query_buf, id, name, qtype, !self.config.use_tcp) catch
            return error.Unexpected;

        // Use explicit timeout if provided, otherwise use config timeout
        const timeout = options.timeout orelse time.Timeout.fromSeconds(self.config.timeout);

        if (self.config.use_tcp) {
            return queryTcp(server, id, name, qtype, timeout, recv_buf);
        }

        // Try UDP first
        const udp_result = queryUdp(server, id, query, timeout, recv_buf);
        if (udp_result) |response| {
            // Check if truncated - fall back to TCP
            const header = Header.decode(response) catch return error.InvalidResponse;
            if (header.flags.tc) {
                return queryTcp(server, id, name, qtype, timeout, recv_buf);
            }
            return response;
        } else |err| {
            return err;
        }
    }

    /// Send query over UDP.
    fn queryUdp(
        server: net.IpAddress,
        id: u16,
        query: []const u8,
        timeout: time.Timeout,
        recv_buf: *[message.max_packet_size]u8,
    ) LookupError![]const u8 {
        var socket = net.Socket.open(.dgram, os.net.Domain.fromPosix(server.any.family), .udp) catch return error.Unexpected;
        defer socket.close();

        // Send query
        _ = socket.sendTo(.{ .ip = server }, query, timeout) catch |err| {
            return if (err == error.Canceled) error.Canceled else if (err == error.Timeout) error.Timeout else error.Unexpected;
        };

        // Receive response
        const recv_result = socket.receiveFrom(recv_buf, timeout) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.Timeout => return error.Timeout,
            else => return error.Unexpected,
        };

        // Validate response came from expected server (IP and port)
        const from = recv_result.from.ip;
        if (from.any.family != server.any.family) return error.InvalidResponse;
        switch (from.any.family) {
            os.net.AF.INET => {
                if (from.in.addr != server.in.addr) return error.InvalidResponse;
                if (from.in.port != server.in.port) return error.InvalidResponse;
            },
            os.net.AF.INET6 => {
                if (!std.mem.eql(u8, &from.in6.addr, &server.in6.addr)) return error.InvalidResponse;
                if (from.in6.port != server.in6.port) return error.InvalidResponse;
            },
            else => return error.InvalidResponse,
        }

        // Validate response ID matches
        if (recv_result.len < 12) return error.InvalidResponse;
        const resp_id = std.mem.readInt(u16, recv_buf[0..2], .big);
        if (resp_id != id) return error.InvalidResponse;

        return recv_buf[0..recv_result.len];
    }

    /// Send query over TCP (for large responses).
    fn queryTcp(
        server: net.IpAddress,
        id: u16,
        name: Name,
        qtype: Type,
        timeout: time.Timeout,
        recv_buf: *[message.max_packet_size]u8,
    ) LookupError![]const u8 {
        // Rebuild query for TCP (with length prefix)
        var query_buf: [514]u8 = undefined;
        const query_body = message.buildQuery(query_buf[2..], id, name, qtype, true) catch
            return error.Unexpected;

        // Add length prefix
        std.mem.writeInt(u16, query_buf[0..2], @intCast(query_body.len), .big);
        const full_query = query_buf[0 .. 2 + query_body.len];

        var stream = server.connect(.{ .timeout = timeout }) catch |err| {
            return if (err == error.Canceled) error.Canceled else if (err == error.Timeout) error.Timeout else error.Unexpected;
        };
        defer stream.close();

        // Send query
        stream.writeAll(full_query, timeout) catch |err| {
            return if (err == error.Canceled) error.Canceled else if (err == error.Timeout) error.Timeout else error.Unexpected;
        };

        // Read response length
        var len_buf: [2]u8 = undefined;
        stream.readAll(&len_buf, timeout) catch |err| {
            return if (err == error.Canceled) error.Canceled else if (err == error.Timeout) error.Timeout else error.Unexpected;
        };
        const resp_len = std.mem.readInt(u16, &len_buf, .big);

        if (resp_len < 12 or resp_len > message.max_packet_size) {
            return error.InvalidResponse;
        }

        // Read response body
        stream.readAll(recv_buf[0..resp_len], timeout) catch |err| {
            return if (err == error.Canceled) error.Canceled else if (err == error.Timeout) error.Timeout else error.Unexpected;
        };

        // Validate response ID
        const resp_id = std.mem.readInt(u16, recv_buf[0..2], .big);
        if (resp_id != id) return error.InvalidResponse;

        return recv_buf[0..resp_len];
    }

    /// Parse DNS response and extract addresses.
    fn parseResponse(result: *LookupResult, response: []const u8) !void {
        var parser = ResponseParser.init(response) catch return error.InvalidResponse;

        // Check response code
        switch (parser.header.flags.rcode) {
            .success => {},
            .name_error => return error.UnknownHostName,
            .server_failure => return error.TemporaryNameServerFailure,
            else => return error.NameServerFailure,
        }

        // Skip questions
        parser.skipQuestions() catch return error.InvalidResponse;

        // Parse answers into temporary result to avoid partial data on error
        var tmp: LookupResult = .{};
        var remaining = parser.header.an_count;
        while (true) {
            const rr = parser.nextAnswer(&remaining) catch return error.InvalidResponse;
            if (rr == null) break;
            const record = rr.?;
            if (record.parseA()) |ipv4| {
                if (tmp.addresses.len < LookupResult.max_addresses) {
                    tmp.addresses.appendAssumeCapacity(net.IpAddress.initIp4(ipv4, 0));
                }
            } else if (record.parseAAAA()) |ipv6| {
                if (tmp.addresses.len < LookupResult.max_addresses) {
                    tmp.addresses.appendAssumeCapacity(net.IpAddress.initIp6(ipv6, 0, 0, 0));
                }
            } else if (record.rtype == .CNAME and tmp.canonical_name == null) {
                tmp.canonical_name = record.parseCNAME(response);
            }
        }

        // Merge successful results
        for (tmp.addresses.constSlice()) |addr| {
            if (result.addresses.len < LookupResult.max_addresses) {
                result.addresses.appendAssumeCapacity(addr);
            }
        }
        if (result.canonical_name == null) {
            result.canonical_name = tmp.canonical_name;
        }
    }
};

// Tests (these require network access, so they're integration tests)

test "Resolver.init" {
    const resolver = Resolver.init(Config.default());
    try std.testing.expectEqual(@as(usize, 1), resolver.config.servers.len);
}
