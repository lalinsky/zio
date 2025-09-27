const std = @import("std");
const zio = @import("zio");

const BoundedBuffer = struct {
    buffer: [8]i32,
    count: usize = 0,
    head: usize = 0,
    tail: usize = 0,
    mutex: zio.Mutex,
    not_empty: zio.Condition,
    not_full: zio.Condition,

    fn init(runtime: *zio.Runtime) BoundedBuffer {
        return .{
            .buffer = std.mem.zeroes([8]i32),
            .mutex = zio.Mutex.init(runtime),
            .not_empty = zio.Condition.init(runtime),
            .not_full = zio.Condition.init(runtime),
        };
    }

    fn put(self: *BoundedBuffer, item: i32) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Wait until buffer is not full
        while (self.count == self.buffer.len) {
            self.not_full.wait(&self.mutex);
        }

        // Add item to buffer
        self.buffer[self.tail] = item;
        self.tail = (self.tail + 1) % self.buffer.len;
        self.count += 1;

        std.log.info("Produced: {} (buffer size: {})", .{ item, self.count });

        // Signal that buffer is not empty
        self.not_empty.signal();
    }

    fn get(self: *BoundedBuffer) i32 {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Wait until buffer is not empty
        while (self.count == 0) {
            self.not_empty.wait(&self.mutex);
        }

        // Remove item from buffer
        const item = self.buffer[self.head];
        self.head = (self.head + 1) % self.buffer.len;
        self.count -= 1;

        std.log.info("Consumed: {} (buffer size: {})", .{ item, self.count });

        // Signal that buffer is not full
        self.not_full.signal();

        return item;
    }
};

fn producer(rt: *zio.Runtime, buffer: *BoundedBuffer, id: u32) void {
    for (0..5) |i| {
        const item = @as(i32, @intCast(id * 100 + i));
        buffer.put(item);
        rt.sleep(100); // Small delay between productions
    }
    std.log.info("Producer {} finished", .{id});
}

fn consumer(rt: *zio.Runtime, buffer: *BoundedBuffer, id: u32) void {
    for (0..5) |_| {
        const item = buffer.get();
        _ = item;
        rt.sleep(150); // Small delay between consumptions
    }
    std.log.info("Consumer {} finished", .{id});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var runtime = try zio.Runtime.init(gpa.allocator(), .{});
    defer runtime.deinit();

    var buffer = BoundedBuffer.init(&runtime);

    // Start 2 producers and 2 consumers
    var producers: [2]zio.Task(void) = undefined;
    var consumers: [2]zio.Task(void) = undefined;

    for (0..2) |i| {
        producers[i] = try runtime.spawn(producer, .{ &runtime, &buffer, @as(u32, @intCast(i)) }, .{});
        consumers[i] = try runtime.spawn(consumer, .{ &runtime, &buffer, @as(u32, @intCast(i)) }, .{});
    }

    defer {
        for (&producers) |*task| task.deinit();
        for (&consumers) |*task| task.deinit();
    }

    try runtime.run();

    std.log.info("All tasks completed. Final buffer size: {}", .{buffer.count});
}
