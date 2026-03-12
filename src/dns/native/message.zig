// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

//! DNS message encoding and decoding per RFC 1035.
//! Supports EDNS0 (RFC 6891) for larger packet sizes.

const std = @import("std");

/// Maximum DNS packet size with EDNS0.
/// Value from https://dnsflagday.net/2020/
pub const max_packet_size = 1232;

/// Maximum domain name length (255 bytes per RFC 1035).
pub const max_name_len = 255;

/// Maximum label length (63 bytes per RFC 1035).
pub const max_label_len = 63;

/// DNS record types.
pub const Type = enum(u16) {
    A = 1,
    NS = 2,
    CNAME = 5,
    SOA = 6,
    PTR = 12,
    MX = 15,
    TXT = 16,
    AAAA = 28,
    SRV = 33,
    OPT = 41, // EDNS0
    _,
};

/// DNS record classes.
pub const Class = enum(u16) {
    IN = 1, // Internet
    CS = 2, // CSNET (obsolete)
    CH = 3, // CHAOS
    HS = 4, // Hesiod
    ANY = 255,
    _,
};

/// DNS response codes.
pub const RCode = enum(u4) {
    success = 0, // No error
    format_error = 1, // Format error
    server_failure = 2, // Server failure
    name_error = 3, // Non-existent domain (NXDOMAIN)
    not_implemented = 4, // Not implemented
    refused = 5, // Query refused
    _,
};

/// DNS message header (12 bytes).
pub const Header = struct {
    id: u16,
    flags: Flags,
    qd_count: u16, // Question count
    an_count: u16, // Answer count
    ns_count: u16, // Authority count
    ar_count: u16, // Additional count

    pub const Flags = packed struct(u16) {
        rcode: RCode = .success,
        z: u3 = 0, // Reserved
        ra: bool = false, // Recursion available
        rd: bool = true, // Recursion desired
        tc: bool = false, // Truncated
        aa: bool = false, // Authoritative answer
        opcode: u4 = 0, // Standard query
        qr: bool = false, // Query (false) or Response (true)
    };

    pub fn encode(self: Header, buf: []u8) []u8 {
        std.debug.assert(buf.len >= 12);
        std.mem.writeInt(u16, buf[0..2], self.id, .big);
        std.mem.writeInt(u16, buf[2..4], @bitCast(self.flags), .big);
        std.mem.writeInt(u16, buf[4..6], self.qd_count, .big);
        std.mem.writeInt(u16, buf[6..8], self.an_count, .big);
        std.mem.writeInt(u16, buf[8..10], self.ns_count, .big);
        std.mem.writeInt(u16, buf[10..12], self.ar_count, .big);
        return buf[0..12];
    }

    pub fn decode(buf: []const u8) error{Truncated}!Header {
        if (buf.len < 12) return error.Truncated;
        return .{
            .id = std.mem.readInt(u16, buf[0..2], .big),
            .flags = @bitCast(std.mem.readInt(u16, buf[2..4], .big)),
            .qd_count = std.mem.readInt(u16, buf[4..6], .big),
            .an_count = std.mem.readInt(u16, buf[6..8], .big),
            .ns_count = std.mem.readInt(u16, buf[8..10], .big),
            .ar_count = std.mem.readInt(u16, buf[10..12], .big),
        };
    }
};

/// DNS question.
pub const Question = struct {
    name: Name,
    qtype: Type,
    qclass: Class,

    pub fn encode(self: Question, buf: []u8) error{BufferTooSmall}![]u8 {
        var pos: usize = 0;

        // Encode name
        const name_bytes = try self.name.encode(buf);
        pos += name_bytes.len;

        if (buf.len < pos + 4) return error.BufferTooSmall;

        // Encode type and class
        std.mem.writeInt(u16, buf[pos..][0..2], @intFromEnum(self.qtype), .big);
        pos += 2;
        std.mem.writeInt(u16, buf[pos..][0..2], @intFromEnum(self.qclass), .big);
        pos += 2;

        return buf[0..pos];
    }
};

/// Decoded resource record.
pub const ResourceRecord = struct {
    name: Name,
    rtype: Type,
    class: Class,
    ttl: u32,
    rdata: []const u8,

    /// Parse A record (IPv4 address).
    pub fn parseA(self: ResourceRecord) ?[4]u8 {
        if (self.rtype != .A or self.rdata.len != 4) return null;
        return self.rdata[0..4].*;
    }

    /// Parse AAAA record (IPv6 address).
    pub fn parseAAAA(self: ResourceRecord) ?[16]u8 {
        if (self.rtype != .AAAA or self.rdata.len != 16) return null;
        return self.rdata[0..16].*;
    }

    /// Parse CNAME record. Returns the target name.
    pub fn parseCNAME(self: ResourceRecord, msg: []const u8) ?Name {
        if (self.rtype != .CNAME) return null;
        // CNAME rdata is a compressed name, need the full message for decompression
        return Name.decode(msg, @intFromPtr(self.rdata.ptr) - @intFromPtr(msg.ptr)) catch null;
    }
};

/// DNS domain name with support for compression.
pub const Name = struct {
    /// Raw label data (without compression).
    data: [max_name_len]u8 = undefined,
    len: u8 = 0,

    /// Create a Name from a dotted string (e.g., "example.com").
    pub fn fromString(s: []const u8) error{ NameTooLong, InvalidName }!Name {
        var name: Name = .{};
        var pos: usize = 0;

        if (s.len == 0) {
            // Root domain
            name.data[0] = 0;
            name.len = 1;
            return name;
        }

        var iter = std.mem.splitScalar(u8, s, '.');
        while (iter.next()) |label| {
            if (label.len == 0) {
                // Empty label - only allow as trailing root label
                if (iter.peek() != null) return error.InvalidName; // Interior empty label
                continue; // Trailing dot, skip (we add root terminator anyway)
            }
            if (label.len > max_label_len) return error.InvalidName;
            if (pos + 1 + label.len > max_name_len) return error.NameTooLong;

            name.data[pos] = @intCast(label.len);
            pos += 1;
            @memcpy(name.data[pos..][0..label.len], label);
            pos += label.len;
        }

        if (pos + 1 > max_name_len) return error.NameTooLong;
        name.data[pos] = 0; // Terminating zero-length label
        pos += 1;
        name.len = @intCast(pos);

        return name;
    }

    /// Encode the name into wire format (already in wire format internally).
    pub fn encode(self: Name, buf: []u8) error{BufferTooSmall}![]u8 {
        if (buf.len < self.len) return error.BufferTooSmall;
        @memcpy(buf[0..self.len], self.data[0..self.len]);
        return buf[0..self.len];
    }

    /// Decode a name from wire format, handling compression pointers.
    pub fn decode(msg: []const u8, start: usize) error{ Truncated, InvalidName }!Name {
        var name: Name = .{};
        var pos = start;
        var out: usize = 0;
        var jumps: usize = 0;
        var end_pos: ?usize = null;

        while (true) {
            if (pos >= msg.len) return error.Truncated;

            const len = msg[pos];

            // Check for compression pointer (top 2 bits set)
            if (len & 0xC0 == 0xC0) {
                if (pos + 1 >= msg.len) return error.Truncated;

                // Save the position after the pointer (for returning)
                if (end_pos == null) {
                    end_pos = pos + 2;
                }

                // Follow the pointer
                const offset = (@as(u16, len & 0x3F) << 8) | msg[pos + 1];
                pos = offset;

                // Prevent infinite loops
                jumps += 1;
                if (jumps > max_name_len) return error.InvalidName;
                continue;
            }

            // Zero length = end of name
            if (len == 0) {
                if (out + 1 > max_name_len) return error.InvalidName;
                name.data[out] = 0;
                out += 1;
                break;
            }

            // Regular label
            if (len > max_label_len) return error.InvalidName;
            if (pos + 1 + len > msg.len) return error.Truncated;
            if (out + 1 + len > max_name_len) return error.InvalidName;

            name.data[out] = len;
            out += 1;
            @memcpy(name.data[out..][0..len], msg[pos + 1 ..][0..len]);
            out += len;
            pos += 1 + len;
        }

        name.len = @intCast(out);
        return name;
    }

    /// Get the wire format length (for skipping in message parsing).
    pub fn wireLen(msg: []const u8, start: usize) error{Truncated}!usize {
        var pos = start;
        while (true) {
            if (pos >= msg.len) return error.Truncated;
            const len = msg[pos];
            if (len & 0xC0 == 0xC0) {
                // Compression pointer - 2 bytes
                return pos + 2 - start;
            }
            if (len == 0) {
                return pos + 1 - start;
            }
            pos += 1 + len;
        }
    }

    /// Convert to a dotted string representation.
    pub fn toString(self: Name, buf: []u8) []u8 {
        var pos: usize = 0;
        var out: usize = 0;

        while (pos < self.len) {
            const label_len = self.data[pos];
            if (label_len == 0) break;

            if (out > 0 and out < buf.len) {
                buf[out] = '.';
                out += 1;
            }

            const end = @min(out + label_len, buf.len);
            const copy_len = end - out;
            if (copy_len > 0) {
                @memcpy(buf[out..end], self.data[pos + 1 ..][0..copy_len]);
                out = end;
            }
            pos += 1 + label_len;
        }

        return buf[0..out];
    }

    /// Check if two names are equal (case-insensitive per RFC 1035).
    pub fn eql(a: Name, b: Name) bool {
        if (a.len != b.len) return false;
        return std.ascii.eqlIgnoreCase(a.data[0..a.len], b.data[0..b.len]);
    }
};

/// EDNS0 OPT pseudo-record for advertising larger buffer sizes.
pub const EdnsOpt = struct {
    udp_size: u16 = max_packet_size,

    pub fn encode(self: EdnsOpt, buf: []u8) error{BufferTooSmall}![]u8 {
        // OPT record format:
        // - Name: root (1 byte, 0x00)
        // - Type: OPT (2 bytes)
        // - Class: UDP payload size (2 bytes)
        // - TTL: extended RCODE and flags (4 bytes)
        // - RDLENGTH: 0 (2 bytes)
        if (buf.len < 11) return error.BufferTooSmall;

        buf[0] = 0; // Root name
        std.mem.writeInt(u16, buf[1..3], @intFromEnum(Type.OPT), .big);
        std.mem.writeInt(u16, buf[3..5], self.udp_size, .big);
        std.mem.writeInt(u32, buf[5..9], 0, .big); // Extended RCODE + flags
        std.mem.writeInt(u16, buf[9..11], 0, .big); // RDLENGTH

        return buf[0..11];
    }
};

/// Build a DNS query message.
pub fn buildQuery(
    buf: []u8,
    id: u16,
    name: Name,
    qtype: Type,
    with_edns: bool,
) error{BufferTooSmall}![]u8 {
    var pos: usize = 0;

    // Header
    const header = Header{
        .id = id,
        .flags = .{ .rd = true },
        .qd_count = 1,
        .an_count = 0,
        .ns_count = 0,
        .ar_count = if (with_edns) 1 else 0,
    };
    _ = header.encode(buf[pos..]);
    pos += 12;

    // Question
    const question = Question{
        .name = name,
        .qtype = qtype,
        .qclass = .IN,
    };
    const q_bytes = try question.encode(buf[pos..]);
    pos += q_bytes.len;

    // EDNS0 OPT record
    if (with_edns) {
        const opt = EdnsOpt{};
        const opt_bytes = try opt.encode(buf[pos..]);
        pos += opt_bytes.len;
    }

    return buf[0..pos];
}

/// Parser for DNS response messages.
pub const ResponseParser = struct {
    msg: []const u8,
    pos: usize,
    header: Header,

    pub const ParseError = error{ Truncated, InvalidName, InvalidResponse };

    pub fn init(msg: []const u8) ParseError!ResponseParser {
        const header = Header.decode(msg) catch return error.Truncated;

        // Basic validation
        if (!header.flags.qr) return error.InvalidResponse; // Must be a response

        return .{
            .msg = msg,
            .pos = 12,
            .header = header,
        };
    }

    /// Skip the question section.
    pub fn skipQuestions(self: *ResponseParser) ParseError!void {
        var count = self.header.qd_count;
        while (count > 0) : (count -= 1) {
            // Skip name
            const name_len = Name.wireLen(self.msg, self.pos) catch return error.Truncated;
            self.pos += name_len;

            // Skip type and class
            if (self.pos + 4 > self.msg.len) return error.Truncated;
            self.pos += 4;
        }
    }

    /// Read the next resource record from the answer section.
    pub fn nextAnswer(self: *ResponseParser, remaining: *u16) ParseError!?ResourceRecord {
        if (remaining.* == 0) return null;
        remaining.* -= 1;

        const rr = try self.readResourceRecord();
        return rr;
    }

    fn readResourceRecord(self: *ResponseParser) ParseError!ResourceRecord {
        // Name
        const name = Name.decode(self.msg, self.pos) catch return error.InvalidName;
        const name_len = Name.wireLen(self.msg, self.pos) catch return error.Truncated;
        self.pos += name_len;

        // Type, Class, TTL, RDLENGTH
        if (self.pos + 10 > self.msg.len) return error.Truncated;

        const rtype: Type = @enumFromInt(std.mem.readInt(u16, self.msg[self.pos..][0..2], .big));
        self.pos += 2;
        const class: Class = @enumFromInt(std.mem.readInt(u16, self.msg[self.pos..][0..2], .big));
        self.pos += 2;
        const ttl = std.mem.readInt(u32, self.msg[self.pos..][0..4], .big);
        self.pos += 4;
        const rdlength = std.mem.readInt(u16, self.msg[self.pos..][0..2], .big);
        self.pos += 2;

        if (self.pos + rdlength > self.msg.len) return error.Truncated;
        const rdata = self.msg[self.pos..][0..rdlength];
        self.pos += rdlength;

        return .{
            .name = name,
            .rtype = rtype,
            .class = class,
            .ttl = ttl,
            .rdata = rdata,
        };
    }
};

// Tests

test "Name.fromString" {
    const name = try Name.fromString("example.com");
    var buf: [256]u8 = undefined;
    const s = name.toString(&buf);
    try std.testing.expectEqualStrings("example.com", s);
}

test "Name.fromString root" {
    const name = try Name.fromString("");
    try std.testing.expectEqual(@as(u8, 1), name.len);
    try std.testing.expectEqual(@as(u8, 0), name.data[0]);
}

test "Name.fromString trailing dot" {
    const name = try Name.fromString("example.com.");
    var buf: [256]u8 = undefined;
    const s = name.toString(&buf);
    try std.testing.expectEqualStrings("example.com", s);
}

test "Name wire encoding roundtrip" {
    const original = try Name.fromString("www.example.com");

    var wire_buf: [256]u8 = undefined;
    const wire = try original.encode(&wire_buf);

    const decoded = try Name.decode(wire, 0);
    try std.testing.expect(original.eql(decoded));
}

test "Name compression decoding" {
    // Simulate a compressed name: pointer to offset 0
    const msg = [_]u8{
        // Name "example.com" at offset 0
        7, 'e', 'x', 'a', 'm', 'p',  'l',  'e',
        3, 'c', 'o', 'm', 0,
        // Pointer to offset 0
          0xC0, 0x00,
    };

    const name1 = try Name.decode(&msg, 0);
    const name2 = try Name.decode(&msg, 13); // Should decompress to same name

    try std.testing.expect(name1.eql(name2));
}

test "buildQuery" {
    var buf: [512]u8 = undefined;
    const name = try Name.fromString("example.com");
    const query = try buildQuery(&buf, 0x1234, name, .A, true);

    // Parse it back
    const header = try Header.decode(query);
    try std.testing.expectEqual(@as(u16, 0x1234), header.id);
    try std.testing.expectEqual(@as(u16, 1), header.qd_count);
    try std.testing.expectEqual(@as(u16, 1), header.ar_count); // EDNS0
    try std.testing.expect(header.flags.rd);
    try std.testing.expect(!header.flags.qr);
}

test "Header encode/decode roundtrip" {
    const original = Header{
        .id = 0xABCD,
        .flags = .{ .rd = true, .aa = true },
        .qd_count = 1,
        .an_count = 2,
        .ns_count = 3,
        .ar_count = 4,
    };

    var buf: [12]u8 = undefined;
    _ = original.encode(&buf);

    const decoded = try Header.decode(&buf);
    try std.testing.expectEqual(original.id, decoded.id);
    try std.testing.expectEqual(original.flags, decoded.flags);
    try std.testing.expectEqual(original.qd_count, decoded.qd_count);
    try std.testing.expectEqual(original.an_count, decoded.an_count);
}
