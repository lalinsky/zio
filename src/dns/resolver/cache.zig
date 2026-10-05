// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

const std = @import("std");
const dns = @import("../root.zig");
const net = @import("../../net.zig");
const Timestamp = @import("../../time.zig").Timestamp;

const cache_capacity = 1024;
const probe_limit = 8;
pub const key_prefix_len = 22;

// Addresses are stored in fixed chunks drawn from a shared pool, so one entry
// can hold anything from a single address up to a full dual-stack answer
// without inflating every slot to the maximum.
const addrs_per_node = 4;
const node_count = 1024;
const none = std.math.maxInt(u16);

/// The largest answer one entry can hold: both families at the resolver's
/// per-family cap. Results larger than this are never offered to the cache.
pub const max_entry_addrs = 2 * dns.max_addrs_per_family;

const max_entry_nodes = (max_entry_addrs + addrs_per_node - 1) / addrs_per_node;

comptime {
    // `put` must never fail: a full sweep releases every node in the pool, so
    // as long as the pool can hold one maximal entry, reclaim always frees
    // enough.
    if (node_count < max_entry_nodes) @compileError("node pool smaller than one maximal entry");
    if (node_count >= none) @compileError("node indices must fit u16 with a sentinel");
    if (max_entry_addrs > std.math.maxInt(u8)) @compileError("CacheSlot.count cannot hold a maximal entry");
}

/// The shape of a lookup request. Cache and dedup are keyed by shape so that a
/// dual-stack ("both") lookup is a single unit — resolved against one search
/// suffix, cached and coalesced as a whole — which keeps A and AAAA consistent.
pub const Shape = enum(u8) {
    ipv4 = 1,
    ipv6 = 2,
    both = 3,
};

pub const CacheKey = struct {
    len: u8,
    shape: u8,
    prefix: [key_prefix_len]u8,
    hash: u64,

    pub fn init(key: *CacheKey, name: []const u8, seed: u64, shape: Shape) void {
        std.debug.assert(name.len <= std.math.maxInt(u8));
        const plen = @min(name.len, key_prefix_len);
        key.len = @intCast(name.len);
        key.shape = @backingInt(shape);
        key.hash = std.hash.Wyhash.hash(seed, name);
        @memset(&key.prefix, 0);
        @memcpy(key.prefix[0..plen], name[0..plen]);
    }

    pub fn eql(a: *const CacheKey, b: *const CacheKey) bool {
        if (a.len != b.len or a.shape != b.shape or a.hash != b.hash) return false;
        const plen = @min(a.len, key_prefix_len);
        return std.mem.eql(u8, a.prefix[0..plen], b.prefix[0..plen]);
    }
};

comptime {
    if (@sizeOf(CacheKey) != 32) @compileError("CacheKey must be exactly 32 bytes");
}

const Node = struct {
    addrs: [addrs_per_node]net.IpAddress,
    next: u16,
};

const CacheSlot = struct {
    key: CacheKey,
    head: u16,
    count: u8,
    expiry: Timestamp,
};

fn slotIndex(key: *const CacheKey) usize {
    return @as(usize, @truncate(key.hash)) & (cache_capacity - 1);
}

pub const Cache = struct {
    slots: [cache_capacity]CacheSlot,
    nodes: [node_count]Node,
    free_head: u16,
    free_count: u16,
    sweep_cursor: u16,

    /// The freelist threads node indices, so — unlike the old inline layout —
    /// a zeroed Cache is not a valid empty one.
    pub fn init() Cache {
        var cache: Cache = .{
            .slots = undefined,
            .nodes = undefined,
            .free_head = 0,
            .free_count = node_count,
            .sweep_cursor = 0,
        };
        for (&cache.slots) |*slot| {
            slot.* = .{
                .key = std.mem.zeroes(CacheKey),
                .head = none,
                .count = 0,
                .expiry = .{ .value = 0 },
            };
        }
        for (&cache.nodes, 0..) |*node, i| {
            node.next = if (i + 1 < node_count) @intCast(i + 1) else none;
        }
        return cache;
    }

    /// Copies the cached addresses for key into `out`, if present and not
    /// expired, and returns how many were copied. Addresses beyond `out.len`
    /// are dropped.
    pub fn get(self: *const Cache, key: *const CacheKey, now: Timestamp, out: []net.IpAddress) ?usize {
        const start = slotIndex(key);
        for (0..probe_limit) |probe| {
            const slot = &self.slots[(start + probe) & (cache_capacity - 1)];
            if (slot.key.len == 0) return null;
            if (!slot.key.eql(key)) continue;
            if (now.value >= slot.expiry.value) return null;

            const n = @min(slot.count, out.len);
            var node = slot.head;
            var copied: usize = 0;
            while (copied < n) {
                const chunk = @min(addrs_per_node, n - copied);
                @memcpy(out[copied..][0..chunk], self.nodes[node].addrs[0..chunk]);
                copied += chunk;
                node = self.nodes[node].next;
            }
            return n;
        }
        return null;
    }

    /// Stores or updates an entry. Prefers an empty or exact-match slot, then
    /// the first expired slot found in the probe window, then the primary
    /// slot. Never fails: when the pool runs short, other entries are evicted.
    pub fn put(self: *Cache, key: *const CacheKey, addrs: []const net.IpAddress, expiry: Timestamp, now: Timestamp) void {
        std.debug.assert(addrs.len > 0 and addrs.len <= max_entry_addrs);

        const start = slotIndex(key);
        var target: usize = cache_capacity; // sentinel: no preferred slot yet
        for (0..probe_limit) |probe| {
            const idx = (start + probe) & (cache_capacity - 1);
            const slot = &self.slots[idx];
            if (slot.key.len == 0 or slot.key.eql(key)) {
                target = idx;
                break;
            }
            if (target == cache_capacity and now.value >= slot.expiry.value) {
                target = idx;
            }
        }
        if (target == cache_capacity) target = start;

        const slot = &self.slots[target];
        self.freeChain(slot);

        const needed = (addrs.len + addrs_per_node - 1) / addrs_per_node;
        if (self.free_count < needed) self.reclaim(needed, target);

        var head: u16 = none;
        var tail: u16 = none;
        var copied: usize = 0;
        while (copied < addrs.len) {
            const idx = self.free_head;
            self.free_head = self.nodes[idx].next;
            self.free_count -= 1;

            const node = &self.nodes[idx];
            node.next = none;
            const chunk = @min(addrs_per_node, addrs.len - copied);
            @memcpy(node.addrs[0..chunk], addrs[copied..][0..chunk]);
            copied += chunk;

            if (tail == none) head = idx else self.nodes[tail].next = idx;
            tail = idx;
        }

        slot.* = .{
            .key = key.*,
            .head = head,
            .count = @intCast(addrs.len),
            .expiry = expiry,
        };
    }

    /// Marks a cached entry as expired and releases its address chain. The
    /// key is kept — zeroing it would punch a hole that orphans entries
    /// further along the probe window.
    pub fn expire(self: *Cache, key: *const CacheKey) void {
        const start = slotIndex(key);
        for (0..probe_limit) |probe| {
            const slot = &self.slots[(start + probe) & (cache_capacity - 1)];
            if (slot.key.len == 0) break;
            if (slot.key.eql(key)) {
                self.freeChain(slot);
                slot.expiry = .{ .value = 0 };
                break;
            }
        }
    }

    /// Splices a slot's whole chain back onto the freelist.
    fn freeChain(self: *Cache, slot: *CacheSlot) void {
        if (slot.head == none) return;
        var freed: u16 = 1;
        var tail = slot.head;
        while (self.nodes[tail].next != none) : (tail = self.nodes[tail].next) freed += 1;
        self.nodes[tail].next = self.free_head;
        self.free_head = slot.head;
        self.free_count += freed;
        slot.head = none;
        slot.count = 0;
    }

    /// Evicts entries starting at a rotating cursor until at least `needed`
    /// nodes are free. The slot being written (`keep`) was already released
    /// by the caller; skipping it is only bookkeeping hygiene. A full pass
    /// releases every node, so this cannot come up short.
    fn reclaim(self: *Cache, needed: usize, keep: usize) void {
        var i: usize = 0;
        while (i < cache_capacity and self.free_count < needed) : (i += 1) {
            const idx = (self.sweep_cursor + i) & (cache_capacity - 1);
            if (idx == keep) continue;
            const slot = &self.slots[idx];
            if (slot.head == none) continue;
            self.freeChain(slot);
            slot.expiry = .{ .value = 0 };
        }
        self.sweep_cursor = @intCast((self.sweep_cursor + i) & (cache_capacity - 1));
    }
};

// -- Tests --------------------------------------------------------------------

fn testAddr(i: usize) net.IpAddress {
    return net.IpAddress.initIp4(.{ 10, 0, @intCast((i >> 8) & 0xff), @intCast(i & 0xff) }, 0);
}

fn expectAddrEql(expected: net.IpAddress, actual: net.IpAddress) !void {
    try std.testing.expectEqual(net.IpAddress.Family.ipv4, expected.getFamily());
    try std.testing.expectEqual(net.IpAddress.Family.ipv4, actual.getFamily());
    const e = @as(*align(1) const u32, @ptrCast(&expected.in.addr)).*;
    const a = @as(*align(1) const u32, @ptrCast(&actual.in.addr)).*;
    try std.testing.expectEqual(e, a);
}

fn fillTestAddrs(buf: []net.IpAddress) void {
    for (buf, 0..) |*a, i| a.* = testAddr(i);
}

/// Counts nodes reachable from live slot chains, for conservation checks.
fn countUsedNodes(cache: *const Cache) usize {
    var used: usize = 0;
    for (&cache.slots) |*slot| {
        var node = slot.head;
        while (node != none) : (node = cache.nodes[node].next) used += 1;
    }
    return used;
}

const far_future: Timestamp = .{ .value = std.math.maxInt(u64) };

test "Cache: put and get" {
    var cache: Cache = .init();
    var key: CacheKey = undefined;
    CacheKey.init(&key, "example.com", 0, .ipv4);

    var addrs: [3]net.IpAddress = undefined;
    fillTestAddrs(&addrs);

    const now: Timestamp = .{ .value = 1 };
    cache.put(&key, &addrs, far_future, now);

    var out: [max_entry_addrs]net.IpAddress = undefined;
    const n = cache.get(&key, now, &out);
    try std.testing.expectEqual(3, n.?);
    for (addrs, out[0..3]) |expected, actual| {
        try expectAddrEql(expected, actual);
    }
}

test "Cache: get truncates to the output buffer" {
    var cache: Cache = .init();
    var key: CacheKey = undefined;
    CacheKey.init(&key, "example.com", 0, .ipv4);

    var addrs: [12]net.IpAddress = undefined;
    fillTestAddrs(&addrs);

    const now: Timestamp = .{ .value = 1 };
    cache.put(&key, &addrs, far_future, now);

    var out: [5]net.IpAddress = undefined;
    const n = cache.get(&key, now, &out);
    try std.testing.expectEqual(5, n.?);
    for (addrs[0..5], out) |expected, actual| {
        try expectAddrEql(expected, actual);
    }
}

test "Cache: maximal dual-stack entry round-trips" {
    var cache: Cache = .init();
    var key: CacheKey = undefined;
    CacheKey.init(&key, "big.example.com", 0, .both);

    var addrs: [max_entry_addrs]net.IpAddress = undefined;
    fillTestAddrs(&addrs);

    const now: Timestamp = .{ .value = 1 };
    cache.put(&key, &addrs, far_future, now);

    var out: [max_entry_addrs]net.IpAddress = undefined;
    const n = cache.get(&key, now, &out);
    try std.testing.expectEqual(max_entry_addrs, n.?);
    for (addrs, out) |expected, actual| {
        try expectAddrEql(expected, actual);
    }
}

test "Cache: expired entry not returned" {
    var cache: Cache = .init();
    var key: CacheKey = undefined;
    CacheKey.init(&key, "example.com", 0, .ipv4);

    var addrs: [1]net.IpAddress = undefined;
    fillTestAddrs(&addrs);

    const now: Timestamp = .{ .value = 1 };
    cache.put(&key, &addrs, .{ .value = 0 }, now);

    var out: [max_entry_addrs]net.IpAddress = undefined;
    try std.testing.expect(cache.get(&key, now, &out) == null);
}

test "Cache: expire invalidates entry and releases its nodes" {
    var cache: Cache = .init();
    var key: CacheKey = undefined;
    CacheKey.init(&key, "example.com", 0, .ipv4);

    var addrs: [9]net.IpAddress = undefined;
    fillTestAddrs(&addrs);

    const now: Timestamp = .{ .value = 1 };
    cache.put(&key, &addrs, far_future, now);
    try std.testing.expectEqual(node_count - 3, cache.free_count);

    var out: [max_entry_addrs]net.IpAddress = undefined;
    try std.testing.expect(cache.get(&key, now, &out) != null);

    cache.expire(&key);
    try std.testing.expect(cache.get(&key, now, &out) == null);
    try std.testing.expectEqual(node_count, cache.free_count);
    try std.testing.expectEqual(0, countUsedNodes(&cache));
}

test "Cache: update existing entry conserves nodes" {
    var cache: Cache = .init();
    var key: CacheKey = undefined;
    CacheKey.init(&key, "example.com", 0, .ipv4);

    const now: Timestamp = .{ .value = 1 };

    var addrs: [12]net.IpAddress = undefined;
    fillTestAddrs(&addrs);
    cache.put(&key, &addrs, far_future, now);

    var new_addrs: [2]net.IpAddress = undefined;
    for (&new_addrs, 100..) |*a, i| a.* = testAddr(i);
    cache.put(&key, &new_addrs, far_future, now);

    var out: [max_entry_addrs]net.IpAddress = undefined;
    const n = cache.get(&key, now, &out);
    try std.testing.expectEqual(2, n.?);
    for (new_addrs, out[0..2]) |expected, actual| {
        try expectAddrEql(expected, actual);
    }
    try std.testing.expectEqual(node_count - 1, cache.free_count);
    try std.testing.expectEqual(1, countUsedNodes(&cache));
}

test "Cache: multiple independent entries" {
    var cache: Cache = .init();
    const names = [_][]const u8{ "a.test", "b.test", "c.test", "d.test" };

    const now: Timestamp = .{ .value = 1 };

    for (names, 0..) |name, i| {
        var k: CacheKey = undefined;
        CacheKey.init(&k, name, 0, .ipv4);
        var addrs: [1]net.IpAddress = .{testAddr(i)};
        cache.put(&k, &addrs, far_future, now);
    }

    var out: [max_entry_addrs]net.IpAddress = undefined;
    for (names, 0..) |name, i| {
        var k: CacheKey = undefined;
        CacheKey.init(&k, name, 0, .ipv4);
        const n = cache.get(&k, now, &out);
        try std.testing.expectEqual(1, n.?);
        try expectAddrEql(testAddr(i), out[0]);
    }
}

test "Cache: long names with shared prefix stay distinct" {
    var cache: Cache = .init();
    const name1 = "abcdefghijklmnopqrstuvw-one.test";
    const name2 = "abcdefghijklmnopqrstuvw-two.test";
    comptime std.debug.assert(name1.len > key_prefix_len);

    const now: Timestamp = .{ .value = 1 };

    var k1: CacheKey = undefined;
    CacheKey.init(&k1, name1, 0, .ipv4);
    var a1: [1]net.IpAddress = .{testAddr(1)};
    cache.put(&k1, &a1, far_future, now);

    var k2: CacheKey = undefined;
    CacheKey.init(&k2, name2, 0, .ipv4);
    var a2: [1]net.IpAddress = .{testAddr(2)};
    cache.put(&k2, &a2, far_future, now);

    var out: [max_entry_addrs]net.IpAddress = undefined;
    try std.testing.expectEqual(1, cache.get(&k1, now, &out).?);
    try expectAddrEql(testAddr(1), out[0]);
    try std.testing.expectEqual(1, cache.get(&k2, now, &out).?);
    try expectAddrEql(testAddr(2), out[0]);
}

test "Cache: same name different shapes stay distinct" {
    var cache: Cache = .init();
    const name = "example.com";
    const now: Timestamp = .{ .value = 1 };

    var k4: CacheKey = undefined;
    CacheKey.init(&k4, name, 0, .ipv4);
    var a4: [1]net.IpAddress = .{testAddr(4)};
    cache.put(&k4, &a4, far_future, now);

    var kboth: CacheKey = undefined;
    CacheKey.init(&kboth, name, 0, .both);
    var aboth: [2]net.IpAddress = .{ testAddr(5), testAddr(6) };
    cache.put(&kboth, &aboth, far_future, now);

    try std.testing.expect(!k4.eql(&kboth));
    var out: [max_entry_addrs]net.IpAddress = undefined;
    try std.testing.expectEqual(1, cache.get(&k4, now, &out).?);
    try std.testing.expectEqual(2, cache.get(&kboth, now, &out).?);
}

test "Cache: pool exhaustion evicts but conserves nodes" {
    var cache: Cache = .init();
    const now: Timestamp = .{ .value = 1 };

    var addrs: [max_entry_addrs]net.IpAddress = undefined;
    fillTestAddrs(&addrs);

    // Far more maximal entries than the pool can hold, so reclaim must run
    // repeatedly. Every put must succeed and be immediately retrievable, and
    // no node may leak or be double-freed.
    var name_buf: [32]u8 = undefined;
    var out: [max_entry_addrs]net.IpAddress = undefined;
    for (0..4 * cache_capacity) |i| {
        const name = std.fmt.bufPrint(&name_buf, "host-{d}.test", .{i}) catch unreachable;
        var k: CacheKey = undefined;
        CacheKey.init(&k, name, 0, .both);
        cache.put(&k, &addrs, far_future, now);

        try std.testing.expectEqual(max_entry_addrs, cache.get(&k, now, &out).?);
        try std.testing.expectEqual(node_count, countUsedNodes(&cache) + cache.free_count);
    }
}

test "Cache: entries past a swept slot still resolve" {
    var cache: Cache = .init();
    const now: Timestamp = .{ .value = 1 };

    // Two names landing on the same primary slot, so the second lives further
    // along the probe window.
    var first: CacheKey = undefined;
    CacheKey.init(&first, "collide-0.test", 0, .ipv4);
    var second: CacheKey = undefined;
    var found = false;
    var name_buf: [32]u8 = undefined;
    var i: usize = 1;
    while (i < 100_000) : (i += 1) {
        const name = std.fmt.bufPrint(&name_buf, "collide-{d}.test", .{i}) catch unreachable;
        var k: CacheKey = undefined;
        CacheKey.init(&k, name, 0, .ipv4);
        if (slotIndex(&k) == slotIndex(&first)) {
            second = k;
            found = true;
            break;
        }
    }
    try std.testing.expect(found);

    var a1: [1]net.IpAddress = .{testAddr(1)};
    var a2: [1]net.IpAddress = .{testAddr(2)};
    cache.put(&first, &a1, far_future, now);
    cache.put(&second, &a2, far_future, now);

    // Free the first entry's chain; its key must survive so the second stays
    // reachable through the probe window.
    cache.expire(&first);

    var out: [max_entry_addrs]net.IpAddress = undefined;
    try std.testing.expect(cache.get(&first, now, &out) == null);
    try std.testing.expectEqual(1, cache.get(&second, now, &out).?);
    try expectAddrEql(testAddr(2), out[0]);
}
