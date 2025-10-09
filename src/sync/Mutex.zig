const std = @import("std");
const Runtime = @import("../runtime.zig").Runtime;
const Cancellable = @import("../runtime.zig").Cancellable;
const coroutines = @import("../coroutines.zig");
const AwaitableList = @import("../runtime.zig").AwaitableList;
const AnyTask = @import("../runtime.zig").AnyTask;

owner: std.atomic.Value(?*coroutines.Coroutine) = std.atomic.Value(?*coroutines.Coroutine).init(null),
wait_queue: AwaitableList = .{},

const Mutex = @This();

pub const init: Mutex = .{};

pub fn tryLock(self: *Mutex) bool {
    const current = coroutines.getCurrent() orelse return false;

    // Try to atomically set owner from null to current
    return self.owner.cmpxchgStrong(null, current, .acquire, .monotonic) == null;
}

pub fn lock(self: *Mutex, runtime: *Runtime) Cancellable!void {
    const current = coroutines.getCurrent() orelse unreachable;

    // Fast path: try to acquire unlocked mutex
    if (self.tryLock()) return;

    // Slow path: add current task to wait queue and suspend
    const task = AnyTask.fromCoroutine(current);
    self.wait_queue.push(&task.awaitable);

    // Suspend until woken by unlock()
    runtime.yield(.waiting) catch |err| {
        // On cancellation, remove ourselves from the wait queue
        _ = self.wait_queue.remove(&task.awaitable);
        return err;
    };

    // When we wake up, unlock() has already transferred ownership to us
    const owner = self.owner.load(.acquire);
    std.debug.assert(owner == current);
}

pub fn unlock(self: *Mutex, runtime: *Runtime) void {
    const current = coroutines.getCurrent() orelse unreachable;
    std.debug.assert(self.owner.load(.monotonic) == current);

    // Check if there are waiters
    if (self.wait_queue.pop()) |awaitable| {
        const task = AnyTask.fromAwaitable(awaitable);
        // Transfer ownership directly to next waiter
        self.owner.store(&task.coro, .release);
        // Wake them up (they already own the lock)
        runtime.markReady(&task.coro);
    } else {
        // No waiters, release the lock completely
        self.owner.store(null, .release);
    }
}

test "Mutex basic lock/unlock" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var shared_counter: u32 = 0;
    var mutex = Mutex.init;

    const TestFn = struct {
        fn worker(rt: *Runtime, counter: *u32, mtx: *Mutex) !void {
            for (0..100) |_| {
                try mtx.lock(rt);
                defer mtx.unlock(rt);
                counter.* += 1;
            }
        }
    };

    var task1 = try runtime.spawn(TestFn.worker, .{ &runtime, &shared_counter, &mutex }, .{});
    defer task1.deinit();
    var task2 = try runtime.spawn(TestFn.worker, .{ &runtime, &shared_counter, &mutex }, .{});
    defer task2.deinit();

    try runtime.run();

    try testing.expectEqual(@as(u32, 200), shared_counter);
}

test "Mutex tryLock" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var mutex = Mutex.init;

    const TestFn = struct {
        fn testTryLock(rt: *Runtime, mtx: *Mutex, results: *[3]bool) void {
            results[0] = mtx.tryLock(); // Should succeed
            results[1] = mtx.tryLock(); // Should fail (already locked)
            mtx.unlock(rt);
            results[2] = mtx.tryLock(); // Should succeed again
            mtx.unlock(rt);
        }
    };

    var results: [3]bool = undefined;
    try runtime.runUntilComplete(TestFn.testTryLock, .{ &runtime, &mutex, &results }, .{});

    try testing.expect(results[0]); // First tryLock should succeed
    try testing.expect(!results[1]); // Second tryLock should fail
    try testing.expect(results[2]); // Third tryLock should succeed
}
