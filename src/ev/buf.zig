const std = @import("std");
const os = @import("../os/root.zig");

pub const ReadBuf = struct {
    iovecs: []os.iovec,

    pub fn fromSlice(slice: []u8, storage: []os.iovec) ReadBuf {
        storage[0] = os.iovecFromSlice(slice);
        return .{ .iovecs = storage[0..1] };
    }

    pub fn fromSlices(slices: [][]u8, storage: []os.iovec) ReadBuf {
        const len = @min(slices.len, storage.len);
        for (0..len) |i| {
            storage[i] = os.iovecFromSlice(slices[i]);
        }
        return .{ .iovecs = storage[0..len] };
    }
};

pub const WriteBuf = struct {
    iovecs: []const os.iovec_const,

    pub fn fromSlice(slice: []const u8, storage: []os.iovec_const) WriteBuf {
        storage[0] = os.iovecConstFromSlice(slice);
        return .{ .iovecs = storage[0..1] };
    }

    pub fn fromSlices(slices: []const []const u8, storage: []os.iovec_const) WriteBuf {
        const len = @min(slices.len, storage.len);
        for (0..len) |i| {
            storage[i] = os.iovecConstFromSlice(slices[i]);
        }
        return .{ .iovecs = storage[0..len] };
    }
};
