const builtin = @import("builtin");
const native_endian = builtin.cpu.arch.endian();

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;
const DefaultPrng = std.Random.DefaultPrng;
const mem = std.mem;
const fs = std.fs;
const File = std.fs.File;
const assert = std.debug.assert;

const tmpDir = std.testing.tmpDir;

test "write a file, read it, then delete it" {
    const io = testing.io;

    var tmp = tmpDir(.{});
    defer tmp.cleanup();

    var data: [1024]u8 = undefined;
    var prng = DefaultPrng.init(testing.random_seed);
    const random = prng.random();
    random.bytes(data[0..]);
    const tmp_file_name = "temp_test_file.txt";
    {
        var file = try tmp.dir.createFile(tmp_file_name, .{});
        defer file.close();

        var file_writer = file.writer(&.{});
        const st = &file_writer.interface;
        try st.print("begin", .{});
        try st.writeAll(&data);
        try st.print("end", .{});
        try st.flush();
    }

    {
        // Make sure the exclusive flag is honored.
        try expectError(File.OpenError.PathAlreadyExists, tmp.dir.createFile(tmp_file_name, .{ .exclusive = true }));
    }

    {
        var file = try tmp.dir.openFile(tmp_file_name, .{});
        defer file.close();

        const file_size = try file.getEndPos();
        const expected_file_size: u64 = "begin".len + data.len + "end".len;
        try expectEqual(expected_file_size, file_size);

        var file_buffer: [1024]u8 = undefined;
        var file_reader = file.reader(io, &file_buffer);
        const contents = try file_reader.interface.allocRemaining(testing.allocator, .limited(2 * 1024));
        defer testing.allocator.free(contents);

        try expect(mem.eql(u8, contents[0.."begin".len], "begin"));
        try expect(mem.eql(u8, contents["begin".len .. contents.len - "end".len], &data));
        try expect(mem.eql(u8, contents[contents.len - "end".len ..], "end"));
    }
    try tmp.dir.deleteFile(tmp_file_name);
}

test "File seek ops" {
    var tmp = tmpDir(.{});
    defer tmp.cleanup();

    const tmp_file_name = "temp_test_file.txt";
    var file = try tmp.dir.createFile(tmp_file_name, .{});
    defer file.close();

    try file.writeAll(&([_]u8{0x55} ** 8192));

    // Seek to the end
    try file.seekFromEnd(0);
    try expect((try file.getPos()) == try file.getEndPos());
    // Negative delta
    try file.seekBy(-4096);
    try expect((try file.getPos()) == 4096);
    // Positive delta
    try file.seekBy(10);
    try expect((try file.getPos()) == 4106);
    // Absolute position
    try file.seekTo(1234);
    try expect((try file.getPos()) == 1234);
}

test "setEndPos" {
    var tmp = tmpDir(.{});
    defer tmp.cleanup();

    const tmp_file_name = "temp_test_file.txt";
    var file = try tmp.dir.createFile(tmp_file_name, .{});
    defer file.close();

    // Verify that the file size changes and the file offset is not moved
    try expect((try file.getEndPos()) == 0);
    try expect((try file.getPos()) == 0);
    try file.setEndPos(8192);
    try expect((try file.getEndPos()) == 8192);
    try expect((try file.getPos()) == 0);
    try file.seekTo(100);
    try file.setEndPos(4096);
    try expect((try file.getEndPos()) == 4096);
    try expect((try file.getPos()) == 100);
    try file.setEndPos(0);
    try expect((try file.getEndPos()) == 0);
    try expect((try file.getPos()) == 100);
}

test "updateTimes" {
    var tmp = tmpDir(.{});
    defer tmp.cleanup();

    const tmp_file_name = "just_a_temporary_file.txt";
    var file = try tmp.dir.createFile(tmp_file_name, .{ .read = true });
    defer file.close();

    const stat_old = try file.stat();
    // Set atime and mtime to 5s before
    try file.updateTimes(
        stat_old.atime.subDuration(.fromSeconds(5)),
        stat_old.mtime.subDuration(.fromSeconds(5)),
    );
    const stat_new = try file.stat();
    try expect(stat_new.atime.nanoseconds < stat_old.atime.nanoseconds);
    try expect(stat_new.mtime.nanoseconds < stat_old.mtime.nanoseconds);
}

test "Group" {
    const io = testing.io;

    var group: Io.Group = .init;
    var results: [2]usize = undefined;

    group.async(io, count, .{ 1, 10, &results[0] });
    group.async(io, count, .{ 20, 30, &results[1] });

    group.wait(io);

    try testing.expectEqualSlices(usize, &.{ 45, 245 }, &results);
}

fn count(a: usize, b: usize, result: *usize) void {
    var sum: usize = 0;
    for (a..b) |i| {
        sum += i;
    }
    result.* = sum;
}

test "Group cancellation" {
    const io = testing.io;

    var group: Io.Group = .init;
    var results: [2]usize = undefined;

    group.async(io, sleep, .{ io, &results[0] });
    group.async(io, sleep, .{ io, &results[1] });

    group.cancel(io);

    try testing.expectEqualSlices(usize, &.{ 1, 1 }, &results);
}

fn sleep(io: Io, result: *usize) void {
    // TODO when cancellation race bug is fixed, make this timeout much longer so that
    // it causes the unit test to be failed if not canceled.
    io.sleep(.fromMilliseconds(1), .awake) catch {};
    result.* = 1;
}

test "Group concurrent" {
    const io = testing.io;

    var group: Io.Group = .init;
    defer group.cancel(io);
    var results: [2]usize = undefined;

    group.concurrent(io, count, .{ 1, 10, &results[0] }) catch |err| switch (err) {
        error.ConcurrencyUnavailable => {
            try testing.expect(builtin.single_threaded);
            return;
        },
    };

    group.concurrent(io, count, .{ 20, 30, &results[1] }) catch |err| switch (err) {
        error.ConcurrencyUnavailable => {
            try testing.expect(builtin.single_threaded);
            return;
        },
    };

    group.wait(io);

    try testing.expectEqualSlices(usize, &.{ 45, 245 }, &results);
}

test "select" {
    const io = testing.io;

    var queue: Io.Queue(u8) = .init(&.{});

    var get_a = io.concurrent(Io.Queue(u8).getOne, .{ &queue, io }) catch |err| switch (err) {
        error.ConcurrencyUnavailable => {
            try testing.expect(builtin.single_threaded);
            return;
        },
    };
    defer _ = get_a.cancel(io) catch {};

    var get_b = try io.concurrent(Io.Queue(u8).getOne, .{ &queue, io });
    defer _ = get_b.cancel(io) catch {};

    var timeout = io.async(Io.sleep, .{ io, .fromMilliseconds(1), .awake });
    defer timeout.cancel(io) catch {};

    switch (try io.select(.{
        .get_a = &get_a,
        .get_b = &get_b,
        .timeout = &timeout,
    })) {
        .get_a => return error.TestFailure,
        .get_b => return error.TestFailure,
        .timeout => {
            queue.close(io);
            try testing.expectError(error.Closed, get_a.await(io));
            try testing.expectError(error.Closed, get_b.await(io));
        },
    }
}

fn testQueue(comptime len: usize) !void {
    const io = testing.io;
    var buf: [len]usize = undefined;
    var queue: Io.Queue(usize) = .init(&buf);
    var begin: usize = 0;
    for (1..len + 1) |n| {
        const end = begin + n;
        for (begin..end) |i| try queue.putOne(io, i);
        for (begin..end) |i| try expect(try queue.getOne(io) == i);
        begin = end;
    }
}

test "Queue" {
    try testQueue(1);
    try testQueue(2);
    try testQueue(3);
    try testQueue(4);
    try testQueue(5);
}

test "Queue.close single-threaded" {
    const io = std.testing.io;

    var buf: [10]u8 = undefined;
    var queue: Io.Queue(u8) = .init(&buf);

    try queue.putAll(io, &.{ 0, 1, 2, 3, 4, 5, 6 });
    try expectEqual(3, try queue.put(io, &.{ 7, 8, 9, 10 }, 0)); // there is capacity for 3 more items

    var get_buf: [4]u8 = undefined;

    // Receive some elements before closing
    try expectEqual(4, try queue.get(io, &get_buf, 0));
    try expectEqual(0, get_buf[0]);
    try expectEqual(1, get_buf[1]);
    try expectEqual(2, get_buf[2]);
    try expectEqual(3, get_buf[3]);
    try expectEqual(4, try queue.getOne(io));

    // ...and add a couple more now there's space
    try queue.putAll(io, &.{ 20, 21 });

    queue.close(io);

    // Receive more elements *after* closing
    try expectEqual(4, try queue.get(io, &get_buf, 0));
    try expectEqual(5, get_buf[0]);
    try expectEqual(6, get_buf[1]);
    try expectEqual(7, get_buf[2]);
    try expectEqual(8, get_buf[3]);
    try expectEqual(9, try queue.getOne(io));

    // Cannot put anything while closed, even if the buffer has space
    try expectError(error.Closed, queue.putOne(io, 100));
    try expectError(error.Closed, queue.putAll(io, &.{ 101, 102 }));
    try expectError(error.Closed, queue.putUncancelable(io, &.{ 103, 104 }, 0));

    // Even if we ask for 3 items, the queue is closed, so we only get the last 2
    try expectEqual(2, try queue.get(io, &get_buf, 4));
    try expectEqual(20, get_buf[0]);
    try expectEqual(21, get_buf[1]);

    // The queue is now empty, so `get` should return `error.Closed` too
    try expectError(error.Closed, queue.getOne(io));
    try expectError(error.Closed, queue.get(io, &get_buf, 0));
    try expectError(error.Closed, queue.putUncancelable(io, &get_buf, 2));
}

test "Event" {
    const global = struct {
        fn waitAndRead(io: Io, event: *Io.Event, ptr: *const u32) Io.Cancelable!u32 {
            try event.wait(io);
            return ptr.*;
        }
    };

    const io = std.testing.io;

    var event: Io.Event = .unset;
    var buffer: u32 = undefined;

    {
        var future = io.concurrent(global.waitAndRead, .{ io, &event, &buffer }) catch |err| switch (err) {
            error.ConcurrencyUnavailable => return error.SkipZigTest,
        };

        buffer = 123;
        event.set(io);

        const result = try future.await(io);

        try std.testing.expectEqual(123, result);
    }

    event.reset();

    {
        var future = io.concurrent(global.waitAndRead, .{ io, &event, &buffer }) catch |err| switch (err) {
            error.ConcurrencyUnavailable => return error.SkipZigTest,
        };
        try std.testing.expectError(error.Canceled, future.cancel(io));
    }
}

test "recancel" {
    const global = struct {
        fn worker(io: Io) Io.Cancelable!void {
            var dummy_event: Io.Event = .unset;

            if (dummy_event.wait(io)) {
                return;
            } else |err| switch (err) {
                error.Canceled => io.recancel(),
            }

            // Now we expect to see `error.Canceled` again.
            return dummy_event.wait(io);
        }
    };

    const io = std.testing.io;
    var future = io.concurrent(global.worker, .{io}) catch |err| switch (err) {
        error.ConcurrencyUnavailable => return error.SkipZigTest,
    };
    if (future.cancel(io)) {
        return error.UnexpectedSuccess; // both `wait` calls should have returned `error.Canceled`
    } else |err| switch (err) {
        error.Canceled => {},
    }
}

test "swapCancelProtection" {
    const global = struct {
        fn waitTwice(
            io: Io,
            event: *Io.Event,
        ) error{ Canceled, CanceledWhileProtected }!void {
            // Wait for `event` while protected from cancelation.
            {
                const old_prot = io.swapCancelProtection(.blocked);
                defer _ = io.swapCancelProtection(old_prot);
                event.wait(io) catch |err| switch (err) {
                    error.Canceled => return error.CanceledWhileProtected,
                };
            }
            // Reset the event (it will never be set again), and this time wait for it without protection.
            event.reset();
            _ = try event.wait(io);
        }
        fn sleepThenSet(io: Io, event: *Io.Event) !void {
            // Give `waitTwice` a chance to get canceled.
            try io.sleep(.fromMilliseconds(200), .awake);
            event.set(io);
        }
    };

    const io = std.testing.io;

    var event: Io.Event = .unset;

    var wait_future = io.concurrent(global.waitTwice, .{ io, &event }) catch |err| switch (err) {
        error.ConcurrencyUnavailable => return error.SkipZigTest,
    };
    defer wait_future.cancel(io) catch {};

    var set_future = try io.concurrent(global.sleepThenSet, .{ io, &event });
    defer set_future.cancel(io) catch {};

    if (wait_future.cancel(io)) {
        return error.UnexpectedSuccess; // there was no `set` call to unblock the second `wait`
    } else |err| switch (err) {
        error.Canceled => {},
        error.CanceledWhileProtected => |e| return e,
    }

    // Because it reached the `set`, it should be too late for `sleepThenSet` to see `error.Canceled`.
    try set_future.cancel(io);
}
