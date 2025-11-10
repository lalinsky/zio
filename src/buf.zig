const std = @import("std");
const system = @import("system.zig");

pub const ReadBuf = extern struct {
    data: system.iovec,

    pub fn fromSlice(data: []u8) ReadBuf {
        return .{ .data = system.iovecFromSlice(data) };
    }

    pub fn fromSlices(src: [][]u8, dest: []ReadBuf) []ReadBuf {
        const len = @min(src.len, dest.len);
        for (0..len) |i| {
            dest[i] = ReadBuf.fromSlice(src[i]);
        }
        return dest[0..len];
    }

    pub fn toIovecs(bufs: []const ReadBuf) []system.iovec {
        std.debug.assert(@alignOf(ReadBuf) == @alignOf(system.iovec));
        std.debug.assert(@sizeOf(ReadBuf) == @sizeOf(system.iovec));
        std.debug.assert(@bitSizeOf(ReadBuf) == @bitSizeOf(system.iovec));
        var ptr: [*]system.iovec = @ptrCast(@constCast(bufs.ptr));
        return ptr[0..bufs.len];
    }
};

pub const WriteBuf = extern struct {
    data: system.iovec_const,

    pub fn fromSlice(data: []const u8) WriteBuf {
        return .{ .data = system.iovecConstFromSlice(data) };
    }

    pub fn fromSlices(comptime n: usize, slices: [][]const u8) [n]WriteBuf {
        var bufs = [_]WriteBuf{undefined} ** n;
        const len = @min(slices.len, n);
        for (0..len) |i| {
            bufs[i] = WriteBuf.fromSlice(slices[i]);
        }
        return bufs;
    }

    pub fn toIovecs(bufs: []const WriteBuf) []const system.iovec_const {
        std.debug.assert(@alignOf(WriteBuf) == @alignOf(system.iovec_const));
        std.debug.assert(@sizeOf(WriteBuf) == @sizeOf(system.iovec_const));
        std.debug.assert(@bitSizeOf(WriteBuf) == @bitSizeOf(system.iovec_const));
        var ptr: [*]const system.iovec_const = @ptrCast(bufs.ptr);
        return ptr[0..bufs.len];
    }
};
