const std = @import("std");
const Runtime = @import("../runtime.zig").Runtime;
const Cancellable = @import("../runtime.zig").Cancellable;
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
/// If cancelled after acquiring a permit, the permit is properly released before returning error.
pub fn wait(self: *Semaphore, rt: *Runtime) Cancellable!void {
    try self.mutex.lock(rt);
    defer self.mutex.unlock(rt);

    var was_cancelled = false;

    while (self.permits == 0) {
        self.cond.wait(rt, &self.mutex) catch {
            // Cancelled while waiting - remember this but continue to check if permit available
            was_cancelled = true;
            break;
        };
    }

    // If we got here, either permits > 0 or we were cancelled
    if (self.permits > 0) {
        // Permit is available - acquire it
        self.permits -= 1;
        if (self.permits > 0) {
            self.cond.signal(rt);
        }

        // If we were cancelled, release the permit before returning error
        if (was_cancelled) {
            self.permits += 1;
            self.cond.signal(rt);
            return error.Cancelled;
        }
    } else {
        // No permit available and we were cancelled
        return error.Cancelled;
    }
}

/// Block until a permit is available or timeout expires.
/// Returns error.Timeout if the timeout expires before a permit becomes available.
/// If cancelled after acquiring a permit, the permit is properly released before returning error.
pub fn timedWait(self: *Semaphore, rt: *Runtime, timeout_ns: u64) error{ Timeout, Cancelled }!void {
    var timeout_timer = std.time.Timer.start() catch unreachable;

    try self.mutex.lock(rt);
    defer self.mutex.unlock(rt);

    var was_cancelled = false;

    while (self.permits == 0) {
        const elapsed = timeout_timer.read();
        if (elapsed > timeout_ns) {
            return error.Timeout;
        }

        const local_timeout_ns = timeout_ns - elapsed;
        self.cond.timedWait(rt, &self.mutex, local_timeout_ns) catch |err| {
            if (err == error.Timeout) {
                return error.Timeout;
            }
            // Must be Cancelled - remember this but continue to check if permit available
            was_cancelled = true;
            break;
        };
    }

    // If we got here, either permits > 0 or we were cancelled
    if (self.permits > 0) {
        // Permit is available - acquire it
        self.permits -= 1;
        if (self.permits > 0) {
            self.cond.signal(rt);
        }

        // If we were cancelled, release the permit before returning error
        if (was_cancelled) {
            self.permits += 1;
            self.cond.signal(rt);
            return error.Cancelled;
        }
    } else {
        // No permit available and we were cancelled
        return error.Cancelled;
    }
}

/// Increment the permit count and wake one waiting coroutine.
/// Retries if cancelled to ensure the permit is posted, then returns error.Cancelled.
pub fn post(self: *Semaphore, rt: *Runtime) Cancellable!void {
    var was_cancelled = false;

    // Retry lock if cancelled - we must post the permit
    while (true) {
        self.mutex.lock(rt) catch {
            was_cancelled = true;
            continue; // Retry if cancelled
        };
        break;
    }
    defer self.mutex.unlock(rt);

    self.permits += 1;
    self.cond.signal(rt);

    if (was_cancelled) {
        return error.Cancelled;
    }
}

test "Semaphore: basic wait/post" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var sem = Semaphore{ .permits = 1 };

    const TestFn = struct {
        fn worker(rt: *Runtime, s: *Semaphore, n: *i32) !void {
            try s.wait(rt);
            n.* += 1;
            try s.post(rt);
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

        fn poster(rt: *Runtime, s: *Semaphore) !void {
            try rt.yield(.ready);
            try s.post(rt);
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
        fn worker(rt: *Runtime, s: *Semaphore) !void {
            try s.wait(rt);
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
