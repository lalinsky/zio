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

const RwLock = @import("../../sync/RwLock.zig");
const Mutex = @import("../../sync/Mutex.zig");
const Condition = @import("../../sync/Condition.zig");
const SimpleQueue = @import("../../utils/simple_queue.zig").SimpleQueue;

const check_interval_secs: u32 = 5;

const cache_ttl_min: u32 = 5;
const cache_ttl_max: u32 = 60;

const max_nameservers = 3;
const max_search_domains = 6;
const max_search_domain_len = 254;

const Cache = @import("cache.zig").Cache;
const CacheKey = @import("cache.zig").CacheKey;
const CacheEntry = @import("cache.zig").CacheEntry;
const max_cached_addrs = @import("cache.zig").max_cached_addrs;

const num_dedup_buckets = 64;

const WaiterNode = struct {
    next: ?*WaiterNode = null,
    prev: ?*WaiterNode = null,
    in_list: if (std.debug.runtime_safety) bool else void = if (std.debug.runtime_safety) false else {},
    key: CacheKey,
    is_active: bool,
    storage: []dns.LookupResult,
    count: usize = 0,
    err: ?dns.LookupError = null,
    done: bool = false,
    cond: Condition = .init,
};

const Bucket = struct {
    mutex: Mutex = .init,
    waiters: SimpleQueue(WaiterNode) = .empty,
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

    cache: Cache,
    hash_seed: u64,
    rotate_index: std.atomic.Value(u32) = .init(0),

    prng_mutex: Mutex,
    prng: std.Random.DefaultPrng,

    dedup_buckets: [num_dedup_buckets]Bucket,

    pub fn init(allocator: std.mem.Allocator) Resolver {
        var hosts_mtime: i64 = 0;
        var conf_mtime: i64 = 0;
        const next_check_s: u32 = @as(u32, @truncate(Timestamp.now(.monotonic).toSeconds())) +% check_interval_secs;
        var prng = std.Random.DefaultPrng.init(Timestamp.now(.realtime).value);
        const hash_seed = prng.random().int(u64);
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
            .cache = std.mem.zeroes(Cache),
            .hash_seed = hash_seed,
            .prng_mutex = .init,
            .prng = prng,
            .dedup_buckets = [_]Bucket{.{}} ** num_dedup_buckets,
        };
    }

    fn getDedupBucket(self: *Resolver, key: *const CacheKey) *Bucket {
        return &self.dedup_buckets[@as(usize, @truncate(key.hash)) & (num_dedup_buckets - 1)];
    }

    fn nextQueryId(self: *Resolver) u16 {
        self.prng_mutex.lockUncancelable();
        defer self.prng_mutex.unlock();
        return self.prng.random().int(u16);
    }

    pub fn deinit(self: *Resolver) void {
        self.hosts.deinit();
        self.conf.deinit();
    }

    pub fn lookup(
        self: *Resolver,
        storage: []dns.LookupResult,
        options: dns.LookupOptions,
    ) dns.ResolverError!usize {
        const now = Timestamp.now(.monotonic);
        self.maybeReloadHosts(now);
        self.maybeReloadResolvConf(now);

        // 1. Check /etc/hosts
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
        }

        // 2. Query each requested family through its own cache/dedup/DNS path.
        if (options.family) |fam| {
            return self.lookupOneFamily(storage, options, fam);
        }

        var total: usize = 0;
        var last_err: dns.LookupError = error.UnknownHostName;

        if (self.lookupOneFamily(storage, options, .ipv4)) |n| {
            total += n;
        } else |err| switch (err) {
            error.Canceled, error.RuntimeShutdown => return err,
            else => last_err = err,
        }

        if (self.lookupOneFamily(storage[total..], options, .ipv6)) |n| {
            total += n;
        } else |err| switch (err) {
            error.Canceled, error.RuntimeShutdown => return err,
            else => {},
        }

        if (total == 0) return last_err;
        return total;
    }

    fn lookupOneFamily(
        self: *Resolver,
        storage: []dns.LookupResult,
        options: dns.LookupOptions,
        family: net.IpAddress.Family,
    ) dns.LookupError!usize {
        var opts = options;
        opts.family = family;

        var key: CacheKey = undefined;
        CacheKey.init(&key, options.name, self.hash_seed, family);

        // 1. Check DNS cache.
        {
            try self.lock.lockShared();
            defer self.lock.unlockShared();
            if (self.cache.get(&key, Timestamp.now(.monotonic))) |entry| {
                var i: usize = 0;
                for (entry.addrs[0..entry.count]) |addr_in| {
                    if (i >= storage.len) break;
                    var addr = addr_in;
                    addr.setPort(options.port);
                    storage[i] = .{ .address = addr };
                    i += 1;
                }
                if (i > 0) return i;
            }
        }

        // 2. Deduplicate concurrent identical DNS queries.
        const bucket = self.getDedupBucket(&key);

        try bucket.mutex.lock();

        var it = bucket.waiters.head;
        while (it) |n| : (it = n.next) {
            if (n.is_active and n.key.eql(&key)) {
                // An identical query is already in flight — join it.
                var node: WaiterNode = .{
                    .key = key,
                    .is_active = false,
                    .storage = storage,
                };
                bucket.waiters.push(&node);

                while (!node.done) {
                    node.cond.wait(&bucket.mutex) catch |err| {
                        if (!node.done) {
                            _ = bucket.waiters.remove(&node);
                            bucket.mutex.unlock();
                            return err;
                        }
                        break;
                    };
                }
                _ = bucket.waiters.remove(&node);
                bucket.mutex.unlock();

                if (node.err) |err| return err;
                for (node.storage[0..node.count]) |*r| r.address.setPort(options.port);
                return node.count;
            }
        }

        // No in-flight request for this name+family — become the active requester.
        var active_node: WaiterNode = .{
            .key = key,
            .is_active = true,
            .storage = storage,
        };
        bucket.waiters.push(&active_node);
        bucket.mutex.unlock();

        var tmp: [16]dns.LookupResult = undefined;
        const buf: []dns.LookupResult = if (storage.len >= tmp.len) storage else tmp[0..];
        const result = self.lookupDns(buf, opts);

        if (result) |r| {
            const now = Timestamp.now(.monotonic);
            self.cacheInsert(options.name, family, buf[0..r.count], r.ttl, now);
        } else |_| {}

        // Notify all joiners, then remove the active node.
        bucket.mutex.lockUncancelable();
        var wit = bucket.waiters.head;
        while (wit) |n| : (wit = n.next) {
            if (!n.is_active and !n.done and n.key.eql(&key)) {
                if (result) |r| {
                    const jcount = @min(n.storage.len, r.count);
                    @memcpy(n.storage[0..jcount], buf[0..jcount]);
                    n.count = jcount;
                    n.err = null;
                } else |err| {
                    n.count = 0;
                    n.err = err;
                }
                n.done = true;
                n.cond.signal();
            }
        }
        _ = bucket.waiters.remove(&active_node);
        bucket.mutex.unlock();

        const r = result catch |err| return err;
        if (buf.ptr != storage.ptr) {
            const acount = @min(storage.len, r.count);
            @memcpy(storage[0..acount], buf[0..acount]);
            return acount;
        }
        return r.count;
    }

    fn lookupDns(
        self: *Resolver,
        storage: []dns.LookupResult,
        options: dns.LookupOptions,
    ) dns.LookupError!QueryResult {
        // Snapshot conf fields while holding the shared lock so we don't hold
        // it across I/O operations.
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
        const qtype: message.QType = switch (options.family.?) {
            .ipv4 => .a,
            .ipv6 => .aaaa,
        };
        const deadline = (Timeout{ .duration = timeout }).toDeadline();

        var fqdn_buf: [256]u8 = undefined;
        var last_err: dns.LookupError = error.UnknownHostName;

        const r: QueryResult = blk: {
            // Rooted name: only try exactly as given.
            if (rooted) {
                break :blk try queryOneType(self, storage, options, name, qtype, srvs, attempts, deadline);
            }

            var dot_count: usize = 0;
            for (name) |c| {
                if (c == '.') dot_count += 1;
            }
            const has_enough_dots = dot_count >= ndots;

            // Enough dots: try unsuffixed first (Go's nameList logic).
            if (has_enough_dots) {
                if (makeFqdn(&fqdn_buf, name, null)) |fqdn| {
                    if (queryOneType(self, storage, options, fqdn, qtype, srvs, attempts, deadline)) |r| {
                        if (r.count > 0) break :blk r;
                    } else |err| {
                        if (err != error.UnknownHostName) return err;
                    }
                }
            }

            // Try with each search domain.
            for (0..search_count) |i| {
                const suffix = search_store[i][0..search_lens[i]];
                if (makeFqdn(&fqdn_buf, name, suffix)) |fqdn| {
                    if (queryOneType(self, storage, options, fqdn, qtype, srvs, attempts, deadline)) |r| {
                        if (r.count > 0) break :blk r;
                    } else |err| {
                        if (err != error.UnknownHostName) return err;
                    }
                }
            }

            // Not enough dots: try unsuffixed last.
            if (!has_enough_dots) {
                if (makeFqdn(&fqdn_buf, name, null)) |fqdn| {
                    if (queryOneType(self, storage, options, fqdn, qtype, srvs, attempts, deadline)) |r| {
                        if (r.count > 0) break :blk r;
                    } else |err| {
                        last_err = err;
                    }
                }
            }

            return last_err;
        };

        return r;
    }

    fn cacheInsert(self: *Resolver, name: []const u8, family: net.IpAddress.Family, results: []const dns.LookupResult, ttl: u32, now: Timestamp) void {
        var key: CacheKey = undefined;
        CacheKey.init(&key, name, self.hash_seed, family);

        if (results.len == 0 or results.len > max_cached_addrs) {
            self.lock.lockUncancelable();
            defer self.lock.unlock();
            self.cache.expire(&key);
            return;
        }

        const ttl_secs = std.math.clamp(ttl, cache_ttl_min, cache_ttl_max);
        var entry: CacheEntry = .{
            .addrs = undefined,
            .count = @intCast(results.len),
            .expiry = now.addDuration(.fromSeconds(ttl_secs)),
        };
        for (results, 0..) |r, i| {
            entry.addrs[i] = r.address;
            entry.addrs[i].setPort(0);
        }

        self.lock.lockUncancelable();
        defer self.lock.unlock();
        self.cache.put(&key, entry, now);
    }

    fn maybeReloadHosts(self: *Resolver, now: Timestamp) void {
        const now_s: u32 = @truncate(now.toSeconds());
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

    fn maybeReloadResolvConf(self: *Resolver, now: Timestamp) void {
        const now_s: u32 = @truncate(now.toSeconds());
        if (now_s < self.conf_next_check.load(.monotonic)) return;

        if (self.conf_reloading.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return;
        defer self.conf_reloading.store(false, .release);

        self.conf_next_check.store(now_s +% check_interval_secs, .monotonic);

        const mtime = check_mtime: {
            const info = fs.stat("/etc/resolv.conf") catch |err| switch (err) {
                error.FileNotFound => break :check_mtime 0,
                else => return,
            };
            break :check_mtime info.mtime;
        };
        if (mtime == self.conf_mtime) return;

        var new_mtime: i64 = 0;
        var new_conf = loadResolvConf(self.allocator, &new_mtime);
        if (new_conf.parse_error) {
            new_conf.deinit();
            return;
        }

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
            const response = exchange(server, query, &recv_buf, id, timeout) catch |err| {
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
    id: u16,
    timeout: Timeout,
) ![]u8 {
    const domain: os.net.Domain = switch (server.getFamily()) {
        .ipv4 => .ipv4,
        .ipv6 => .ipv6,
    };

    var sock = try net.Socket.open(.dgram, domain, .ip);
    defer sock.close();

    const deadline = timeout.toDeadline();
    _ = try sock.sendTo(.{ .ip = server }, query, deadline);
    const data = while (true) {
        const r = try sock.receiveFrom(recv_buf, deadline);
        if (sameEndpoint(r.from.ip, server)) break recv_buf[0..r.len];
        log.debug("dns: ignoring response from unexpected source", .{});
    };

    // TC bit (0x0200) in flags word at offset 2: retry with TCP.
    // Only upgrade when the ID matches — a spoofed packet with TC=1 and a
    // wrong ID would otherwise waste a TCP connection.
    if (data.len >= 4 and
        std.mem.readInt(u16, data[0..2], .big) == id and
        std.mem.readInt(u16, data[2..4], .big) & 0x0200 != 0)
    {
        return exchangeTcp(server, query, recv_buf, deadline);
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
        if (err == error.FileNotFound) {
            const conf = ResolvConf.default(allocator) catch |err2| {
                log.warn("dns: failed to init default ResolvConf: {}", .{err2});
                return .{ .arena = .init(allocator), .servers = &.{}, .search = &.{}, .parse_error = true };
            };
            mtime_out.* = 0;
            return conf;
        }
        log.warn("dns: failed to open /etc/resolv.conf: {}", .{err});
        return .{ .arena = .init(allocator), .servers = &.{}, .search = &.{}, .parse_error = true };
    };
    defer file.close();
    if (file.stat()) |info| {
        mtime_out.* = info.mtime;
    } else |_| {}
    var buf: [4096]u8 = undefined;
    var reader = file.reader(&buf);
    return ResolvConf.parse(allocator, &reader.interface) catch |err| {
        log.warn("dns: failed to parse /etc/resolv.conf: {}", .{err});
        return .{ .arena = .init(allocator), .servers = &.{}, .search = &.{}, .parse_error = true };
    };
}
