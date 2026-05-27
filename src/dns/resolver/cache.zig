// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

const std = @import("std");
const net = @import("../../net.zig");
const Timestamp = @import("../../time.zig").Timestamp;

pub const max_cached_addrs = 3;
const cache_capacity = 1024;
const probe_limit = 8;
pub const key_prefix_len = 23;

pub const CacheKey = struct {
    len: u8,
    prefix: [key_prefix_len]u8,
    hash: u64,

    pub fn init(key: *CacheKey, name: []const u8, seed: u64) void {
        const plen = @min(name.len, key_prefix_len);
        key.len = @intCast(name.len);
        key.hash = std.hash.Wyhash.hash(seed, name);
        @memset(&key.prefix, 0);
        @memcpy(key.prefix[0..plen], name[0..plen]);
    }

    pub fn eql(a: *const CacheKey, b: *const CacheKey) bool {
        if (a.len != b.len or a.hash != b.hash) return false;
        const plen = @min(a.len, key_prefix_len);
        return std.mem.eql(u8, a.prefix[0..plen], b.prefix[0..plen]);
    }
};

comptime {
    if (@sizeOf(CacheKey) != 32) @compileError("CacheKey must be exactly 32 bytes");
}

pub const CacheEntry = struct {
    addrs: [max_cached_addrs]net.IpAddress,
    count: u8,
    expiry: Timestamp,
};

const CacheSlot = struct {
    key: CacheKey,
    entry: CacheEntry,
};

fn slotIndex(key: *const CacheKey) usize {
    return @as(usize, @truncate(key.hash)) & (cache_capacity - 1);
}

pub const Cache = struct {
    slots: [cache_capacity]CacheSlot,

    // Returns the cached entry for key if present and not expired.
    pub fn get(self: *const Cache, key: *const CacheKey, now: Timestamp) ?CacheEntry {
        const start = slotIndex(key);
        for (0..probe_limit) |probe| {
            const slot = &self.slots[(start + probe) & (cache_capacity - 1)];
            if (slot.key.len == 0) return null;
            if (!slot.key.eql(key)) continue;
            if (now.value < slot.entry.expiry.value) {
                return slot.entry;
            }
            return null;
        }
        return null;
    }

    // Stores or updates an entry. Prefers an empty or exact-match slot, then the
    // first expired slot found in the probe window, then the primary slot.
    pub fn put(self: *Cache, key: *const CacheKey, entry: CacheEntry, now: Timestamp) void {
        const start = slotIndex(key);
        var target: usize = cache_capacity; // sentinel: no preferred slot yet
        for (0..probe_limit) |probe| {
            const idx = (start + probe) & (cache_capacity - 1);
            const slot = &self.slots[idx];
            if (slot.key.len == 0 or slot.key.eql(key)) {
                target = idx;
                break;
            }
            if (target == cache_capacity and now.value >= slot.entry.expiry.value) {
                target = idx;
            }
        }
        if (target == cache_capacity) target = start;
        self.slots[target] = .{ .key = key.*, .entry = entry };
    }

    // Marks a cached entry as expired so the slot can be reused without
    // breaking probe chains for other keys.
    pub fn expire(self: *Cache, key: *const CacheKey) void {
        const start = slotIndex(key);
        for (0..probe_limit) |probe| {
            const slot = &self.slots[(start + probe) & (cache_capacity - 1)];
            if (slot.key.len == 0) break;
            if (slot.key.eql(key)) {
                slot.entry.expiry = .{ .value = 0 };
                break;
            }
        }
    }
};

test "Cache: put and get" {
    var cache: Cache = std.mem.zeroes(Cache);
    var key: CacheKey = undefined;
    CacheKey.init(&key, "example.com", 0);
    var entry: CacheEntry = std.mem.zeroes(CacheEntry);
    entry.count = 1;
    entry.expiry = .{ .value = std.math.maxInt(u64) };

    const now: Timestamp = .{ .value = 1 };
    cache.put(&key, entry, now);
    const result = cache.get(&key, now);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(u8, 1), result.?.count);
}

test "Cache: expired entry not returned" {
    var cache: Cache = std.mem.zeroes(Cache);
    var key: CacheKey = undefined;
    CacheKey.init(&key, "example.com", 0);
    var entry: CacheEntry = std.mem.zeroes(CacheEntry);
    entry.count = 1;
    entry.expiry = .{ .value = 0 };

    const now: Timestamp = .{ .value = 1 };
    cache.put(&key, entry, now);
    try std.testing.expect(cache.get(&key, now) == null);
}

test "Cache: expire invalidates entry" {
    var cache: Cache = std.mem.zeroes(Cache);
    var key: CacheKey = undefined;
    CacheKey.init(&key, "example.com", 0);
    var entry: CacheEntry = std.mem.zeroes(CacheEntry);
    entry.count = 1;
    entry.expiry = .{ .value = std.math.maxInt(u64) };

    const now: Timestamp = .{ .value = 1 };
    cache.put(&key, entry, now);
    try std.testing.expect(cache.get(&key, now) != null);
    cache.expire(&key);
    try std.testing.expect(cache.get(&key, now) == null);
}

test "Cache: update existing entry" {
    var cache: Cache = std.mem.zeroes(Cache);
    var key: CacheKey = undefined;
    CacheKey.init(&key, "example.com", 0);

    const now: Timestamp = .{ .value = 1 };

    var e1: CacheEntry = std.mem.zeroes(CacheEntry);
    e1.count = 1;
    e1.expiry = .{ .value = std.math.maxInt(u64) };
    cache.put(&key, e1, now);

    var e2: CacheEntry = std.mem.zeroes(CacheEntry);
    e2.count = 2;
    e2.expiry = .{ .value = std.math.maxInt(u64) };
    cache.put(&key, e2, now);

    const result = cache.get(&key, now);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(u8, 2), result.?.count);
}

test "Cache: multiple independent entries" {
    var cache: Cache = std.mem.zeroes(Cache);
    const names = [_][]const u8{ "a.test", "b.test", "c.test", "d.test" };

    const now: Timestamp = .{ .value = 1 };

    for (names, 0..) |name, i| {
        var k: CacheKey = undefined;
        CacheKey.init(&k, name, 0);
        var e: CacheEntry = std.mem.zeroes(CacheEntry);
        e.count = @intCast(i + 1);
        e.expiry = .{ .value = std.math.maxInt(u64) };
        cache.put(&k, e, now);
    }

    for (names, 0..) |name, i| {
        var k: CacheKey = undefined;
        CacheKey.init(&k, name, 0);
        const result = cache.get(&k, now);
        try std.testing.expect(result != null);
        try std.testing.expectEqual(@as(u8, @intCast(i + 1)), result.?.count);
    }
}
