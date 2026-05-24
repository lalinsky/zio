// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

const std = @import("std");
const dns = @import("../root.zig");
const fs = @import("../../fs.zig");
const net = @import("../../net.zig");
const os = @import("../../os/root.zig");
const Hosts = @import("hosts.zig").Hosts;
const ResolvConf = @import("resolvconf.zig").ResolvConf;
const message = @import("message.zig");
const log = @import("../../common.zig").log;
const Timestamp = @import("../../time.zig").Timestamp;
const Duration = @import("../../time.zig").Duration;
const Timeout = @import("../../time.zig").Timeout;

fn nowS() u32 {
    return @truncate(Timestamp.now(.monotonic).toSeconds());
}
const RwLock = @import("../../sync/RwLock.zig");

const check_interval_secs: u32 = 5;

const cache_ttl_min: u32 = 5;
const cache_ttl_max: u32 = 60;

const max_nameservers = 3;
const max_search_domains = 6;
const max_search_domain_len = 254;

const max_cached_name_len = 31;

const CacheKey = struct {
    len: u8,
    buf: [max_cached_name_len]u8,

    fn init(name: []const u8) ?CacheKey {
        if (name.len > max_cached_name_len) return null;
        var key: CacheKey = .{ .len = @intCast(name.len), .buf = undefined };
        @memcpy(key.buf[0..name.len], name);
        return key;
    }

    fn slice(self: *const CacheKey) []const u8 {
        return self.buf[0..self.len];
    }
};

comptime {
    if (@sizeOf(CacheKey) != 32) @compileError("CacheKey must be exactly 32 bytes");
}

const CacheKeyContext = struct {
    pub fn hash(_: @This(), key: CacheKey) u64 {
        return std.hash.Wyhash.hash(0, key.slice());
    }
    pub fn eql(_: @This(), a: CacheKey, b: CacheKey) bool {
        return a.len == b.len and std.mem.eql(u8, a.buf[0..a.len], b.buf[0..b.len]);
    }
};

const max_cached_addrs = 3;

const CacheEntry = struct {
    addrs: [max_cached_addrs]net.IpAddress,
    count: u8,
    expiry: Timestamp,
};

pub const Resolver = struct {
    allocator: std.mem.Allocator,
    lock: RwLock,

    hosts: Hosts,
    hosts_mtime: i64,
    hosts_next_check: std.atomic.Value(u32),
    hosts_reloading: std.atomic.Value(bool),

    conf: ResolvConf,
    conf_mtime: i64,
    conf_next_check: std.atomic.Value(u32),
    conf_reloading: std.atomic.Value(bool),

    cache: std.HashMapUnmanaged(CacheKey, CacheEntry, CacheKeyContext, std.hash_map.default_max_load_percentage),
    rotate_index: std.atomic.Value(u32) = .init(0),

    prng_mutex: std.Thread.Mutex,
    prng: std.Random.DefaultPrng,

    pub fn init(allocator: std.mem.Allocator) Resolver {
        var hosts_mtime: i64 = 0;
        var conf_mtime: i64 = 0;
        const next_check_s = nowS() +% check_interval_secs;
        return .{
            .allocator = allocator,
            .lock = .init,
            .hosts = loadHosts(allocator, &hosts_mtime),
            .hosts_mtime = hosts_mtime,
            .hosts_next_check = .init(next_check_s),
            .hosts_reloading = .init(false),
            .conf = loadResolvConf(allocator, &conf_mtime),
            .conf_mtime = conf_mtime,
            .conf_next_check = .init(next_check_s),
            .conf_reloading = .init(false),
            .cache = .empty,
            .prng_mutex = .{},
            .prng = std.Random.DefaultPrng.init(Timestamp.now(.realtime).value),
        };
    }

    fn nextQueryId(self: *Resolver) u16 {
        self.prng_mutex.lock();
        defer self.prng_mutex.unlock();
        return self.prng.random().int(u16);
    }

    pub fn deinit(self: *Resolver) void {
        self.hosts.deinit();
        self.conf.deinit();
        self.cache.deinit(self.allocator);
    }

    pub fn lookup(
        self: *Resolver,
        storage: []dns.LookupResult,
        options: dns.LookupOptions,
    ) dns.LookupError!usize {
        self.maybeReloadHosts();
        self.maybeReloadResolvConf();

        // 1. Check /etc/hosts and DNS cache
        {
            try self.lock.lockShared();
            defer self.lock.unlockShared();

            if (self.hosts.lookupByName(options.name)) |addrs| {
                var i: usize = 0;
                for (addrs) |addr_in| {
                    if (i >= storage.len) break;
                    if (options.family) |f| {
                        if (addr_in.getFamily() != f) continue;
                    }
                    var addr = addr_in;
                    addr.setPort(options.port);
                    storage[i] = .{ .address = addr };
                    i += 1;
                }
                if (i > 0) return i;
            }

            if (CacheKey.init(options.name)) |key| {
                if (self.cache.get(key)) |entry| {
                    if (Timestamp.now(.monotonic).value < entry.expiry.value) {
                        var i: usize = 0;
                        for (entry.addrs[0..entry.count]) |addr_in| {
                            if (i >= storage.len) break;
                            if (options.family) |f| {
                                if (addr_in.getFamily() != f) continue;
                            }
                            var addr = addr_in;
                            addr.setPort(options.port);
                            storage[i] = .{ .address = addr };
                            i += 1;
                        }
                        if (i > 0) return i;
                    }
                }
            }
        }

        // 2. DNS query — snapshot conf fields while holding the shared lock so
        //    we don't hold it across I/O operations.
        var servers: [max_nameservers]net.IpAddress = undefined;
        var server_count: usize = 0;
        var ndots: u8 = undefined;
        var timeout: Duration = undefined;
        var attempts: u8 = undefined;
        var rotate: bool = undefined;

        var search_store: [max_search_domains][max_search_domain_len + 1]u8 = undefined;
        var search_lens: [max_search_domains]usize = undefined;
        var search_count: usize = 0;

        {
            try self.lock.lockShared();
            defer self.lock.unlockShared();

            const conf = &self.conf;
            ndots = conf.ndots;
            timeout = conf.timeout;
            attempts = conf.attempts;
            rotate = conf.rotate;

            const sc = @min(conf.servers.len, max_nameservers);
            for (conf.servers[0..sc]) |srv| {
                servers[server_count] = srv;
                server_count += 1;
            }

            for (conf.search) |s| {
                if (search_count >= max_search_domains) break;
                const len = @min(s.len, max_search_domain_len);
                @memcpy(search_store[search_count][0..len], s[0..len]);
                search_lens[search_count] = len;
                search_count += 1;
            }
        }

        if (server_count == 0) return error.UnknownHostName;

        if (rotate and server_count > 1) {
            const offset = self.rotate_index.fetchAdd(1, .monotonic) % @as(u32, @intCast(server_count));
            std.mem.rotate(net.IpAddress, servers[0..server_count], @intCast(offset));
        }

        const srvs = servers[0..server_count];
        const name = options.name;
        const rooted = name.len > 0 and name[name.len - 1] == '.';

        var fqdn_buf: [256]u8 = undefined;
        var last_err: dns.LookupError = error.UnknownHostName;

        // Rooted name: only try exactly as given.
        if (rooted) {
            const r = try queryOneName(self, storage, options, name, srvs, attempts, timeout);
            self.cacheInsert(options, storage[0..r.count], r.ttl);
            return r.count;
        }

        var dot_count: usize = 0;
        for (name) |c| {
            if (c == '.') dot_count += 1;
        }
        const has_enough_dots = dot_count >= ndots;

        // Enough dots: try unsuffixed first (Go's nameList logic).
        if (has_enough_dots) {
            if (makeFqdn(&fqdn_buf, name, null)) |fqdn| {
                if (queryOneName(self, storage, options, fqdn, srvs, attempts, timeout)) |r| {
                    if (r.count > 0) {
                        self.cacheInsert(options, storage[0..r.count], r.ttl);
                        return r.count;
                    }
                } else |err| {
                    if (err != error.UnknownHostName) return err;
                }
            }
        }

        // Try with each search domain.
        for (0..search_count) |i| {
            const suffix = search_store[i][0..search_lens[i]];
            if (makeFqdn(&fqdn_buf, name, suffix)) |fqdn| {
                if (queryOneName(self, storage, options, fqdn, srvs, attempts, timeout)) |r| {
                    if (r.count > 0) {
                        self.cacheInsert(options, storage[0..r.count], r.ttl);
                        return r.count;
                    }
                } else |err| {
                    if (err != error.UnknownHostName) return err;
                }
            }
        }

        // Not enough dots: try unsuffixed last.
        if (!has_enough_dots) {
            if (makeFqdn(&fqdn_buf, name, null)) |fqdn| {
                if (queryOneName(self, storage, options, fqdn, srvs, attempts, timeout)) |r| {
                    if (r.count > 0) {
                        self.cacheInsert(options, storage[0..r.count], r.ttl);
                        return r.count;
                    }
                } else |err| {
                    last_err = err;
                }
            }
        }

        return last_err;
    }

    fn cacheRemove(self: *Resolver, name: []const u8) void {
        const key = CacheKey.init(name) orelse return;
        self.lock.lockUncancelable();
        defer self.lock.unlock();
        _ = self.cache.remove(key);
    }

    /// Insert a successful DNS result into the cache. Only caches when family is
    /// unfiltered (both A and AAAA) and the result fits in max_cached_addrs.
    /// Silently skips on allocation failure.
    fn cacheInsert(self: *Resolver, options: dns.LookupOptions, results: []const dns.LookupResult, ttl: u32) void {
        if (options.family != null) return;
        if (results.len == 0 or results.len > max_cached_addrs) {
            self.cacheRemove(options.name);
            return;
        }

        const ttl_secs = std.math.clamp(ttl, cache_ttl_min, cache_ttl_max);
        var entry: CacheEntry = .{
            .addrs = undefined,
            .count = @intCast(results.len),
            .expiry = Timestamp.now(.monotonic).addDuration(.fromSeconds(ttl_secs)),
        };
        for (results, 0..) |r, i| {
            entry.addrs[i] = r.address;
            entry.addrs[i].setPort(0);
        }

        self.lock.lockUncancelable();
        defer self.lock.unlock();

        const key = CacheKey.init(options.name) orelse return;
        if (self.cache.getPtr(key)) |ptr| {
            ptr.* = entry;
            return;
        }
        self.cache.put(self.allocator, key, entry) catch {};
    }

    fn maybeReloadHosts(self: *Resolver) void {
        const now_s = nowS();
        if (now_s < self.hosts_next_check.load(.monotonic)) return;

        if (self.hosts_reloading.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return;
        defer self.hosts_reloading.store(false, .release);

        self.hosts_next_check.store(now_s +% check_interval_secs, .monotonic);

        const info = fs.stat("/etc/hosts") catch return;
        if (info.mtime == self.hosts_mtime) return;

        var new_mtime: i64 = 0;
        const new_hosts = loadHosts(self.allocator, &new_mtime);

        self.lock.lockUncancelable();
        const old_hosts = self.hosts;
        self.hosts = new_hosts;
        self.hosts_mtime = new_mtime;
        self.lock.unlock();

        var old = old_hosts;
        old.deinit();
    }

    fn maybeReloadResolvConf(self: *Resolver) void {
        const now_s = nowS();
        if (now_s < self.conf_next_check.load(.monotonic)) return;

        if (self.conf_reloading.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return;
        defer self.conf_reloading.store(false, .release);

        self.conf_next_check.store(now_s +% check_interval_secs, .monotonic);

        const info = fs.stat("/etc/resolv.conf") catch return;
        if (info.mtime == self.conf_mtime) return;

        var new_mtime: i64 = 0;
        const new_conf = loadResolvConf(self.allocator, &new_mtime);

        self.lock.lockUncancelable();
        const old_conf = self.conf;
        self.conf = new_conf;
        self.conf_mtime = new_mtime;
        self.lock.unlock();

        var old = old_conf;
        old.deinit();
    }
};

/// Build name + '.' + suffix into buf. suffix must already end with '.'.
/// Returns null if the resulting FQDN would exceed the buffer.
fn makeFqdn(buf: *[256]u8, name: []const u8, suffix: ?[]const u8) ?[]u8 {
    const total = name.len + 1 + if (suffix) |s| s.len else @as(usize, 0);
    if (total > buf.len) return null;
    @memcpy(buf[0..name.len], name);
    buf[name.len] = '.';
    if (suffix) |s| @memcpy(buf[name.len + 1 ..][0..s.len], s);
    return buf[0..total];
}

const QueryResult = struct { count: usize, ttl: u32 };

/// Try a single FQDN against all servers, querying A and/or AAAA based on
/// options.family. Fills storage and returns count + minimum TTL.
fn queryOneName(
    resolver: *Resolver,
    storage: []dns.LookupResult,
    options: dns.LookupOptions,
    fqdn: []const u8,
    servers: []const net.IpAddress,
    attempts: u8,
    timeout: Duration,
) dns.LookupError!QueryResult {
    const sock_timeout: Timeout = .{ .duration = timeout };
    var filled: usize = 0;
    var min_ttl: u32 = std.math.maxInt(u32);
    var last_err: dns.LookupError = error.UnknownHostName;

    const do_a = options.family == null or options.family == .ipv4;
    const do_aaaa = options.family == null or options.family == .ipv6;

    if (do_a and filled < storage.len) {
        if (queryOneType(resolver, storage[filled..], options, fqdn, .a, servers, attempts, sock_timeout)) |r| {
            filled += r.count;
            min_ttl = @min(min_ttl, r.ttl);
        } else |err| switch (err) {
            error.Canceled, error.RuntimeShutdown, error.NoThreadPool => return err,
            else => last_err = err,
        }
    }

    if (do_aaaa and filled < storage.len) {
        if (queryOneType(resolver, storage[filled..], options, fqdn, .aaaa, servers, attempts, sock_timeout)) |r| {
            filled += r.count;
            min_ttl = @min(min_ttl, r.ttl);
        } else |err| switch (err) {
            error.Canceled, error.RuntimeShutdown, error.NoThreadPool => return err,
            else => last_err = err,
        }
    }

    if (filled == 0) return last_err;
    return .{ .count = filled, .ttl = if (min_ttl == std.math.maxInt(u32)) 0 else min_ttl };
}

/// Query all servers for one record type (A or AAAA), retrying up to `attempts`
/// times. Returns count + TTL from the successful response, or an error if all
/// attempts failed.
fn queryOneType(
    resolver: *Resolver,
    storage: []dns.LookupResult,
    options: dns.LookupOptions,
    fqdn: []const u8,
    qtype: message.QType,
    servers: []const net.IpAddress,
    attempts: u8,
    timeout: Timeout,
) dns.LookupError!QueryResult {
    const id = resolver.nextQueryId();

    var query_buf: [message.max_udp_size]u8 = undefined;
    const query = message.buildQuery(&query_buf, id, fqdn, qtype) catch return error.Unexpected;

    var recv_buf: [4096]u8 = undefined;
    var addr_storage: [16]net.IpAddress = undefined;
    var last_err: dns.LookupError = error.UnknownHostName;

    for (0..attempts) |_| {
        for (servers) |server| {
            const response = exchange(server, query, &recv_buf, timeout) catch |err| {
                if (err == error.Canceled) return error.Canceled;
                log.debug("dns: {s}: {}", .{ fqdn, err });
                last_err = error.TemporaryNameServerFailure;
                continue;
            };

            const max_addrs = @min(addr_storage.len, storage.len);
            const result = message.parseResponse(response, id, qtype, addr_storage[0..max_addrs], options.port) catch |err| {
                log.debug("dns: parse error for {s}: {}", .{ fqdn, err });
                last_err = error.NameServerFailure;
                continue;
            };

            switch (result.rcode) {
                .no_error => {},
                .nx_domain => return error.UnknownHostName,
                .serv_fail => {
                    last_err = error.TemporaryNameServerFailure;
                    continue;
                },
                else => {
                    last_err = error.NameServerFailure;
                    continue;
                },
            }

            const count = @min(result.count, storage.len);
            for (addr_storage[0..count], 0..) |addr, i| {
                storage[i] = .{ .address = addr };
            }
            return .{ .count = count, .ttl = result.ttl };
        }
    }

    return last_err;
}

fn sameEndpoint(a: net.IpAddress, b: net.IpAddress) bool {
    if (a.getFamily() != b.getFamily()) return false;
    if (a.getPort() != b.getPort()) return false;
    return switch (a.getFamily()) {
        .ipv4 => @as(*align(1) const u32, @ptrCast(&a.in.addr)).* == @as(*align(1) const u32, @ptrCast(&b.in.addr)).*,
        .ipv6 => @as(u128, @bitCast(a.in6.addr)) == @as(u128, @bitCast(b.in6.addr)) and a.in6.scope_id == b.in6.scope_id,
    };
}

/// Send a DNS query via UDP (with automatic TCP fallback when TC bit is set).
/// Returns the response payload slice into recv_buf.
fn exchange(
    server: net.IpAddress,
    query: []const u8,
    recv_buf: []u8,
    timeout: Timeout,
) ![]u8 {
    const domain: os.net.Domain = switch (server.getFamily()) {
        .ipv4 => .ipv4,
        .ipv6 => .ipv6,
    };

    var sock = try net.Socket.open(.dgram, domain, .ip);
    defer sock.close();

    _ = try sock.sendTo(.{ .ip = server }, query, timeout);
    const r = try sock.receiveFrom(recv_buf, timeout);
    if (!sameEndpoint(r.from.ip, server)) return error.ConnectionRefused;
    const data = recv_buf[0..r.len];

    // TC bit (0x0200) in flags word at offset 2: retry with TCP.
    if (data.len >= 4 and std.mem.readInt(u16, data[2..4], .big) & 0x0200 != 0) {
        return exchangeTcp(server, query, recv_buf, timeout);
    }

    return data;
}

/// DNS-over-TCP exchange: 2-byte length-prefixed request and response.
fn exchangeTcp(
    server: net.IpAddress,
    query: []const u8,
    recv_buf: []u8,
    timeout: Timeout,
) ![]u8 {
    var stream = try server.connect(.{ .timeout = timeout });
    defer stream.close();

    var len_prefix: [2]u8 = undefined;
    std.mem.writeInt(u16, &len_prefix, @intCast(query.len), .big);
    try stream.writeAll(&len_prefix, timeout);
    try stream.writeAll(query, timeout);

    var resp_len_buf: [2]u8 = undefined;
    var got: usize = 0;
    while (got < 2) {
        const n = try stream.read(resp_len_buf[got..], timeout);
        if (n == 0) return error.ConnectionResetByPeer;
        got += n;
    }

    const resp_len = std.mem.readInt(u16, &resp_len_buf, .big);
    if (resp_len > recv_buf.len) return error.MessageTooBig;

    got = 0;
    while (got < resp_len) {
        const n = try stream.read(recv_buf[got..resp_len], timeout);
        if (n == 0) return error.ConnectionResetByPeer;
        got += n;
    }

    return recv_buf[0..resp_len];
}

fn loadHosts(allocator: std.mem.Allocator, mtime_out: *i64) Hosts {
    const file = fs.openFile("/etc/hosts") catch |err| {
        log.warn("dns: failed to open /etc/hosts: {}", .{err});
        return .{ .arena = .init(allocator), .by_name = .empty };
    };
    defer file.close();
    if (file.stat()) |info| {
        mtime_out.* = info.mtime;
    } else |_| {}
    var buf: [4096]u8 = undefined;
    var reader = file.reader(&buf);
    return Hosts.parse(allocator, &reader.interface) catch |err| {
        log.warn("dns: failed to parse /etc/hosts: {}", .{err});
        return .{ .arena = .init(allocator), .by_name = .empty };
    };
}

fn loadResolvConf(allocator: std.mem.Allocator, mtime_out: *i64) ResolvConf {
    const file = fs.openFile("/etc/resolv.conf") catch |err| {
        log.warn("dns: failed to open /etc/resolv.conf: {}", .{err});
        return .{ .arena = .init(allocator), .servers = &.{}, .search = &.{} };
    };
    defer file.close();
    if (file.stat()) |info| {
        mtime_out.* = info.mtime;
    } else |_| {}
    var buf: [4096]u8 = undefined;
    var reader = file.reader(&buf);
    return ResolvConf.parse(allocator, &reader.interface) catch |err| {
        log.warn("dns: failed to parse /etc/resolv.conf: {}", .{err});
        return .{ .arena = .init(allocator), .servers = &.{}, .search = &.{} };
    };
}
