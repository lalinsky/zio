// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

const std = @import("std");
const net = @import("../../net.zig");
const Timestamp = @import("../../time.zig").Timestamp;

pub const max_cached_addrs = 3;
pub const max_cached_name_len = 31;
const cache_capacity = 1024;
const probe_limit = 8;

pub const CacheKey = struct {
    len: u8,
    buf: [max_cached_name_len]u8,

    pub fn init(name: []const u8) ?CacheKey {
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
    return @as(usize, @truncate(std.hash.Wyhash.hash(0, key.slice()))) & (cache_capacity - 1);
}

fn eqlKey(a: CacheKey, b: *const CacheKey) bool {
    return a.len == b.len and std.mem.eql(u8, a.buf[0..a.len], b.buf[0..b.len]);
}

pub const Cache = struct {
    slots: [cache_capacity]CacheSlot,

    // Returns the cached entry for key if present and not expired.
    pub fn get(self: *const Cache, key: *const CacheKey) ?CacheEntry {
        const start = slotIndex(key);
        for (0..probe_limit) |probe| {
            const slot = &self.slots[(start + probe) & (cache_capacity - 1)];
            if (slot.key.len == 0) return null;
            if (!eqlKey(slot.key, key)) continue;
            if (Timestamp.now(.monotonic).value < slot.entry.expiry.value) {
                return slot.entry;
            }
            return null;
        }
        return null;
    }

    // Stores or updates an entry. Prefers an empty or exact-match slot, then the
    // first expired slot found in the probe window, then the primary slot.
    pub fn put(self: *Cache, key: *const CacheKey, entry: CacheEntry) void {
        const start = slotIndex(key);
        const now = Timestamp.now(.monotonic);
        var target: usize = cache_capacity; // sentinel: no preferred slot yet
        for (0..probe_limit) |probe| {
            const idx = (start + probe) & (cache_capacity - 1);
            const slot = &self.slots[idx];
            if (slot.key.len == 0 or eqlKey(slot.key, key)) {
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
            if (eqlKey(slot.key, key)) {
                slot.entry.expiry = .{ .value = 0 };
                break;
            }
        }
    }
};

test "Cache: put and get" {
    var cache: Cache = std.mem.zeroes(Cache);
    const key = CacheKey.init("example.com").?;
    var entry: CacheEntry = std.mem.zeroes(CacheEntry);
    entry.count = 1;
    entry.expiry = .{ .value = std.math.maxInt(u64) };

    cache.put(&key, entry);
    const result = cache.get(&key);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(u8, 1), result.?.count);
}

test "Cache: expired entry not returned" {
    var cache: Cache = std.mem.zeroes(Cache);
    const key = CacheKey.init("example.com").?;
    var entry: CacheEntry = std.mem.zeroes(CacheEntry);
    entry.count = 1;
    entry.expiry = .{ .value = 0 };

    cache.put(&key, entry);
    try std.testing.expect(cache.get(&key) == null);
}

test "Cache: expire invalidates entry" {
    var cache: Cache = std.mem.zeroes(Cache);
    const key = CacheKey.init("example.com").?;
    var entry: CacheEntry = std.mem.zeroes(CacheEntry);
    entry.count = 1;
    entry.expiry = .{ .value = std.math.maxInt(u64) };

    cache.put(&key, entry);
    try std.testing.expect(cache.get(&key) != null);
    cache.expire(&key);
    try std.testing.expect(cache.get(&key) == null);
}

test "Cache: update existing entry" {
    var cache: Cache = std.mem.zeroes(Cache);
    const key = CacheKey.init("example.com").?;

    var e1: CacheEntry = std.mem.zeroes(CacheEntry);
    e1.count = 1;
    e1.expiry = .{ .value = std.math.maxInt(u64) };
    cache.put(&key, e1);

    var e2: CacheEntry = std.mem.zeroes(CacheEntry);
    e2.count = 2;
    e2.expiry = .{ .value = std.math.maxInt(u64) };
    cache.put(&key, e2);

    const result = cache.get(&key);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(u8, 2), result.?.count);
}

test "Cache: multiple independent entries" {
    var cache: Cache = std.mem.zeroes(Cache);
    const names = [_][]const u8{ "a.test", "b.test", "c.test", "d.test" };

    for (names, 0..) |name, i| {
        const k = CacheKey.init(name).?;
        var e: CacheEntry = std.mem.zeroes(CacheEntry);
        e.count = @intCast(i + 1);
        e.expiry = .{ .value = std.math.maxInt(u64) };
        cache.put(&k, e);
    }

    for (names, 0..) |name, i| {
        const k = CacheKey.init(name).?;
        const result = cache.get(&k);
        try std.testing.expect(result != null);
        try std.testing.expectEqual(@as(u8, @intCast(i + 1)), result.?.count);
    }
}
