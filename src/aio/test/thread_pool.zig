const std = @import("std");
const aio = @import("../root.zig");

test "aio.ThreadPool: one task" {
    var thread_pool: aio.ThreadPool = undefined;
    try thread_pool.init(std.testing.allocator, .{
        .min_threads = 1,
        .max_threads = 1,
    });
    defer thread_pool.deinit();

    var loop: aio.Loop = undefined;
    try loop.init(.{
        .thread_pool = &thread_pool,
    });
    defer loop.deinit();

    const TestFn = struct {
        called: usize = 0,
        pub fn main(work: *aio.Work) void {
            var self: *@This() = @ptrCast(@alignCast(work.userdata));
            self.called += 1;
        }
    };

    var test_fn: TestFn = .{};
    var work = aio.Work.init(&TestFn.main, @ptrCast(&test_fn));

    loop.add(&work.c);

    try loop.run(.until_done);

    try std.testing.expectEqual(.dead, work.c.state);
    try std.testing.expectEqual(1, test_fn.called);
}

test "aio.ThreadPool: many tasks" {
    var thread_pool: aio.ThreadPool = undefined;
    try thread_pool.init(std.testing.allocator, .{
        .min_threads = 1,
        .max_threads = 10,
    });
    defer thread_pool.deinit();

    var loop: aio.Loop = undefined;
    try loop.init(.{
        .thread_pool = &thread_pool,
    });
    defer loop.deinit();

    var active = std.atomic.Value(usize).init(0);
    var max_active = std.atomic.Value(usize).init(0);

    const TestFn = struct {
        called: usize = 0,
        active: *std.atomic.Value(usize),
        max_active: *std.atomic.Value(usize),

        pub fn main(work: *aio.Work) void {
            var self: *@This() = @ptrCast(@alignCast(work.userdata));

            // Track concurrent execution
            const current = self.active.fetchAdd(1, .acq_rel) + 1;
            defer _ = self.active.fetchSub(1, .acq_rel);
            _ = self.max_active.fetchMax(current, .acq_rel);

            aio.system.time.sleep(12);
            self.called += 1;
        }
    };

    const num_tasks = 1000;

    var test_fn: [num_tasks]TestFn = undefined;
    var work: [num_tasks]aio.Work = undefined;

    for (0..num_tasks) |i| {
        test_fn[i] = .{ .active = &active, .max_active = &max_active };
        work[i] = aio.Work.init(&TestFn.main, @ptrCast(&test_fn[i]));
        loop.add(&work[i].c);
    }

    try loop.run(.until_done);

    for (0..num_tasks) |i| {
        try std.testing.expectEqual(.dead, work[i].c.state);
        try std.testing.expectEqual(1, test_fn[i].called);
    }

    // Verify tasks actually ran concurrently
    try std.testing.expect(max_active.load(.acquire) > 1);
}
