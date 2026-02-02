const std = @import("std");
const zio = @import("zio");

const SearchResult = struct {
    file_path: []const u8,
    line_number: usize,
    line: []const u8,
};

// --8<-- [start:searchFile]
fn searchFile(
    gpa: std.mem.Allocator,
    dir: zio.Dir,
    path: []const u8,
    pattern: []const u8,
    results_channel: *zio.Channel(SearchResult),
) !void {
    const file = dir.openFile(path, .{}) catch |err| {
        std.log.warn("Failed to open file {s}: {}", .{ path, err });
        return;
    };
    defer file.close();

    var read_buffer: [4096]u8 = undefined;
    var reader = file.reader(&read_buffer);

    var line_number: usize = 0;
    while (true) {
        const line = reader.interface.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => break,
            error.ReadFailed => |e| return reader.err orelse e,
            else => |e| return e,
        };
        line_number += 1;

        if (std.mem.indexOf(u8, line, pattern)) |_| {
            const result = SearchResult{
                .file_path = path,
                .line_number = line_number,
                .line = try gpa.dupe(u8, line),
            };
            errdefer gpa.free(result.line);
            try results_channel.send(result);
        }
    }
}
// --8<-- [end:searchFile]

// --8<-- [start:worker]
fn worker(
    gpa: std.mem.Allocator,
    dir: zio.Dir,
    id: usize,
    work_channel: *zio.Channel([]const u8),
    results_channel: *zio.Channel(SearchResult),
    pattern: []const u8,
) zio.Cancelable!void {
    while (true) {
        const path = work_channel.receive() catch |err| switch (err) {
            error.ChannelClosed => {
                std.log.info("Worker {} exiting", .{id});
                return;
            },
            error.Canceled => return error.Canceled,
        };

        std.log.info("Worker {} searching {s}", .{ id, path });
        searchFile(gpa, dir, path, pattern, results_channel) catch |err| {
            std.log.warn("Worker {} error searching {s}: {}", .{ id, path, err });
        };
    }
}
// --8<-- [end:worker]

// --8<-- [start:collector]
fn collector(
    gpa: std.mem.Allocator,
    results_channel: *zio.Channel(SearchResult),
) !void {
    const stdout = zio.stdout();
    var write_buffer: [4096]u8 = undefined;
    var writer = stdout.writer(&write_buffer);

    while (true) {
        const result = results_channel.receive() catch |err| switch (err) {
            error.ChannelClosed => return,
            error.Canceled => return error.Canceled,
        };

        try writer.interface.print("{s}:{}: {s}", .{
            result.file_path,
            result.line_number,
            result.line,
        });
        try writer.interface.flush();

        gpa.free(result.line);
    }
}
// --8<-- [end:collector]

pub fn main() !void {
    const gpa = std.heap.smp_allocator;

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    if (args.len < 3) {
        std.log.err("Usage: {s} <pattern> <file1> [file2...]", .{args[0]});
        return error.InvalidArgs;
    }

    const pattern = args[1];
    const files = args[2..];

    var rt = try zio.Runtime.init(gpa, .{ .executors = .auto });
    defer rt.deinit();

    const cwd = zio.Dir.cwd();

    // --8<-- [start:channels]
    // Create channels
    var work_buffer: [16][]const u8 = undefined;
    var work_channel = zio.Channel([]const u8).init(&work_buffer);

    var results_channel = zio.Channel(SearchResult).init(&.{});
    // --8<-- [end:channels]

    var workers_group: zio.Group = .init;
    defer workers_group.cancel(rt);

    var collector_group: zio.Group = .init;
    defer collector_group.cancel(rt);

    // --8<-- [start:coordination]
    // Start worker tasks
    const num_workers = 4;
    for (0..num_workers) |i| {
        try workers_group.spawn(rt, worker, .{ gpa, cwd, i, &work_channel, &results_channel, pattern });
    }

    // Start collector task
    try collector_group.spawn(rt, collector, .{ gpa, &results_channel });

    // Distribute work
    for (files) |file_path| {
        work_channel.send(file_path) catch |err| switch (err) {
            error.ChannelClosed => break,
            error.Canceled => return error.Canceled,
        };
    }

    // Close work channel to signal workers to exit
    work_channel.close(.graceful);

    // Wait for all workers to finish
    try workers_group.wait(rt);

    // Now close results channel to signal collector to exit
    results_channel.close(.graceful);

    // Wait for collector to finish
    try collector_group.wait(rt);
    // --8<-- [end:coordination]

    std.log.info("Search complete.", .{});
}
