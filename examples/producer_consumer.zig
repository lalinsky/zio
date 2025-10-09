const std = @import("std");
const zio = @import("zio");

fn producer(rt: *zio.Runtime, queue: *zio.Queue(i32), id: u32) void {
    for (0..5) |i| {
        const item = @as(i32, @intCast(id * 100 + i));
        queue.put(rt, item) catch |err| switch (err) {
            error.QueueClosed => {
                std.log.info("Producer {}: queue closed, exiting", .{id});
                return;
            },
            error.Canceled => {
                std.log.info("Producer {}: cancelled, exiting", .{id});
                return;
            },
        };
        std.log.info("Produced: {}", .{item});
        rt.sleep(100); // Small delay between productions
    }
    std.log.info("Producer {} finished", .{id});
}

fn consumer(rt: *zio.Runtime, queue: *zio.Queue(i32), id: u32) void {
    for (0..5) |_| {
        const item = queue.get(rt) catch |err| switch (err) {
            error.QueueClosed => {
                std.log.info("Consumer {}: queue closed, exiting", .{id});
                return;
            },
            error.Canceled => {
                std.log.info("Consumer {}: cancelled, exiting", .{id});
                return;
            },
        };
        std.log.info("Consumed: {}", .{item});
        rt.sleep(150); // Small delay between consumptions
    }
    std.log.info("Consumer {} finished", .{id});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var runtime = try zio.Runtime.init(gpa.allocator(), .{});
    defer runtime.deinit();

    var buffer: [8]i32 = undefined;
    var queue = zio.Queue(i32).init(&buffer);

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
        producers[i] = try runtime.spawn(producer, .{ &runtime, &queue, @as(u32, @intCast(i)) }, .{});
        producer_count += 1;
        consumers[i] = try runtime.spawn(consumer, .{ &runtime, &queue, @as(u32, @intCast(i)) }, .{});
        consumer_count += 1;
    }

    try runtime.run();

    std.log.info("All tasks completed.", .{});
}
