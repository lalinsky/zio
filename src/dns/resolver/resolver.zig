// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

const std = @import("std");
const dns = @import("../root.zig");
const fs = @import("../../fs.zig");
const net = @import("../../net.zig");
const os = @import("../../os/root.zig");
const getCurrentExecutorOrNull = @import("../../runtime.zig").getCurrentExecutorOrNull;
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
const Shape = @import("cache.zig").Shape;
const max_cached_addrs = @import("cache.zig").max_cached_addrs;

// Maximum addresses parsed/returned per family within one batched query.
const max_addrs_per_family = 8;

const num_dedup_buckets = 64;

const WaiterNode = struct {
    next: ?*WaiterNode = null,
    prev: ?*WaiterNode = null,
    in_list: if (std.debug.runtime_safety) bool else void = if (std.debug.runtime_safety) false else {},
    key: CacheKey,
    is_active: bool,
    storage: []dns.LookupResult,
    count: usize = 0,
    canonical_name_buffer: ?*[net.HostName.max_len]u8 = null,
    canonical_name_len: usize = 0,
    err: ?dns.LookupError = null,
    done: bool = false,
    cond: Condition = .init,
};

const Bucket = struct {
    mutex: Mutex = .init,
    waiters: SimpleQueue(WaiterNode) = .empty,
};

fn getCurrentTime() Timestamp {
    if (getCurrentExecutorOrNull()) |exec| {
        return exec.loop.now();
    }
    return Timestamp.now(.monotonic);
}

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
        const now = getCurrentTime();
        const next_check_s: u32 = @as(u32, @truncate(now.toSeconds())) +% check_interval_secs;
        var prng = std.Random.DefaultPrng.init(now.value);
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
        const now = getCurrentTime();
        self.maybeReloadHosts(now);
        self.maybeReloadResolvConf(now);

        // When canonical name is requested, reserve storage[0] for it and use
        // storage[1..] for addresses. Pre-fill the buffer with the queried name
        // as the default; the DNS path may overwrite it with a real CNAME target.
        const cname_buf = options.canonical_name_buffer;
        if (cname_buf) |buf| {
            const len = @min(options.name.len, buf.len);
            @memcpy(buf[0..len], options.name[0..len]);
        }
        const addr_storage = if (cname_buf != null and storage.len > 0) storage[1..] else storage;
        if (cname_buf != null and storage.len == 0) return 0;

        // 0. Numeric IP literal — parse directly without touching hosts or DNS.
        if (net.IpAddress.parseIp4(options.name, options.port) catch null) |addr| {
            if (options.family == null or options.family == .ipv4) {
                if (addr_storage.len == 0) return error.TooManyAddresses;
                addr_storage[0] = .{ .address = addr };
                if (cname_buf) |buf| {
                    storage[0] = .{ .canonical_name = .{ .bytes = buf[0..options.name.len] } };
                    return 2;
                }
                return 1;
            }
            return error.AddressFamilyUnsupported;
        }
        if (net.IpAddress.parseIp6(options.name, options.port) catch null) |addr| {
            if (options.family == null or options.family == .ipv6) {
                if (addr_storage.len == 0) return error.TooManyAddresses;
                addr_storage[0] = .{ .address = addr };
                if (cname_buf) |buf| {
                    storage[0] = .{ .canonical_name = .{ .bytes = buf[0..options.name.len] } };
                    return 2;
                }
                return 1;
            }
            return error.AddressFamilyUnsupported;
        }

        // 1. Check /etc/hosts
        {
            try self.lock.lockShared();
            defer self.lock.unlockShared();

            if (self.hosts.lookupByName(options.name)) |addrs| {
                var i: usize = 0;
                for (addrs) |addr_in| {
                    if (options.family) |f| {
                        if (addr_in.getFamily() != f) continue;
                    }
                    if (i >= addr_storage.len) return error.TooManyAddresses;
                    var addr = addr_in;
                    addr.setPort(options.port);
                    addr_storage[i] = .{ .address = addr };
                    i += 1;
                }
                if (i > 0) {
                    if (cname_buf) |buf| {
                        storage[0] = .{ .canonical_name = .{ .bytes = buf[0..options.name.len] } };
                        return i + 1;
                    }
                    return i;
                }
            }
        }

        // 2. DNS. The request shape (single family or dual-stack) drives a
        // single cache/dedup unit and a single batched query.
        const shape: Shape = if (options.family) |f| switch (f) {
            .ipv4 => .ipv4,
            .ipv6 => .ipv6,
        } else .both;

        const r = try self.lookupShape(addr_storage, options, shape, now);
        if (cname_buf) |buf| {
            const len = if (r.canonical_name_len > 0) r.canonical_name_len else options.name.len;
            storage[0] = .{ .canonical_name = .{ .bytes = buf[0..len] } };
            return r.count + 1;
        }
        return r.count;
    }

    const ShapeResult = struct { count: usize, canonical_name_len: usize };

    /// Resolve one request shape through its cache/dedup/DNS path. The whole
    /// shape (e.g. A+AAAA for a dual-stack lookup) is one coalescing unit.
    fn lookupShape(
        self: *Resolver,
        storage: []dns.LookupResult,
        options: dns.LookupOptions,
        shape: Shape,
        now: Timestamp,
    ) dns.LookupError!ShapeResult {
        var opts = options;
        // Always decode the canonical name into a local buffer so waiters
        // receive it regardless of whether the active requester asked for one.
        var cname_buf: [net.HostName.max_len]u8 = undefined;
        opts.canonical_name_buffer = &cname_buf;

        var key: CacheKey = undefined;
        CacheKey.init(&key, options.name, self.hash_seed, shape);

        // 1. Check DNS cache.
        {
            try self.lock.lockShared();
            defer self.lock.unlockShared();
            if (self.cache.get(&key, now)) |entry| {
                var i: usize = 0;
                for (entry.addrs[0..entry.count]) |addr_in| {
                    if (i >= storage.len) return error.TooManyAddresses;
                    var addr = addr_in;
                    addr.setPort(options.port);
                    storage[i] = .{ .address = addr };
                    i += 1;
                }
                if (i > 0) return .{ .count = i, .canonical_name_len = 0 };
            }
        }

        // 2. Deduplicate concurrent identical lookups (same name + shape).
        const bucket = self.getDedupBucket(&key);

        try bucket.mutex.lock();

        var it = bucket.waiters.head;
        while (it) |n| : (it = n.next) {
            if (n.is_active and n.key.eql(&key)) {
                // An identical lookup is already in flight — join it.
                var node: WaiterNode = .{
                    .key = key,
                    .is_active = false,
                    .storage = storage,
                    .canonical_name_buffer = options.canonical_name_buffer,
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
                return .{ .count = node.count, .canonical_name_len = node.canonical_name_len };
            }
        }

        // No in-flight lookup for this name+shape — become the active requester.
        var active_node: WaiterNode = .{
            .key = key,
            .is_active = true,
            .storage = storage,
        };
        bucket.waiters.push(&active_node);
        bucket.mutex.unlock();

        var tmp: [2 * max_addrs_per_family]dns.LookupResult = undefined;
        const buf: []dns.LookupResult = if (storage.len >= tmp.len) storage else tmp[0..];
        const result = self.lookupDnsBatched(buf, opts, shape);

        if (result) |r| {
            const now_updated = getCurrentTime();
            self.cacheInsert(options.name, shape, buf[0..r.count], r.ttl, now_updated);
        } else |_| {}

        // Notify all joiners, then remove the active node.
        bucket.mutex.lockUncancelable();
        var wit = bucket.waiters.head;
        while (wit) |n| : (wit = n.next) {
            if (!n.is_active and !n.done and n.key.eql(&key)) {
                if (result) |r| {
                    if (r.count > n.storage.len) {
                        n.err = error.TooManyAddresses;
                    } else {
                        @memcpy(n.storage[0..r.count], buf[0..r.count]);
                        n.count = r.count;
                        n.canonical_name_len = r.canonical_name_len;
                        if (r.canonical_name_len > 0) if (n.canonical_name_buffer) |cbuf| {
                            @memcpy(cbuf[0..r.canonical_name_len], cname_buf[0..r.canonical_name_len]);
                        };
                        n.err = null;
                    }
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
        if (r.canonical_name_len > 0) if (options.canonical_name_buffer) |cbuf| {
            @memcpy(cbuf[0..r.canonical_name_len], cname_buf[0..r.canonical_name_len]);
        };
        if (buf.ptr != storage.ptr) {
            if (r.count > storage.len) return error.TooManyAddresses;
            @memcpy(storage[0..r.count], buf[0..r.count]);
            return .{ .count = r.count, .canonical_name_len = r.canonical_name_len };
        }
        return .{ .count = r.count, .canonical_name_len = r.canonical_name_len };
    }

    fn lookupDnsBatched(
        self: *Resolver,
        storage: []dns.LookupResult,
        options: dns.LookupOptions,
        shape: Shape,
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
        var fqdn_buf: [256]u8 = undefined;
        var last_err: dns.LookupError = error.UnknownHostName;

        // Rooted name: only try exactly as given.
        if (rooted) {
            const r = try queryBatch(self, storage, options, name, shape, srvs, attempts, timeout);
            if (r.count == 0) return error.UnknownHostName;
            return r;
        }

        var dot_count: usize = 0;
        for (name) |c| {
            if (c == '.') dot_count += 1;
        }
        const has_enough_dots = dot_count >= ndots;

        // Enough dots: try unsuffixed first (Go's nameList logic).
        if (has_enough_dots) {
            if (makeFqdn(&fqdn_buf, name, null)) |fqdn| {
                if (queryBatch(self, storage, options, fqdn, shape, srvs, attempts, timeout)) |r| {
                    if (r.count > 0) return r;
                } else |err| switch (err) {
                    error.Canceled => return err,
                    else => last_err = err,
                }
            }
        }

        // Try with each search domain.
        for (0..search_count) |i| {
            const suffix = search_store[i][0..search_lens[i]];
            if (makeFqdn(&fqdn_buf, name, suffix)) |fqdn| {
                if (queryBatch(self, storage, options, fqdn, shape, srvs, attempts, timeout)) |r| {
                    if (r.count > 0) return r;
                } else |err| switch (err) {
                    error.Canceled => return err,
                    else => last_err = err,
                }
            }
        }

        // Not enough dots: try unsuffixed last.
        if (!has_enough_dots) {
            if (makeFqdn(&fqdn_buf, name, null)) |fqdn| {
                if (queryBatch(self, storage, options, fqdn, shape, srvs, attempts, timeout)) |r| {
                    if (r.count > 0) return r;
                } else |err| {
                    last_err = err;
                }
            }
        }

        return last_err;
    }

    fn cacheInsert(self: *Resolver, name: []const u8, shape: Shape, results: []const dns.LookupResult, ttl: u32, now: Timestamp) void {
        var key: CacheKey = undefined;
        CacheKey.init(&key, name, self.hash_seed, shape);

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

const QueryResult = struct { count: usize, ttl: u32, canonical_name_len: usize = 0 };

/// Per-family state tracked across the attempts × servers loop of one batched
/// query. A query is `done` once it reaches a terminal state (records found or
/// a definitive empty answer); temporary failures leave it pending for retry.
const FamilyQuery = struct {
    qtype: message.QType,
    id: u16,
    done: bool = false,
    found: bool = false,
    truncated: bool = false,
    answered: bool = false, // got a response this send-round (for recv accounting)
    addrs: [max_addrs_per_family]net.IpAddress = undefined,
    count: usize = 0,
    ttl: u32 = 0,
};

/// Query all needed families for one FQDN over a single UDP socket per server,
/// demultiplexing responses by query id. Returns the union of addresses found.
///
/// Semantics (matching Go/c-ares dual-stack behavior):
///   - count > 0  → at least one family had records at this name; stop searching.
///   - count == 0 → every family answered definitively with no records
///                  (NODATA/NXDOMAIN); caller advances to the next candidate.
///   - error      → a family never got a definitive answer (all temp failures).
fn queryBatch(
    self: *Resolver,
    storage: []dns.LookupResult,
    options: dns.LookupOptions,
    fqdn: []const u8,
    shape: Shape,
    servers: []const net.IpAddress,
    attempts: u8,
    timeout: Duration,
) dns.LookupError!QueryResult {
    var queries: [2]FamilyQuery = undefined;
    var nq: usize = 0;
    if (shape != .ipv6) {
        queries[nq] = .{ .qtype = .a, .id = self.nextQueryId() };
        nq += 1;
    }
    if (shape != .ipv4) {
        var id = self.nextQueryId();
        // Keep ids distinct so demux is unambiguous.
        if (nq > 0 and id == queries[0].id) id +%= 1;
        queries[nq] = .{ .qtype = .aaaa, .id = id };
        nq += 1;
    }
    const qs = queries[0..nq];

    // Build the query packets once; ids are stable across retries.
    var query_bufs: [2][message.max_udp_size]u8 = undefined;
    var query_lens: [2]usize = undefined;
    for (qs, 0..) |*q, i| {
        const built = message.buildQuery(&query_bufs[i], q.id, fqdn, q.qtype) catch return error.Unexpected;
        query_lens[i] = built.len;
    }

    var recv_buf: [4096]u8 = undefined;
    var parse_addrs: [max_addrs_per_family]net.IpAddress = undefined;

    // The canonical name is decoded from the first family that yields records.
    const cname_out: ?[]u8 = if (options.canonical_name_buffer) |b| b[0..] else null;
    var canonical_name_len: usize = 0;

    var last_err: dns.LookupError = error.TemporaryNameServerFailure;

    attempt_loop: for (0..attempts) |_| {
        for (servers) |server| {
            var any_pending = false;
            for (qs) |*q| {
                q.answered = false;
                if (!q.done) any_pending = true;
            }
            if (!any_pending) break :attempt_loop;

            const domain: os.net.Domain = switch (server.getFamily()) {
                .ipv4 => .ipv4,
                .ipv6 => .ipv6,
            };
            var sock = net.Socket.open(.dgram, domain, .ip) catch {
                last_err = error.TemporaryNameServerFailure;
                continue;
            };
            defer sock.close();

            const deadline = (Timeout{ .duration = timeout }).toDeadline();

            // Send all pending queries to this server on the one socket.
            var sent = false;
            for (qs, 0..) |*q, i| {
                if (q.done) continue;
                _ = sock.sendTo(.{ .ip = server }, query_bufs[i][0..query_lens[i]], deadline) catch |err| {
                    if (err == error.Canceled) return error.Canceled;
                    continue;
                };
                sent = true;
            }
            if (!sent) {
                last_err = error.TemporaryNameServerFailure;
                continue;
            }

            // Receive and demux until every pending query answered this round
            // or the deadline hits (unanswered families retry on the next server).
            while (true) {
                var still_waiting = false;
                for (qs) |*q| {
                    if (!q.done and !q.answered) still_waiting = true;
                }
                if (!still_waiting) break;

                const r = sock.receiveFrom(&recv_buf, deadline) catch |err| {
                    if (err == error.Canceled) return error.Canceled;
                    break;
                };
                if (!sameEndpoint(r.from.ip, server)) continue;
                if (r.len < 2) continue;
                const resp_id = std.mem.readInt(u16, recv_buf[0..2], .big);

                var qi: ?usize = null;
                for (qs, 0..) |*q, i| {
                    if (!q.done and !q.answered and q.id == resp_id) {
                        qi = i;
                        break;
                    }
                }
                const idx = qi orelse continue; // unknown / duplicate / stale
                const q = &qs[idx];

                const result = message.parseResponse(
                    recv_buf[0..r.len],
                    q.id,
                    q.qtype,
                    &parse_addrs,
                    options.port,
                    if (canonical_name_len == 0) cname_out else null,
                ) catch {
                    last_err = error.NameServerFailure;
                    q.answered = true; // got a (bad) response; retry on next server
                    continue;
                };

                q.answered = true;
                switch (result.rcode) {
                    .no_error => {
                        if (result.truncated) {
                            // Partial UDP payload — defer to TCP below.
                            q.truncated = true;
                            q.done = true;
                        } else {
                            const c = @min(result.count, parse_addrs.len);
                            @memcpy(q.addrs[0..c], parse_addrs[0..c]);
                            q.count = c;
                            q.ttl = result.ttl;
                            q.found = c > 0;
                            q.done = true;
                            if (q.found and canonical_name_len == 0 and result.canonical_name_len > 0) {
                                canonical_name_len = result.canonical_name_len;
                            }
                        }
                    },
                    .nx_domain => {
                        q.count = 0;
                        q.found = false;
                        q.done = true;
                    },
                    .serv_fail => last_err = error.TemporaryNameServerFailure,
                    else => last_err = error.NameServerFailure,
                }
            }
        }
    }

    // TCP fallback for any truncated family.
    for (qs, 0..) |*q, i| {
        if (!q.truncated) continue;
        q.truncated = false;
        var resolved = false;
        for (servers) |server| {
            const deadline = (Timeout{ .duration = timeout }).toDeadline();
            const resp = exchangeTcp(server, query_bufs[i][0..query_lens[i]], &recv_buf, deadline) catch |err| {
                if (err == error.Canceled) return error.Canceled;
                last_err = error.TemporaryNameServerFailure;
                continue;
            };
            const result = message.parseResponse(
                resp,
                q.id,
                q.qtype,
                &parse_addrs,
                options.port,
                if (canonical_name_len == 0) cname_out else null,
            ) catch {
                last_err = error.NameServerFailure;
                continue;
            };
            switch (result.rcode) {
                .no_error => {
                    const c = @min(result.count, parse_addrs.len);
                    @memcpy(q.addrs[0..c], parse_addrs[0..c]);
                    q.count = c;
                    q.ttl = result.ttl;
                    q.found = c > 0;
                    if (q.found and canonical_name_len == 0 and result.canonical_name_len > 0) {
                        canonical_name_len = result.canonical_name_len;
                    }
                    resolved = true;
                },
                .nx_domain => {
                    q.count = 0;
                    q.found = false;
                    resolved = true;
                },
                .serv_fail => {
                    last_err = error.TemporaryNameServerFailure;
                    continue;
                },
                else => {
                    last_err = error.NameServerFailure;
                    continue;
                },
            }
            break;
        }
        // No definitive TCP answer — keep the family pending so the batch
        // reports a temporary failure instead of a false empty result.
        if (!resolved) q.done = false;
    }

    // Assemble the union of all families that found records.
    var total: usize = 0;
    var min_ttl: u32 = 0;
    var any_found = false;
    var all_done = true;
    for (qs) |*q| {
        if (q.found) {
            for (q.addrs[0..q.count]) |a| {
                if (total >= storage.len) break;
                storage[total] = .{ .address = a };
                total += 1;
            }
            min_ttl = if (!any_found) q.ttl else @min(min_ttl, q.ttl);
            any_found = true;
        }
        if (!q.done) all_done = false;
    }

    if (any_found) {
        return .{ .count = total, .ttl = min_ttl, .canonical_name_len = canonical_name_len };
    }
    if (all_done) {
        // Every family answered definitively with no records → advance candidate.
        return .{ .count = 0, .ttl = 0, .canonical_name_len = 0 };
    }
    // At least one family never reached a definitive answer.
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
