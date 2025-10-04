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
        _ = runtime;
        return .{
            .buffer = std.mem.zeroes([8]i32),
            .mutex = zio.Mutex.init,
            .not_empty = zio.Condition.init,
            .not_full = zio.Condition.init,
        };
    }

    fn put(self: *BoundedBuffer, rt: *zio.Runtime, item: i32) void {
        self.mutex.lock(rt);
        defer self.mutex.unlock(rt);

        // Wait until buffer is not full
        while (self.count == self.buffer.len) {
            self.not_full.wait(rt, &self.mutex);
        }

        // Add item to buffer
        self.buffer[self.tail] = item;
        self.tail = (self.tail + 1) % self.buffer.len;
        self.count += 1;

        std.log.info("Produced: {} (buffer size: {})", .{ item, self.count });

        // Signal that buffer is not empty
        self.not_empty.signal(rt);
    }

    fn get(self: *BoundedBuffer, rt: *zio.Runtime) i32 {
        self.mutex.lock(rt);
        defer self.mutex.unlock(rt);

        // Wait until buffer is not empty
        while (self.count == 0) {
            self.not_empty.wait(rt, &self.mutex);
        }

        // Remove item from buffer
        const item = self.buffer[self.head];
        self.head = (self.head + 1) % self.buffer.len;
        self.count -= 1;

        std.log.info("Consumed: {} (buffer size: {})", .{ item, self.count });

        // Signal that buffer is not full
        self.not_full.signal(rt);

        return item;
    }
};

fn producer(rt: *zio.Runtime, buffer: *BoundedBuffer, id: u32) void {
    for (0..5) |i| {
        const item = @as(i32, @intCast(id * 100 + i));
        buffer.put(rt, item);
        rt.sleep(100); // Small delay between productions
    }
    std.log.info("Producer {} finished", .{id});
}

fn consumer(rt: *zio.Runtime, buffer: *BoundedBuffer, id: u32) void {
    for (0..5) |_| {
        const item = buffer.get(rt);
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
    var producers: [2]zio.JoinHandle(void) = undefined;
    var consumers: [2]zio.JoinHandle(void) = undefined;
    var producer_count: usize = 0;
    var consumer_count: usize = 0;

    defer {
        for (producers[0..producer_count]) |*task| task.deinit();
        for (consumers[0..consumer_count]) |*task| task.deinit();
    }

    for (0..2) |i| {
        producers[i] = try runtime.spawn(producer, .{ &runtime, &buffer, @as(u32, @intCast(i)) }, .{});
        producer_count += 1;
        consumers[i] = try runtime.spawn(consumer, .{ &runtime, &buffer, @as(u32, @intCast(i)) }, .{});
        consumer_count += 1;
    }

    try runtime.run();

    std.log.info("All tasks completed. Final buffer size: {}", .{buffer.count});
}
