const std = @import("std");

pub const Address = std.net.Address;

pub fn parseIp4(ip: []const u8, port: u16) !Address {
    return Address.parseIp4(ip, port);
}

pub fn parseIp6(ip: []const u8, port: u16) !Address {
    return Address.parseIp6(ip, port);
}

pub fn initIp4(ip: [4]u8, port: u16) Address {
    return Address.initIp4(ip, port);
}

pub fn initIp6(ip: [16]u8, port: u16, flowinfo: u32, scope_id: u32) Address {
    return Address.initIp6(ip, port, flowinfo, scope_id);
}

pub fn resolveIp(name: []const u8, port: u16, family: std.posix.AF) !Address {
    return Address.resolveIp(name, port, family);
}

pub fn format(self: Address, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
    return self.format(fmt, options, writer);
}

test "address creation" {
    const testing = std.testing;

    const addr4 = try parseIp4("127.0.0.1", 8080);
    try testing.expect(addr4.getPort() == 8080);

    const addr6 = try parseIp6("::1", 8080);
    try testing.expect(addr6.getPort() == 8080);

    const local = initIp4([_]u8{ 127, 0, 0, 1 }, 9000);
    try testing.expect(local.getPort() == 9000);
}