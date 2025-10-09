const std = @import("std");
const Runtime = @import("../runtime.zig").Runtime;
const Mutex = @import("Mutex.zig");
const Condition = @import("Condition.zig");

/// Queue is a coroutine-safe bounded FIFO queue implemented as a ring buffer.
/// It blocks coroutines when full (put) or empty (get).
/// NOT safe for use across OS threads - use within a single Runtime only.
pub fn Queue(comptime T: type) type {
    return struct {
        buffer: []T,
        head: usize = 0,
        tail: usize = 0,
        count: usize = 0,

        mutex: Mutex = Mutex.init,
        not_empty: Condition = Condition.init,
        not_full: Condition = Condition.init,

        closed: bool = false,

        const Self = @This();

        /// Initialize a queue with the provided buffer.
        /// The buffer's length determines the queue capacity.
        pub fn init(buffer: []T) Self {
            std.debug.assert(buffer.len > 0);
            return .{ .buffer = buffer };
        }

        /// Check if the queue is empty.
        pub fn isEmpty(self: *Self, rt: *Runtime) bool {
            self.mutex.lock(rt);
            defer self.mutex.unlock(rt);
            return self.count == 0;
        }

        /// Check if the queue is full.
        pub fn isFull(self: *Self, rt: *Runtime) bool {
            self.mutex.lock(rt);
            defer self.mutex.unlock(rt);
            return self.count == self.buffer.len;
        }

        /// Get an item from the queue, blocking if empty.
        /// Returns error.QueueClosed if the queue is closed and empty.
        pub fn get(self: *Self, rt: *Runtime) !T {
            self.mutex.lock(rt);
            defer self.mutex.unlock(rt);

            // Wait while empty and not closed
            while (self.count == 0 and !self.closed) {
                self.not_empty.wait(rt, &self.mutex);
            }

            // If closed and empty, return error
            if (self.closed and self.count == 0) {
                return error.QueueClosed;
            }

            // Get item from head
            const item = self.buffer[self.head];
            self.head = (self.head + 1) % self.buffer.len;
            self.count -= 1;

            // Signal that queue is not full
            self.not_full.signal(rt);

            return item;
        }

        /// Try to get an item without blocking.
        /// Returns error.QueueEmpty if empty, error.QueueClosed if closed and empty.
        pub fn tryGet(self: *Self, rt: *Runtime) !T {
            self.mutex.lock(rt);
            defer self.mutex.unlock(rt);

            if (self.count == 0) {
                if (self.closed) {
                    return error.QueueClosed;
                }
                return error.QueueEmpty;
            }

            const item = self.buffer[self.head];
            self.head = (self.head + 1) % self.buffer.len;
            self.count -= 1;

            self.not_full.signal(rt);

            return item;
        }

        /// Put an item into the queue, blocking if full.
        /// Returns error.QueueClosed if the queue is closed.
        pub fn put(self: *Self, rt: *Runtime, item: T) !void {
            self.mutex.lock(rt);
            defer self.mutex.unlock(rt);

            if (self.closed) {
                return error.QueueClosed;
            }

            // Wait while full
            while (self.count == self.buffer.len) {
                self.not_full.wait(rt, &self.mutex);
                // Check if closed while waiting
                if (self.closed) {
                    return error.QueueClosed;
                }
            }

            // Add item to tail
            self.buffer[self.tail] = item;
            self.tail = (self.tail + 1) % self.buffer.len;
            self.count += 1;

            // Signal that queue is not empty
            self.not_empty.signal(rt);
        }

        /// Try to put an item without blocking.
        /// Returns error.QueueFull if full, error.QueueClosed if closed.
        pub fn tryPut(self: *Self, rt: *Runtime, item: T) !void {
            self.mutex.lock(rt);
            defer self.mutex.unlock(rt);

            if (self.closed) {
                return error.QueueClosed;
            }

            if (self.count == self.buffer.len) {
                return error.QueueFull;
            }

            self.buffer[self.tail] = item;
            self.tail = (self.tail + 1) % self.buffer.len;
            self.count += 1;

            self.not_empty.signal(rt);
        }

        /// Close the queue.
        /// If immediate is true, clears all items from the queue.
        /// After closing, put operations will return error.QueueClosed.
        /// get operations will drain remaining items, then return error.QueueClosed.
        pub fn close(self: *Self, rt: *Runtime, immediate: bool) void {
            self.mutex.lock(rt);
            defer self.mutex.unlock(rt);

            self.closed = true;

            if (immediate) {
                // Clear the buffer
                self.head = 0;
                self.tail = 0;
                self.count = 0;
            }

            // Wake all waiters so they can see the queue is closed
            self.not_empty.broadcast(rt);
            self.not_full.broadcast(rt);
        }
    };
}

test "Queue: basic put and get" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var buffer: [10]u32 = undefined;
    var queue = Queue(u32).init(&buffer);

    const TestFn = struct {
        fn producer(rt: *Runtime, q: *Queue(u32)) !void {
            try q.put(rt, 1);
            try q.put(rt, 2);
            try q.put(rt, 3);
        }

        fn consumer(rt: *Runtime, q: *Queue(u32), results: *[3]u32) !void {
            results[0] = try q.get(rt);
            results[1] = try q.get(rt);
            results[2] = try q.get(rt);
        }
    };

    var results: [3]u32 = undefined;
    var producer_task = try runtime.spawn(TestFn.producer, .{ &runtime, &queue }, .{});
    defer producer_task.deinit();
    var consumer_task = try runtime.spawn(TestFn.consumer, .{ &runtime, &queue, &results }, .{});
    defer consumer_task.deinit();

    try runtime.run();

    try testing.expectEqual(@as(u32, 1), results[0]);
    try testing.expectEqual(@as(u32, 2), results[1]);
    try testing.expectEqual(@as(u32, 3), results[2]);
}

test "Queue: tryPut and tryGet" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var buffer: [2]u32 = undefined;
    var queue = Queue(u32).init(&buffer);

    const TestFn = struct {
        fn testTry(rt: *Runtime, q: *Queue(u32)) !void {
            // tryGet on empty queue should fail
            const empty_err = q.tryGet(rt);
            try testing.expectError(error.QueueEmpty, empty_err);

            // tryPut should succeed
            try q.tryPut(rt, 1);
            try q.tryPut(rt, 2);

            // tryPut on full queue should fail
            const full_err = q.tryPut(rt, 3);
            try testing.expectError(error.QueueFull, full_err);

            // tryGet should succeed
            const val1 = try q.tryGet(rt);
            try testing.expectEqual(@as(u32, 1), val1);

            const val2 = try q.tryGet(rt);
            try testing.expectEqual(@as(u32, 2), val2);

            // tryGet on empty queue should fail again
            const empty_err2 = q.tryGet(rt);
            try testing.expectError(error.QueueEmpty, empty_err2);
        }
    };

    try runtime.runUntilComplete(TestFn.testTry, .{ &runtime, &queue }, .{});
}

test "Queue: blocking behavior when empty" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var buffer: [5]u32 = undefined;
    var queue = Queue(u32).init(&buffer);

    const TestFn = struct {
        fn consumer(rt: *Runtime, q: *Queue(u32), result: *u32) !void {
            result.* = try q.get(rt); // Blocks until producer adds item
        }

        fn producer(rt: *Runtime, q: *Queue(u32)) !void {
            rt.yield(.ready); // Let consumer start waiting
            try q.put(rt, 42);
        }
    };

    var result: u32 = 0;
    var consumer_task = try runtime.spawn(TestFn.consumer, .{ &runtime, &queue, &result }, .{});
    defer consumer_task.deinit();
    var producer_task = try runtime.spawn(TestFn.producer, .{ &runtime, &queue }, .{});
    defer producer_task.deinit();

    try runtime.run();

    try testing.expectEqual(@as(u32, 42), result);
}

test "Queue: blocking behavior when full" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var buffer: [2]u32 = undefined;
    var queue = Queue(u32).init(&buffer);

    const TestFn = struct {
        fn producer(rt: *Runtime, q: *Queue(u32), count: *u32) !void {
            try q.put(rt, 1);
            try q.put(rt, 2);
            try q.put(rt, 3); // Blocks until consumer takes item
            count.* += 1;
        }

        fn consumer(rt: *Runtime, q: *Queue(u32)) !void {
            rt.yield(.ready); // Let producer fill the queue
            rt.yield(.ready);
            _ = try q.get(rt); // Unblock producer
        }
    };

    var count: u32 = 0;
    var producer_task = try runtime.spawn(TestFn.producer, .{ &runtime, &queue, &count }, .{});
    defer producer_task.deinit();
    var consumer_task = try runtime.spawn(TestFn.consumer, .{ &runtime, &queue }, .{});
    defer consumer_task.deinit();

    try runtime.run();

    try testing.expectEqual(@as(u32, 1), count);
}

test "Queue: multiple producers and consumers" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var buffer: [10]u32 = undefined;
    var queue = Queue(u32).init(&buffer);

    const TestFn = struct {
        fn producer(rt: *Runtime, q: *Queue(u32), start: u32) !void {
            for (0..5) |i| {
                try q.put(rt, start + @as(u32, @intCast(i)));
            }
        }

        fn consumer(rt: *Runtime, q: *Queue(u32), sum: *u32) !void {
            for (0..5) |_| {
                const val = try q.get(rt);
                sum.* += val;
            }
        }
    };

    var sum: u32 = 0;
    var producer1 = try runtime.spawn(TestFn.producer, .{ &runtime, &queue, @as(u32, 0) }, .{});
    defer producer1.deinit();
    var producer2 = try runtime.spawn(TestFn.producer, .{ &runtime, &queue, @as(u32, 100) }, .{});
    defer producer2.deinit();
    var consumer1 = try runtime.spawn(TestFn.consumer, .{ &runtime, &queue, &sum }, .{});
    defer consumer1.deinit();
    var consumer2 = try runtime.spawn(TestFn.consumer, .{ &runtime, &queue, &sum }, .{});
    defer consumer2.deinit();

    try runtime.run();

    // Sum should be: (0+1+2+3+4) + (100+101+102+103+104) = 10 + 510 = 520
    try testing.expectEqual(@as(u32, 520), sum);
}

test "Queue: close graceful" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var buffer: [5]u32 = undefined;
    var queue = Queue(u32).init(&buffer);

    const TestFn = struct {
        fn producer(rt: *Runtime, q: *Queue(u32)) !void {
            try q.put(rt, 1);
            try q.put(rt, 2);
            q.close(rt, false); // Graceful close - items remain
        }

        fn consumer(rt: *Runtime, q: *Queue(u32), results: *[3]?u32) !void {
            rt.yield(.ready); // Let producer finish
            results[0] = q.get(rt) catch null;
            results[1] = q.get(rt) catch null;
            results[2] = q.get(rt) catch null; // Should fail with QueueClosed
        }
    };

    var results: [3]?u32 = .{ null, null, null };
    var producer_task = try runtime.spawn(TestFn.producer, .{ &runtime, &queue }, .{});
    defer producer_task.deinit();
    var consumer_task = try runtime.spawn(TestFn.consumer, .{ &runtime, &queue, &results }, .{});
    defer consumer_task.deinit();

    try runtime.run();

    try testing.expectEqual(@as(?u32, 1), results[0]);
    try testing.expectEqual(@as(?u32, 2), results[1]);
    try testing.expectEqual(@as(?u32, null), results[2]); // Closed, no more items
}

test "Queue: close immediate" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var buffer: [5]u32 = undefined;
    var queue = Queue(u32).init(&buffer);

    const TestFn = struct {
        fn producer(rt: *Runtime, q: *Queue(u32)) !void {
            try q.put(rt, 1);
            try q.put(rt, 2);
            try q.put(rt, 3);
            q.close(rt, true); // Immediate close - clears all items
        }

        fn consumer(rt: *Runtime, q: *Queue(u32), result: *?u32) !void {
            rt.yield(.ready); // Let producer finish
            result.* = q.get(rt) catch null; // Should fail immediately
        }
    };

    var result: ?u32 = null;
    var producer_task = try runtime.spawn(TestFn.producer, .{ &runtime, &queue }, .{});
    defer producer_task.deinit();
    var consumer_task = try runtime.spawn(TestFn.consumer, .{ &runtime, &queue, &result }, .{});
    defer consumer_task.deinit();

    try runtime.run();

    try testing.expectEqual(@as(?u32, null), result);
}

test "Queue: put on closed queue" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var buffer: [5]u32 = undefined;
    var queue = Queue(u32).init(&buffer);

    const TestFn = struct {
        fn testClosed(rt: *Runtime, q: *Queue(u32)) !void {
            q.close(rt, false);

            const put_err = q.put(rt, 1);
            try testing.expectError(error.QueueClosed, put_err);

            const tryput_err = q.tryPut(rt, 2);
            try testing.expectError(error.QueueClosed, tryput_err);
        }
    };

    try runtime.runUntilComplete(TestFn.testClosed, .{ &runtime, &queue }, .{});
}

test "Queue: ring buffer wrapping" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var buffer: [3]u32 = undefined;
    var queue = Queue(u32).init(&buffer);

    const TestFn = struct {
        fn testWrap(rt: *Runtime, q: *Queue(u32)) !void {
            // Fill the queue
            try q.put(rt, 1);
            try q.put(rt, 2);
            try q.put(rt, 3);

            // Empty it
            _ = try q.get(rt);
            _ = try q.get(rt);
            _ = try q.get(rt);

            // Fill it again (should wrap around)
            try q.put(rt, 4);
            try q.put(rt, 5);
            try q.put(rt, 6);

            // Verify items
            const v1 = try q.get(rt);
            const v2 = try q.get(rt);
            const v3 = try q.get(rt);

            try testing.expectEqual(@as(u32, 4), v1);
            try testing.expectEqual(@as(u32, 5), v2);
            try testing.expectEqual(@as(u32, 6), v3);
        }
    };

    try runtime.runUntilComplete(TestFn.testWrap, .{ &runtime, &queue }, .{});
}
