// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

//! DNS wire format: query building and response parsing (RFC 1035).

const std = @import("std");
const net = @import("../../net.zig");

/// Maximum DNS payload size for UDP (https://dnsflagday.net/2020/).
pub const max_udp_size = 1232;

pub const QType = enum(u16) {
    a = 1,
    aaaa = 28,
    _,
};

pub const RCode = enum(u4) {
    no_error = 0,
    form_err = 1,
    serv_fail = 2,
    nx_domain = 3,
    not_imp = 4,
    refused = 5,
    _,
};

/// Encode a domain name into DNS wire format at buf[pos..].
/// The name must be rooted (trailing dot). Returns the new offset.
fn encodeName(buf: []u8, pos: usize, name: []const u8) !usize {
    var p = pos;
    // Strip trailing dot — we add the terminal zero ourselves.
    const n = if (name.len > 0 and name[name.len - 1] == '.') name[0 .. name.len - 1] else name;
    var labels = std.mem.splitScalar(u8, n, '.');
    while (labels.next()) |label| {
        if (label.len == 0 or label.len > 63) return error.InvalidName;
        if (p + 1 + label.len > buf.len) return error.BufferTooSmall;
        buf[p] = @intCast(label.len);
        @memcpy(buf[p + 1 ..][0..label.len], label);
        p += 1 + label.len;
    }
    if (p >= buf.len) return error.BufferTooSmall;
    buf[p] = 0;
    return p + 1;
}

/// Build a DNS query into buf. Returns the slice of buf used.
pub fn buildQuery(buf: []u8, id: u16, name: []const u8, qtype: QType) ![]u8 {
    if (buf.len < 12) return error.BufferTooSmall;
    std.mem.writeInt(u16, buf[0..2], id, .big);
    std.mem.writeInt(u16, buf[2..4], 0x0100, .big); // QR=0 OPCODE=0 RD=1
    std.mem.writeInt(u16, buf[4..6], 1, .big); // QDCOUNT
    std.mem.writeInt(u16, buf[6..8], 0, .big); // ANCOUNT
    std.mem.writeInt(u16, buf[8..10], 0, .big); // NSCOUNT
    std.mem.writeInt(u16, buf[10..12], 0, .big); // ARCOUNT
    const p = try encodeName(buf, 12, name);
    if (p + 4 > buf.len) return error.BufferTooSmall;
    std.mem.writeInt(u16, buf[p..][0..2], @intFromEnum(qtype), .big);
    std.mem.writeInt(u16, buf[p + 2 ..][0..2], 1, .big); // CLASS IN
    return buf[0 .. p + 4];
}

/// Decode a DNS wire-format name at buf[pos] into out, following compression
/// pointers. Labels are joined with '.', no trailing dot. Returns the decoded
/// length and the end position in the *original* location (after the pointer
/// word, not after the pointer target).
pub fn decodeName(buf: []const u8, pos: usize, out: []u8) !struct { end: usize, len: usize } {
    var p = pos;
    var out_len: usize = 0;
    var end: usize = 0;
    var jumped = false;
    var depth: usize = 0;
    while (p < buf.len and depth < 128) : (depth += 1) {
        const b = buf[p];
        if (b == 0) {
            if (!jumped) end = p + 1;
            break;
        }
        if (b & 0xc0 == 0xc0) {
            if (p + 2 > buf.len) return error.Truncated;
            if (!jumped) end = p + 2;
            jumped = true;
            p = (@as(usize, b & 0x3f) << 8) | buf[p + 1];
            continue;
        }
        if (b & 0xc0 != 0) return error.InvalidMessage;
        const label_len = b & 0x3f;
        p += 1;
        if (p + label_len > buf.len) return error.Truncated;
        if (out_len > 0) {
            if (out_len >= out.len) return error.BufferTooSmall;
            out[out_len] = '.';
            out_len += 1;
        }
        if (out_len + label_len > out.len) return error.BufferTooSmall;
        @memcpy(out[out_len..][0..label_len], buf[p..][0..label_len]);
        out_len += label_len;
        p += label_len;
    }
    if (!jumped) end = p + 1;
    return .{ .end = end, .len = out_len };
}

/// Skip a DNS-encoded name starting at buf[pos], following compression pointers.
/// Returns the position of the byte after the name in the *current* location
/// (i.e. after the pointer word, not after the pointer target).
fn skipName(buf: []const u8, pos: usize) !usize {
    var p = pos;
    while (p < buf.len) {
        const b = buf[p];
        if (b == 0) return p + 1;
        if (b & 0xc0 == 0xc0) {
            if (p + 2 > buf.len) return error.Truncated;
            return p + 2; // pointer is always 2 bytes and terminal
        }
        if (b & 0xc0 != 0) return error.InvalidMessage;
        p += 1 + (b & 0x3f);
    }
    return error.Truncated;
}

pub const ParseResult = struct {
    truncated: bool,
    rcode: RCode,
    count: usize,
    ttl: u32,
    canonical_name_len: usize = 0,
};

/// Parse a DNS response. Fills addresses with port into storage.
/// If cname_out is provided, the last CNAME target is decoded into it and
/// null-terminated (the caller reads it back via sliceTo).
/// Returns error if the message is malformed or the ID doesn't match.
pub fn parseResponse(
    buf: []const u8,
    id: u16,
    qtype: QType,
    storage: []net.IpAddress,
    port: u16,
    cname_out: ?[]u8,
) !ParseResult {
    if (buf.len < 12) return error.Truncated;
    if (std.mem.readInt(u16, buf[0..2], .big) != id) return error.IdMismatch;

    const flags = std.mem.readInt(u16, buf[2..4], .big);
    if (flags & 0x8000 == 0) return error.NotAResponse;

    const truncated = flags & 0x0200 != 0;
    const rcode: RCode = @enumFromInt(@as(u4, @truncate(flags)));
    const qdcount = std.mem.readInt(u16, buf[4..6], .big);
    const ancount = std.mem.readInt(u16, buf[6..8], .big);

    var p: usize = 12;

    for (0..qdcount) |_| {
        p = try skipName(buf, p);
        if (p + 4 > buf.len) return error.Truncated;
        p += 4; // QTYPE + QCLASS
    }

    var count: usize = 0;
    var ttl: u32 = 0;
    var canonical_name_len: usize = 0;
    for (0..ancount) |_| {
        const name_start = p;
        p = try skipName(buf, p);
        if (p + 10 > buf.len) return error.Truncated;
        const rtype = std.mem.readInt(u16, buf[p..][0..2], .big);
        const record_ttl = std.mem.readInt(u32, buf[p + 4 ..][0..4], .big);
        const rdlength = std.mem.readInt(u16, buf[p + 8 ..][0..2], .big);
        p += 10;
        if (p + rdlength > buf.len) return error.Truncated;
        const rdata = buf[p..][0..rdlength];
        p += rdlength;

        switch (rtype) {
            1 => if (qtype == .a and rdlength == 4) { // A
                ttl = if (count == 0) record_ttl else @min(ttl, record_ttl);
                if (count < storage.len)
                    storage[count] = net.IpAddress.initIp4(rdata[0..4].*, port);
                count += 1;
                // Decode the owner name of the first A record as the canonical name.
                if (count == 1) if (cname_out) |out| {
                    if (decodeName(buf, name_start, out)) |r| {
                        canonical_name_len = r.len;
                    } else |_| {}
                };
            },
            28 => if (qtype == .aaaa and rdlength == 16) { // AAAA
                ttl = if (count == 0) record_ttl else @min(ttl, record_ttl);
                if (count < storage.len)
                    storage[count] = net.IpAddress.initIp6(rdata[0..16].*, port, 0, 0);
                count += 1;
                // Decode the owner name of the first AAAA record as the canonical name.
                if (count == 1) if (cname_out) |out| {
                    if (decodeName(buf, name_start, out)) |r| {
                        canonical_name_len = r.len;
                    } else |_| {}
                };
            },
            else => {},
        }
    }

    return .{ .truncated = truncated, .rcode = rcode, .count = count, .ttl = ttl, .canonical_name_len = canonical_name_len };
}

test "buildQuery encodes correctly" {
    var buf: [512]u8 = undefined;
    const q = try buildQuery(&buf, 0x1234, "example.com.", .a);

    // Header
    try std.testing.expectEqual(@as(u16, 0x1234), std.mem.readInt(u16, q[0..2], .big));
    try std.testing.expectEqual(@as(u16, 0x0100), std.mem.readInt(u16, q[2..4], .big));
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, q[4..6], .big));

    // Name: 7example3com0
    try std.testing.expectEqual(@as(u8, 7), q[12]);
    try std.testing.expectEqualSlices(u8, "example", q[13..20]);
    try std.testing.expectEqual(@as(u8, 3), q[20]);
    try std.testing.expectEqualSlices(u8, "com", q[21..24]);
    try std.testing.expectEqual(@as(u8, 0), q[24]);

    // QTYPE=A, QCLASS=IN
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, q[25..27], .big));
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, q[27..29], .big));
}

test "parseResponse extracts A record" {
    // Minimal hand-crafted response for "example.com." A -> 93.184.216.34
    var buf: [512]u8 = undefined;
    var pos: usize = 0;

    // Header: id=0x1234, QR+RD+RA, QDCOUNT=1, ANCOUNT=1
    std.mem.writeInt(u16, buf[0..2], 0x1234, .big);
    std.mem.writeInt(u16, buf[2..4], 0x8180, .big);
    std.mem.writeInt(u16, buf[4..6], 1, .big);
    std.mem.writeInt(u16, buf[6..8], 1, .big);
    std.mem.writeInt(u16, buf[8..10], 0, .big);
    std.mem.writeInt(u16, buf[10..12], 0, .big);
    pos = 12;

    // Question: example.com. A IN
    pos = try encodeName(&buf, pos, "example.com.");
    std.mem.writeInt(u16, buf[pos..][0..2], 1, .big);
    std.mem.writeInt(u16, buf[pos + 2 ..][0..2], 1, .big);
    pos += 4;

    // Answer: pointer to name, A IN TTL=60 RDATA=93.184.216.34
    std.mem.writeInt(u16, buf[pos..][0..2], 0xc00c, .big); // pointer to offset 12
    std.mem.writeInt(u16, buf[pos + 2 ..][0..2], 1, .big); // TYPE A
    std.mem.writeInt(u16, buf[pos + 4 ..][0..2], 1, .big); // CLASS IN
    std.mem.writeInt(u32, buf[pos + 6 ..][0..4], 60, .big); // TTL
    std.mem.writeInt(u16, buf[pos + 10 ..][0..2], 4, .big); // RDLENGTH
    buf[pos + 12] = 93;
    buf[pos + 13] = 184;
    buf[pos + 14] = 216;
    buf[pos + 15] = 34;
    pos += 16;

    var storage: [4]net.IpAddress = undefined;
    const result = try parseResponse(buf[0..pos], 0x1234, .a, &storage, 80, null);

    try std.testing.expectEqual(false, result.truncated);
    try std.testing.expectEqual(RCode.no_error, result.rcode);
    try std.testing.expectEqual(1, result.count);
    try std.testing.expectEqual(@as(u16, 80), storage[0].getPort());
}
