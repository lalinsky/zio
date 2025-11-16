const std = @import("std");
const system = @import("system.zig");

pub const ReadBuf = struct {
    iovecs: []system.iovec,

    pub fn fromSlice(slice: []u8, storage: []system.iovec) ReadBuf {
        storage[0] = system.iovecFromSlice(slice);
        return .{ .iovecs = storage[0..1] };
    }

    pub fn fromSlices(slices: [][]u8, storage: []system.iovec) ReadBuf {
        const len = @min(slices.len, storage.len);
        for (0..len) |i| {
            storage[i] = system.iovecFromSlice(slices[i]);
        }
        return .{ .iovecs = storage[0..len] };
    }
};

pub const WriteBuf = struct {
    iovecs: []const system.iovec_const,

    pub fn fromSlice(slice: []const u8, storage: []system.iovec_const) WriteBuf {
        storage[0] = system.iovecConstFromSlice(slice);
        return .{ .iovecs = storage[0..1] };
    }

    pub fn fromSlices(slices: []const []const u8, storage: []system.iovec_const) WriteBuf {
        const len = @min(slices.len, storage.len);
        for (0..len) |i| {
            storage[i] = system.iovecConstFromSlice(slices[i]);
        }
        return .{ .iovecs = storage[0..len] };
    }
};
