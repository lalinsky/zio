// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

const std = @import("std");

const ev = @import("ev/root.zig");
const Runtime = @import("runtime.zig").Runtime;
const Executor = @import("runtime.zig").Executor;
const resumeTask = @import("runtime/task.zig").resumeTask;
const AnyTask = @import("runtime/task.zig").AnyTask;
const meta = @import("meta.zig");
const Cancelable = @import("common.zig").Cancelable;
const Timeoutable = @import("common.zig").Timeoutable;
const Duration = @import("time.zig").Duration;
const AutoCancel = @import("runtime/autocancel.zig").AutoCancel;

/// Generic callback that resumes the task stored in userdata
pub fn genericCallback(loop: *ev.Loop, completion: *ev.Completion) void {
    _ = loop;
    const task: *AnyTask = @ptrCast(@alignCast(completion.userdata.?));
    resumeTask(task, .local);
}

/// Cancels the I/O operation and waits for full completion.
pub fn cancelIo(rt: *Runtime, completion: *ev.Completion) void {
    // We can't handle user cancelations during this
    rt.beginShield();
    defer rt.endShield();

    // Cancel the operation and wait for the cancelation to complete
    var cancel = ev.Cancel{
        .c = ev.Completion.init(.cancel),
        .target = completion,
    };
    const task = rt.getCurrentTask();
    cancel.c.userdata = task;
    cancel.c.callback = genericCallback;

    const executor = task.getExecutor();
    executor.loop.add(&cancel.c);
    waitForIo(rt, &cancel.c) catch {};

    // Now wait for the main operation to complete
    // This can't return error.Canceled because of the shield
    waitForIo(rt, completion) catch unreachable;
}

pub fn waitForIo(rt: *Runtime, completion: *ev.Completion) Cancelable!void {
    const task = rt.getCurrentTask();
    var executor = task.getExecutor();

    // Transition to preparing_to_wait state before yielding
    task.state.store(.preparing_to_wait, .release);

    // Re-check completion state after setting preparing_to_wait
    // If IO completed and callback was already called, restore ready state and exit
    // We must check for .dead (not .completed) because .completed means the callback
    // hasn't been called yet, and the completion is still referenced by the loop
    if (completion.state == .dead) {
        task.state.store(.ready, .release);
        return;
    }

    // Yield with atomic state transition (.preparing_to_wait -> .waiting)
    // If IO completes before the yield, the CAS inside yield() will fail and we won't suspend
    executor.yield(.preparing_to_wait, .waiting, .allow_cancel) catch |err| {
        cancelIo(rt, completion);
        return err;
    };

    std.debug.assert(completion.state == .dead);
}

/// Runs an I/O operation to completion.
/// Sets up the callback, submits to the event loop, and waits for completion.
pub fn runIo(rt: *Runtime, c: *ev.Completion) Cancelable!void {
    const task = rt.getCurrentTask();
    const executor = task.getExecutor();

    c.userdata = task;
    c.callback = genericCallback;

    // Clear callback and context in defer when runtime safety is on to catch use-after-return bugs
    defer if (std.debug.runtime_safety) {
        c.callback = null;
        c.userdata = null;
    };

    executor.loop.add(c);
    try waitForIo(rt, c);
}

/// Context for tracking multiple I/O operations
const MultiIoContext = struct {
    task: *AnyTask,
    remaining: std.atomic.Value(usize),
};

/// Callback for multi I/O that only resumes when all operations complete
fn multiIoCallback(loop: *ev.Loop, completion: *ev.Completion) void {
    _ = loop;
    const ctx: *MultiIoContext = @ptrCast(@alignCast(completion.userdata.?));
    if (ctx.remaining.fetchSub(1, .release) == 1) {
        resumeTask(ctx.task, .maybe_remote);
    }
}

/// Runs multiple I/O operations to completion.
/// Submits all operations and waits for all to complete.
pub fn runIoMulti(rt: *Runtime, completions: []const *ev.Completion) Cancelable!void {
    if (completions.len == 0) return;

    const task = rt.getCurrentTask();
    const executor = task.getExecutor();

    var ctx = MultiIoContext{
        .task = task,
        .remaining = .init(completions.len),
    };

    for (completions) |c| {
        c.userdata = &ctx;
        c.callback = multiIoCallback;
    }

    // Clear callbacks and context in defer when runtime safety is on to catch use-after-return bugs
    defer if (std.debug.runtime_safety) {
        for (completions) |c| {
            c.callback = null;
            c.userdata = null;
        }
    };

    task.state.store(.preparing_to_wait, .release);

    for (completions) |c| {
        executor.loop.add(c);
    }

    executor.yield(.preparing_to_wait, .waiting, .allow_cancel) catch |err| {
        // Cancel all remaining operations
        for (completions) |c| {
            if (c.state != .dead) {
                cancelIo(rt, c);
            }
        }
        return err;
    };

    for (completions) |c| {
        std.debug.assert(c.state == .dead);
    }
}

pub fn timedWaitForIo(rt: *Runtime, completion: *ev.Completion, timeout: Duration) (Timeoutable || Cancelable)!void {
    const task = rt.getCurrentTask();
    var executor = task.getExecutor();

    // Set up timeout timer
    var timer = AutoCancel.init;
    defer timer.clear(rt);
    timer.set(rt, timeout);

    // Transition to preparing_to_wait state before yielding
    task.state.store(.preparing_to_wait, .release);

    // Re-check completion state after setting preparing_to_wait
    // If IO completed and callback was already called, restore ready state and exit
    // We must check for .dead (not .completed) because .completed means the callback
    // hasn't been called yet, and the completion is still referenced by the loop
    if (completion.state == .dead) {
        task.state.store(.ready, .release);
        return;
    }

    // Yield with atomic state transition (.preparing_to_wait -> .waiting)
    // If IO completes before the yield, the CAS inside yield() will fail and we won't suspend
    executor.yield(.preparing_to_wait, .waiting, .allow_cancel) catch |err| {
        // Check if this auto-cancel triggered before clearing timeout state
        const is_timeout = timer.check(rt, err);
        timer.clear(rt);
        cancelIo(rt, completion);
        if (is_timeout) return error.Timeout;
        return err;
    };

    std.debug.assert(completion.state == .dead);
}

// Note: runIo and IoOperation have been removed in favor of working directly
// with ev's typed completions (FileRead, FileWrite, etc.)

/// Helper function to fill an iovec buffer for writing with support for splatting patterns.
/// Used by both FileWriter and Stream.Writer to handle the splat parameter correctly.
///
/// Parameters:
/// - out: Output buffer of slices to fill
/// - header: Optional header data to write first
/// - data: Array of data slices, with the last slice being the pattern for splatting
/// - splat: Number of times to repeat the pattern (0 = don't include, 1 = include once, >1 = repeat)
/// - splat_buffer: Temporary buffer for expanding single-byte patterns
///
/// Returns: Number of slices filled in `out`
pub fn fillBuf(
    out: [][]const u8,
    header: []const u8,
    data: []const []const u8,
    splat: usize,
    splat_buffer: []u8,
) usize {
    var len: usize = 0;
    const max_len = out.len;

    // Add header
    if (header.len > 0 and len < max_len) {
        out[len] = header;
        len += 1;
    }

    if (data.len == 0) return len;

    // Add data slices (except last which might be pattern)
    const last_index = data.len - 1;
    for (data[0..last_index]) |bytes| {
        if (bytes.len > 0 and len < max_len) {
            out[len] = bytes;
            len += 1;
        }
    }

    // Handle pattern/splat
    const pattern = data[last_index];
    switch (splat) {
        0 => {},
        1 => if (pattern.len > 0 and len < max_len) {
            out[len] = pattern;
            len += 1;
        },
        else => switch (pattern.len) {
            0 => {},
            1 => {
                const memset_len = @min(splat_buffer.len, splat);
                const buf = splat_buffer[0..memset_len];
                @memset(buf, pattern[0]);
                if (len < max_len) {
                    out[len] = buf;
                    len += 1;
                }
                var remaining_splat = splat - buf.len;
                while (remaining_splat > splat_buffer.len and len < max_len) {
                    out[len] = splat_buffer;
                    len += 1;
                    remaining_splat -= splat_buffer.len;
                }
                if (remaining_splat > 0 and len < max_len) {
                    out[len] = splat_buffer[0..remaining_splat];
                    len += 1;
                }
            },
            else => {
                var i: usize = 0;
                while (i < splat and len < max_len) : (i += 1) {
                    out[len] = pattern;
                    len += 1;
                }
            },
        },
    }

    return len;
}

test "fillBuf: single-byte pattern with small splat" {
    var out: [16][]const u8 = undefined;
    var splat_buf: [64]u8 = undefined;
    var data = [_][]const u8{"x"};

    const len = fillBuf(&out, "", &data, 5, &splat_buf);
    try std.testing.expectEqual(1, len);
    try std.testing.expectEqualStrings("xxxxx", out[0]);
}

test "fillBuf: single-byte pattern with large splat" {
    var out: [16][]const u8 = undefined;
    var splat_buf: [64]u8 = undefined;
    var data = [_][]const u8{"y"};

    const len = fillBuf(&out, "", &data, 200, &splat_buf);
    try std.testing.expect(len > 1); // Should use multiple iovecs

    var total: usize = 0;
    for (out[0..len]) |slice| {
        total += slice.len;
        // Verify all bytes are 'y'
        for (slice) |byte| {
            try std.testing.expectEqual(@as(u8, 'y'), byte);
        }
    }
    try std.testing.expectEqual(200, total);
}

test "fillBuf: multi-byte pattern with splat" {
    var out: [16][]const u8 = undefined;
    var splat_buf: [64]u8 = undefined;
    var data = [_][]const u8{"ab"};

    const len = fillBuf(&out, "", &data, 3, &splat_buf);
    try std.testing.expectEqual(3, len);
    try std.testing.expectEqualStrings("ab", out[0]);
    try std.testing.expectEqualStrings("ab", out[1]);
    try std.testing.expectEqualStrings("ab", out[2]);
}

test "fillBuf: with header and data" {
    var out: [16][]const u8 = undefined;
    var splat_buf: [64]u8 = undefined;
    var data = [_][]const u8{ "hello", "world", "!" };

    const len = fillBuf(&out, "header:", &data, 1, &splat_buf);
    try std.testing.expectEqual(4, len);
    try std.testing.expectEqualStrings("header:", out[0]);
    try std.testing.expectEqualStrings("hello", out[1]);
    try std.testing.expectEqualStrings("world", out[2]);
    try std.testing.expectEqualStrings("!", out[3]);
}

test "fillBuf: splat=0 excludes pattern" {
    var out: [16][]const u8 = undefined;
    var splat_buf: [64]u8 = undefined;
    var data = [_][]const u8{ "hello", "pattern" };

    const len = fillBuf(&out, "", &data, 0, &splat_buf);
    try std.testing.expectEqual(1, len);
    try std.testing.expectEqualStrings("hello", out[0]);
}

test "fillBuf: empty pattern with splat" {
    var out: [16][]const u8 = undefined;
    var splat_buf: [64]u8 = undefined;
    var data = [_][]const u8{ "hello", "" };

    const len = fillBuf(&out, "", &data, 5, &splat_buf);
    try std.testing.expectEqual(1, len);
    try std.testing.expectEqualStrings("hello", out[0]);
}
