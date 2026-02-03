// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

const std = @import("std");
const zio = @import("zio");

fn producer(channel: *zio.Channel(i32), id: u32) zio.Cancelable!void {
    for (0..5) |i| {
        const item = @as(i32, @intCast(id * 100 + i));
        channel.send(item) catch |err| switch (err) {
            error.ChannelClosed => {
                std.log.info("Producer {}: channel closed, exiting", .{id});
                return;
            },
            error.Canceled => {
                std.log.info("Producer {}: canceled, exiting", .{id});
                return;
            },
        };
        std.log.info("Produced: {}", .{item});
        try zio.sleep(.fromMilliseconds(100)); // Small delay between productions
    }
    std.log.info("Producer {} finished", .{id});
}

fn consumer(channel: *zio.Channel(i32), id: u32) zio.Cancelable!void {
    for (0..5) |_| {
        const item = channel.receive() catch |err| switch (err) {
            error.ChannelClosed => {
                std.log.info("Consumer {}: channel closed, exiting", .{id});
                return;
            },
            error.Canceled => {
                std.log.info("Consumer {}: canceled, exiting", .{id});
                return;
            },
        };
        std.log.info("Consumed: {}", .{item});
        try zio.sleep(.fromMilliseconds(150)); // Small delay between consumptions
    }
    std.log.info("Consumer {} finished", .{id});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var rt = try zio.Runtime.init(gpa.allocator(), .{});
    defer rt.deinit();

    var buffer: [8]i32 = undefined;
    var channel = zio.Channel(i32).init(&buffer);

    // Start 2 producers and 2 consumers
    var group: zio.Group = .init;
    defer group.cancel();

    for (0..2) |i| {
        try group.spawn(producer, .{ &channel, @intCast(i) });
        try group.spawn(consumer, .{ &channel, @intCast(i) });
    }

    try group.wait();

    std.log.info("All tasks completed.", .{});
}
