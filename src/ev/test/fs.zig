const std = @import("std");
const builtin = @import("builtin");
const ev = @import("../root.zig");
const os = @import("../../os/root.zig");

test "File: open/close" {
    var thread_pool: ev.ThreadPool = undefined;
    try thread_pool.init(.{ .min_threads = 1, .max_threads = 4 });
    defer thread_pool.deinit();

    var loop: ev.Loop = undefined;
    try loop.init(.{ .allocator = std.testing.allocator, .thread_pool = &thread_pool });
    defer loop.deinit();
    // Stop the pool before the loop is torn down: completion
    // callbacks wake the loop, so the loop must outlive the pool's workers.
    defer thread_pool.stop();

    const cwd = os.fs.cwd();

    var file_create = ev.FileCreate.init(cwd, "test-file", .{ .read = true, .truncate = true, .mode = 0o664 });
    loop.add(&file_create.c);

    try loop.run();

    try std.testing.expectEqual(.dead, file_create.c.loadState().phase);
    try std.testing.expectEqual(true, file_create.c.has_result);

    const fd = (try file_create.getResult()).fd;
    if (builtin.os.tag == .windows) {
        try std.testing.expect(fd != os.windows.INVALID_HANDLE_VALUE);
    } else {
        try std.testing.expect(fd > 0);
    }

    // Write some data to the file
    const write_data = "Hello, zevent!";
    var write_iov: [1]os.iovec_const = undefined;
    var file_write = ev.FileWrite.init(fd, .fromSlice(write_data, &write_iov), 0);
    loop.add(&file_write.c);
    try loop.run();
    try std.testing.expectEqual(.dead, file_write.c.loadState().phase);
    try std.testing.expectEqual(true, file_write.c.has_result);
    const bytes_written = try file_write.getResult();
    try std.testing.expectEqual(write_data.len, bytes_written);

    // Sync file (full sync)
    var file_sync1 = ev.FileSync.init(fd, .{ .only_data = false });
    loop.add(&file_sync1.c);
    try loop.run();
    try std.testing.expectEqual(.dead, file_sync1.c.loadState().phase);
    try std.testing.expectEqual(true, file_sync1.c.has_result);
    try file_sync1.getResult();

    // Read the data back
    var read_buffer: [64]u8 = @splat(0);
    var read_iov: [1]os.iovec = undefined;
    var file_read = ev.FileRead.init(fd, .fromSlice(&read_buffer, &read_iov), 0);
    loop.add(&file_read.c);
    try loop.run();
    try std.testing.expectEqual(.dead, file_read.c.loadState().phase);
    try std.testing.expectEqual(true, file_read.c.has_result);
    const bytes_read = try file_read.getResult();
    try std.testing.expectEqual(write_data.len, bytes_read);
    try std.testing.expectEqualStrings(write_data, read_buffer[0..bytes_read]);

    // Sync file (data only)
    var file_sync2 = ev.FileSync.init(fd, .{ .only_data = true });
    loop.add(&file_sync2.c);
    try loop.run();
    try std.testing.expectEqual(.dead, file_sync2.c.loadState().phase);
    try std.testing.expectEqual(true, file_sync2.c.has_result);
    try file_sync2.getResult();

    var file_close = ev.FileClose.init(fd);
    loop.add(&file_close.c);

    try loop.run();

    try std.testing.expectEqual(.dead, file_close.c.loadState().phase);
    try std.testing.expectEqual(true, file_close.c.has_result);

    try file_close.getResult();
}

test "File: rename/delete" {
    var thread_pool: ev.ThreadPool = undefined;
    try thread_pool.init(.{ .min_threads = 1, .max_threads = 4 });
    defer thread_pool.deinit();

    var loop: ev.Loop = undefined;
    try loop.init(.{ .allocator = std.testing.allocator, .thread_pool = &thread_pool });
    defer loop.deinit();
    // Stop the pool before the loop is torn down: completion
    // callbacks wake the loop, so the loop must outlive the pool's workers.
    defer thread_pool.stop();

    const cwd = os.fs.cwd();

    // Create a test file
    var file_create = ev.FileCreate.init(cwd, "test-rename-src", .{ .read = true, .truncate = true, .mode = 0o664 });
    loop.add(&file_create.c);
    try loop.run();
    try std.testing.expectEqual(.dead, file_create.c.loadState().phase);
    const fd = (try file_create.getResult()).fd;

    // Write some data
    const write_data = "rename test";
    var write_iov: [1]os.iovec_const = undefined;
    var file_write = ev.FileWrite.init(fd, .fromSlice(write_data, &write_iov), 0);
    loop.add(&file_write.c);
    try loop.run();
    try std.testing.expectEqual(.dead, file_write.c.loadState().phase);

    // Close the file
    var file_close = ev.FileClose.init(fd);
    loop.add(&file_close.c);
    try loop.run();
    try std.testing.expectEqual(.dead, file_close.c.loadState().phase);

    // Rename the file
    var file_rename = ev.DirRename.init(cwd, "test-rename-src", cwd, "test-rename-dst");
    loop.add(&file_rename.c);
    try loop.run();
    try std.testing.expectEqual(.dead, file_rename.c.loadState().phase);
    try std.testing.expectEqual(true, file_rename.c.has_result);
    try file_rename.getResult();

    // Verify the renamed file exists by opening it
    var file_open = ev.FileOpen.init(cwd, "test-rename-dst", .{ .mode = .read_only });
    loop.add(&file_open.c);
    try loop.run();
    try std.testing.expectEqual(.dead, file_open.c.loadState().phase);
    const fd2 = (try file_open.getResult()).fd;

    // Read and verify the data
    var read_buffer: [64]u8 = @splat(0);
    var read_iov2: [1]os.iovec = undefined;
    var file_read = ev.FileRead.init(fd2, .fromSlice(&read_buffer, &read_iov2), 0);
    loop.add(&file_read.c);
    try loop.run();
    try std.testing.expectEqual(.dead, file_read.c.loadState().phase);
    const bytes_read = try file_read.getResult();
    try std.testing.expectEqual(write_data.len, bytes_read);
    try std.testing.expectEqualStrings(write_data, read_buffer[0..bytes_read]);

    // Close the file
    var file_close2 = ev.FileClose.init(fd2);
    loop.add(&file_close2.c);
    try loop.run();
    try std.testing.expectEqual(.dead, file_close2.c.loadState().phase);

    // Delete the file
    var file_delete = ev.DirDeleteFile.init(cwd, "test-rename-dst");
    loop.add(&file_delete.c);
    try loop.run();
    try std.testing.expectEqual(.dead, file_delete.c.loadState().phase);
    try std.testing.expectEqual(true, file_delete.c.has_result);
    try file_delete.getResult();

    // Verify the file no longer exists
    var file_open_fail = ev.FileOpen.init(cwd, "test-rename-dst", .{ .mode = .read_only });
    loop.add(&file_open_fail.c);
    try loop.run();
    try std.testing.expectEqual(.dead, file_open_fail.c.loadState().phase);
    try std.testing.expectError(error.FileNotFound, file_open_fail.getResult());
}

test "File: read EOF" {
    var thread_pool: ev.ThreadPool = undefined;
    try thread_pool.init(.{ .min_threads = 1, .max_threads = 4 });
    defer thread_pool.deinit();

    var loop: ev.Loop = undefined;
    try loop.init(.{ .allocator = std.testing.allocator, .thread_pool = &thread_pool });
    defer loop.deinit();
    // Stop the pool before the loop is torn down: completion
    // callbacks wake the loop, so the loop must outlive the pool's workers.
    defer thread_pool.stop();

    const cwd = os.fs.cwd();

    // Create and write a small file
    var file_create = ev.FileCreate.init(cwd, "test-eof", .{ .read = true, .truncate = true, .mode = 0o664 });
    loop.add(&file_create.c);
    try loop.run();
    const fd = (try file_create.getResult()).fd;

    const write_data = "Hello";
    var write_iov: [1]os.iovec_const = undefined;
    var file_write = ev.FileWrite.init(fd, .fromSlice(write_data, &write_iov), 0);
    loop.add(&file_write.c);
    try loop.run();
    try std.testing.expectEqual(write_data.len, try file_write.getResult());

    // Read all data
    var read_buffer1: [64]u8 = @splat(0);
    var read_iov1: [1]os.iovec = undefined;
    var file_read1 = ev.FileRead.init(fd, .fromSlice(&read_buffer1, &read_iov1), 0);
    loop.add(&file_read1.c);
    try loop.run();
    const bytes_read1 = try file_read1.getResult();
    try std.testing.expectEqual(write_data.len, bytes_read1);
    try std.testing.expectEqualStrings(write_data, read_buffer1[0..bytes_read1]);

    // Read at EOF - should return 0 bytes, not an error
    var read_buffer2: [64]u8 = @splat(0);
    var read_iov2: [1]os.iovec = undefined;
    var file_read2 = ev.FileRead.init(fd, .fromSlice(&read_buffer2, &read_iov2), write_data.len);
    loop.add(&file_read2.c);
    try loop.run();
    try std.testing.expectEqual(.dead, file_read2.c.loadState().phase);
    try std.testing.expectEqual(true, file_read2.c.has_result);
    const bytes_read2 = try file_read2.getResult();
    try std.testing.expectEqual(0, bytes_read2);

    // Close and delete
    var file_close = ev.FileClose.init(fd);
    loop.add(&file_close.c);
    try loop.run();
    try file_close.getResult();

    var file_delete = ev.DirDeleteFile.init(cwd, "test-eof");
    loop.add(&file_delete.c);
    try loop.run();
    try file_delete.getResult();
}

test "File: size" {
    var thread_pool: ev.ThreadPool = undefined;
    try thread_pool.init(.{ .min_threads = 1, .max_threads = 4 });
    defer thread_pool.deinit();

    var loop: ev.Loop = undefined;
    try loop.init(.{ .allocator = std.testing.allocator, .thread_pool = &thread_pool });
    defer loop.deinit();
    // Stop the pool before the loop is torn down: completion
    // callbacks wake the loop, so the loop must outlive the pool's workers.
    defer thread_pool.stop();

    const cwd = os.fs.cwd();

    // Create a file
    var file_create = ev.FileCreate.init(cwd, "test-size", .{ .read = true, .truncate = true, .mode = 0o664 });
    loop.add(&file_create.c);
    try loop.run();
    const fd = (try file_create.getResult()).fd;

    // Check size of empty file
    var file_size1 = ev.FileSize.init(fd);
    loop.add(&file_size1.c);
    try loop.run();
    try std.testing.expectEqual(.dead, file_size1.c.loadState().phase);
    try std.testing.expectEqual(true, file_size1.c.has_result);
    const size1 = try file_size1.getResult();
    try std.testing.expectEqual(0, size1);

    // Write some data
    const write_data = "Hello, file size test!";
    var write_iov: [1]os.iovec_const = undefined;
    var file_write = ev.FileWrite.init(fd, .fromSlice(write_data, &write_iov), 0);
    loop.add(&file_write.c);
    try loop.run();
    try std.testing.expectEqual(write_data.len, try file_write.getResult());

    // Check size after write
    var file_size2 = ev.FileSize.init(fd);
    loop.add(&file_size2.c);
    try loop.run();
    try std.testing.expectEqual(.dead, file_size2.c.loadState().phase);
    try std.testing.expectEqual(true, file_size2.c.has_result);
    const size2 = try file_size2.getResult();
    try std.testing.expectEqual(write_data.len, size2);

    // Write more data at different offset
    const more_data = " More data!";
    var write_iov2: [1]os.iovec_const = undefined;
    var file_write2 = ev.FileWrite.init(fd, .fromSlice(more_data, &write_iov2), write_data.len);
    loop.add(&file_write2.c);
    try loop.run();
    try std.testing.expectEqual(more_data.len, try file_write2.getResult());

    // Check final size
    var file_size3 = ev.FileSize.init(fd);
    loop.add(&file_size3.c);
    try loop.run();
    const size3 = try file_size3.getResult();
    try std.testing.expectEqual(write_data.len + more_data.len, size3);

    // Close and delete
    var file_close = ev.FileClose.init(fd);
    loop.add(&file_close.c);
    try loop.run();
    try file_close.getResult();

    var file_delete = ev.DirDeleteFile.init(cwd, "test-size");
    loop.add(&file_delete.c);
    try loop.run();
    try file_delete.getResult();
}

test "File: stat" {
    var thread_pool: ev.ThreadPool = undefined;
    try thread_pool.init(.{ .min_threads = 1, .max_threads = 4 });
    defer thread_pool.deinit();

    var loop: ev.Loop = undefined;
    try loop.init(.{ .allocator = std.testing.allocator, .thread_pool = &thread_pool });
    defer loop.deinit();
    // Stop the pool before the loop is torn down: completion
    // callbacks wake the loop, so the loop must outlive the pool's workers.
    defer thread_pool.stop();

    const cwd = os.fs.cwd();

    // Create a file
    var file_create = ev.FileCreate.init(cwd, "test-stat", .{ .read = true, .truncate = true, .mode = 0o664 });
    loop.add(&file_create.c);
    try loop.run();
    const fd = (try file_create.getResult()).fd;

    // Stat empty file (by fd - path is null)
    var file_stat1 = ev.FileStat.init(fd, null, .{});
    loop.add(&file_stat1.c);
    try loop.run();
    try std.testing.expectEqual(.dead, file_stat1.c.loadState().phase);
    try std.testing.expectEqual(true, file_stat1.c.has_result);
    const stat1 = try file_stat1.getResult();
    try std.testing.expectEqual(0, stat1.size);
    try std.testing.expectEqual(.file, stat1.kind);
    try std.testing.expect(stat1.inode != 0);

    // Write some data
    const write_data = "Hello, file stat test!";
    var write_iov: [1]os.iovec_const = undefined;
    var file_write = ev.FileWrite.init(fd, .fromSlice(write_data, &write_iov), 0);
    loop.add(&file_write.c);
    try loop.run();
    try std.testing.expectEqual(write_data.len, try file_write.getResult());

    // Stat after write (by fd - path is null)
    var file_stat2 = ev.FileStat.init(fd, null, .{});
    loop.add(&file_stat2.c);
    try loop.run();
    const stat2 = try file_stat2.getResult();
    try std.testing.expectEqual(write_data.len, stat2.size);
    try std.testing.expectEqual(.file, stat2.kind);
    // mtime should be updated
    try std.testing.expect(stat2.mtime >= stat1.mtime);

    // Close and delete
    var file_close = ev.FileClose.init(fd);
    loop.add(&file_close.c);
    try loop.run();
    try file_close.getResult();

    var file_delete = ev.DirDeleteFile.init(cwd, "test-stat");
    loop.add(&file_delete.c);
    try loop.run();
    try file_delete.getResult();
}

test "File: stat_path" {
    var thread_pool: ev.ThreadPool = undefined;
    try thread_pool.init(.{ .min_threads = 1, .max_threads = 4 });
    defer thread_pool.deinit();

    var loop: ev.Loop = undefined;
    try loop.init(.{ .allocator = std.testing.allocator, .thread_pool = &thread_pool });
    defer loop.deinit();
    // Stop the pool before the loop is torn down: completion
    // callbacks wake the loop, so the loop must outlive the pool's workers.
    defer thread_pool.stop();

    const cwd = os.fs.cwd();

    // Create a file
    var file_create = ev.FileCreate.init(cwd, "test-stat-path", .{ .read = true, .truncate = true, .mode = 0o664 });
    loop.add(&file_create.c);
    try loop.run();
    const fd = (try file_create.getResult()).fd;

    // Write some data
    const write_data = "Hello, file stat_path test!";
    var write_iov: [1]os.iovec_const = undefined;
    var file_write = ev.FileWrite.init(fd, .fromSlice(write_data, &write_iov), 0);
    loop.add(&file_write.c);
    try loop.run();
    try std.testing.expectEqual(write_data.len, try file_write.getResult());

    // Close file so we can stat by path
    var file_close = ev.FileClose.init(fd);
    loop.add(&file_close.c);
    try loop.run();
    try file_close.getResult();

    // Stat by path (using FileStat with non-null path)
    var file_stat = ev.FileStat.init(cwd, "test-stat-path", .{});
    loop.add(&file_stat.c);
    try loop.run();
    try std.testing.expectEqual(.dead, file_stat.c.loadState().phase);
    try std.testing.expectEqual(true, file_stat.c.has_result);
    const stat = try file_stat.getResult();
    try std.testing.expectEqual(write_data.len, stat.size);
    try std.testing.expectEqual(.file, stat.kind);
    try std.testing.expect(stat.inode != 0);

    // Delete the file
    var file_delete = ev.DirDeleteFile.init(cwd, "test-stat-path");
    loop.add(&file_delete.c);
    try loop.run();
    try file_delete.getResult();
}

extern "c" fn mkfifo(path: [*:0]const u8, mode: std.c.mode_t) c_int;

test "File: opening a directory with allow_directory=false returns IsDir" {
    var thread_pool: ev.ThreadPool = undefined;
    try thread_pool.init(.{ .min_threads = 1, .max_threads = 4 });
    defer thread_pool.deinit();

    var loop: ev.Loop = undefined;
    try loop.init(.{ .allocator = std.testing.allocator, .thread_pool = &thread_pool });
    defer loop.deinit();
    defer thread_pool.stop();

    const cwd = os.fs.cwd();

    var file_open = ev.FileOpen.init(cwd, ".", .{ .mode = .read_only, .allow_directory = false });
    loop.add(&file_open.c);
    try loop.run();
    try std.testing.expectEqual(.dead, file_open.c.loadState().phase);
    try std.testing.expectEqual(true, file_open.c.has_result);
    // The thread pool route checks the opened fd; backends that open
    // files natively (io_uring, iocp) do not at this layer. Windows
    // refuses directories at CreateFileW time and reports AccessDenied.
    switch (comptime ev.Backend.capability(.file_open)) {
        .no => if (builtin.os.tag == .windows) {
            try std.testing.expectError(error.AccessDenied, file_open.getResult());
        } else {
            try std.testing.expectError(error.IsDir, file_open.getResult());
        },
        .yes => {
            const fd = (try file_open.getResult()).fd;
            var file_close = ev.FileClose.init(fd);
            loop.add(&file_close.c);
            try loop.run();
            try file_close.getResult();
        },
        .maybe => if (file_open.getResult()) |res| {
            var file_close = ev.FileClose.init(res.fd);
            loop.add(&file_close.c);
            try loop.run();
            try file_close.getResult();
        } else |err| {
            try std.testing.expectError(error.IsDir, err);
        },
    }
}

test "File: opening a regular file with allow_directory=false works" {
    var thread_pool: ev.ThreadPool = undefined;
    try thread_pool.init(.{ .min_threads = 1, .max_threads = 4 });
    defer thread_pool.deinit();

    var loop: ev.Loop = undefined;
    try loop.init(.{ .allocator = std.testing.allocator, .thread_pool = &thread_pool });
    defer loop.deinit();
    defer thread_pool.stop();

    const cwd = os.fs.cwd();

    var file_create = ev.FileCreate.init(cwd, "test-allow-directory", .{ .read = true, .truncate = true, .mode = 0o664 });
    loop.add(&file_create.c);
    try loop.run();
    _ = try file_create.getResult();

    var file_open = ev.FileOpen.init(cwd, "test-allow-directory", .{ .mode = .read_only, .allow_directory = false });
    loop.add(&file_open.c);
    try loop.run();
    try std.testing.expectEqual(.dead, file_open.c.loadState().phase);
    const fd = (try file_open.getResult()).fd;

    var file_close = ev.FileClose.init(fd);
    loop.add(&file_close.c);
    try loop.run();
    try file_close.getResult();

    var file_delete = ev.DirDeleteFile.init(cwd, "test-allow-directory");
    loop.add(&file_delete.c);
    try loop.run();
    try file_delete.getResult();
}

test "File: opening a FIFO with allow_directory=false is unchanged" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var thread_pool: ev.ThreadPool = undefined;
    try thread_pool.init(.{ .min_threads = 1, .max_threads = 4 });
    defer thread_pool.deinit();

    var loop: ev.Loop = undefined;
    try loop.init(.{ .allocator = std.testing.allocator, .thread_pool = &thread_pool });
    defer loop.deinit();
    defer thread_pool.stop();

    const cwd = os.fs.cwd();

    // A FIFO opened read-only with no writer blocks in the open. The
    // directory check must not change that: it runs after the open
    // succeeds and lets non-directories through untouched.
    const path = "test-allow-directory.fifo";
    _ = std.c.unlink(path);
    try std.testing.expectEqual(0, mkfifo(path, 0o600));
    defer _ = std.c.unlink(path);

    // Writer in the background, so the checked open completes.
    const Writer = struct {
        fn run(p: []const u8) void {
            const fd = std.posix.openat(std.posix.AT.FDCWD, p, .{ .ACCMODE = .WRONLY }, 0) catch return;
            _ = std.posix.system.close(fd);
        }
    };
    var writer_thread = try std.Thread.spawn(.{}, Writer.run, .{path});

    var file_open = ev.FileOpen.init(cwd, path, .{ .mode = .read_only, .allow_directory = false });
    loop.add(&file_open.c);
    try loop.run();
    try std.testing.expectEqual(.dead, file_open.c.loadState().phase);
    const fd = try file_open.getResult();
    // The thread pool route probes the fd and marks a FIFO pollable;
    // a native open leaves the streaming route at the default.
    switch (comptime ev.Backend.capability(.file_open)) {
        .no => try std.testing.expectEqual(.pollable, fd.streaming_route),
        .yes => try std.testing.expectEqual(.thread_pool, fd.streaming_route),
        .maybe => {},
    }

    var file_close = ev.FileClose.init(fd.fd);
    loop.add(&file_close.c);
    try loop.run();
    try file_close.getResult();

    writer_thread.join();
}
