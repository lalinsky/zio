const std = @import("std");
const Runtime = @import("../runtime.zig").Runtime;
const Mutex = @import("Mutex.zig");
const Condition = @import("Condition.zig");

/// Semaphore is a coroutine-safe counting semaphore.
/// It blocks coroutines when the permit count is zero.
/// NOT safe for use across OS threads - use within a single Runtime only.
mutex: Mutex = Mutex.init,
cond: Condition = Condition.init,
/// It is OK to initialize this field to any value.
permits: usize = 0,

const Semaphore = @This();

/// Block until a permit is available, then decrement the permit count.
pub fn wait(self: *Semaphore, rt: *Runtime) void {
    self.mutex.lock(rt);
    defer self.mutex.unlock(rt);

    while (self.permits == 0) {
        self.cond.wait(rt, &self.mutex);
    }

    self.permits -= 1;
    if (self.permits > 0) {
        self.cond.signal(rt);
    }
}

/// Block until a permit is available or timeout expires.
/// Returns error.Timeout if the timeout expires before a permit becomes available.
pub fn timedWait(self: *Semaphore, rt: *Runtime, timeout_ns: u64) error{Timeout}!void {
    var timeout_timer = std.time.Timer.start() catch unreachable;

    self.mutex.lock(rt);
    defer self.mutex.unlock(rt);

    while (self.permits == 0) {
        const elapsed = timeout_timer.read();
        if (elapsed > timeout_ns) {
            return error.Timeout;
        }

        const local_timeout_ns = timeout_ns - elapsed;
        try self.cond.timedWait(rt, &self.mutex, local_timeout_ns);
    }

    self.permits -= 1;
    if (self.permits > 0) {
        self.cond.signal(rt);
    }
}

/// Increment the permit count and wake one waiting coroutine.
pub fn post(self: *Semaphore, rt: *Runtime) void {
    self.mutex.lock(rt);
    defer self.mutex.unlock(rt);

    self.permits += 1;
    self.cond.signal(rt);
}

test "Semaphore: basic wait/post" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var sem = Semaphore{ .permits = 1 };

    const TestFn = struct {
        fn worker(rt: *Runtime, s: *Semaphore, n: *i32) void {
            s.wait(rt);
            n.* += 1;
            s.post(rt);
        }
    };

    var n: i32 = 0;
    var task1 = try runtime.spawn(TestFn.worker, .{ &runtime, &sem, &n }, .{});
    defer task1.deinit();
    var task2 = try runtime.spawn(TestFn.worker, .{ &runtime, &sem, &n }, .{});
    defer task2.deinit();
    var task3 = try runtime.spawn(TestFn.worker, .{ &runtime, &sem, &n }, .{});
    defer task3.deinit();

    try runtime.run();

    try testing.expectEqual(@as(i32, 3), n);
}

test "Semaphore: timedWait timeout" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var sem = Semaphore{};
    var timed_out = false;

    const TestFn = struct {
        fn waiter(rt: *Runtime, s: *Semaphore, timeout_flag: *bool) void {
            s.timedWait(rt, 10_000_000) catch |err| {
                if (err == error.Timeout) {
                    timeout_flag.* = true;
                }
            };
        }
    };

    try runtime.runUntilComplete(TestFn.waiter, .{ &runtime, &sem, &timed_out }, .{});

    try testing.expect(timed_out);
    try testing.expectEqual(@as(usize, 0), sem.permits);
}

test "Semaphore: timedWait success" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var sem = Semaphore{};
    var got_permit = false;

    const TestFn = struct {
        fn waiter(rt: *Runtime, s: *Semaphore, flag: *bool) void {
            s.timedWait(rt, 100_000_000) catch return;
            flag.* = true;
        }

        fn poster(rt: *Runtime, s: *Semaphore) void {
            rt.yield(.ready);
            s.post(rt);
        }
    };

    var waiter_task = try runtime.spawn(TestFn.waiter, .{ &runtime, &sem, &got_permit }, .{});
    defer waiter_task.deinit();
    var poster_task = try runtime.spawn(TestFn.poster, .{ &runtime, &sem }, .{});
    defer poster_task.deinit();

    try runtime.run();

    try testing.expect(got_permit);
    try testing.expectEqual(@as(usize, 0), sem.permits);
}

test "Semaphore: multiple permits" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var sem = Semaphore{ .permits = 3 };

    const TestFn = struct {
        fn worker(rt: *Runtime, s: *Semaphore) void {
            s.wait(rt);
            // Don't post - consume the permit
        }
    };

    var task1 = try runtime.spawn(TestFn.worker, .{ &runtime, &sem }, .{});
    defer task1.deinit();
    var task2 = try runtime.spawn(TestFn.worker, .{ &runtime, &sem }, .{});
    defer task2.deinit();
    var task3 = try runtime.spawn(TestFn.worker, .{ &runtime, &sem }, .{});
    defer task3.deinit();

    try runtime.run();

    try testing.expectEqual(@as(usize, 0), sem.permits);
}
