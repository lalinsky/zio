//! Mini-Redis Server
//!
//! A minimal Redis server implementation demonstrating the use of zio's
//! Reader/Writer interfaces for protocol parsing and response building.
//!
//! Implements RESP2 (REdis Serialization Protocol) with the following commands:
//! - PING: Returns PONG
//! - ECHO <message>: Returns the message
//! - SET <key> <value>: Stores a key-value pair
//! - GET <key>: Retrieves a value by key
//! - DEL <key>: Deletes a key
//! - EXISTS <key>: Checks if a key exists
//!
//! Usage:
//!   zig build
//!   ./zig-out/bin/mini-redis
//!
//! Test with redis-cli:
//!   redis-cli -p 6379
//!   > PING
//!   PONG
//!   > SET greeting "Hello, World!"
//!   OK
//!   > GET greeting
//!   "Hello, World!"

const std = @import("std");
const zio = @import("zio");

// Protocol limits
const MAX_BULK_LEN = 64 * 1024; // 64KB max bulk string
const MAX_ARRAY_LEN = 128; // max command args

// Buffer sizes
const READ_BUFFER_SIZE = 64 * 1024; // 64KB for reading commands
const WRITE_BUFFER_SIZE = 16 * 1024; // 16KB for writing responses

// =============================================================================
// StringRef - Reference-counted string with single allocation
// =============================================================================

/// A reference-counted string with single allocation for struct + data
const StringRef = struct {
    refcount: usize,
    len: usize,
    data: [0]u8,

    /// Create a new StringRef with refcount=1
    /// Allocates StringRef struct and string data in a single memory block
    fn create(allocator: std.mem.Allocator, str: []const u8) !*StringRef {
        // Calculate total size: StringRef struct + string data
        const total_size = @sizeOf(StringRef) + str.len;

        // Single allocation for both struct and data
        const bytes = try allocator.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(@alignOf(StringRef)), total_size);
        errdefer allocator.free(bytes);

        // First part is the StringRef struct
        const ref: *StringRef = @ptrCast(bytes.ptr);

        // Initialize the struct
        ref.* = .{
            .refcount = 1,
            .len = str.len,
            .data = undefined,
        };

        // Second part is the string data (right after the struct)
        const data_ptr: [*]u8 = @ptrCast(&ref.data);
        const data_slice = data_ptr[0..str.len];
        @memcpy(data_slice, str);

        return ref;
    }

    /// Get data slice from StringRef
    fn getData(self: *const StringRef) []const u8 {
        const data_ptr: [*]const u8 = @ptrCast(&self.data);
        return data_ptr[0..self.len];
    }

    /// Get StringRef pointer from data slice
    fn fromData(data: []const u8) *StringRef {
        const field_ptr: *const [0]u8 = @ptrCast(data.ptr);
        const parent: *align(1) const StringRef = @fieldParentPtr("data", field_ptr);
        return @alignCast(@constCast(parent));
    }

    /// Increment the reference count
    fn borrow(self: *StringRef) void {
        self.refcount += 1;
    }

    /// Decrement the reference count and free if it reaches zero
    fn release(self: *StringRef, allocator: std.mem.Allocator) void {
        self.refcount -= 1;
        if (self.refcount == 0) {
            self.destroy(allocator);
        }
    }

    /// Destroy the StringRef (called when refcount reaches 0)
    fn destroy(self: *StringRef, allocator: std.mem.Allocator) void {
        // Reconstruct the original allocation from self pointer
        const bytes: [*]align(@alignOf(StringRef)) u8 = @ptrCast(self);
        const total_size = @sizeOf(StringRef) + self.len;
        allocator.free(bytes[0..total_size]);
    }
};

// =============================================================================
// Store - Key-Value Storage
// =============================================================================

const Store = struct {
    map: std.StringHashMapUnmanaged(*StringRef),
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) Store {
        return .{
            .map = .{},
            .allocator = allocator,
        };
    }

    fn deinit(self: *Store) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.release(self.allocator);
            self.allocator.free(entry.key_ptr.*);
        }
        self.map.deinit(self.allocator);
    }

    fn set(self: *Store, key: []const u8, value: []const u8) !void {
        // Create new StringRef
        const value_ref = try StringRef.create(self.allocator, value);
        errdefer value_ref.release(self.allocator);

        // Get or put the key
        const gop = try self.map.getOrPut(self.allocator, key);
        errdefer if (!gop.found_existing) self.map.removeByPtr(gop.key_ptr);

        if (gop.found_existing) {
            // Release old value
            gop.value_ptr.*.release(self.allocator);
        } else {
            // Allocate owned key for new entry
            gop.key_ptr.* = try self.allocator.dupe(u8, key);
        }

        // Set new value
        gop.value_ptr.* = value_ref;
    }

    fn get(self: *Store, key: []const u8) ?[]const u8 {
        if (self.map.get(key)) |value_ref| {
            value_ref.borrow();
            return value_ref.getData();
        }
        return null;
    }

    fn releaseValue(self: *Store, value_data: []const u8) void {
        const ref = StringRef.fromData(value_data);
        ref.release(self.allocator);
    }

    fn del(self: *Store, key: []const u8) bool {
        if (self.map.fetchRemove(key)) |kv| {
            kv.value.release(self.allocator);
            self.allocator.free(kv.key);
            return true;
        }
        return false;
    }

    fn exists(self: *Store, key: []const u8) bool {
        return self.map.contains(key);
    }
};

// =============================================================================
// RESP2 Protocol Parser
// =============================================================================

const Command = struct {
    args: [][]u8,
    arena: std.heap.ArenaAllocator,

    fn deinit(self: *Command) void {
        self.arena.deinit();
    }
};

const RespParser = struct {
    reader: *std.io.Reader,
    allocator: std.mem.Allocator,

    /// Parse one command (array of bulk strings)
    fn parseCommand(self: *RespParser) !Command {
        // Read '*' + count + \r\n
        const star = try self.reader.takeByte();
        if (star != '*') return error.ProtocolError;

        const count_line = try self.reader.takeDelimiterExclusive('\n');
        if (count_line.len == 0 or count_line[count_line.len - 1] != '\r') {
            return error.ProtocolError;
        }

        const count = try std.fmt.parseInt(usize, count_line[0 .. count_line.len - 1], 10);
        if (count == 0 or count > MAX_ARRAY_LEN) return error.ProtocolError;

        // Create arena for this command's allocations
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();

        const arena_allocator = arena.allocator();

        // Parse each bulk string
        const args = try arena_allocator.alloc([]u8, count);
        var i: usize = 0;

        while (i < count) : (i += 1) {
            args[i] = try self.parseBulkString(arena_allocator);
        }

        return Command{ .args = args, .arena = arena };
    }

    /// Parse $<len>\r\n<data>\r\n
    fn parseBulkString(self: *RespParser, allocator: std.mem.Allocator) ![]u8 {
        const dollar = try self.reader.takeByte();
        if (dollar != '$') return error.ProtocolError;

        const len_line = try self.reader.takeDelimiterExclusive('\n');
        if (len_line.len == 0 or len_line[len_line.len - 1] != '\r') {
            return error.ProtocolError;
        }

        const len = try std.fmt.parseInt(usize, len_line[0 .. len_line.len - 1], 10);
        if (len > MAX_BULK_LEN) return error.BulkStringTooLarge;

        // Read data + \r\n
        const data = try self.reader.take(len);
        const owned = try allocator.dupe(u8, data);

        const cr = try self.reader.takeByte();
        const lf = try self.reader.takeByte();
        if (cr != '\r' or lf != '\n') return error.ProtocolError;

        return owned;
    }
};

// =============================================================================
// RESP2 Response Writer
// =============================================================================

const RespWriter = struct {
    writer: *std.io.Writer,

    /// Write +OK\r\n style response
    fn writeSimpleString(self: *RespWriter, str: []const u8) !void {
        try self.writer.writeByte('+');
        try self.writer.writeAll(str);
        try self.writer.writeAll("\r\n");
    }

    /// Write -ERR message\r\n style response
    fn writeError(self: *RespWriter, msg: []const u8) !void {
        try self.writer.writeByte('-');
        try self.writer.writeAll(msg);
        try self.writer.writeAll("\r\n");
    }

    /// Write :123\r\n style response
    fn writeInteger(self: *RespWriter, n: i64) !void {
        try self.writer.writeByte(':');
        try self.writer.print("{d}\r\n", .{n});
    }

    /// Write $6\r\nfoobar\r\n style response
    fn writeBulkString(self: *RespWriter, str: []const u8) !void {
        try self.writer.print("${d}\r\n", .{str.len});
        try self.writer.writeAll(str);
        try self.writer.writeAll("\r\n");
    }

    /// Write $-1\r\n (null bulk string)
    fn writeNull(self: *RespWriter) !void {
        try self.writer.writeAll("$-1\r\n");
    }
};

// =============================================================================
// Command Handlers
// =============================================================================

const CommandHandler = struct {
    store: *Store,

    fn execute(self: *CommandHandler, cmd: *Command, resp: *RespWriter) !void {
        if (cmd.args.len == 0) return error.EmptyCommand;

        const command_name = cmd.args[0];

        // Convert command to uppercase for case-insensitive matching
        var upper_buf: [32]u8 = undefined;
        if (command_name.len > upper_buf.len) {
            return resp.writeError("ERR command name too long");
        }
        const upper_cmd = std.ascii.upperString(&upper_buf, command_name);

        if (std.mem.eql(u8, upper_cmd, "PING")) {
            return self.handlePing(cmd, resp);
        } else if (std.mem.eql(u8, upper_cmd, "ECHO")) {
            return self.handleEcho(cmd, resp);
        } else if (std.mem.eql(u8, upper_cmd, "SET")) {
            return self.handleSet(cmd, resp);
        } else if (std.mem.eql(u8, upper_cmd, "GET")) {
            return self.handleGet(cmd, resp);
        } else if (std.mem.eql(u8, upper_cmd, "DEL")) {
            return self.handleDel(cmd, resp);
        } else if (std.mem.eql(u8, upper_cmd, "EXISTS")) {
            return self.handleExists(cmd, resp);
        } else {
            try resp.writeError("ERR unknown command");
        }
    }

    fn handlePing(self: *CommandHandler, cmd: *Command, resp: *RespWriter) !void {
        _ = self;
        if (cmd.args.len != 1) {
            return resp.writeError("ERR wrong number of arguments for 'ping' command");
        }
        try resp.writeSimpleString("PONG");
    }

    fn handleEcho(self: *CommandHandler, cmd: *Command, resp: *RespWriter) !void {
        _ = self;
        if (cmd.args.len != 2) {
            return resp.writeError("ERR wrong number of arguments for 'echo' command");
        }
        try resp.writeBulkString(cmd.args[1]);
    }

    fn handleSet(self: *CommandHandler, cmd: *Command, resp: *RespWriter) !void {
        if (cmd.args.len != 3) {
            return resp.writeError("ERR wrong number of arguments for 'set' command");
        }
        try self.store.set(cmd.args[1], cmd.args[2]);
        try resp.writeSimpleString("OK");
    }

    fn handleGet(self: *CommandHandler, cmd: *Command, resp: *RespWriter) !void {
        if (cmd.args.len != 2) {
            return resp.writeError("ERR wrong number of arguments for 'get' command");
        }
        if (self.store.get(cmd.args[1])) |value_data| {
            defer self.store.releaseValue(value_data);
            try resp.writeBulkString(value_data);
        } else {
            try resp.writeNull();
        }
    }

    fn handleDel(self: *CommandHandler, cmd: *Command, resp: *RespWriter) !void {
        if (cmd.args.len != 2) {
            return resp.writeError("ERR wrong number of arguments for 'del' command");
        }
        const deleted = self.store.del(cmd.args[1]);
        try resp.writeInteger(if (deleted) 1 else 0);
    }

    fn handleExists(self: *CommandHandler, cmd: *Command, resp: *RespWriter) !void {
        if (cmd.args.len != 2) {
            return resp.writeError("ERR wrong number of arguments for 'exists' command");
        }
        const exists_result = self.store.exists(cmd.args[1]);
        try resp.writeInteger(if (exists_result) 1 else 0);
    }
};

// =============================================================================
// Connection Handler
// =============================================================================

const ConnectionHandler = struct {
    stream: zio.TcpStream,
    store: *Store,
    allocator: std.mem.Allocator,

    fn run(rt: *zio.Runtime, stream: zio.TcpStream, store_ptr: *Store, alloc: std.mem.Allocator) !void {
        _ = rt;
        var self = ConnectionHandler{
            .stream = stream,
            .store = store_ptr,
            .allocator = alloc,
        };
        defer self.stream.close();

        self.handle() catch |err| {
            std.log.debug("Connection handler error: {}", .{err});
        };
    }

    fn handle(self: *ConnectionHandler) !void {
        const read_buffer = try self.allocator.alloc(u8, READ_BUFFER_SIZE);
        defer self.allocator.free(read_buffer);

        const write_buffer = try self.allocator.alloc(u8, WRITE_BUFFER_SIZE);
        defer self.allocator.free(write_buffer);

        var reader = self.stream.reader(read_buffer);
        var writer = self.stream.writer(write_buffer);

        var parser = RespParser{
            .reader = &reader.interface,
            .allocator = self.allocator,
        };

        var resp_writer = RespWriter{ .writer = &writer.interface };
        var handler = CommandHandler{ .store = self.store };

        while (true) {
            var cmd = parser.parseCommand() catch |err| {
                switch (err) {
                    error.EndOfStream => break,
                    error.ProtocolError => {
                        try resp_writer.writeError("ERR Protocol error");
                        try writer.interface.flush();
                        continue;
                    },
                    error.BulkStringTooLarge => {
                        try resp_writer.writeError("ERR Bulk string too large");
                        try writer.interface.flush();
                        continue;
                    },
                    else => {
                        try resp_writer.writeError("ERR Internal error");
                        try writer.interface.flush();
                        return err;
                    },
                }
            };
            defer cmd.deinit();

            handler.execute(&cmd, &resp_writer) catch |err| {
                std.log.err("Command execution error: {}", .{err});
                try resp_writer.writeError("ERR Command failed");
            };

            try writer.interface.flush();
        }
    }
};

// =============================================================================
// Main Server
// =============================================================================

fn runServer(rt: *zio.Runtime, store_ptr: *Store, alloc: std.mem.Allocator) !void {
    const addr = try zio.Address.parseIp4("127.0.0.1", 6379);
    var listener = try zio.TcpListener.init(rt, addr);
    defer listener.close();

    try listener.bind(addr);
    try listener.listen(128);

    std.log.info("Mini-Redis server listening on 127.0.0.1:6379", .{});
    std.log.info("Test with: redis-cli -p 6379", .{});

    while (true) {
        var stream = try listener.accept();
        errdefer stream.close();
        var handle = try rt.spawn(ConnectionHandler.run, .{ rt, stream, store_ptr, alloc }, .{});
        handle.deinit();
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var runtime = try zio.Runtime.init(allocator, .{});
    defer runtime.deinit();

    var store = Store.init(allocator);
    defer store.deinit();

    try runtime.runUntilComplete(runServer, .{ &runtime, &store, allocator }, .{});
}
