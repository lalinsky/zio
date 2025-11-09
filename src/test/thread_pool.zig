const std = @import("std");
const ThreadPool = @import("../thread_pool.zig").ThreadPool;
const Completion = @import("../completion.zig").Completion;
const Work = @import("../completion.zig").Work;
const Loop = @import("../loop.zig").Loop;

test "ThreadPool: one task" {
    var thread_pool: ThreadPool = undefined;
    try thread_pool.init(std.testing.allocator, .{
        .min_threads = 1,
        .max_threads = 1,
    });
    defer thread_pool.deinit();

    var loop: Loop = undefined;
    try loop.init(.{
        .thread_pool = &thread_pool,
    });
    defer loop.deinit();

    const TestFn = struct {
        called: usize = 0,
        pub fn main(_: *Loop, work: *Work) void {
            var self: *@This() = @ptrCast(@alignCast(work.userdata));
            self.called += 1;
        }
    };

    var test_fn: TestFn = .{};
    var work = Work.init(&TestFn.main, @ptrCast(&test_fn));

    loop.add(&work.c);

    try loop.run(.until_done);

    try std.testing.expectEqual(.completed, work.c.state);
    try std.testing.expectEqual(1, test_fn.called);
}

test "ThreadPool: many tasks" {
    var thread_pool: ThreadPool = undefined;
    try thread_pool.init(std.testing.allocator, .{
        .min_threads = 1,
        .max_threads = 10,
    });
    defer thread_pool.deinit();

    var loop: Loop = undefined;
    try loop.init(.{
        .thread_pool = &thread_pool,
    });
    defer loop.deinit();

    const TestFn = struct {
        called: usize = 0,
        pub fn main(_: *Loop, work: *Work) void {
            var self: *@This() = @ptrCast(@alignCast(work.userdata));
            self.called += 1;
        }
    };

    const num_tasks = 1000;

    var test_fn: [num_tasks]TestFn = undefined;
    var work: [num_tasks]Work = undefined;

    for (0..num_tasks) |i| {
        test_fn[i] = .{};
        work[i] = Work.init(&TestFn.main, @ptrCast(&test_fn[i]));
        loop.add(&work[i].c);
    }

    try loop.run(.until_done);

    for (0..num_tasks) |i| {
        try std.testing.expectEqual(.completed, work[i].c.state);
        try std.testing.expectEqual(1, test_fn[i].called);
    }

    try std.testing.expect(thread_pool.running_threads.load(.acquire) > 1);
}
