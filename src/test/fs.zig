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

    var file_open = aio.FileOpen.init(cwd.fd, "test-file", 0o664, .{ .create = true, .truncate = true });
    loop.add(&file_open.c);

    try loop.run(.until_done);

    try std.testing.expectEqual(.completed, file_open.c.state);
    try std.testing.expectEqual(true, file_open.c.has_result);

    const fd = try file_open.getResult();
    if (builtin.os.tag == .windows) {
        try std.testing.expect(fd != std.os.windows.INVALID_HANDLE_VALUE);
    } else {
        try std.testing.expect(fd > 0);
    }

    // Sync file (full sync)
    var file_sync1 = aio.FileSync.init(fd, .{ .only_data = false });
    loop.add(&file_sync1.c);
    try loop.run(.until_done);
    try std.testing.expectEqual(.completed, file_sync1.c.state);
    try std.testing.expectEqual(true, file_sync1.c.has_result);
    try file_sync1.getResult();

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
