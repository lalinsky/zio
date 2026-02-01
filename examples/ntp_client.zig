const std = @import("std");
const zio = @import("zio");

// --8<-- [start:lookup]
fn lookupHost(rt: *zio.Runtime, hostname: []const u8, port: u16) !zio.net.Address {
    const host = try zio.net.HostName.init(hostname);
    var iter = try host.lookup(rt, .{ .port = port });
    defer iter.deinit();

    while (iter.next()) |result| {
        switch (result) {
            .address => |ip_addr| return .{ .ip = ip_addr },
            else => continue,
        }
    }

    return error.NoAddressFound;
}
// --8<-- [end:lookup]

const NtpPacket = extern struct {
    flags: packed struct(u8) {
        mode: u3 = 3, // Client mode
        version: u3 = 3, // NTP version 3
        leap: u2 = 0, // No leap second warning
    } = .{},
    stratum: u8 = 0,
    poll: u8 = 0,
    precision: u8 = 0,
    root_delay: u32 = 0,
    root_dispersion: u32 = 0,
    reference_id: u32 = 0,
    reference_timestamp: u64 = 0,
    origin_timestamp: u64 = 0,
    receive_timestamp: u64 = 0,
    transmit_timestamp: u64 = 0,
};

fn queryNtpServer(rt: *zio.Runtime, server: []const u8, port: u16, timeout: zio.Timeout) !void {
    const addr = try lookupHost(rt, server, port);
    std.log.info("Querying NTP server {s}:{d} ({f})", .{ server, port, addr });

    // Create UDP socket (bind to any local port)
    const local_addr = try zio.net.IpAddress.parseIp4("0.0.0.0", 0);
    const socket = try local_addr.bind(.{});
    defer socket.close(rt);

    // Prepare and send NTP request
    const request: NtpPacket = .{};

    var buffer: [@sizeOf(NtpPacket)]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writer.writeStruct(request, .big);

    const sent = try socket.sendTo(addr, &buffer, timeout);
    if (sent != @sizeOf(NtpPacket)) {
        return error.IncompleteSend;
    }

    // Receive response
    const result = socket.receiveFrom(&buffer, timeout) catch |err| {
        std.log.warn("Failed to receive NTP response: {}", .{err});
        return err;
    };

    if (result.len < @sizeOf(NtpPacket)) {
        std.log.warn("Received incomplete NTP packet: {} bytes", .{result.len});
        return error.IncompletePacket;
    }

    var reader = std.Io.Reader.fixed(buffer[0..result.len]);
    const response = try reader.takeStruct(NtpPacket, .big);

    // Parse response (transmit_timestamp is already in native byte order)
    const ntp_time = response.transmit_timestamp;

    if (ntp_time == 0) {
        std.log.warn("Invalid NTP response (zero timestamp)", .{});
        return error.InvalidResponse;
    }

    // NTP timestamp: upper 32 bits = seconds, lower 32 bits = fractional seconds
    const seconds: u32 = @truncate(ntp_time >> 32);
    const milliseconds: u32 = @truncate((ntp_time & 0xFFFFFFFF) * 1000 >> 32);

    // Format time using stdlib helpers (convert NTP epoch to Unix epoch)
    const epoch_secs: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@as(i64, seconds) + std.time.epoch.ntp) };
    const day_seconds = epoch_secs.getDaySeconds();
    const year_day = epoch_secs.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    std.log.info("Current time: {d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}.{d:0>3} UTC", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
        milliseconds,
    });
}

pub fn main() !void {
    const gpa = std.heap.smp_allocator;

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    const server = if (args.len > 1) args[1] else "pool.ntp.org";
    const port: u16 = 123;

    var rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();

    // Setup SIGINT handler
    var signal = try zio.Signal.init(.interrupt);
    defer signal.deinit();

    const interval: zio.Timeout = .{ .duration = .fromSeconds(30) };
    const request_timeout: zio.Timeout = .{ .duration = .fromSeconds(5) };

    std.log.info("NTP client starting. Press Ctrl+C to stop.", .{});
    std.log.info("Server: {s}:{d}", .{ server, port });
    std.log.info("Update interval: {f}", .{interval});
    std.log.info("Request timeout: {f}", .{request_timeout});

    while (true) {
        // Query NTP server
        queryNtpServer(rt, server, port, request_timeout) catch |err| {
            std.log.err("NTP query failed: {}", .{err});
        };

        // --8<-- [start:select]
        // Wait for next query or shutdown signal
        const result = try zio.select(rt, .{
            .interval = &interval,
            .shutdown = &signal,
        });

        switch (result) {
            .interval => continue, // Query again after interval
            .shutdown => break, // Exit on Ctrl+C
        }
        // --8<-- [end:select]
    }

    std.log.info("NTP client stopped.", .{});
}
