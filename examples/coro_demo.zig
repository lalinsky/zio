// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

//! Low-level coroutine API demo.
//!
//! This example demonstrates the raw coroutine primitives in zio.coro.
//! For most use cases, prefer the higher-level zio.Runtime API which
//! provides automatic scheduling, I/O integration, and synchronization.
//!
//! The low-level API is useful when you need:
//! - Custom scheduling strategies
//! - Integration with external event loops (e.g. libuv)
//! - Fine-grained control over context switching

const std = @import("std");
const zio = @import("zio");

const coro = zio.coro;

fn producer(c: *coro.Coroutine, channel: *Channel(?usize)) void {
    std.log.info("[producer] starting", .{});

    for (0..5) |i| {
        std.log.info("[producer] sending: {}", .{i});
        channel.send(c, i);
    }

    std.log.info("[producer] sending: done (null)", .{});
    channel.send(c, null);

    std.log.info("[producer] finished", .{});
}

fn consumer(c: *coro.Coroutine, channel: *Channel(?usize)) usize {
    std.log.info("[consumer] starting", .{});

    var sum: usize = 0;
    while (true) {
        const value = channel.recv(c) orelse break;
        std.log.info("[consumer] received: {}", .{value});
        sum += value;
    }

    std.log.info("[consumer] finished with sum: {}", .{sum});
    return sum;
}

/// Simple unbuffered channel for demonstration.
fn Channel(T: type) type {
    return struct {
        data: ?T = null,

        fn send(self: *@This(), c: *coro.Coroutine, value: T) void {
            while (self.data != null) {
                c.yield();
            }
            self.data = value;
        }

        fn recv(self: *@This(), c: *coro.Coroutine) T {
            while (self.data == null) {
                c.yield();
            }
            const value = self.data.?;
            self.data = null;
            return value;
        }
    };
}

pub fn main() !void {
    std.log.info("=== Low-level coroutine demo ===", .{});
    std.log.info("", .{});

    // Setup stack growth handler (required for automatic stack extension)
    try coro.setupStackGrowth();
    defer coro.cleanupStackGrowth();

    // Parent context - where we return when coroutines yield
    var parent_context: coro.Context = undefined;

    // Create producer coroutine
    var producer_coro: coro.Coroutine = .{
        .parent_context_ptr = .init(&parent_context),
        .context = undefined,
    };
    try coro.stackAlloc(&producer_coro.context.stack_info, 64 * 1024, 4096);
    defer coro.stackFree(producer_coro.context.stack_info);

    // Create consumer coroutine
    var consumer_coro: coro.Coroutine = .{
        .parent_context_ptr = .init(&parent_context),
        .context = undefined,
    };
    try coro.stackAlloc(&consumer_coro.context.stack_info, 64 * 1024, 4096);
    defer coro.stackFree(consumer_coro.context.stack_info);

    // Shared channel
    var channel: Channel(?usize) = .{};

    // Setup coroutines with their entry points
    const ProducerClosure = coro.Closure(producer);
    const ConsumerClosure = coro.Closure(consumer);

    var producer_closure = ProducerClosure.init(.{&channel});
    var consumer_closure = ConsumerClosure.init(.{&channel});

    producer_coro.setup(&ProducerClosure.start, &producer_closure);
    consumer_coro.setup(&ConsumerClosure.start, &consumer_closure);

    // Simple round-robin scheduler
    std.log.info("[scheduler] starting round-robin scheduling", .{});
    while (!producer_closure.finished or !consumer_closure.finished) {
        if (!producer_closure.finished) {
            producer_coro.step();
        }
        if (!consumer_closure.finished) {
            consumer_coro.step();
        }
    }

    std.log.info("", .{});
    std.log.info("[scheduler] all coroutines finished", .{});
    std.log.info("[result] sum = {}", .{consumer_closure.result});
}
