// Simple ICMP ping demo using raw sockets
//
// Note: Requires root or CAP_NET_RAW capability
//
// Usage: zig build examples && sudo ./zig-out/bin/ping 8.8.8.8

const std = @import("std");
const zio = @import("zio");

// ICMP Echo Request/Reply structures
const IcmpHeader = extern struct {
    type: u8,
    code: u8,
    checksum: u16,
    id: u16,
    sequence: u16,
};

const ICMP_ECHO_REQUEST: u8 = 8;
const ICMP_ECHO_REPLY: u8 = 0;

fn calculateChecksum(data: []const u8) u16 {
    var sum: u32 = 0;
    var i: usize = 0;

    // Sum 16-bit words (network byte order / big endian)
    while (i + 1 < data.len) : (i += 2) {
        const word = std.mem.readInt(u16, data[i..][0..2], .big);
        sum +%= word;
    }

    // Add remaining byte if odd length (shifted to high byte)
    if (i < data.len) {
        sum +%= @as(u32, data[i]) << 8;
    }

    // Fold 32-bit sum to 16 bits
    while (sum >> 16 != 0) {
        sum = (sum & 0xFFFF) +% (sum >> 16);
    }

    return @truncate(~sum);
}

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try init.args.toSlice(allocator);
    defer allocator.free(args);

    if (args.len < 2) {
        std.log.err("Usage: {s} <address>", .{args[0]});
        return error.InvalidArguments;
    }

    const address = args[1];
    std.log.info("Pinging {s}...", .{address});

    var rt = try zio.Runtime.init(allocator, .{});
    defer rt.deinit();

    // Parse IP address
    const addr = try zio.net.Address.parseIp(address, 0);
    std.log.info("Target: {f}", .{&addr});

    // Create raw ICMP socket (requires root/CAP_NET_RAW)
    const socket = try zio.net.Socket.open(.raw, .ipv4, .icmp);
    defer socket.close();

    const pid: u16 = 1;
    var sequence: u16 = 1;

    // Send pings in a loop
    while (true) : (sequence += 1) {
        // Prepare ICMP echo request
        var packet: [64]u8 = undefined;
        var writer = std.Io.Writer.fixed(&packet);

        // Write ICMP header (checksum set to 0 initially)
        const header = IcmpHeader{
            .type = ICMP_ECHO_REQUEST,
            .code = 0,
            .checksum = 0,
            .id = pid,
            .sequence = sequence,
        };
        try writer.writeStruct(header, .big);

        // Fill payload with pattern
        const payload = packet[8..];
        for (payload, 0..) |*b, i| {
            b.* = @truncate(i);
        }

        // Calculate and set checksum
        const checksum = calculateChecksum(&packet);
        std.mem.writeInt(u16, packet[2..4], checksum, .big);

        // Start timer
        var stopwatch = zio.time.Stopwatch.start();

        // Send the ping using sendMsg
        var send_storage: [1]zio.os.iovec_const = undefined;
        _ = try socket.sendMsg(.fromSlice(&packet, &send_storage), addr, null, .none);

        // Wait for reply using receiveMsg
        var recv_buf: [1024]u8 = undefined;
        var recv_storage: [1]zio.os.iovec = undefined;
        const result = try socket.receiveMsg(.fromSlice(&recv_buf, &recv_storage), null, .none);

        // Stop timer
        const elapsed = stopwatch.read();

        // Parse reply (raw sockets include IP header)
        if (result.len < 28) {
            std.log.err("Reply too short", .{});
            continue;
        }

        // Skip IP header and read ICMP header
        const ip_header_len: usize = @intCast((recv_buf[0] & 0x0F) * 4);
        if (ip_header_len < 20 or ip_header_len > result.len) {
            std.log.err("Invalid IP header length: {d}", .{ip_header_len});
            continue;
        }
        var reader = std.Io.Reader.fixed(recv_buf[ip_header_len..result.len]);
        const icmp_reply = try reader.takeStruct(IcmpHeader, .big);

        if (icmp_reply.type == ICMP_ECHO_REPLY and icmp_reply.id == pid) {
            std.log.info("{d} bytes from {f}: icmp_seq={d} time={f}", .{ result.len, result.from, icmp_reply.sequence, elapsed });
        } else {
            std.log.warn("Received ICMP type {d}, code {d}", .{ icmp_reply.type, icmp_reply.code });
        }

        // Wait 1 second before next ping
        try zio.sleep(.fromSeconds(1));
    }
}
