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
    const write_iov = [_]aio.WriteBuf{.fromSlice(write_data)};
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
    var read_iov = [_]aio.ReadBuf{.fromSlice(&read_buffer)};
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

test "File: rename/delete" {
    var thread_pool: aio.ThreadPool = undefined;
    try thread_pool.init(std.testing.allocator, .{ .min_threads = 1, .max_threads = 4 });
    defer thread_pool.deinit();

    var loop: aio.Loop = undefined;
    try loop.init(.{ .allocator = std.testing.allocator, .thread_pool = &thread_pool });
    defer loop.deinit();

    const cwd = std.fs.cwd();

    // Create a test file
    var file_create = aio.FileCreate.init(cwd.fd, "test-rename-src", .{ .read = true, .truncate = true, .mode = 0o664 });
    loop.add(&file_create.c);
    try loop.run(.until_done);
    try std.testing.expectEqual(.completed, file_create.c.state);
    const fd = try file_create.getResult();

    // Write some data
    const write_data = "rename test";
    const write_iov = [_]aio.WriteBuf{.fromSlice(write_data)};
    var file_write = aio.FileWrite.init(fd, &write_iov, 0);
    loop.add(&file_write.c);
    try loop.run(.until_done);
    try std.testing.expectEqual(.completed, file_write.c.state);

    // Close the file
    var file_close = aio.FileClose.init(fd);
    loop.add(&file_close.c);
    try loop.run(.until_done);
    try std.testing.expectEqual(.completed, file_close.c.state);

    // Rename the file
    var file_rename = aio.FileRename.init(cwd.fd, "test-rename-src", cwd.fd, "test-rename-dst");
    loop.add(&file_rename.c);
    try loop.run(.until_done);
    try std.testing.expectEqual(.completed, file_rename.c.state);
    try std.testing.expectEqual(true, file_rename.c.has_result);
    try file_rename.getResult();

    // Verify the renamed file exists by opening it
    var file_open = aio.FileOpen.init(cwd.fd, "test-rename-dst", .{ .mode = .read_only });
    loop.add(&file_open.c);
    try loop.run(.until_done);
    try std.testing.expectEqual(.completed, file_open.c.state);
    const fd2 = try file_open.getResult();

    // Read and verify the data
    var read_buffer = [_]u8{0} ** 64;
    var read_iov = [_]aio.ReadBuf{.fromSlice(&read_buffer)};
    var file_read = aio.FileRead.init(fd2, &read_iov, 0);
    loop.add(&file_read.c);
    try loop.run(.until_done);
    try std.testing.expectEqual(.completed, file_read.c.state);
    const bytes_read = try file_read.getResult();
    try std.testing.expectEqual(write_data.len, bytes_read);
    try std.testing.expectEqualStrings(write_data, read_buffer[0..bytes_read]);

    // Close the file
    var file_close2 = aio.FileClose.init(fd2);
    loop.add(&file_close2.c);
    try loop.run(.until_done);
    try std.testing.expectEqual(.completed, file_close2.c.state);

    // Delete the file
    var file_delete = aio.FileDelete.init(cwd.fd, "test-rename-dst");
    loop.add(&file_delete.c);
    try loop.run(.until_done);
    try std.testing.expectEqual(.completed, file_delete.c.state);
    try std.testing.expectEqual(true, file_delete.c.has_result);
    try file_delete.getResult();

    // Verify the file no longer exists
    var file_open_fail = aio.FileOpen.init(cwd.fd, "test-rename-dst", .{ .mode = .read_only });
    loop.add(&file_open_fail.c);
    try loop.run(.until_done);
    try std.testing.expectEqual(.completed, file_open_fail.c.state);
    try std.testing.expectError(error.FileNotFound, file_open_fail.getResult());
}
