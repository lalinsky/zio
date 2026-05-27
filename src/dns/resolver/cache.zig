// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

const std = @import("std");
const net = @import("../../net.zig");
const Timestamp = @import("../../time.zig").Timestamp;

pub const max_cached_addrs = 3;
const cache_capacity = 1024;
const probe_limit = 8;

pub const CacheKey = struct {
    hash: u64,
    len: u8,
    buf: [48 - @sizeOf(u64) - @sizeOf(u8)]u8,

    pub fn init(name: []const u8) CacheKey {
        var key: CacheKey = .{
            .len = @intCast(name.len),
            .hash = std.hash.Wyhash.hash(0, name),
            .buf = @splat(0),
        };
        const n = @min(name.len, key.buf.len);
        @memcpy(key.buf[0..n], name[0..n]);
        return key;
    }
};

comptime {
    if (@sizeOf(CacheKey) != 48) @compileError("CacheKey must be exactly 48 bytes");
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

fn eqlKey(a: CacheKey, b: *const CacheKey) bool {
    return a.len == b.len and a.hash == b.hash and std.mem.eql(u8, &a.buf, &b.buf);
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
    const key = CacheKey.init("example.com");
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
    const key = CacheKey.init("example.com");
    var entry: CacheEntry = std.mem.zeroes(CacheEntry);
    entry.count = 1;
    entry.expiry = .{ .value = 0 };

    cache.put(&key, entry);
    try std.testing.expect(cache.get(&key) == null);
}

test "Cache: expire invalidates entry" {
    var cache: Cache = std.mem.zeroes(Cache);
    const key = CacheKey.init("example.com");
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
    const key = CacheKey.init("example.com");

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
        const k = CacheKey.init(name);
        var e: CacheEntry = std.mem.zeroes(CacheEntry);
        e.count = @intCast(i + 1);
        e.expiry = .{ .value = std.math.maxInt(u64) };
        cache.put(&k, e);
    }

    for (names, 0..) |name, i| {
        const k = CacheKey.init(name);
        const result = cache.get(&k);
        try std.testing.expect(result != null);
        try std.testing.expectEqual(@as(u8, @intCast(i + 1)), result.?.count);
    }
}
