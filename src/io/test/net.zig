const std = @import("std");
const meta = @import("../../meta.zig");
const Runtime = @import("../../runtime.zig").Runtime;
const IpAddress = @import("../net.zig").IpAddress;
const UnixAddress = @import("../net.zig").UnixAddress;

test "IpAddress: initIp4" {
    const addr = IpAddress.initIp4(.{0} ** 4, 8080);
    try std.testing.expectEqual(std.posix.AF.INET, addr.any.family);
}

test "IpAddress: initIp6" {
    const addr = IpAddress.initIp6(.{0} ** 16, 8080, 0, 0);
    try std.testing.expectEqual(std.posix.AF.INET6, addr.any.family);
}

test "IpAddress: parseIp4" {
    const addr = try IpAddress.parseIp4("127.0.0.1", 8080);
    try std.testing.expectEqual(std.posix.AF.INET, addr.any.family);
}

test "IpAddress: parseIp6" {
    const addr = try IpAddress.parseIp6("::1", 8080);
    try std.testing.expectEqual(std.posix.AF.INET6, addr.any.family);
}

test "UnixAddress: init" {
    const addr = try UnixAddress.init("/tmp/socket");
    try std.testing.expectEqual(std.posix.AF.UNIX, addr.any.family);
}

pub fn checkListen(addr: anytype, options: anytype) !void {
    const testFn = struct {
        pub fn run(rt: *Runtime, addr_inner: @TypeOf(addr), options_inner: @TypeOf(options)) !void {
            const server = try addr_inner.listen(rt, options_inner);
            defer server.close(rt);
        }
    }.run;

    var runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    try runtime.runUntilComplete(testFn, .{ &runtime, addr, options }, .{});
}

test "UnixAddress: listen" {
    const path = "/tmp/zio-test-socket";
    defer std.fs.deleteFileAbsolute(path) catch {};

    const addr = try UnixAddress.init(path);
    try checkListen(addr, UnixAddress.ListenOptions{});
}

test "IpAddress: listen" {
    const addr = try IpAddress.parseIp4("127.0.0.1", 0);
    try checkListen(addr, IpAddress.ListenOptions{});
}
