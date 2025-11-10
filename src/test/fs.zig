const std = @import("std");
const builtin = @import("builtin");
const aio = @import("../root.zig");

test "File: open/close" {
    var thread_pool: aio.ThreadPool = undefined;
    try thread_pool.init(std.testing.allocator, .{ .min_threads = 1, .max_threads = 4 });
    defer thread_pool.deinit();

    var loop: aio.Loop = undefined;
    try loop.init(.{ .allocator = std.testing.allocator, .thread_pool = &thread_pool });
    defer loop.deinit();

    const cwd = std.fs.cwd();

    var file_create = aio.FileCreate.init(cwd.fd, "test-file", .{ .read = true, .truncate = true, .mode = 0o664 });
    loop.add(&file_create.c);

    try loop.run(.until_done);

    try std.testing.expectEqual(.completed, file_create.c.state);
    try std.testing.expectEqual(true, file_create.c.has_result);

    const fd = try file_create.getResult();
    if (builtin.os.tag == .windows) {
        try std.testing.expect(fd != std.os.windows.INVALID_HANDLE_VALUE);
    } else {
        try std.testing.expect(fd > 0);
    }

    // Write some data to the file
    const write_data = "Hello, zevent!";
    const write_iov = [_]aio.system.iovec_const{aio.system.iovecConstFromSlice(write_data)};
    var file_write = aio.FileWrite.init(fd, &write_iov, 0);
    loop.add(&file_write.c);
    try loop.run(.until_done);
    try std.testing.expectEqual(.completed, file_write.c.state);
    try std.testing.expectEqual(true, file_write.c.has_result);
    const bytes_written = try file_write.getResult();
    try std.testing.expectEqual(write_data.len, bytes_written);

    // Sync file (full sync)
    var file_sync1 = aio.FileSync.init(fd, .{ .only_data = false });
    loop.add(&file_sync1.c);
    try loop.run(.until_done);
    try std.testing.expectEqual(.completed, file_sync1.c.state);
    try std.testing.expectEqual(true, file_sync1.c.has_result);
    try file_sync1.getResult();

    // Read the data back
    var read_buffer = [_]u8{0} ** 64;
    var read_iov = [_]aio.system.iovec{aio.system.iovecFromSlice(&read_buffer)};
    var file_read = aio.FileRead.init(fd, &read_iov, 0);
    loop.add(&file_read.c);
    try loop.run(.until_done);
    try std.testing.expectEqual(.completed, file_read.c.state);
    try std.testing.expectEqual(true, file_read.c.has_result);
    const bytes_read = try file_read.getResult();
    try std.testing.expectEqual(write_data.len, bytes_read);
    try std.testing.expectEqualStrings(write_data, read_buffer[0..bytes_read]);

    // Sync file (data only)
    var file_sync2 = aio.FileSync.init(fd, .{ .only_data = true });
    loop.add(&file_sync2.c);
    try loop.run(.until_done);
    try std.testing.expectEqual(.completed, file_sync2.c.state);
    try std.testing.expectEqual(true, file_sync2.c.has_result);
    try file_sync2.getResult();

    var file_close = aio.FileClose.init(fd);
    loop.add(&file_close.c);

    try loop.run(.until_done);

    try std.testing.expectEqual(.completed, file_close.c.state);
    try std.testing.expectEqual(true, file_close.c.has_result);

    try file_close.getResult();
}
