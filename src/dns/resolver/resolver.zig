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
const Cancelable = @import("../../common.zig").Cancelable;
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
const Shape = @import("cache.zig").Shape;
const max_entry_addrs = @import("cache.zig").max_entry_addrs;

// Maximum addresses parsed/returned per family within one batched query.
const max_addrs_per_family = dns.max_addrs_per_family;

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
    hosts_path: []const u8,
    hosts_mtime: i64,
    hosts_next_check: std.atomic.Value(u32),
    hosts_reloading: std.atomic.Value(bool),

    conf: ResolvConf,
    conf_path: []const u8,
    conf_mtime: i64,
    conf_next_check: std.atomic.Value(u32),
    conf_reloading: std.atomic.Value(bool),

    loaded: std.atomic.Value(bool),
    load_mutex: Mutex,

    cache: Cache,
    hash_seed: u64,
    rotate_index: std.atomic.Value(u32) = .init(0),

    prng_mutex: Mutex,
    prng: std.Random.DefaultPrng,

    dedup_buckets: [num_dedup_buckets]Bucket,

    pub fn init(allocator: std.mem.Allocator) Resolver {
        const now = getCurrentTime();
        var prng = std.Random.DefaultPrng.init(now.value);
        const hash_seed = prng.random().int(u64);
        return .{
            .allocator = allocator,
            .lock = .init,
            .hosts = .{ .arena = .init(allocator), .by_name = .empty },
            .hosts_path = "/etc/hosts",
            .hosts_mtime = 0,
            .hosts_next_check = .init(0),
            .hosts_reloading = .init(false),
            .conf = .{ .arena = .init(allocator), .servers = &.{}, .search = &.{} },
            .conf_path = "/etc/resolv.conf",
            .conf_mtime = 0,
            .conf_next_check = .init(0),
            .conf_reloading = .init(false),
            .loaded = .init(false),
            .load_mutex = .init,
            .cache = .init(),
            .hash_seed = hash_seed,
            .prng_mutex = .init,
            .prng = prng,
            .dedup_buckets = @splat(.{}),
        };
    }

    fn getDedupBucket(self: *Resolver, key: *const CacheKey) *Bucket {
        return &self.dedup_buckets[@as(usize, @truncate(key.hash)) & (num_dedup_buckets - 1)];
    }

    /// Whether a lookup for `key` is in flight. Call with the bucket mutex held.
    fn hasActive(bucket: *Bucket, key: *const CacheKey) bool {
        var it = bucket.waiters.head;
        while (it) |n| : (it = n.next) {
            if (n.is_active and n.key.eql(key)) return true;
        }
        return false;
    }

    /// Promotes the first joiner waiting on the same lookup as `node` to be its
    /// active requester, so the lookup survives `node` giving up; the other
    /// joiners keep waiting on the promoted one. Call with the bucket mutex held.
    fn handOff(bucket: *Bucket, node: *const WaiterNode) void {
        var it = bucket.waiters.head;
        while (it) |n| : (it = n.next) {
            if (n != node and !n.is_active and !n.done and n.key.eql(&node.key)) {
                n.is_active = true;
                n.cond.signal();
                return;
            }
        }
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
        // A name longer than the DNS limit is unresolvable and would overflow
        // the canonical-name buffer (sized to net.HostName.max_len) and the
        // cache key below, so reject it up front.
        if (options.name.len > net.HostName.max_len) return error.UnknownHostName;

        const now = getCurrentTime();
        try self.ensureLoaded(now);
        try self.maybeReloadHosts(now);
        try self.maybeReloadResolvConf(now);

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
                var i: usize = 0;
                if (addr_storage.len > 0) {
                    addr_storage[0] = .{ .address = addr };
                    i = 1;
                }
                if (cname_buf) |buf| {
                    storage[0] = .{ .canonical_name = .{ .bytes = buf[0..options.name.len] } };
                    return i + 1;
                }
                return i;
            }
            return error.AddressFamilyUnsupported;
        }
        if (net.IpAddress.parseIp6(options.name, options.port) catch null) |addr| {
            if (options.family == null or options.family == .ipv6) {
                var i: usize = 0;
                if (addr_storage.len > 0) {
                    addr_storage[0] = .{ .address = addr };
                    i = 1;
                }
                if (cname_buf) |buf| {
                    storage[0] = .{ .canonical_name = .{ .bytes = buf[0..options.name.len] } };
                    return i + 1;
                }
                return i;
            }
            return error.AddressFamilyUnsupported;
        }

        // 1. Check /etc/hosts
        {
            try self.lock.lockShared();
            defer self.lock.unlockShared();

            if (self.hosts.lookupByName(options.name)) |entry| {
                var i: usize = 0;
                // Track matches separately from what fits: a hosts entry that
                // matched the family filter must answer the lookup even when
                // nothing fits the buffer, rather than fall through to DNS.
                var matched = false;
                for (entry.addrs) |addr_in| {
                    if (options.family) |f| {
                        if (addr_in.getFamily() != f) continue;
                    }
                    matched = true;
                    if (i >= addr_storage.len) break;
                    var addr = addr_in;
                    addr.setPort(options.port);
                    addr_storage[i] = .{ .address = addr };
                    i += 1;
                }
                if (matched) {
                    if (cname_buf) |buf| {
                        const canonical_name = entry.canonical_name orelse options.name;
                        @memcpy(buf[0..canonical_name.len], canonical_name);
                        storage[0] = .{ .canonical_name = .{ .bytes = buf[0..canonical_name.len] } };
                        return i + 1;
                    }
                    return i;
                }
            }
        }

        // 2. RFC 6761 localhost names, which always resolve to the loopback addresses.
        if (isLocalhost(options.name)) {
            var i: usize = 0;
            if (options.family != .ipv4 and i < addr_storage.len) {
                addr_storage[i] = .{ .address = .initIp6(.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, options.port, 0, 0) };
                i += 1;
            }
            if (options.family != .ipv6 and i < addr_storage.len) {
                addr_storage[i] = .{ .address = .initIp4(.{ 127, 0, 0, 1 }, options.port) };
                i += 1;
            }
            if (cname_buf) |buf| {
                const canonical_name = "localhost";
                @memcpy(buf[0..canonical_name.len], canonical_name);
                storage[0] = .{ .canonical_name = .{ .bytes = buf[0..canonical_name.len] } };
                return i + 1;
            }
            return i;
        }

        // 3. DNS. The request shape (single family or dual-stack) drives a
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
            var cached: [max_entry_addrs]net.IpAddress = undefined;
            if (self.cache.get(&key, now, cached[0..])) |n| {
                const c = @min(n, storage.len);
                for (cached[0..c], storage[0..c]) |addr_in, *out| {
                    var addr = addr_in;
                    addr.setPort(options.port);
                    out.* = .{ .address = addr };
                }
                return .{ .count = c, .canonical_name_len = 0 };
            }
        }

        // 2. Deduplicate concurrent identical lookups (same name + shape).
        const bucket = self.getDedupBucket(&key);

        try bucket.mutex.lock();

        var node: WaiterNode = .{
            .key = key,
            .is_active = !hasActive(bucket, &key),
            .storage = storage,
            .canonical_name_buffer = options.canonical_name_buffer,
        };
        bucket.waiters.push(&node);

        if (!node.is_active) {
            // An identical lookup is already in flight — join it. If its
            // requester is canceled, it may promote this node to active instead.
            while (!node.done and !node.is_active) {
                node.cond.wait(&bucket.mutex) catch |err| {
                    if (node.is_active) handOff(bucket, &node);
                    _ = bucket.waiters.remove(&node);
                    bucket.mutex.unlock();
                    return err;
                };
            }
            if (node.done) {
                _ = bucket.waiters.remove(&node);
                bucket.mutex.unlock();

                if (node.err) |err| return err;
                for (node.storage[0..node.count]) |*r| r.address.setPort(options.port);
                return .{ .count = node.count, .canonical_name_len = node.canonical_name_len };
            }
        }
        bucket.mutex.unlock();

        // Always resolve into an internal buffer sized for the full answer, so
        // what gets cached never depends on the caller's buffer; the caller
        // receives whatever prefix fits.
        var tmp: [max_entry_addrs]dns.LookupResult = undefined;
        const result = self.lookupDnsBatched(tmp[0..], opts, shape);

        if (result) |r| {
            const now_updated = getCurrentTime();
            self.cacheInsert(options.name, shape, tmp[0..r.count], r.truncated, r.ttl, now_updated);
        } else |_| {}

        // Notify all joiners, then remove the active node. A cancellation is
        // this requester's own, not an answer: pass the lookup on to a joiner.
        bucket.mutex.lockUncancelable();
        const canceled = if (result) |_| false else |err| err == error.Canceled;
        if (canceled) {
            handOff(bucket, &node);
        } else {
            var wit = bucket.waiters.head;
            while (wit) |n| : (wit = n.next) {
                if (n.is_active or n.done or !n.key.eql(&key)) continue;
                if (result) |r| {
                    const c = @min(r.count, n.storage.len);
                    @memcpy(n.storage[0..c], tmp[0..c]);
                    n.count = c;
                    n.canonical_name_len = r.canonical_name_len;
                    if (r.canonical_name_len > 0) if (n.canonical_name_buffer) |cbuf| {
                        @memcpy(cbuf[0..r.canonical_name_len], cname_buf[0..r.canonical_name_len]);
                    };
                    n.err = null;
                } else |err| {
                    n.count = 0;
                    n.err = err;
                }
                n.done = true;
                n.cond.signal();
            }
        }
        _ = bucket.waiters.remove(&node);
        bucket.mutex.unlock();

        const r = result catch |err| return err;
        if (r.canonical_name_len > 0) if (options.canonical_name_buffer) |cbuf| {
            @memcpy(cbuf[0..r.canonical_name_len], cname_buf[0..r.canonical_name_len]);
        };
        const c = @min(r.count, storage.len);
        @memcpy(storage[0..c], tmp[0..c]);
        return .{ .count = c, .canonical_name_len = r.canonical_name_len };
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
                    error.UnknownHostName => {},
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
                    error.UnknownHostName => {},
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
                    if (err != error.UnknownHostName) last_err = err;
                }
            }
        }

        return last_err;
    }

    fn cacheInsert(self: *Resolver, name: []const u8, shape: Shape, results: []const dns.LookupResult, truncated: bool, ttl: u32, now: Timestamp) void {
        var key: CacheKey = undefined;
        CacheKey.init(&key, name, self.hash_seed, shape);

        if (results.len == 0 or truncated) {
            self.lock.lockUncancelable();
            defer self.lock.unlock();
            self.cache.expire(&key);
            return;
        }

        const ttl_secs = std.math.clamp(ttl, cache_ttl_min, cache_ttl_max);
        var addrs: [max_entry_addrs]net.IpAddress = undefined;
        for (results, addrs[0..results.len]) |r, *out| {
            out.* = r.address;
            out.setPort(0);
        }

        self.lock.lockUncancelable();
        defer self.lock.unlock();
        self.cache.put(&key, addrs[0..results.len], now.addDuration(.fromSeconds(ttl_secs)), now);
    }

    /// Loads /etc/hosts and /etc/resolv.conf on first use. Concurrent first
    /// lookups wait for it; if the loading task is canceled, the next one loads.
    fn ensureLoaded(self: *Resolver, now: Timestamp) Cancelable!void {
        if (self.loaded.load(.acquire)) return;

        try self.load_mutex.lock();
        defer self.load_mutex.unlock();
        if (self.loaded.load(.monotonic)) return;

        // Without a previous table or configuration to keep, a failed load
        // starts empty; mtime 0 makes the next check retry it.
        var hosts_mtime: i64 = 0;
        var hosts = loadHosts(self.allocator, self.hosts_path, &hosts_mtime) catch |err| switch (err) {
            error.Canceled => |e| return e,
            error.LoadFailed => Hosts{ .arena = .init(self.allocator), .by_name = .empty },
        };
        errdefer hosts.deinit();
        var conf_mtime: i64 = 0;
        const conf = loadResolvConf(self.allocator, self.conf_path, &conf_mtime) catch |err| switch (err) {
            error.Canceled => |e| return e,
            error.LoadFailed => ResolvConf{ .arena = .init(self.allocator), .servers = &.{}, .search = &.{} },
        };

        self.hosts.deinit();
        self.hosts = hosts;
        self.hosts_mtime = hosts_mtime;
        self.conf.deinit();
        self.conf = conf;
        self.conf_mtime = conf_mtime;

        const next_check_s: u32 = @as(u32, @truncate(now.toSeconds())) +% check_interval_secs;
        self.hosts_next_check.store(next_check_s, .monotonic);
        self.conf_next_check.store(next_check_s, .monotonic);
        self.loaded.store(true, .release);
    }

    fn maybeReloadHosts(self: *Resolver, now: Timestamp) Cancelable!void {
        const now_s: u32 = @truncate(now.toSeconds());
        if (now_s < self.hosts_next_check.load(.monotonic)) return;

        if (self.hosts_reloading.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return;
        defer self.hosts_reloading.store(false, .release);

        self.hosts_next_check.store(now_s +% check_interval_secs, .monotonic);

        const info = fs.stat(self.hosts_path) catch |err| switch (err) {
            error.Canceled => |e| return e,
            else => return,
        };
        if (info.mtime == self.hosts_mtime) return;

        // A failed load keeps the current table and mtime, so the next check retries.
        var new_mtime: i64 = 0;
        const new_hosts = loadHosts(self.allocator, self.hosts_path, &new_mtime) catch |err| switch (err) {
            error.Canceled => |e| return e,
            error.LoadFailed => return,
        };

        self.lock.lockUncancelable();
        const old_hosts = self.hosts;
        self.hosts = new_hosts;
        self.hosts_mtime = new_mtime;
        self.lock.unlock();

        var old = old_hosts;
        old.deinit();
    }

    fn maybeReloadResolvConf(self: *Resolver, now: Timestamp) Cancelable!void {
        const now_s: u32 = @truncate(now.toSeconds());
        if (now_s < self.conf_next_check.load(.monotonic)) return;

        if (self.conf_reloading.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return;
        defer self.conf_reloading.store(false, .release);

        self.conf_next_check.store(now_s +% check_interval_secs, .monotonic);

        const mtime = check_mtime: {
            const info = fs.stat(self.conf_path) catch |err| switch (err) {
                error.FileNotFound => break :check_mtime 0,
                error.Canceled => |e| return e,
                else => return,
            };
            break :check_mtime info.mtime;
        };
        if (mtime == self.conf_mtime) return;

        // A failed load keeps the current configuration and mtime, so the next check retries.
        var new_mtime: i64 = 0;
        const new_conf = loadResolvConf(self.allocator, self.conf_path, &new_mtime) catch |err| switch (err) {
            error.Canceled => |e| return e,
            error.LoadFailed => return,
        };

        self.lock.lockUncancelable();
        const old_conf = self.conf;
        self.conf = new_conf;
        self.conf_mtime = new_mtime;
        self.lock.unlock();

        var old = old_conf;
        old.deinit();
    }
};

/// Whether `name` is `localhost` or a name under it, with or without the root dot.
fn isLocalhost(name: []const u8) bool {
    const bare = if (std.mem.endsWith(u8, name, ".")) name[0 .. name.len - 1] else name;
    const localhost = "localhost";
    if (!std.ascii.endsWithIgnoreCase(bare, localhost)) return false;
    return bare.len == localhost.len or bare[bare.len - localhost.len - 1] == '.';
}

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

const QueryResult = struct {
    count: usize,
    ttl: u32,
    canonical_name_len: usize = 0,
    // True when a family had more records than max_addrs_per_family; the
    // result is incomplete and must not be cached.
    truncated: bool = false,
};

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
    overflow: bool = false, // the answer had more records than `addrs` holds
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
        const built = message.buildQuery(&query_bufs[i], q.id, fqdn, q.qtype) catch return error.UnknownHostName;
        query_lens[i] = built.len;
    }

    var recv_buf: [65535]u8 = undefined;
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
            var sock = net.Socket.open(.dgram, domain, .ip) catch |err| {
                if (err == error.Canceled) return error.Canceled;
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
                            q.overflow = result.count > parse_addrs.len;
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
                    if (result.truncated) {
                        last_err = error.NameServerFailure;
                        continue;
                    }
                    const c = @min(result.count, parse_addrs.len);
                    @memcpy(q.addrs[0..c], parse_addrs[0..c]);
                    q.count = c;
                    q.overflow = result.count > parse_addrs.len;
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

    // Assemble the union of all families that found records, interleaved
    // IPv6-first (RFC 6724 preference), so a caller whose buffer is smaller
    // than the answer still sees both families. This runs before caching, so
    // a cache hit and a fresh lookup return the same order.
    var min_ttl: u32 = 0;
    var any_found = false;
    var any_overflow = false;
    var all_done = true;
    var v6: ?*FamilyQuery = null;
    var v4: ?*FamilyQuery = null;
    for (qs) |*q| {
        if (q.found) {
            if (q.qtype == .aaaa) v6 = q else v4 = q;
            min_ttl = if (!any_found) q.ttl else @min(min_ttl, q.ttl);
            any_found = true;
            if (q.overflow) any_overflow = true;
        }
        if (!q.done) all_done = false;
    }

    var total: usize = 0;
    var next6: usize = 0;
    var next4: usize = 0;
    var take6 = true;
    while (total < storage.len) {
        const rem6 = if (v6) |q| q.count - next6 else 0;
        const rem4 = if (v4) |q| q.count - next4 else 0;
        if (rem6 == 0 and rem4 == 0) break;
        // Alternate; once one family is exhausted, continue with the other.
        const use6 = if (rem6 == 0) false else if (rem4 == 0) true else take6;
        if (use6) {
            storage[total] = .{ .address = v6.?.addrs[next6] };
            next6 += 1;
        } else {
            storage[total] = .{ .address = v4.?.addrs[next4] };
            next4 += 1;
        }
        total += 1;
        take6 = !take6;
    }

    if (any_found) {
        return .{ .count = total, .ttl = min_ttl, .canonical_name_len = canonical_name_len, .truncated = any_overflow };
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

/// Reads and parses the hosts file at `path`, setting `mtime_out` only on success.
fn loadHosts(allocator: std.mem.Allocator, path: []const u8, mtime_out: *i64) (Cancelable || error{LoadFailed})!Hosts {
    const file = fs.openFile(path) catch |err| switch (err) {
        error.Canceled => |e| return e,
        else => {
            log.warn("dns: failed to open {s}: {}", .{ path, err });
            return error.LoadFailed;
        },
    };
    defer file.close();
    var mtime: i64 = 0;
    if (file.stat()) |info| {
        if (info.kind == .directory) {
            log.warn("dns: failed to read {s}: it is a directory", .{path});
            return error.LoadFailed;
        }
        mtime = info.mtime;
    } else |err| switch (err) {
        error.Canceled => |e| return e,
        else => {},
    }
    var buf: [4096]u8 = undefined;
    var reader = file.reader(&buf);
    const hosts = Hosts.parse(allocator, &reader.interface) catch |err| {
        if (reader.err) |read_err| if (read_err == error.Canceled) return error.Canceled;
        log.warn("dns: failed to parse {s}: {}", .{ path, err });
        return error.LoadFailed;
    };
    mtime_out.* = mtime;
    return hosts;
}

/// Reads and parses the resolver configuration at `path`, setting `mtime_out`
/// only on success. A file that is missing or that cannot be opened or read
/// for good is the default configuration.
fn loadResolvConf(allocator: std.mem.Allocator, path: []const u8, mtime_out: *i64) (Cancelable || error{LoadFailed})!ResolvConf {
    const file = fs.openFile(path) catch |err| switch (err) {
        error.Canceled => |e| return e,
        error.FileNotFound,
        error.NotDir,
        error.IsDir,
        error.SymLinkLoop,
        error.AccessDenied,
        error.PermissionDenied,
        => return defaultResolvConf(allocator, path, mtime_out),
        else => {
            log.warn("dns: failed to open {s}: {}", .{ path, err });
            return error.LoadFailed;
        },
    };
    defer file.close();
    var mtime: i64 = 0;
    if (file.stat()) |info| {
        if (info.kind == .directory) return defaultResolvConf(allocator, path, mtime_out);
        mtime = info.mtime;
    } else |err| switch (err) {
        error.Canceled => |e| return e,
        else => {},
    }
    var buf: [4096]u8 = undefined;
    var reader = file.reader(&buf);
    const conf = ResolvConf.parse(allocator, &reader.interface) catch |err| {
        if (err == error.Canceled) return error.Canceled;
        if (reader.err) |read_err| if (read_err == error.Canceled) return error.Canceled;
        log.warn("dns: failed to parse {s}: {}", .{ path, err });
        return error.LoadFailed;
    };
    mtime_out.* = mtime;
    return conf;
}

/// The configuration for a file that is not there to read. The mtime is that
/// of whatever is at `path`, so a reload waits for it to change.
fn defaultResolvConf(allocator: std.mem.Allocator, path: []const u8, mtime_out: *i64) (Cancelable || error{LoadFailed})!ResolvConf {
    var conf = ResolvConf.default(allocator) catch |err| {
        log.warn("dns: failed to init default ResolvConf: {}", .{err});
        return error.LoadFailed;
    };
    const info = fs.stat(path) catch |err| switch (err) {
        error.Canceled => |e| {
            conf.deinit();
            return e;
        },
        else => {
            mtime_out.* = 0;
            return conf;
        },
    };
    mtime_out.* = info.mtime;
    return conf;
}

// -- Tests --------------------------------------------------------------------

const Runtime = @import("../../runtime.zig").Runtime;
const yield = @import("../../runtime.zig").yield;
const Event = @import("../../sync/Event.zig");

/// Builds a DNS response for `query` with `num_answers` records of `qtype`,
/// each answer's name a compression pointer to the question. Addresses are
/// distinct: 10.0.x.x for A, 2001::x for AAAA.
fn buildTestResponse(out: []u8, query: []const u8, num_answers: u16, qtype: message.QType) usize {
    // Find the end of the question section (QNAME + QTYPE + QCLASS).
    var p: usize = 12;
    while (query[p] != 0) p += query[p] + 1;
    p += 1 + 4;
    const qend = p;

    @memcpy(out[0..2], query[0..2]); // id
    std.mem.writeInt(u16, out[2..4], 0x8180, .big); // QR + RD + RA, NOERROR
    std.mem.writeInt(u16, out[4..6], 1, .big); // QDCOUNT
    std.mem.writeInt(u16, out[6..8], num_answers, .big); // ANCOUNT
    std.mem.writeInt(u16, out[8..10], 0, .big); // NSCOUNT
    std.mem.writeInt(u16, out[10..12], 0, .big); // ARCOUNT
    @memcpy(out[12..qend], query[12..qend]);

    var w: usize = qend;
    for (0..num_answers) |i| {
        std.mem.writeInt(u16, out[w..][0..2], 0xC00C, .big); // name: ptr to question
        std.mem.writeInt(u16, out[w + 2 ..][0..2], @intFromEnum(qtype), .big);
        std.mem.writeInt(u16, out[w + 4 ..][0..2], 1, .big); // class IN
        std.mem.writeInt(u32, out[w + 6 ..][0..4], 60, .big); // ttl
        w += 10;
        switch (qtype) {
            .a => {
                std.mem.writeInt(u16, out[w..][0..2], 4, .big);
                out[w + 2] = 10;
                out[w + 3] = 0;
                out[w + 4] = @intCast((i >> 8) & 0xff);
                out[w + 5] = @intCast(i & 0xff);
                w += 6;
            },
            .aaaa => {
                std.mem.writeInt(u16, out[w..][0..2], 16, .big);
                @memset(out[w + 2 ..][0..16], 0);
                out[w + 2] = 0x20;
                out[w + 3] = 0x01;
                out[w + 16] = @intCast((i >> 8) & 0xff);
                out[w + 17] = @intCast(i & 0xff);
                w += 18;
            },
            _ => unreachable,
        }
    }
    return w;
}

/// Serves `num_queries` DNS queries on `sock`, answering A queries with
/// `num_a` records and AAAA queries with `num_aaaa`.
const TestDnsServer = struct {
    fn run(sock: net.Socket, num_a: u16, num_aaaa: u16, num_queries: usize) !void {
        var qbuf: [512]u8 = undefined;
        var rbuf: [4096]u8 = undefined;
        var served: usize = 0;
        while (served < num_queries) : (served += 1) {
            const r = try sock.receiveFrom(&qbuf, .none);
            var p: usize = 12;
            while (qbuf[p] != 0) p += qbuf[p] + 1;
            const qtype: message.QType = @enumFromInt(std.mem.readInt(u16, qbuf[p + 1 ..][0..2], .big));
            const n = if (qtype == .a) num_a else num_aaaa;
            const len = buildTestResponse(&rbuf, qbuf[0..r.len], n, qtype);
            _ = try sock.sendTo(r.from, rbuf[0..len], .none);
        }
    }
};

test "queryBatch: answer beyond the family buffer is capped and flagged, not an error" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const bind_addr = try net.IpAddress.parseIp4("127.0.0.1", 0);
    const sock = try bind_addr.bind(.{});
    defer sock.close();

    var server_task = try rt.spawn(TestDnsServer.run, .{ sock, 80, 0, 1 });
    defer server_task.cancel();

    var resolver = Resolver.init(std.testing.allocator);
    defer resolver.deinit();

    var storage: [2 * max_addrs_per_family]dns.LookupResult = undefined;
    const servers = [_]net.IpAddress{sock.address.ip};
    const r = try queryBatch(&resolver, storage[0..], .{ .name = "big.test", .port = 80 }, "big.test.", .ipv4, &servers, 1, .fromSeconds(5));

    try std.testing.expectEqual(max_addrs_per_family, r.count);
    try std.testing.expect(r.truncated);
    try server_task.join();
}

test "queryBatch: answer within the family buffer is complete and unflagged" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const bind_addr = try net.IpAddress.parseIp4("127.0.0.1", 0);
    const sock = try bind_addr.bind(.{});
    defer sock.close();

    var server_task = try rt.spawn(TestDnsServer.run, .{ sock, 12, 0, 1 });
    defer server_task.cancel();

    var resolver = Resolver.init(std.testing.allocator);
    defer resolver.deinit();

    var storage: [2 * max_addrs_per_family]dns.LookupResult = undefined;
    const servers = [_]net.IpAddress{sock.address.ip};
    const r = try queryBatch(&resolver, storage[0..], .{ .name = "big.test", .port = 80 }, "big.test.", .ipv4, &servers, 1, .fromSeconds(5));

    try std.testing.expectEqual(12, r.count);
    try std.testing.expect(!r.truncated);
    try server_task.join();
}

test "queryBatch: dual-stack answers interleave IPv6-first" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const bind_addr = try net.IpAddress.parseIp4("127.0.0.1", 0);
    const sock = try bind_addr.bind(.{});
    defer sock.close();

    var server_task = try rt.spawn(TestDnsServer.run, .{ sock, 3, 2, 2 });
    defer server_task.cancel();

    var resolver = Resolver.init(std.testing.allocator);
    defer resolver.deinit();

    var storage: [2 * max_addrs_per_family]dns.LookupResult = undefined;
    const servers = [_]net.IpAddress{sock.address.ip};
    const r = try queryBatch(&resolver, storage[0..], .{ .name = "dual.test", .port = 80 }, "dual.test.", .both, &servers, 1, .fromSeconds(5));

    try std.testing.expectEqual(5, r.count);
    const expected_families = [_]net.IpAddress.Family{ .ipv6, .ipv4, .ipv6, .ipv4, .ipv4 };
    for (storage[0..r.count], expected_families) |entry, family| {
        try std.testing.expectEqual(family, entry.address.getFamily());
    }
    try server_task.join();
}

/// Points the resolver at `servers` with one attempt, and keeps the system
/// files from being loaded or reloaded over it.
fn useTestConfig(resolver: *Resolver, servers: []net.IpAddress, timeout: Duration) void {
    resolver.conf.servers = servers;
    resolver.conf.timeout = timeout;
    resolver.conf.attempts = 1;
    resolver.hosts_next_check.store(std.math.maxInt(u32), .monotonic);
    resolver.conf_next_check.store(std.math.maxInt(u32), .monotonic);
    resolver.loaded.store(true, .monotonic);
}

/// Drops the first query, answers every later one with one A record.
const DroppingDnsServer = struct {
    fn run(sock: net.Socket, received: *std.atomic.Value(usize), first_received: *Event) !void {
        var qbuf: [512]u8 = undefined;
        var rbuf: [4096]u8 = undefined;
        while (true) {
            const r = try sock.receiveFrom(&qbuf, .none);
            if (received.fetchAdd(1, .monotonic) == 0) {
                first_received.set();
                continue;
            }
            const len = buildTestResponse(&rbuf, qbuf[0..r.len], 1, .a);
            _ = try sock.sendTo(r.from, rbuf[0..len], .none);
        }
    }
};

fn lookupDedupTest(resolver: *Resolver) !usize {
    var storage: [4]dns.LookupResult = undefined;
    return resolver.lookup(&storage, .{ .name = "dedup.test.", .port = 80, .family = .ipv4 });
}

fn countJoiners(bucket: *Bucket, key: *const CacheKey) !usize {
    try bucket.mutex.lock();
    defer bucket.mutex.unlock();
    var count: usize = 0;
    var it = bucket.waiters.head;
    while (it) |n| : (it = n.next) {
        if (!n.is_active and n.key.eql(key)) count += 1;
    }
    return count;
}

test "lookup: canceling the active requester hands the lookup to one joiner" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const bind_addr = try net.IpAddress.parseIp4("127.0.0.1", 0);
    const sock = try bind_addr.bind(.{});
    defer sock.close();

    var received: std.atomic.Value(usize) = .init(0);
    var first_received: Event = .init;
    var server_task = try rt.spawn(DroppingDnsServer.run, .{ sock, &received, &first_received });
    defer server_task.cancel();

    var resolver = Resolver.init(std.testing.allocator);
    defer resolver.deinit();
    var servers = [_]net.IpAddress{sock.address.ip};
    useTestConfig(&resolver, &servers, .fromSeconds(60));

    var key: CacheKey = undefined;
    CacheKey.init(&key, "dedup.test.", resolver.hash_seed, .ipv4);
    const bucket = resolver.getDedupBucket(&key);

    var active = try rt.spawn(lookupDedupTest, .{&resolver});
    defer active.cancel();
    try first_received.wait();

    var joiner1 = try rt.spawn(lookupDedupTest, .{&resolver});
    defer joiner1.cancel();
    var joiner2 = try rt.spawn(lookupDedupTest, .{&resolver});
    defer joiner2.cancel();
    while (try countJoiners(bucket, &key) < 2) try yield();

    active.cancel();
    try std.testing.expectError(error.Canceled, active.join());

    try std.testing.expectEqual(1, try joiner1.join());
    try std.testing.expectEqual(1, try joiner2.join());
    try std.testing.expectEqual(2, received.load(.monotonic));
}

fn lookupReloadTest(resolver: *Resolver) !usize {
    var storage: [4]dns.LookupResult = undefined;
    return resolver.lookup(&storage, .{ .name = "reload.test.", .port = 80, .family = .ipv4 });
}

test "lookup: cancellation during a config reload is propagated" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    // A server that never answers, so a lookup that ignores the cancel fails differently.
    const bind_addr = try net.IpAddress.parseIp4("127.0.0.1", 0);
    const sock = try bind_addr.bind(.{});
    defer sock.close();

    var resolver = Resolver.init(std.testing.allocator);
    defer resolver.deinit();
    var servers = [_]net.IpAddress{sock.address.ip};
    useTestConfig(&resolver, &servers, .fromSeconds(1));
    resolver.hosts_next_check.store(0, .monotonic);

    var task = try rt.spawn(lookupReloadTest, .{&resolver});
    task.cancel();
    try std.testing.expectError(error.Canceled, task.join());
}

test "lookup: cancellation during the first config load is propagated" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var resolver = Resolver.init(std.testing.allocator);
    defer resolver.deinit();

    var task = try rt.spawn(lookupReloadTest, .{&resolver});
    task.cancel();
    try std.testing.expectError(error.Canceled, task.join());
    try std.testing.expect(!resolver.loaded.load(.monotonic));

    var storage: [1]dns.LookupResult = undefined;
    try std.testing.expectEqual(1, try resolver.lookup(&storage, .{ .name = "127.0.0.1", .port = 80 }));
    try std.testing.expect(resolver.loaded.load(.monotonic));
}

fn writeTestFile(dir: fs.Dir, name: []const u8, contents: []const u8) !void {
    const file = try dir.createFile(name, .{ .truncate = true });
    defer file.close();
    try std.testing.expectEqual(contents.len, try file.write(contents, 0));
}

fn expectHostsEntry(resolver: *Resolver) !void {
    var storage: [4]dns.LookupResult = undefined;
    const n = try resolver.lookup(&storage, .{ .name = "foo.test", .port = 80, .family = .ipv4 });
    try std.testing.expectEqual(1, n);
    try std.testing.expect(sameEndpoint(storage[0].address, try net.IpAddress.parseIp4("10.1.2.3", 80)));
}

test "lookup: a failed hosts reload keeps the current table" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const parent = try fs.Dir.cwd().openDir(".", .{});
    defer parent.close();
    var temp = try parent.createTempDir(.{ .prefix = "zio_test_" });
    defer temp.deinit();
    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/hosts", .{temp.name()});

    try writeTestFile(temp.dir, "hosts", "10.1.2.3 foo.test\n");

    // A server that never answers, so a lookup that falls through to DNS fails.
    const bind_addr = try net.IpAddress.parseIp4("127.0.0.1", 0);
    const sock = try bind_addr.bind(.{});
    defer sock.close();

    var resolver = Resolver.init(std.testing.allocator);
    defer resolver.deinit();
    var servers = [_]net.IpAddress{sock.address.ip};
    useTestConfig(&resolver, &servers, .fromMilliseconds(100));
    resolver.hosts_path = path;

    resolver.hosts_next_check.store(0, .monotonic);
    try expectHostsEntry(&resolver);

    // A directory opens, and on some systems (NetBSD) even reads.
    try temp.dir.deleteFile("hosts");
    try temp.dir.createDir("hosts", 0o755);

    resolver.hosts_mtime = 0;
    resolver.hosts_next_check.store(0, .monotonic);
    try expectHostsEntry(&resolver);
}

test "lookup: a resolv.conf reload skips an invalid nameserver" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const parent = try fs.Dir.cwd().openDir(".", .{});
    defer parent.close();
    var temp = try parent.createTempDir(.{ .prefix = "zio_test_" });
    defer temp.deinit();
    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/resolv.conf", .{temp.name()});

    try writeTestFile(temp.dir, "resolv.conf", "nameserver fe80::1%nonexistent0\nnameserver 10.0.0.1\noptions ndots:3\n");

    var resolver = Resolver.init(std.testing.allocator);
    defer resolver.deinit();
    var servers = [_]net.IpAddress{try net.IpAddress.parseIp4("127.0.0.1", 53)};
    useTestConfig(&resolver, &servers, .fromSeconds(1));
    resolver.conf_path = path;
    resolver.conf_next_check.store(0, .monotonic);

    try resolver.maybeReloadResolvConf(getCurrentTime());

    try std.testing.expect(resolver.conf_mtime != 0);
    try std.testing.expectEqual(3, resolver.conf.ndots);
    try std.testing.expectEqual(1, resolver.conf.servers.len);
    try std.testing.expect(sameEndpoint(resolver.conf.servers[0], try net.IpAddress.parseIp4("10.0.0.1", 53)));
}

test "lookup: an unreadable resolv.conf starts with the default servers" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const parent = try fs.Dir.cwd().openDir(".", .{});
    defer parent.close();
    var temp = try parent.createTempDir(.{ .prefix = "zio_test_" });
    defer temp.deinit();
    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/resolv.conf", .{temp.name()});
    try temp.dir.createDir("resolv.conf", 0o755);

    var resolver = Resolver.init(std.testing.allocator);
    defer resolver.deinit();
    resolver.hosts_path = path;
    resolver.conf_path = path;

    try resolver.ensureLoaded(getCurrentTime());

    try std.testing.expectEqual((try fs.stat(path)).mtime, resolver.conf_mtime);
    try std.testing.expectEqual(2, resolver.conf.servers.len);
    try std.testing.expect(sameEndpoint(resolver.conf.servers[0], try net.IpAddress.parseIp4("127.0.0.1", 53)));
    try std.testing.expect(sameEndpoint(resolver.conf.servers[1], try net.IpAddress.parseIp6("::1", 53)));
}

test "lookup: a name that does not encode is an unknown host" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var resolver = Resolver.init(std.testing.allocator);
    defer resolver.deinit();
    var servers = [_]net.IpAddress{try net.IpAddress.parseIp4("127.0.0.1", 53)};
    useTestConfig(&resolver, &servers, .fromSeconds(1));

    var storage: [4]dns.LookupResult = undefined;
    try std.testing.expectError(error.UnknownHostName, resolver.lookup(&storage, .{ .name = "a..test", .port = 80 }));
    try std.testing.expectError(error.UnknownHostName, resolver.lookup(&storage, .{ .name = "a..test.", .port = 80 }));
}

test "lookup: a hosts entry reports the first name on its line as canonical" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var resolver = Resolver.init(std.testing.allocator);
    defer resolver.deinit();
    var servers = [_]net.IpAddress{try net.IpAddress.parseIp4("127.0.0.1", 53)};
    useTestConfig(&resolver, &servers, .fromSeconds(1));

    var reader = std.Io.Reader.fixed("10.1.2.3 main.test alias.test\n");
    resolver.hosts.deinit();
    resolver.hosts = try Hosts.parse(std.testing.allocator, &reader);

    var cname_buf: [net.HostName.max_len]u8 = undefined;
    var storage: [4]dns.LookupResult = undefined;
    const n = try resolver.lookup(&storage, .{ .name = "Alias.Test", .port = 80, .canonical_name_buffer = &cname_buf });
    try std.testing.expectEqual(2, n);
    try std.testing.expectEqualStrings("main.test", storage[0].canonical_name.bytes);
    try std.testing.expect(sameEndpoint(storage[1].address, try net.IpAddress.parseIp4("10.1.2.3", 80)));
}

test "isLocalhost" {
    try std.testing.expect(isLocalhost("localhost"));
    try std.testing.expect(isLocalhost("localhost."));
    try std.testing.expect(isLocalhost("LocalHost"));
    try std.testing.expect(isLocalhost("foo.localhost"));
    try std.testing.expect(isLocalhost("a.b.LOCALHOST."));
    try std.testing.expect(!isLocalhost("xlocalhost"));
    try std.testing.expect(!isLocalhost("foo.xlocalhost."));
    try std.testing.expect(!isLocalhost("localhost.com"));
    try std.testing.expect(!isLocalhost("localhost.."));
    try std.testing.expect(!isLocalhost("."));
    try std.testing.expect(!isLocalhost(""));
}

test "lookup: localhost names resolve to the loopback addresses without DNS" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    // A server that never answers, so a lookup that reaches DNS fails.
    const bind_addr = try net.IpAddress.parseIp4("127.0.0.1", 0);
    const sock = try bind_addr.bind(.{});
    defer sock.close();

    var resolver = Resolver.init(std.testing.allocator);
    defer resolver.deinit();
    var servers = [_]net.IpAddress{sock.address.ip};
    useTestConfig(&resolver, &servers, .fromMilliseconds(100));

    var cname_buf: [net.HostName.max_len]u8 = undefined;
    var storage: [4]dns.LookupResult = undefined;
    const n = try resolver.lookup(&storage, .{ .name = "App.LocalHost.", .port = 80, .canonical_name_buffer = &cname_buf });
    try std.testing.expectEqual(3, n);
    try std.testing.expectEqualStrings("localhost", storage[0].canonical_name.bytes);
    try std.testing.expect(sameEndpoint(storage[1].address, try net.IpAddress.parseIp6("::1", 80)));
    try std.testing.expect(sameEndpoint(storage[2].address, try net.IpAddress.parseIp4("127.0.0.1", 80)));

    try std.testing.expectEqual(1, try resolver.lookup(&storage, .{ .name = "foo.localhost", .port = 80, .family = .ipv4 }));
    try std.testing.expect(sameEndpoint(storage[0].address, try net.IpAddress.parseIp4("127.0.0.1", 80)));

    try std.testing.expectError(error.TemporaryNameServerFailure, resolver.lookup(&storage, .{ .name = "xlocalhost.", .port = 80 }));
}
