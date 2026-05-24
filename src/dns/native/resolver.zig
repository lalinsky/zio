// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

const std = @import("std");
const dns = @import("../root.zig");
const fs = @import("../../fs.zig");
const Hosts = @import("hosts.zig").Hosts;
const ResolvConf = @import("resolvconf.zig").ResolvConf;
const log = @import("../../common.zig").log;
const Timestamp = @import("../../time.zig").Timestamp;
const Duration = @import("../../time.zig").Duration;
const RwLock = @import("../../sync/RwLock.zig");

const check_interval: Duration = .fromSeconds(5);

pub const Resolver = struct {
    allocator: std.mem.Allocator,
    lock: RwLock,

    hosts: Hosts,
    hosts_mtime: i64,
    hosts_next_check: std.atomic.Value(Timestamp),
    hosts_reloading: std.atomic.Value(bool),

    conf: ResolvConf,
    conf_mtime: i64,
    conf_next_check: std.atomic.Value(Timestamp),
    conf_reloading: std.atomic.Value(bool),

    pub fn init(allocator: std.mem.Allocator) Resolver {
        var hosts_mtime: i64 = 0;
        var conf_mtime: i64 = 0;
        const next_check = Timestamp.now(.monotonic).addDuration(check_interval);
        return .{
            .allocator = allocator,
            .lock = .init,
            .hosts = loadHosts(allocator, &hosts_mtime),
            .hosts_mtime = hosts_mtime,
            .hosts_next_check = .init(next_check),
            .hosts_reloading = .init(false),
            .conf = loadResolvConf(allocator, &conf_mtime),
            .conf_mtime = conf_mtime,
            .conf_next_check = .init(next_check),
            .conf_reloading = .init(false),
        };
    }

    pub fn deinit(self: *Resolver) void {
        self.hosts.deinit();
        self.conf.deinit();
    }

    pub fn lookup(
        self: *Resolver,
        storage: []dns.LookupResult,
        options: dns.LookupOptions,
    ) dns.LookupError!usize {
        self.maybeReloadHosts();
        self.maybeReloadResolvConf();

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

        return error.UnknownHostName;
    }

    fn maybeReloadHosts(self: *Resolver) void {
        const now = Timestamp.now(.monotonic);
        if (now.value < self.hosts_next_check.load(.monotonic).value) return;

        if (self.hosts_reloading.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return;
        defer self.hosts_reloading.store(false, .release);

        self.hosts_next_check.store(now.addDuration(check_interval), .monotonic);

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
        const now = Timestamp.now(.monotonic);
        if (now.value < self.conf_next_check.load(.monotonic).value) return;

        if (self.conf_reloading.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return;
        defer self.conf_reloading.store(false, .release);

        self.conf_next_check.store(now.addDuration(check_interval), .monotonic);

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
