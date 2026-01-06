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
