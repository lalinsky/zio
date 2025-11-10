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

    var file_close = aio.FileClose.init(fd);
    loop.add(&file_close.c);

    try loop.run(.until_done);

    try std.testing.expectEqual(.completed, file_close.c.state);
    try std.testing.expectEqual(true, file_close.c.has_result);

    try file_close.getResult();
}
