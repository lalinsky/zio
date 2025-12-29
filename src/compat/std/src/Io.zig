const builtin = @import("builtin");
const is_windows = builtin.os.tag == .windows;

const std = @import("std.zig");
const windows = std.os.windows;
const posix = std.posix;
const math = std.math;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

pub const Limit = enum(usize) {
    nothing = 0,
    unlimited = std.math.maxInt(usize),
    _,

    /// `std.math.maxInt(usize)` is interpreted to mean `.unlimited`.
    pub fn limited(n: usize) Limit {
        return @enumFromInt(n);
    }

    /// Any value grater than `std.math.maxInt(usize)` is interpreted to mean
    /// `.unlimited`.
    pub fn limited64(n: u64) Limit {
        return @enumFromInt(@min(n, std.math.maxInt(usize)));
    }

    pub fn countVec(data: []const []const u8) Limit {
        var total: usize = 0;
        for (data) |d| total += d.len;
        return .limited(total);
    }

    pub fn min(a: Limit, b: Limit) Limit {
        return @enumFromInt(@min(@intFromEnum(a), @intFromEnum(b)));
    }

    pub fn minInt(l: Limit, n: usize) usize {
        return @min(n, @intFromEnum(l));
    }

    pub fn minInt64(l: Limit, n: u64) usize {
        return @min(n, @intFromEnum(l));
    }

    pub fn slice(l: Limit, s: []u8) []u8 {
        return s[0..l.minInt(s.len)];
    }

    pub fn sliceConst(l: Limit, s: []const u8) []const u8 {
        return s[0..l.minInt(s.len)];
    }

    pub fn toInt(l: Limit) ?usize {
        return switch (l) {
            else => @intFromEnum(l),
            .unlimited => null,
        };
    }

    /// Reduces a slice to account for the limit, leaving room for one extra
    /// byte above the limit, allowing for the use case of differentiating
    /// between end-of-stream and reaching the limit.
    pub fn slice1(l: Limit, non_empty_buffer: []u8) []u8 {
        assert(non_empty_buffer.len >= 1);
        return non_empty_buffer[0..@min(@intFromEnum(l) +| 1, non_empty_buffer.len)];
    }

    pub fn nonzero(l: Limit) bool {
        return @intFromEnum(l) > 0;
    }

    /// Return a new limit reduced by `amount` or return `null` indicating
    /// limit would be exceeded.
    pub fn subtract(l: Limit, amount: usize) ?Limit {
        if (l == .unlimited) return .unlimited;
        if (amount > @intFromEnum(l)) return null;
        return @enumFromInt(@intFromEnum(l) - amount);
    }
};

pub const Reader = @import("Io/Reader.zig");
pub const Writer = @import("Io/Writer.zig");

pub fn poll(
    gpa: Allocator,
    comptime StreamEnum: type,
    files: PollFiles(StreamEnum),
) Poller(StreamEnum) {
    const enum_fields = @typeInfo(StreamEnum).@"enum".fields;
    var result: Poller(StreamEnum) = .{
        .gpa = gpa,
        .readers = @splat(.failing),
        .poll_fds = undefined,
        .windows = if (is_windows) .{
            .first_read_done = false,
            .overlapped = [1]windows.OVERLAPPED{
                std.mem.zeroes(windows.OVERLAPPED),
            } ** enum_fields.len,
            .small_bufs = undefined,
            .active = .{
                .count = 0,
                .handles_buf = undefined,
                .stream_map = undefined,
            },
        } else {},
    };

    inline for (enum_fields, 0..) |field, i| {
        if (is_windows) {
            result.windows.active.handles_buf[i] = @field(files, field.name).handle;
        } else {
            result.poll_fds[i] = .{
                .fd = @field(files, field.name).handle,
                .events = posix.POLL.IN,
                .revents = undefined,
            };
        }
    }

    return result;
}

pub fn Poller(comptime StreamEnum: type) type {
    return struct {
        const enum_fields = @typeInfo(StreamEnum).@"enum".fields;
        const PollFd = if (is_windows) void else posix.pollfd;

        gpa: Allocator,
        readers: [enum_fields.len]Reader,
        poll_fds: [enum_fields.len]PollFd,
        windows: if (is_windows) struct {
            first_read_done: bool,
            overlapped: [enum_fields.len]windows.OVERLAPPED,
            small_bufs: [enum_fields.len][128]u8,
            active: struct {
                count: math.IntFittingRange(0, enum_fields.len),
                handles_buf: [enum_fields.len]windows.HANDLE,
                stream_map: [enum_fields.len]StreamEnum,

                pub fn removeAt(self: *@This(), index: u32) void {
                    assert(index < self.count);
                    for (index + 1..self.count) |i| {
                        self.handles_buf[i - 1] = self.handles_buf[i];
                        self.stream_map[i - 1] = self.stream_map[i];
                    }
                    self.count -= 1;
                }
            },
        } else void,

        const Self = @This();

        pub fn deinit(self: *Self) void {
            const gpa = self.gpa;
            if (is_windows) {
                // cancel any pending IO to prevent clobbering OVERLAPPED value
                for (self.windows.active.handles_buf[0..self.windows.active.count]) |h| {
                    _ = windows.kernel32.CancelIo(h);
                }
            }
            inline for (&self.readers) |*r| gpa.free(r.buffer);
            self.* = undefined;
        }

        pub fn poll(self: *Self) !bool {
            if (is_windows) {
                return pollWindows(self, null);
            } else {
                return pollPosix(self, null);
            }
        }

        pub fn pollTimeout(self: *Self, nanoseconds: u64) !bool {
            if (is_windows) {
                return pollWindows(self, nanoseconds);
            } else {
                return pollPosix(self, nanoseconds);
            }
        }

        pub fn reader(self: *Self, which: StreamEnum) *Reader {
            return &self.readers[@intFromEnum(which)];
        }

        pub fn toOwnedSlice(self: *Self, which: StreamEnum) error{OutOfMemory}![]u8 {
            const gpa = self.gpa;
            const r = reader(self, which);
            if (r.seek == 0) {
                const new = try gpa.realloc(r.buffer, r.end);
                r.buffer = &.{};
                r.end = 0;
                return new;
            }
            const new = try gpa.dupe(u8, r.buffered());
            gpa.free(r.buffer);
            r.buffer = &.{};
            r.seek = 0;
            r.end = 0;
            return new;
        }

        fn pollWindows(self: *Self, nanoseconds: ?u64) !bool {
            const bump_amt = 512;
            const gpa = self.gpa;

            if (!self.windows.first_read_done) {
                var already_read_data = false;
                for (0..enum_fields.len) |i| {
                    const handle = self.windows.active.handles_buf[i];
                    switch (try windowsAsyncReadToFifoAndQueueSmallRead(
                        gpa,
                        handle,
                        &self.windows.overlapped[i],
                        &self.readers[i],
                        &self.windows.small_bufs[i],
                        bump_amt,
                    )) {
                        .populated, .empty => |state| {
                            if (state == .populated) already_read_data = true;
                            self.windows.active.handles_buf[self.windows.active.count] = handle;
                            self.windows.active.stream_map[self.windows.active.count] = @as(StreamEnum, @enumFromInt(i));
                            self.windows.active.count += 1;
                        },
                        .closed => {}, // don't add to the wait_objects list
                        .closed_populated => {
                            // don't add to the wait_objects list, but we did already get data
                            already_read_data = true;
                        },
                    }
                }
                self.windows.first_read_done = true;
                if (already_read_data) return true;
            }

            while (true) {
                if (self.windows.active.count == 0) return false;

                const status = windows.kernel32.WaitForMultipleObjects(
                    self.windows.active.count,
                    &self.windows.active.handles_buf,
                    0,
                    if (nanoseconds) |ns|
                        @min(std.math.cast(u32, ns / std.time.ns_per_ms) orelse (windows.INFINITE - 1), windows.INFINITE - 1)
                    else
                        windows.INFINITE,
                );
                if (status == windows.WAIT_FAILED)
                    return windows.unexpectedError(windows.GetLastError());
                if (status == windows.WAIT_TIMEOUT)
                    return true;

                if (status < windows.WAIT_OBJECT_0 or status > windows.WAIT_OBJECT_0 + enum_fields.len - 1)
                    unreachable;

                const active_idx = status - windows.WAIT_OBJECT_0;

                const stream_idx = @intFromEnum(self.windows.active.stream_map[active_idx]);
                const handle = self.windows.active.handles_buf[active_idx];

                const overlapped = &self.windows.overlapped[stream_idx];
                const stream_reader = &self.readers[stream_idx];
                const small_buf = &self.windows.small_bufs[stream_idx];

                const num_bytes_read = switch (try windowsGetReadResult(handle, overlapped, false)) {
                    .success => |n| n,
                    .closed => {
                        self.windows.active.removeAt(active_idx);
                        continue;
                    },
                    .aborted => unreachable,
                };
                const buf = small_buf[0..num_bytes_read];
                const dest = try writableSliceGreedyAlloc(stream_reader, gpa, buf.len);
                @memcpy(dest[0..buf.len], buf);
                advanceBufferEnd(stream_reader, buf.len);

                switch (try windowsAsyncReadToFifoAndQueueSmallRead(
                    gpa,
                    handle,
                    overlapped,
                    stream_reader,
                    small_buf,
                    bump_amt,
                )) {
                    .empty => {}, // irrelevant, we already got data from the small buffer
                    .populated => {},
                    .closed,
                    .closed_populated, // identical, since we already got data from the small buffer
                    => self.windows.active.removeAt(active_idx),
                }
                return true;
            }
        }

        fn pollPosix(self: *Self, nanoseconds: ?u64) !bool {
            const gpa = self.gpa;
            // We ask for ensureUnusedCapacity with this much extra space. This
            // has more of an effect on small reads because once the reads
            // start to get larger the amount of space an ArrayList will
            // allocate grows exponentially.
            const bump_amt = 512;

            const err_mask = posix.POLL.ERR | posix.POLL.NVAL | posix.POLL.HUP;

            const events_len = try posix.poll(&self.poll_fds, if (nanoseconds) |ns|
                std.math.cast(i32, ns / std.time.ns_per_ms) orelse std.math.maxInt(i32)
            else
                -1);
            if (events_len == 0) {
                for (self.poll_fds) |poll_fd| {
                    if (poll_fd.fd != -1) return true;
                } else return false;
            }

            var keep_polling = false;
            for (&self.poll_fds, &self.readers) |*poll_fd, *r| {
                // Try reading whatever is available before checking the error
                // conditions.
                // It's still possible to read after a POLL.HUP is received,
                // always check if there's some data waiting to be read first.
                if (poll_fd.revents & posix.POLL.IN != 0) {
                    const buf = try writableSliceGreedyAlloc(r, gpa, bump_amt);
                    const amt = posix.read(poll_fd.fd, buf) catch |err| switch (err) {
                        error.BrokenPipe => 0, // Handle the same as EOF.
                        else => |e| return e,
                    };
                    advanceBufferEnd(r, amt);
                    if (amt == 0) {
                        // Remove the fd when the EOF condition is met.
                        poll_fd.fd = -1;
                    } else {
                        keep_polling = true;
                    }
                } else if (poll_fd.revents & err_mask != 0) {
                    // Exclude the fds that signaled an error.
                    poll_fd.fd = -1;
                } else if (poll_fd.fd != -1) {
                    keep_polling = true;
                }
            }
            return keep_polling;
        }

        /// Returns a slice into the unused capacity of `buffer` with at least
        /// `min_len` bytes, extending `buffer` by resizing it with `gpa` as necessary.
        ///
        /// After calling this function, typically the caller will follow up with a
        /// call to `advanceBufferEnd` to report the actual number of bytes buffered.
        fn writableSliceGreedyAlloc(r: *Reader, allocator: Allocator, min_len: usize) Allocator.Error![]u8 {
            {
                const unused = r.buffer[r.end..];
                if (unused.len >= min_len) return unused;
            }
            if (r.seek > 0) {
                const data = r.buffer[r.seek..r.end];
                @memmove(r.buffer[0..data.len], data);
                r.seek = 0;
                r.end = data.len;
            }
            {
                var list: std.ArrayList(u8) = .{
                    .items = r.buffer[0..r.end],
                    .capacity = r.buffer.len,
                };
                defer r.buffer = list.allocatedSlice();
                try list.ensureUnusedCapacity(allocator, min_len);
            }
            const unused = r.buffer[r.end..];
            assert(unused.len >= min_len);
            return unused;
        }

        /// After writing directly into the unused capacity of `buffer`, this function
        /// updates `end` so that users of `Reader` can receive the data.
        fn advanceBufferEnd(r: *Reader, n: usize) void {
            assert(n <= r.buffer.len - r.end);
            r.end += n;
        }

        /// The `ReadFile` docuementation states that `lpNumberOfBytesRead` does not have a meaningful
        /// result when using overlapped I/O, but also that it cannot be `null` on Windows 7. For
        /// compatibility, we point it to this dummy variables, which we never otherwise access.
        /// See: https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-readfile
        var win_dummy_bytes_read: u32 = undefined;

        /// Read as much data as possible from `handle` with `overlapped`, and write it to the FIFO. Before
        /// returning, queue a read into `small_buf` so that `WaitForMultipleObjects` returns when more data
        /// is available. `handle` must have no pending asynchronous operation.
        fn windowsAsyncReadToFifoAndQueueSmallRead(
            gpa: Allocator,
            handle: windows.HANDLE,
            overlapped: *windows.OVERLAPPED,
            r: *Reader,
            small_buf: *[128]u8,
            bump_amt: usize,
        ) !enum { empty, populated, closed_populated, closed } {
            var read_any_data = false;
            while (true) {
                const fifo_read_pending = while (true) {
                    const buf = try writableSliceGreedyAlloc(r, gpa, bump_amt);
                    const buf_len = math.cast(u32, buf.len) orelse math.maxInt(u32);

                    if (0 == windows.kernel32.ReadFile(
                        handle,
                        buf.ptr,
                        buf_len,
                        &win_dummy_bytes_read,
                        overlapped,
                    )) switch (windows.GetLastError()) {
                        .IO_PENDING => break true,
                        .BROKEN_PIPE => return if (read_any_data) .closed_populated else .closed,
                        else => |err| return windows.unexpectedError(err),
                    };

                    const num_bytes_read = switch (try windowsGetReadResult(handle, overlapped, false)) {
                        .success => |n| n,
                        .closed => return if (read_any_data) .closed_populated else .closed,
                        .aborted => unreachable,
                    };

                    read_any_data = true;
                    advanceBufferEnd(r, num_bytes_read);

                    if (num_bytes_read == buf_len) {
                        // We filled the buffer, so there's probably more data available.
                        continue;
                    } else {
                        // We didn't fill the buffer, so assume we're out of data.
                        // There is no pending read.
                        break false;
                    }
                };

                if (fifo_read_pending) cancel_read: {
                    // Cancel the pending read into the FIFO.
                    _ = windows.kernel32.CancelIo(handle);

                    // We have to wait for the handle to be signalled, i.e. for the cancellation to complete.
                    switch (windows.kernel32.WaitForSingleObject(handle, windows.INFINITE)) {
                        windows.WAIT_OBJECT_0 => {},
                        windows.WAIT_FAILED => return windows.unexpectedError(windows.GetLastError()),
                        else => unreachable,
                    }

                    // If it completed before we canceled, make sure to tell the FIFO!
                    const num_bytes_read = switch (try windowsGetReadResult(handle, overlapped, true)) {
                        .success => |n| n,
                        .closed => return if (read_any_data) .closed_populated else .closed,
                        .aborted => break :cancel_read,
                    };
                    read_any_data = true;
                    advanceBufferEnd(r, num_bytes_read);
                }

                // Try to queue the 1-byte read.
                if (0 == windows.kernel32.ReadFile(
                    handle,
                    small_buf,
                    small_buf.len,
                    &win_dummy_bytes_read,
                    overlapped,
                )) switch (windows.GetLastError()) {
                    .IO_PENDING => {
                        // 1-byte read pending as intended
                        return if (read_any_data) .populated else .empty;
                    },
                    .BROKEN_PIPE => return if (read_any_data) .closed_populated else .closed,
                    else => |err| return windows.unexpectedError(err),
                };

                // We got data back this time. Write it to the FIFO and run the main loop again.
                const num_bytes_read = switch (try windowsGetReadResult(handle, overlapped, false)) {
                    .success => |n| n,
                    .closed => return if (read_any_data) .closed_populated else .closed,
                    .aborted => unreachable,
                };
                const buf = small_buf[0..num_bytes_read];
                const dest = try writableSliceGreedyAlloc(r, gpa, buf.len);
                @memcpy(dest[0..buf.len], buf);
                advanceBufferEnd(r, buf.len);
                read_any_data = true;
            }
        }

        /// Simple wrapper around `GetOverlappedResult` to determine the result of a `ReadFile` operation.
        /// If `!allow_aborted`, then `aborted` is never returned (`OPERATION_ABORTED` is considered unexpected).
        ///
        /// The `ReadFile` documentation states that the number of bytes read by an overlapped `ReadFile` must be determined using `GetOverlappedResult`, even if the
        /// operation immediately returns data:
        /// "Use NULL for [lpNumberOfBytesRead] if this is an asynchronous operation to avoid potentially
        /// erroneous results."
        /// "If `hFile` was opened with `FILE_FLAG_OVERLAPPED`, the following conditions are in effect: [...]
        /// The lpNumberOfBytesRead parameter should be set to NULL. Use the GetOverlappedResult function to
        /// get the actual number of bytes read."
        /// See: https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-readfile
        fn windowsGetReadResult(
            handle: windows.HANDLE,
            overlapped: *windows.OVERLAPPED,
            allow_aborted: bool,
        ) !union(enum) {
            success: u32,
            closed,
            aborted,
        } {
            var num_bytes_read: u32 = undefined;
            if (0 == windows.kernel32.GetOverlappedResult(
                handle,
                overlapped,
                &num_bytes_read,
                0,
            )) switch (windows.GetLastError()) {
                .BROKEN_PIPE => return .closed,
                .OPERATION_ABORTED => |err| if (allow_aborted) {
                    return .aborted;
                } else {
                    return windows.unexpectedError(err);
                },
                else => |err| return windows.unexpectedError(err),
            };
            return .{ .success = num_bytes_read };
        }
    };
}

/// Given an enum, returns a struct with fields of that enum, each field
/// representing an I/O stream for polling.
pub fn PollFiles(comptime StreamEnum: type) type {
    return @Struct(.auto, null, std.meta.fieldNames(StreamEnum), &@splat(Io.File), &@splat(.{}));
}

test {
    _ = net;
    _ = Reader;
    _ = Writer;
    _ = Evented;
    _ = Threaded;
    _ = @import("Io/test.zig");
}

const Io = @This();

pub const Evented = switch (builtin.os.tag) {
    .linux => switch (builtin.cpu.arch) {
        .x86_64, .aarch64 => @import("Io/IoUring.zig"),
        else => void, // context-switching code not implemented yet
    },
    .dragonfly, .freebsd, .netbsd, .openbsd, .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => switch (builtin.cpu.arch) {
        .x86_64, .aarch64 => @import("Io/Kqueue.zig"),
        else => void, // context-switching code not implemented yet
    },
    else => void,
};
pub const Threaded = @import("Io/Threaded.zig");
pub const net = @import("Io/net.zig");

userdata: ?*anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    /// If it returns `null` it means `result` has been already populated and
    /// `await` will be a no-op.
    ///
    /// When this function returns non-null, the implementation guarantees that
    /// a unit of concurrency has been assigned to the returned task.
    ///
    /// Thread-safe.
    async: *const fn (
        /// Corresponds to `Io.userdata`.
        userdata: ?*anyopaque,
        /// The pointer of this slice is an "eager" result value.
        /// The length is the size in bytes of the result type.
        /// This pointer's lifetime expires directly after the call to this function.
        result: []u8,
        result_alignment: std.mem.Alignment,
        /// Copied and then passed to `start`.
        context: []const u8,
        context_alignment: std.mem.Alignment,
        start: *const fn (context: *const anyopaque, result: *anyopaque) void,
    ) ?*AnyFuture,
    /// Thread-safe.
    concurrent: *const fn (
        /// Corresponds to `Io.userdata`.
        userdata: ?*anyopaque,
        result_len: usize,
        result_alignment: std.mem.Alignment,
        /// Copied and then passed to `start`.
        context: []const u8,
        context_alignment: std.mem.Alignment,
        start: *const fn (context: *const anyopaque, result: *anyopaque) void,
    ) ConcurrentError!*AnyFuture,
    /// This function is only called when `async` returns a non-null value.
    ///
    /// Thread-safe.
    await: *const fn (
        /// Corresponds to `Io.userdata`.
        userdata: ?*anyopaque,
        /// The same value that was returned from `async`.
        any_future: *AnyFuture,
        /// Points to a buffer where the result is written.
        /// The length is equal to size in bytes of result type.
        result: []u8,
        result_alignment: std.mem.Alignment,
    ) void,
    /// Equivalent to `await` but initiates cancel request.
    ///
    /// This function is only called when `async` returns a non-null value.
    ///
    /// Thread-safe.
    cancel: *const fn (
        /// Corresponds to `Io.userdata`.
        userdata: ?*anyopaque,
        /// The same value that was returned from `async`.
        any_future: *AnyFuture,
        /// Points to a buffer where the result is written.
        /// The length is equal to size in bytes of result type.
        result: []u8,
        result_alignment: std.mem.Alignment,
    ) void,

    /// When this function returns, implementation guarantees that `start` has
    /// either already been called, or a unit of concurrency has been assigned
    /// to the task of calling the function.
    ///
    /// Thread-safe.
    groupAsync: *const fn (
        /// Corresponds to `Io.userdata`.
        userdata: ?*anyopaque,
        /// Owner of the spawned async task.
        group: *Group,
        /// Copied and then passed to `start`.
        context: []const u8,
        context_alignment: std.mem.Alignment,
        start: *const fn (*Group, context: *const anyopaque) void,
    ) void,
    /// Thread-safe.
    groupConcurrent: *const fn (
        /// Corresponds to `Io.userdata`.
        userdata: ?*anyopaque,
        /// Owner of the spawned async task.
        group: *Group,
        /// Copied and then passed to `start`.
        context: []const u8,
        context_alignment: std.mem.Alignment,
        start: *const fn (*Group, context: *const anyopaque) void,
    ) ConcurrentError!void,
    groupWait: *const fn (?*anyopaque, *Group, token: *anyopaque) void,
    groupCancel: *const fn (?*anyopaque, *Group, token: *anyopaque) void,

    recancel: *const fn (?*anyopaque) void,
    swapCancelProtection: *const fn (?*anyopaque, new: CancelProtection) CancelProtection,
    checkCancel: *const fn (?*anyopaque) Cancelable!void,

    /// Blocks until one of the futures from the list has a result ready, such
    /// that awaiting it will not block. Returns that index.
    select: *const fn (?*anyopaque, futures: []const *AnyFuture) Cancelable!usize,

    futexWait: *const fn (?*anyopaque, ptr: *const u32, expected: u32, Timeout) Cancelable!void,
    futexWaitUncancelable: *const fn (?*anyopaque, ptr: *const u32, expected: u32) void,
    futexWake: *const fn (?*anyopaque, ptr: *const u32, max_waiters: u32) void,

    dirCreateDir: *const fn (?*anyopaque, Dir, []const u8, Dir.Permissions) Dir.CreateDirError!void,
    dirCreateDirPath: *const fn (?*anyopaque, Dir, []const u8, Dir.Permissions) Dir.CreateDirPathError!Dir.CreatePathStatus,
    dirCreateDirPathOpen: *const fn (?*anyopaque, Dir, []const u8, Dir.Permissions, Dir.OpenOptions) Dir.CreateDirPathOpenError!Dir,
    dirOpenDir: *const fn (?*anyopaque, Dir, []const u8, Dir.OpenOptions) Dir.OpenError!Dir,
    dirStat: *const fn (?*anyopaque, Dir) Dir.StatError!Dir.Stat,
    dirStatFile: *const fn (?*anyopaque, Dir, []const u8, Dir.StatFileOptions) Dir.StatFileError!File.Stat,
    dirAccess: *const fn (?*anyopaque, Dir, []const u8, Dir.AccessOptions) Dir.AccessError!void,
    dirCreateFile: *const fn (?*anyopaque, Dir, []const u8, File.CreateFlags) File.OpenError!File,
    dirOpenFile: *const fn (?*anyopaque, Dir, []const u8, File.OpenFlags) File.OpenError!File,
    dirClose: *const fn (?*anyopaque, []const Dir) void,
    dirRead: *const fn (?*anyopaque, *Dir.Reader, []Dir.Entry) Dir.Reader.Error!usize,
    dirRealPath: *const fn (?*anyopaque, Dir, out_buffer: []u8) Dir.RealPathError!usize,
    dirRealPathFile: *const fn (?*anyopaque, Dir, path_name: []const u8, out_buffer: []u8) Dir.RealPathFileError!usize,
    dirDeleteFile: *const fn (?*anyopaque, Dir, []const u8) Dir.DeleteFileError!void,
    dirDeleteDir: *const fn (?*anyopaque, Dir, []const u8) Dir.DeleteDirError!void,
    dirRename: *const fn (?*anyopaque, old_dir: Dir, old_sub_path: []const u8, new_dir: Dir, new_sub_path: []const u8) Dir.RenameError!void,
    dirSymLink: *const fn (?*anyopaque, Dir, target_path: []const u8, sym_link_path: []const u8, Dir.SymLinkFlags) Dir.SymLinkError!void,
    dirReadLink: *const fn (?*anyopaque, Dir, sub_path: []const u8, buffer: []u8) Dir.ReadLinkError!usize,
    dirSetOwner: *const fn (?*anyopaque, Dir, ?File.Uid, ?File.Gid) Dir.SetOwnerError!void,
    dirSetFileOwner: *const fn (?*anyopaque, Dir, []const u8, ?File.Uid, ?File.Gid, Dir.SetFileOwnerOptions) Dir.SetFileOwnerError!void,
    dirSetPermissions: *const fn (?*anyopaque, Dir, Dir.Permissions) Dir.SetPermissionsError!void,
    dirSetFilePermissions: *const fn (?*anyopaque, Dir, []const u8, File.Permissions, Dir.SetFilePermissionsOptions) Dir.SetFilePermissionsError!void,
    dirSetTimestamps: *const fn (?*anyopaque, Dir, []const u8, Dir.SetTimestampsOptions) Dir.SetTimestampsError!void,
    dirHardLink: *const fn (?*anyopaque, old_dir: Dir, old_sub_path: []const u8, new_dir: Dir, new_sub_path: []const u8, Dir.HardLinkOptions) Dir.HardLinkError!void,

    fileStat: *const fn (?*anyopaque, File) File.StatError!File.Stat,
    fileLength: *const fn (?*anyopaque, File) File.LengthError!u64,
    fileClose: *const fn (?*anyopaque, []const File) void,
    fileWriteStreaming: *const fn (?*anyopaque, File, header: []const u8, data: []const []const u8, splat: usize) File.Writer.Error!usize,
    fileWritePositional: *const fn (?*anyopaque, File, header: []const u8, data: []const []const u8, splat: usize, offset: u64) File.WritePositionalError!usize,
    fileWriteFileStreaming: *const fn (?*anyopaque, File, header: []const u8, *Io.File.Reader, Io.Limit) File.Writer.WriteFileError!usize,
    fileWriteFilePositional: *const fn (?*anyopaque, File, header: []const u8, *Io.File.Reader, Io.Limit, offset: u64) File.WriteFilePositionalError!usize,
    /// Returns 0 on end of stream.
    fileReadStreaming: *const fn (?*anyopaque, File, data: []const []u8) File.Reader.Error!usize,
    /// Returns 0 on end of stream.
    fileReadPositional: *const fn (?*anyopaque, File, data: []const []u8, offset: u64) File.ReadPositionalError!usize,
    fileSeekBy: *const fn (?*anyopaque, File, relative_offset: i64) File.SeekError!void,
    fileSeekTo: *const fn (?*anyopaque, File, absolute_offset: u64) File.SeekError!void,
    fileSync: *const fn (?*anyopaque, File) File.SyncError!void,
    fileIsTty: *const fn (?*anyopaque, File) Cancelable!bool,
    fileEnableAnsiEscapeCodes: *const fn (?*anyopaque, File) File.EnableAnsiEscapeCodesError!void,
    fileSupportsAnsiEscapeCodes: *const fn (?*anyopaque, File) Cancelable!bool,
    fileSetLength: *const fn (?*anyopaque, File, u64) File.SetLengthError!void,
    fileSetOwner: *const fn (?*anyopaque, File, ?File.Uid, ?File.Gid) File.SetOwnerError!void,
    fileSetPermissions: *const fn (?*anyopaque, File, File.Permissions) File.SetPermissionsError!void,
    fileSetTimestamps: *const fn (?*anyopaque, File, File.SetTimestampsOptions) File.SetTimestampsError!void,
    fileLock: *const fn (?*anyopaque, File, File.Lock) File.LockError!void,
    fileTryLock: *const fn (?*anyopaque, File, File.Lock) File.LockError!bool,
    fileUnlock: *const fn (?*anyopaque, File) void,
    fileDowngradeLock: *const fn (?*anyopaque, File) File.DowngradeLockError!void,
    fileRealPath: *const fn (?*anyopaque, File, out_buffer: []u8) File.RealPathError!usize,

    processExecutableOpen: *const fn (?*anyopaque, File.OpenFlags) std.process.OpenExecutableError!File,
    processExecutablePath: *const fn (?*anyopaque, buffer: []u8) std.process.ExecutablePathError!usize,
    lockStderr: *const fn (?*anyopaque, buffer: []u8, ?Terminal.Mode) Cancelable!LockedStderr,
    tryLockStderr: *const fn (?*anyopaque, buffer: []u8, ?Terminal.Mode) Cancelable!?LockedStderr,
    unlockStderr: *const fn (?*anyopaque) void,
    processSetCurrentDir: *const fn (?*anyopaque, Dir) std.process.SetCurrentDirError!void,

    now: *const fn (?*anyopaque, Clock) Clock.Error!Timestamp,
    sleep: *const fn (?*anyopaque, Timeout) SleepError!void,

    netListenIp: *const fn (?*anyopaque, address: net.IpAddress, net.IpAddress.ListenOptions) net.IpAddress.ListenError!net.Server,
    netAccept: *const fn (?*anyopaque, server: net.Socket.Handle) net.Server.AcceptError!net.Stream,
    netBindIp: *const fn (?*anyopaque, address: *const net.IpAddress, options: net.IpAddress.BindOptions) net.IpAddress.BindError!net.Socket,
    netConnectIp: *const fn (?*anyopaque, address: *const net.IpAddress, options: net.IpAddress.ConnectOptions) net.IpAddress.ConnectError!net.Stream,
    netListenUnix: *const fn (?*anyopaque, *const net.UnixAddress, net.UnixAddress.ListenOptions) net.UnixAddress.ListenError!net.Socket.Handle,
    netConnectUnix: *const fn (?*anyopaque, *const net.UnixAddress) net.UnixAddress.ConnectError!net.Socket.Handle,
    netSend: *const fn (?*anyopaque, net.Socket.Handle, []net.OutgoingMessage, net.SendFlags) struct { ?net.Socket.SendError, usize },
    netReceive: *const fn (?*anyopaque, net.Socket.Handle, message_buffer: []net.IncomingMessage, data_buffer: []u8, net.ReceiveFlags, Timeout) struct { ?net.Socket.ReceiveTimeoutError, usize },
    /// Returns 0 on end of stream.
    netRead: *const fn (?*anyopaque, src: net.Socket.Handle, data: [][]u8) net.Stream.Reader.Error!usize,
    netWrite: *const fn (?*anyopaque, dest: net.Socket.Handle, header: []const u8, data: []const []const u8, splat: usize) net.Stream.Writer.Error!usize,
    netWriteFile: *const fn (?*anyopaque, net.Socket.Handle, header: []const u8, *Io.File.Reader, Io.Limit) net.Stream.Writer.WriteFileError!usize,
    netClose: *const fn (?*anyopaque, handle: []const net.Socket.Handle) void,
    netShutdown: *const fn (?*anyopaque, handle: net.Socket.Handle, how: net.ShutdownHow) net.ShutdownError!void,
    netInterfaceNameResolve: *const fn (?*anyopaque, *const net.Interface.Name) net.Interface.Name.ResolveError!net.Interface,
    netInterfaceName: *const fn (?*anyopaque, net.Interface) net.Interface.NameError!net.Interface.Name,
    netLookup: *const fn (?*anyopaque, net.HostName, *Queue(net.HostName.LookupResult), net.HostName.LookupOptions) net.HostName.LookupError!void,
};

pub const Cancelable = error{
    /// Caller has requested the async operation to stop.
    Canceled,
};

pub const UnexpectedError = error{
    /// The Operating System returned an undocumented error code.
    ///
    /// This error is in theory not possible, but it would be better
    /// to handle this error than to invoke undefined behavior.
    ///
    /// When this error code is observed, it usually means the Zig Standard
    /// Library needs a small patch to add the error code to the error set for
    /// the respective function.
    Unexpected,
};

pub const Dir = @import("Io/Dir.zig");
pub const File = @import("Io/File.zig");
pub const Terminal = @import("Io/Terminal.zig");

pub const Clock = enum {
    /// A settable system-wide clock that measures real (i.e. wall-clock)
    /// time. This clock is affected by discontinuous jumps in the system
    /// time (e.g., if the system administrator manually changes the
    /// clock), and by frequency adjustments performed by NTP and similar
    /// applications.
    ///
    /// This clock normally counts the number of seconds since 1970-01-01
    /// 00:00:00 Coordinated Universal Time (UTC) except that it ignores
    /// leap seconds; near a leap second it is typically adjusted by NTP to
    /// stay roughly in sync with UTC.
    ///
    /// Timestamps returned by implementations of this clock represent time
    /// elapsed since 1970-01-01T00:00:00Z, the POSIX/Unix epoch, ignoring
    /// leap seconds. This is colloquially known as "Unix time". If the
    /// underlying OS uses a different epoch for native timestamps (e.g.,
    /// Windows, which uses 1601-01-01) they are translated accordingly.
    real,
    /// A nonsettable system-wide clock that represents time since some
    /// unspecified point in the past.
    ///
    /// Monotonic: Guarantees that the time returned by consecutive calls
    /// will not go backwards, but successive calls may return identical
    /// (not-increased) time values.
    ///
    /// Not affected by discontinuous jumps in the system time (e.g., if
    /// the system administrator manually changes the clock), but may be
    /// affected by frequency adjustments.
    ///
    /// This clock expresses intent to **exclude time that the system is
    /// suspended**. However, implementations may be unable to satisify
    /// this, and may include that time.
    ///
    /// * On Linux, corresponds `CLOCK_MONOTONIC`.
    /// * On macOS, corresponds to `CLOCK_UPTIME_RAW`.
    awake,
    /// Identical to `awake` except it expresses intent to **include time
    /// that the system is suspended**, however, due to limitations it may
    /// behave identically to `awake`.
    ///
    /// * On Linux, corresponds `CLOCK_BOOTTIME`.
    /// * On macOS, corresponds to `CLOCK_MONOTONIC_RAW`.
    boot,
    /// Tracks the amount of CPU in user or kernel mode used by the calling
    /// process.
    cpu_process,
    /// Tracks the amount of CPU in user or kernel mode used by the calling
    /// thread.
    cpu_thread,

    pub const Error = error{UnsupportedClock} || UnexpectedError;

    /// This function is not cancelable because first of all it does not block,
    /// but more importantly, the cancelation logic itself may want to check
    /// the time.
    pub fn now(clock: Clock, io: Io) Error!Io.Timestamp {
        return io.vtable.now(io.userdata, clock);
    }

    pub const Timestamp = struct {
        raw: Io.Timestamp,
        clock: Clock,

        /// This function is not cancelable because first of all it does not block,
        /// but more importantly, the cancelation logic itself may want to check
        /// the time.
        pub fn now(io: Io, clock: Clock) Error!Clock.Timestamp {
            return .{
                .raw = try io.vtable.now(io.userdata, clock),
                .clock = clock,
            };
        }

        pub fn wait(t: Clock.Timestamp, io: Io) SleepError!void {
            return io.vtable.sleep(io.userdata, .{ .deadline = t });
        }

        pub fn durationTo(from: Clock.Timestamp, to: Clock.Timestamp) Clock.Duration {
            assert(from.clock == to.clock);
            return .{
                .raw = from.raw.durationTo(to.raw),
                .clock = from.clock,
            };
        }

        pub fn addDuration(from: Clock.Timestamp, duration: Clock.Duration) Clock.Timestamp {
            assert(from.clock == duration.clock);
            return .{
                .raw = from.raw.addDuration(duration.raw),
                .clock = from.clock,
            };
        }

        pub fn subDuration(from: Clock.Timestamp, duration: Clock.Duration) Clock.Timestamp {
            assert(from.clock == duration.clock);
            return .{
                .raw = from.raw.subDuration(duration.raw),
                .clock = from.clock,
            };
        }

        pub fn fromNow(io: Io, duration: Clock.Duration) Error!Clock.Timestamp {
            return .{
                .clock = duration.clock,
                .raw = (try duration.clock.now(io)).addDuration(duration.raw),
            };
        }

        pub fn untilNow(timestamp: Clock.Timestamp, io: Io) Error!Clock.Duration {
            const now_ts = try Clock.Timestamp.now(io, timestamp.clock);
            return timestamp.durationTo(now_ts);
        }

        pub fn durationFromNow(timestamp: Clock.Timestamp, io: Io) Error!Clock.Duration {
            const now_ts = try timestamp.clock.now(io);
            return .{
                .clock = timestamp.clock,
                .raw = now_ts.durationTo(timestamp.raw),
            };
        }

        pub fn toClock(t: Clock.Timestamp, io: Io, clock: Clock) Error!Clock.Timestamp {
            if (t.clock == clock) return t;
            const now_old = try t.clock.now(io);
            const now_new = try clock.now(io);
            const duration = now_old.durationTo(t);
            return .{
                .clock = clock,
                .raw = now_new.addDuration(duration),
            };
        }

        pub fn compare(lhs: Clock.Timestamp, op: std.math.CompareOperator, rhs: Clock.Timestamp) bool {
            assert(lhs.clock == rhs.clock);
            return std.math.compare(lhs.raw.nanoseconds, op, rhs.raw.nanoseconds);
        }
    };

    pub const Duration = struct {
        raw: Io.Duration,
        clock: Clock,

        pub fn sleep(duration: Clock.Duration, io: Io) SleepError!void {
            return io.vtable.sleep(io.userdata, .{ .duration = duration });
        }
    };
};

pub const Timestamp = struct {
    nanoseconds: i96,

    pub const zero: Timestamp = .{ .nanoseconds = 0 };

    pub fn durationTo(from: Timestamp, to: Timestamp) Duration {
        return .{ .nanoseconds = to.nanoseconds - from.nanoseconds };
    }

    pub fn addDuration(from: Timestamp, duration: Duration) Timestamp {
        return .{ .nanoseconds = from.nanoseconds + duration.nanoseconds };
    }

    pub fn subDuration(from: Timestamp, duration: Duration) Timestamp {
        return .{ .nanoseconds = from.nanoseconds - duration.nanoseconds };
    }

    pub fn withClock(t: Timestamp, clock: Clock) Clock.Timestamp {
        return .{ .raw = t, .clock = clock };
    }

    pub fn fromNanoseconds(x: i96) Timestamp {
        return .{ .nanoseconds = x };
    }

    pub fn toMilliseconds(t: Timestamp) i64 {
        return @intCast(@divTrunc(t.nanoseconds, std.time.ns_per_ms));
    }

    pub fn toSeconds(t: Timestamp) i64 {
        return @intCast(@divTrunc(t.nanoseconds, std.time.ns_per_s));
    }

    pub fn toNanoseconds(t: Timestamp) i96 {
        return t.nanoseconds;
    }

    pub fn formatNumber(t: Timestamp, w: *std.Io.Writer, n: std.fmt.Number) std.Io.Writer.Error!void {
        return w.printInt(t.nanoseconds, n.mode.base() orelse 10, n.case, .{
            .precision = n.precision,
            .width = n.width,
            .alignment = n.alignment,
            .fill = n.fill,
        });
    }
};

pub const Duration = struct {
    nanoseconds: i96,

    pub const zero: Duration = .{ .nanoseconds = 0 };
    pub const max: Duration = .{ .nanoseconds = std.math.maxInt(i96) };

    pub fn fromNanoseconds(x: i96) Duration {
        return .{ .nanoseconds = x };
    }

    pub fn fromMilliseconds(x: i64) Duration {
        return .{ .nanoseconds = @as(i96, x) * std.time.ns_per_ms };
    }

    pub fn fromSeconds(x: i64) Duration {
        return .{ .nanoseconds = @as(i96, x) * std.time.ns_per_s };
    }

    pub fn toMilliseconds(d: Duration) i64 {
        return @intCast(@divTrunc(d.nanoseconds, std.time.ns_per_ms));
    }

    pub fn toSeconds(d: Duration) i64 {
        return @intCast(@divTrunc(d.nanoseconds, std.time.ns_per_s));
    }

    pub fn toNanoseconds(d: Duration) i96 {
        return d.nanoseconds;
    }
};

/// Declares under what conditions an operation should return `error.Timeout`.
pub const Timeout = union(enum) {
    none,
    duration: Clock.Duration,
    deadline: Clock.Timestamp,

    pub const Error = error{ Timeout, UnsupportedClock };

    pub fn toDeadline(t: Timeout, io: Io) Clock.Error!?Clock.Timestamp {
        return switch (t) {
            .none => null,
            .duration => |d| try .fromNow(io, d),
            .deadline => |d| d,
        };
    }

    pub fn toDurationFromNow(t: Timeout, io: Io) Clock.Error!?Clock.Duration {
        return switch (t) {
            .none => null,
            .duration => |d| d,
            .deadline => |d| try d.durationFromNow(io),
        };
    }

    pub fn sleep(timeout: Timeout, io: Io) SleepError!void {
        return io.vtable.sleep(io.userdata, timeout);
    }
};

pub const AnyFuture = opaque {};

pub fn Future(Result: type) type {
    return struct {
        any_future: ?*AnyFuture,
        result: Result,

        /// Equivalent to `await` but places a cancellation request. This causes the task to receive
        /// `error.Canceled` from its next "cancelation point" (if any). A cancelation point is a
        /// call to a function in `Io` which can return `error.Canceled`.
        ///
        /// After cancelation of a task is requested, only the next cancelation point in that task
        /// will return `error.Canceled`: future points will not re-signal the cancelation. As such,
        /// it is usually a bug to ignore `error.Canceled`. However, to defer handling cancelation
        /// requests, see also `recancel` and `CancelProtection`.
        ///
        /// Idempotent. Not threadsafe.
        pub fn cancel(f: *@This(), io: Io) Result {
            const any_future = f.any_future orelse return f.result;
            io.vtable.cancel(io.userdata, any_future, @ptrCast(&f.result), .of(Result));
            f.any_future = null;
            return f.result;
        }

        /// Idempotent. Not threadsafe.
        pub fn await(f: *@This(), io: Io) Result {
            const any_future = f.any_future orelse return f.result;
            io.vtable.await(io.userdata, any_future, @ptrCast(&f.result), .of(Result));
            f.any_future = null;
            return f.result;
        }
    };
}

pub const Group = struct {
    state: usize,
    context: ?*anyopaque,
    /// This value indicates whether or not a group has pending tasks. `null`
    /// means there are no pending tasks, and no resources associated with the
    /// group, so `await` and `cancel` return immediately without calling the
    /// implementation. This means that `token` must be accessed atomically to
    /// avoid racing with the check in `await` and `cancel`.
    token: std.atomic.Value(?*anyopaque),

    pub const init: Group = .{ .state = 0, .context = null, .token = .init(null) };

    /// Calls `function` with `args` asynchronously. The resource spawned is
    /// owned by the group.
    ///
    /// `function` *may* be called immediately, before `async` returns.
    ///
    /// When this function returns, it is guaranteed that `function` has
    /// already been called and completed, or it has successfully been assigned
    /// a unit of concurrency.
    ///
    /// After this is called, `wait` or `cancel` must be called before the
    /// group is deinitialized.
    ///
    /// Threadsafe.
    ///
    /// See also:
    /// * `concurrent`
    /// * `Io.async`
    pub fn async(g: *Group, io: Io, function: anytype, args: std.meta.ArgsTuple(@TypeOf(function))) void {
        const Args = @TypeOf(args);
        const TypeErased = struct {
            fn start(group: *Group, context: *const anyopaque) void {
                _ = group;
                const args_casted: *const Args = @ptrCast(@alignCast(context));
                @call(.auto, function, args_casted.*);
            }
        };
        io.vtable.groupAsync(io.userdata, g, @ptrCast(&args), .of(Args), TypeErased.start);
    }

    /// Calls `function` with `args`, such that the function is not guaranteed
    /// to have returned until `wait` is called, allowing the caller to
    /// progress while waiting for any `Io` operations.
    ///
    /// The resource spawned is owned by the group; after this is called,
    /// `wait` or `cancel` must be called before the group is deinitialized.
    ///
    /// This has stronger guarantee than `async`, placing restrictions on what kind
    /// of `Io` implementations are supported. By calling `async` instead, one
    /// allows, for example, stackful single-threaded blocking I/O.
    ///
    /// Threadsafe.
    ///
    /// See also:
    /// * `async`
    /// * `Io.concurrent`
    pub fn concurrent(g: *Group, io: Io, function: anytype, args: std.meta.ArgsTuple(@TypeOf(function))) ConcurrentError!void {
        const Args = @TypeOf(args);
        const TypeErased = struct {
            fn start(group: *Group, context: *const anyopaque) void {
                _ = group;
                const args_casted: *const Args = @ptrCast(@alignCast(context));
                @call(.auto, function, args_casted.*);
            }
        };
        return io.vtable.groupConcurrent(io.userdata, g, @ptrCast(&args), .of(Args), TypeErased.start);
    }

    /// Blocks until all tasks of the group finish. During this time,
    /// cancellation requests propagate to all members of the group.
    ///
    /// Idempotent. Not threadsafe.
    ///
    /// It is safe to call this function concurrently with `Group.async` or
    /// `Group.concurrent`, provided that the group does not complete until
    /// the call to `Group.async` or `Group.concurrent` returns.
    pub fn wait(g: *Group, io: Io) void {
        const token = g.token.load(.acquire) orelse return;
        io.vtable.groupWait(io.userdata, g, token);
        assert(g.token.raw == null);
    }

    /// Equivalent to `wait` but immediately requests cancellation on all
    /// members of the group.
    ///
    /// For a description of cancelation and cancelation points, see `Future.cancel`.
    ///
    /// Idempotent. Not threadsafe.
    ///
    /// It is safe to call this function concurrently with `Group.async` or
    /// `Group.concurrent`, provided that the group does not complete until
    /// the call to `Group.async` or `Group.concurrent` returns.
    pub fn cancel(g: *Group, io: Io) void {
        const token = g.token.load(.acquire) orelse return;
        io.vtable.groupCancel(io.userdata, g, token);
        assert(g.token.raw == null);
    }
};

/// Asserts that `error.Canceled` was returned from a prior cancelation point, and "re-arms" the
/// cancelation request, so that `error.Canceled` will be returned again from the next cancelation
/// point.
///
/// For a description of cancelation and cancelation points, see `Future.cancel`.
pub fn recancel(io: Io) void {
    io.vtable.recancel(io.userdata);
}

/// In rare cases, it is desirable to completely block cancelation notification, so that a region
/// of code can run uninterrupted before `error.Canceled` is potentially observed. Therefore, every
/// task has a "cancel protection" state which indicates whether or not `Io` functions can introduce
/// cancelation points.
///
/// To modify a task's cancel protection state, see `swapCancelProtection`.
///
/// For a description of cancelation and cancelation points, see `Future.cancel`.
pub const CancelProtection = enum {
    /// Any call to an `Io` function with `error.Canceled` in its error set is a cancelation point.
    ///
    /// This is the default state, which all tasks are created in.
    unblocked,
    /// No `Io` function introduces a cancelation point (`error.Canceled` will never be returned).
    blocked,
};
/// Updates the current task's cancel protection state (see `CancelProtection`).
///
/// The typical usage for this function is to protect a block of code from cancelation:
/// ```
/// const old_cancel_protect = io.swapCancelProtection(.blocked);
/// defer _ = io.swapCancelProtection(old_cancel_protect);
/// doSomeWork() catch |err| switch (err) {
///     error.Canceled => unreachable,
/// };
/// ```
///
/// For a description of cancelation and cancelation points, see `Future.cancel`.
pub fn swapCancelProtection(io: Io, new: CancelProtection) CancelProtection {
    return io.vtable.swapCancelProtection(io.userdata, new);
}

/// This function acts as a pure cancelation point (subject to protection; see `CancelProtection`)
/// and does nothing else. In other words, it returns `error.Canceled` if there is an outstanding
/// non-blocked cancelation request, but otherwise is a no-op.
///
/// It is rarely necessary to call this function. The primary use case is in long-running CPU-bound
/// tasks which may need to respond to cancelation before completing. Short tasks, or those which
/// perform other `Io` operations (and hence have other cancelation points), will typically already
/// respond quickly to cancelation requests.
///
/// For a description of cancelation and cancelation points, see `Future.cancel`.
pub fn checkCancel(io: Io) Cancelable!void {
    return io.vtable.checkCancel(io.userdata);
}

pub fn Select(comptime U: type) type {
    return struct {
        io: Io,
        group: Group,
        queue: Queue(U),
        outstanding: usize,

        const S = @This();

        pub const Union = U;

        pub const Field = std.meta.FieldEnum(U);

        pub fn init(io: Io, buffer: []U) S {
            return .{
                .io = io,
                .queue = .init(buffer),
                .group = .init,
                .outstanding = 0,
            };
        }

        /// Calls `function` with `args` asynchronously. The resource spawned is
        /// owned by the select.
        ///
        /// `function` must have return type matching the `field` field of `Union`.
        ///
        /// `function` *may* be called immediately, before `async` returns.
        ///
        /// When this function returns, it is guaranteed that `function` has
        /// already been called and completed, or it has successfully been
        /// assigned a unit of concurrency.
        ///
        /// After this is called, `wait` or `cancel` must be called before the
        /// select is deinitialized.
        ///
        /// Threadsafe.
        ///
        /// Related:
        /// * `Io.async`
        /// * `Group.async`
        pub fn async(
            s: *S,
            comptime field: Field,
            function: anytype,
            args: std.meta.ArgsTuple(@TypeOf(function)),
        ) void {
            const Args = @TypeOf(args);
            const TypeErased = struct {
                fn start(group: *Group, context: *const anyopaque) void {
                    const args_casted: *const Args = @ptrCast(@alignCast(context));
                    const unerased_select: *S = @fieldParentPtr("group", group);
                    const elem = @unionInit(U, @tagName(field), @call(.auto, function, args_casted.*));
                    unerased_select.queue.putOneUncancelable(unerased_select.io, elem) catch |err| switch (err) {
                        error.Closed => unreachable,
                    };
                }
            };
            _ = @atomicRmw(usize, &s.outstanding, .Add, 1, .monotonic);
            s.io.vtable.groupAsync(s.io.userdata, &s.group, @ptrCast(&args), .of(Args), TypeErased.start);
        }

        /// Blocks until another task of the select finishes.
        ///
        /// Asserts there is at least one more `outstanding` task.
        ///
        /// Not threadsafe.
        pub fn wait(s: *S) Cancelable!U {
            s.outstanding -= 1;
            return s.queue.getOne(s.io) catch |err| switch (err) {
                error.Canceled => |e| return e,
                error.Closed => unreachable,
            };
        }

        /// Equivalent to `wait` but requests cancellation on all remaining
        /// tasks owned by the select.
        ///
        /// For a description of cancelation and cancelation points, see `Future.cancel`.
        ///
        /// It is illegal to call `wait` after this.
        ///
        /// Idempotent. Not threadsafe.
        pub fn cancel(s: *S) void {
            s.outstanding = 0;
            s.group.cancel(s.io);
        }
    };
}

/// Atomically checks if the value at `ptr` equals `expected`, and if so, blocks until either:
///
/// * a matching (same `ptr` argument) `futexWake` call occurs, or
/// * a spurious ("random") wakeup occurs.
///
/// Typically, `futexWake` should be called immediately after updating the value at `ptr.*`, to
/// unblock tasks using `futexWait` to wait for the value to change from what it previously was.
///
/// The caller is responsible for identifying spurious wakeups if necessary, typically by checking
/// the value at `ptr.*`.
///
/// Asserts that `T` is 4 bytes in length and has a well-defined layout with no padding bits.
pub fn futexWait(io: Io, comptime T: type, ptr: *align(@alignOf(u32)) const T, expected: T) Cancelable!void {
    return futexWaitTimeout(io, T, ptr, expected, .none);
}
/// Same as `futexWait`, except also unblocks if `timeout` expires. As with `futexWait`, spurious
/// wakeups are possible. It remains the caller's responsibility to differentiate between these
/// three possible wake-up reasons if necessary.
pub fn futexWaitTimeout(io: Io, comptime T: type, ptr: *align(@alignOf(u32)) const T, expected: T, timeout: Timeout) Cancelable!void {
    const expected_int: u32 = switch (@typeInfo(T)) {
        .@"enum" => @bitCast(@intFromEnum(expected)),
        else => @bitCast(expected),
    };
    return io.vtable.futexWait(io.userdata, @ptrCast(ptr), expected_int, timeout);
}
/// Same as `futexWait`, except does not introduce a cancelation point.
///
/// For a description of cancelation and cancelation points, see `Future.cancel`.
pub fn futexWaitUncancelable(io: Io, comptime T: type, ptr: *align(@alignOf(u32)) const T, expected: T) void {
    const expected_int: u32 = switch (@typeInfo(T)) {
        .@"enum" => @bitCast(@intFromEnum(expected)),
        else => @bitCast(expected),
    };
    io.vtable.futexWaitUncancelable(io.userdata, @ptrCast(ptr), expected_int);
}
/// Unblocks pending futex waits on `ptr`, up to a limit of `max_waiters` calls.
pub fn futexWake(io: Io, comptime T: type, ptr: *align(@alignOf(u32)) const T, max_waiters: u32) void {
    comptime assert(@sizeOf(T) == @sizeOf(u32));
    if (max_waiters == 0) return;
    return io.vtable.futexWake(io.userdata, @ptrCast(ptr), max_waiters);
}

pub const Mutex = struct {
    state: std.atomic.Value(State),

    pub const init: Mutex = .{ .state = .init(.unlocked) };

    const State = enum(u32) {
        unlocked,
        locked_once,
        contended,
    };

    pub fn tryLock(m: *Mutex) bool {
        switch (m.state.cmpxchgWeak(
            .unlocked,
            .locked_once,
            .acquire,
            .monotonic,
        ) orelse return true) {
            .unlocked => unreachable,
            .locked_once, .contended => return false,
        }
    }

    pub fn lock(m: *Mutex, io: Io) Cancelable!void {
        const initial_state = m.state.cmpxchgWeak(
            .unlocked,
            .locked_once,
            .acquire,
            .monotonic,
        ) orelse {
            @branchHint(.likely);
            return;
        };
        if (initial_state == .contended) {
            try io.futexWait(State, &m.state.raw, .contended);
        }
        while (m.state.swap(.contended, .acquire) != .unlocked) {
            try io.futexWait(State, &m.state.raw, .contended);
        }
    }

    /// Same as `lock`, except does not introduce a cancelation point.
    ///
    /// For a description of cancelation and cancelation points, see `Future.cancel`.
    pub fn lockUncancelable(m: *Mutex, io: Io) void {
        const initial_state = m.state.cmpxchgWeak(
            .unlocked,
            .locked_once,
            .acquire,
            .monotonic,
        ) orelse {
            @branchHint(.likely);
            return;
        };
        if (initial_state == .contended) {
            io.futexWaitUncancelable(State, &m.state.raw, .contended);
        }
        while (m.state.swap(.contended, .acquire) != .unlocked) {
            io.futexWaitUncancelable(State, &m.state.raw, .contended);
        }
    }

    pub fn unlock(m: *Mutex, io: Io) void {
        switch (m.state.swap(.unlocked, .release)) {
            .unlocked => unreachable,
            .locked_once => {},
            .contended => {
                @branchHint(.unlikely);
                io.futexWake(State, &m.state.raw, 1);
            },
        }
    }
};

pub const Condition = struct {
    state: std.atomic.Value(State),
    /// Incremented whenever the condition is signaled
    epoch: std.atomic.Value(u32),

    const State = packed struct(u32) {
        waiters: u16,
        signals: u16,
    };

    pub const init: Condition = .{
        .state = .init(.{ .waiters = 0, .signals = 0 }),
        .epoch = .init(0),
    };

    pub fn wait(cond: *Condition, io: Io, mutex: *Mutex) Cancelable!void {
        try waitInner(cond, io, mutex, false);
    }

    /// Same as `wait`, except does not introduce a cancelation point.
    ///
    /// For a description of cancelation and cancelation points, see `Future.cancel`.
    pub fn waitUncancelable(cond: *Condition, io: Io, mutex: *Mutex) void {
        waitInner(cond, io, mutex, true) catch |err| switch (err) {
            error.Canceled => unreachable,
        };
    }

    fn waitInner(cond: *Condition, io: Io, mutex: *Mutex, uncancelable: bool) Cancelable!void {
        var epoch = cond.epoch.load(.acquire); // `.acquire` to ensure ordered before state load

        {
            const prev_state = cond.state.fetchAdd(.{ .waiters = 1, .signals = 0 }, .monotonic);
            assert(prev_state.waiters < math.maxInt(u16)); // overflow caused by too many waiters
        }

        mutex.unlock(io);
        defer mutex.lockUncancelable(io);

        while (true) {
            const result = if (uncancelable)
                io.futexWaitUncancelable(u32, &cond.epoch.raw, epoch)
            else
                io.futexWait(u32, &cond.epoch.raw, epoch);

            epoch = cond.epoch.load(.acquire); // `.acquire` to ensure ordered before `state` laod

            // Even on error, try to consume a pending signal first. Otherwise a race might
            // cause a signal to get stuck in the state with no corresponding waiter.
            {
                var prev_state = cond.state.load(.monotonic);
                while (prev_state.signals > 0) {
                    prev_state = cond.state.cmpxchgWeak(prev_state, .{
                        .waiters = prev_state.waiters - 1,
                        .signals = prev_state.signals - 1,
                    }, .acquire, .monotonic) orelse {
                        // We successfully consumed a signal.
                        return;
                    };
                }
            }

            // There are no more signals available; this was a spurious wakeup or an error. If it
            // was an error, we will remove ourselves as a waiter and return that error. Otherwise,
            // we'll loop back to the futex wait.
            result catch |err| {
                const prev_state = cond.state.fetchSub(.{ .waiters = 1, .signals = 0 }, .monotonic);
                assert(prev_state.waiters > 0); // underflow caused by illegal state
                return err;
            };
        }
    }

    pub fn signal(cond: *Condition, io: Io) void {
        var prev_state = cond.state.load(.monotonic);
        while (prev_state.waiters > prev_state.signals) {
            @branchHint(.unlikely);
            prev_state = cond.state.cmpxchgWeak(prev_state, .{
                .waiters = prev_state.waiters,
                .signals = prev_state.signals + 1,
            }, .release, .monotonic) orelse {
                // Update the epoch to tell the waiting threads that there are new signals for them.
                // Note that a waiting thread could miss a take if *exactly* (1<<32)-1 wakes happen
                // between it observing the epoch and sleeping on it, but this is extraordinarily
                // unlikely due to the precise number of calls required.
                _ = cond.epoch.fetchAdd(1, .release); // `.release` to ensure ordered after `state` update
                io.futexWake(u32, &cond.epoch.raw, 1);
                return;
            };
        }
    }

    pub fn broadcast(cond: *Condition, io: Io) void {
        var prev_state = cond.state.load(.monotonic);
        while (prev_state.waiters > prev_state.signals) {
            @branchHint(.unlikely);
            prev_state = cond.state.cmpxchgWeak(prev_state, .{
                .waiters = prev_state.waiters,
                .signals = prev_state.waiters,
            }, .release, .monotonic) orelse {
                // Update the epoch to tell the waiting threads that there are new signals for them.
                // Note that a waiting thread could miss a take if *exactly* (1<<32)-1 wakes happen
                // between it observing the epoch and sleeping on it, but this is extraordinarily
                // unlikely due to the precise number of calls required.
                _ = cond.epoch.fetchAdd(1, .release); // `.release` to ensure ordered after `state` update
                io.futexWake(u32, &cond.epoch.raw, prev_state.waiters - prev_state.signals);
                return;
            };
        }
    }
};

/// Logical boolean flag which can be set and unset and supports a "wait until set" operation.
pub const Event = enum(u32) {
    unset,
    waiting,
    is_set,

    /// Returns whether the logical boolean is `true`.
    pub fn isSet(event: *const Event) bool {
        return switch (@atomicLoad(Event, event, .acquire)) {
            .unset, .waiting => false,
            .is_set => true,
        };
    }

    /// Blocks until the logical boolean is `true`.
    pub fn wait(event: *Event, io: Io) Io.Cancelable!void {
        if (@cmpxchgStrong(Event, event, .unset, .waiting, .acquire, .acquire)) |prev| switch (prev) {
            .unset => unreachable,
            .waiting => {},
            .is_set => return,
        };
        errdefer {
            // Ideally we would restore the event back to `.unset` instead of `.waiting`, but there
            // might be other threads waiting on the event. In theory we could track the *number* of
            // waiting threads in the unused bits of the `Event`, but that has its own problem: the
            // waiters would wake up when a *new waiter* was added. So it's easiest to just leave
            // the state at `.waiting`---at worst it causes one redundant call to `futexWake`.
        }
        while (true) {
            try io.futexWait(Event, event, .waiting);
            switch (@atomicLoad(Event, event, .acquire)) {
                .unset => unreachable, // `reset` called before pending `wait` returned
                .waiting => continue,
                .is_set => return,
            }
        }
    }

    /// Same as `wait`, except does not introduce a cancelation point.
    ///
    /// For a description of cancelation and cancelation points, see `Future.cancel`.
    pub fn waitUncancelable(event: *Event, io: Io) void {
        if (@cmpxchgStrong(Event, event, .unset, .waiting, .acquire, .acquire)) |prev| switch (prev) {
            .unset => unreachable,
            .waiting => {},
            .is_set => return,
        };
        while (true) {
            io.futexWaitUncancelable(Event, event, .waiting);
            switch (@atomicLoad(Event, event, .acquire)) {
                .unset => unreachable, // `reset` called before pending `wait` returned
                .waiting => continue,
                .is_set => return,
            }
        }
    }

    pub const WaitTimeoutError = error{Timeout} || Cancelable;

    /// Blocks the calling thread until either the logical boolean is set, the timeout expires, or a
    /// spurious wakeup occurs. If the timeout expires or a spurious wakeup occurs, `error.Timeout`
    /// is returned.
    pub fn waitTimeout(event: *Event, io: Io, timeout: Timeout) WaitTimeoutError!void {
        if (@cmpxchgStrong(Event, event, .unset, .waiting, .acquire, .acquire)) |prev| switch (prev) {
            .unset => unreachable,
            .waiting => assert(!builtin.single_threaded), // invalid state
            .is_set => return,
        };
        errdefer {
            // Ideally we would restore the event back to `.unset` instead of `.waiting`, but there
            // might be other threads waiting on the event. In theory we could track the *number* of
            // waiting threads in the unused bits of the `Event`, but that has its own problem: the
            // waiters would wake up when a *new waiter* was added. So it's easiest to just leave
            // the state at `.waiting`---at worst it causes one redundant call to `futexWake`.
        }
        try io.futexWaitTimeout(Event, event, .waiting, timeout);
        switch (@atomicLoad(Event, event, .acquire)) {
            .unset => unreachable, // `reset` called before pending `wait` returned
            .waiting => return error.Timeout,
            .is_set => return,
        }
    }

    /// Sets the logical boolean to true, and hence unblocks any pending calls to `wait`. The
    /// logical boolean remains true until `reset` is called, so future calls to `set` have no
    /// semantic effect.
    ///
    /// Any memory accesses prior to a `set` call are "released", so that if this `set` call causes
    /// `isSet` to return `true` or a wait to finish, those tasks will be able to observe those
    /// memory accesses.
    pub fn set(e: *Event, io: Io) void {
        switch (@atomicRmw(Event, e, .Xchg, .is_set, .release)) {
            .unset, .is_set => {},
            .waiting => io.futexWake(Event, e, std.math.maxInt(u32)),
        }
    }

    /// Sets the logical boolean to false.
    ///
    /// Assumes that there is no pending call to `wait` or `waitUncancelable`.
    ///
    /// However, concurrent calls to `isSet`, `set`, and `reset` are allowed.
    pub fn reset(e: *Event) void {
        @atomicStore(Event, e, .unset, .monotonic);
    }
};

pub const QueueClosedError = error{Closed};

pub const TypeErasedQueue = struct {
    mutex: Mutex,
    closed: bool,

    /// Ring buffer. This data is logically *after* queued getters.
    buffer: []u8,
    start: usize,
    len: usize,

    putters: std.DoublyLinkedList,
    getters: std.DoublyLinkedList,

    const Put = struct {
        remaining: []const u8,
        needed: usize,
        condition: Condition,
        node: std.DoublyLinkedList.Node,
    };

    const Get = struct {
        remaining: []u8,
        needed: usize,
        condition: Condition,
        node: std.DoublyLinkedList.Node,
    };

    pub fn init(buffer: []u8) TypeErasedQueue {
        return .{
            .mutex = .init,
            .closed = false,
            .buffer = buffer,
            .start = 0,
            .len = 0,
            .putters = .{},
            .getters = .{},
        };
    }

    pub fn close(q: *TypeErasedQueue, io: Io) void {
        q.mutex.lockUncancelable(io);
        defer q.mutex.unlock(io);
        q.closed = true;
        {
            var it = q.getters.first;
            while (it) |node| : (it = node.next) {
                const getter: *Get = @alignCast(@fieldParentPtr("node", node));
                getter.condition.signal(io);
            }
        }
        {
            var it = q.putters.first;
            while (it) |node| : (it = node.next) {
                const putter: *Put = @alignCast(@fieldParentPtr("node", node));
                putter.condition.signal(io);
            }
        }
    }

    pub fn put(q: *TypeErasedQueue, io: Io, elements: []const u8, min: usize) (QueueClosedError || Cancelable)!usize {
        assert(elements.len >= min);
        if (elements.len == 0) return 0;
        try q.mutex.lock(io);
        defer q.mutex.unlock(io);
        return q.putLocked(io, elements, min, false);
    }

    /// Same as `put`, except does not introduce a cancelation point.
    ///
    /// For a description of cancelation and cancelation points, see `Future.cancel`.
    pub fn putUncancelable(q: *TypeErasedQueue, io: Io, elements: []const u8, min: usize) QueueClosedError!usize {
        assert(elements.len >= min);
        if (elements.len == 0) return 0;
        q.mutex.lockUncancelable(io);
        defer q.mutex.unlock(io);
        return q.putLocked(io, elements, min, true) catch |err| switch (err) {
            error.Canceled => unreachable,
            error.Closed => |e| return e,
        };
    }

    fn puttableSlice(q: *const TypeErasedQueue) ?[]u8 {
        const unwrapped_index = q.start + q.len;
        const wrapped_index, const overflow = @subWithOverflow(unwrapped_index, q.buffer.len);
        const slice = switch (overflow) {
            1 => q.buffer[unwrapped_index..],
            0 => q.buffer[wrapped_index..q.start],
        };
        return if (slice.len > 0) slice else null;
    }

    fn putLocked(q: *TypeErasedQueue, io: Io, elements: []const u8, target: usize, uncancelable: bool) (QueueClosedError || Cancelable)!usize {
        // A closed queue cannot be added to, even if there is space in the buffer.
        if (q.closed) return error.Closed;

        // Getters have first priority on the data, and only when the getters
        // queue is empty do we start populating the buffer.

        // The number of elements we add immediately, before possibly blocking.
        var n: usize = 0;

        while (q.getters.popFirst()) |getter_node| {
            const getter: *Get = @alignCast(@fieldParentPtr("node", getter_node));
            const copy_len = @min(getter.remaining.len, elements.len - n);
            assert(copy_len > 0);
            @memcpy(getter.remaining[0..copy_len], elements[n..][0..copy_len]);
            getter.remaining = getter.remaining[copy_len..];
            getter.needed -|= copy_len;
            n += copy_len;
            if (getter.needed == 0) {
                getter.condition.signal(io);
            } else {
                assert(n == elements.len); // we didn't have enough elements for the getter
                q.getters.prepend(getter_node);
            }
            if (n == elements.len) return elements.len;
        }

        while (q.puttableSlice()) |slice| {
            const copy_len = @min(slice.len, elements.len - n);
            assert(copy_len > 0);
            @memcpy(slice[0..copy_len], elements[n..][0..copy_len]);
            q.len += copy_len;
            n += copy_len;
            if (n == elements.len) return elements.len;
        }

        // Don't block if we hit the target.
        if (n >= target) return n;

        var pending: Put = .{
            .remaining = elements[n..],
            .needed = target - n,
            .condition = .init,
            .node = .{},
        };
        q.putters.append(&pending.node);
        defer if (pending.needed > 0) q.putters.remove(&pending.node);

        while (pending.needed > 0 and !q.closed) {
            if (uncancelable) {
                pending.condition.waitUncancelable(io, &q.mutex);
                continue;
            }
            pending.condition.wait(io, &q.mutex) catch |err| switch (err) {
                error.Canceled => if (pending.remaining.len == elements.len) {
                    // Canceled while waiting, and appended no elements.
                    return error.Canceled;
                } else {
                    // Canceled while waiting, but appended some elements, so report those first.
                    io.recancel();
                    return elements.len - pending.remaining.len;
                },
            };
        }
        if (pending.remaining.len == elements.len) {
            // The queue was closed while we were waiting. We appended no elements.
            assert(q.closed);
            return error.Closed;
        }
        return elements.len - pending.remaining.len;
    }

    pub fn get(q: *TypeErasedQueue, io: Io, buffer: []u8, min: usize) (QueueClosedError || Cancelable)!usize {
        assert(buffer.len >= min);
        if (buffer.len == 0) return 0;
        try q.mutex.lock(io);
        defer q.mutex.unlock(io);
        return q.getLocked(io, buffer, min, false);
    }

    /// Same as `get`, except does not introduce a cancelation point.
    ///
    /// For a description of cancelation and cancelation points, see `Future.cancel`.
    pub fn getUncancelable(q: *TypeErasedQueue, io: Io, buffer: []u8, min: usize) QueueClosedError!usize {
        assert(buffer.len >= min);
        if (buffer.len == 0) return 0;
        q.mutex.lockUncancelable(io);
        defer q.mutex.unlock(io);
        return q.getLocked(io, buffer, min, true) catch |err| switch (err) {
            error.Canceled => unreachable,
            error.Closed => |e| return e,
        };
    }

    fn gettableSlice(q: *const TypeErasedQueue) ?[]const u8 {
        const overlong_slice = q.buffer[q.start..];
        const slice = overlong_slice[0..@min(overlong_slice.len, q.len)];
        return if (slice.len > 0) slice else null;
    }

    fn getLocked(q: *TypeErasedQueue, io: Io, buffer: []u8, target: usize, uncancelable: bool) (QueueClosedError || Cancelable)!usize {
        // The ring buffer gets first priority, then data should come from any
        // queued putters, then finally the ring buffer should be filled with
        // data from putters so they can be resumed.

        // The number of elements we received immediately, before possibly blocking.
        var n: usize = 0;

        while (q.gettableSlice()) |slice| {
            const copy_len = @min(slice.len, buffer.len - n);
            assert(copy_len > 0);
            @memcpy(buffer[n..][0..copy_len], slice[0..copy_len]);
            q.start += copy_len;
            if (q.buffer.len - q.start == 0) q.start = 0;
            q.len -= copy_len;
            n += copy_len;
            if (n == buffer.len) {
                q.fillRingBufferFromPutters(io);
                return buffer.len;
            }
        }

        // Copy directly from putters into buffer.
        while (q.putters.popFirst()) |putter_node| {
            const putter: *Put = @alignCast(@fieldParentPtr("node", putter_node));
            const copy_len = @min(putter.remaining.len, buffer.len - n);
            assert(copy_len > 0);
            @memcpy(buffer[n..][0..copy_len], putter.remaining[0..copy_len]);
            putter.remaining = putter.remaining[copy_len..];
            putter.needed -|= copy_len;
            n += copy_len;
            if (putter.needed == 0) {
                putter.condition.signal(io);
            } else {
                assert(n == buffer.len); // we didn't have enough space for the putter
                q.putters.prepend(putter_node);
            }
            if (n == buffer.len) {
                q.fillRingBufferFromPutters(io);
                return buffer.len;
            }
        }

        // No need to call `fillRingBufferFromPutters` from this point onwards,
        // because we emptied the ring buffer *and* the putter queue!

        // Don't block if we hit the target or if the queue is closed. Return how
        // many elements we could get immediately, unless the queue was closed and
        // empty, in which case report `error.Closed`.
        if (n == 0 and q.closed) return error.Closed;
        if (n >= target or q.closed) return n;

        var pending: Get = .{
            .remaining = buffer[n..],
            .needed = target - n,
            .condition = .init,
            .node = .{},
        };
        q.getters.append(&pending.node);
        defer if (pending.needed > 0) q.getters.remove(&pending.node);

        while (pending.needed > 0 and !q.closed) {
            if (uncancelable) {
                pending.condition.waitUncancelable(io, &q.mutex);
                continue;
            }
            pending.condition.wait(io, &q.mutex) catch |err| switch (err) {
                error.Canceled => if (pending.remaining.len == buffer.len) {
                    // Canceled while waiting, and received no elements.
                    return error.Canceled;
                } else {
                    // Canceled while waiting, but received some elements, so report those first.
                    io.recancel();
                    return buffer.len - pending.remaining.len;
                },
            };
        }
        if (pending.remaining.len == buffer.len) {
            // The queue was closed while we were waiting. We received no elements.
            assert(q.closed);
            return error.Closed;
        }
        return buffer.len - pending.remaining.len;
    }

    /// Called when there is nonzero space available in the ring buffer and
    /// potentially putters waiting. The mutex is already held and the task is
    /// to copy putter data to the ring buffer and signal any putters whose
    /// buffers been fully copied.
    fn fillRingBufferFromPutters(q: *TypeErasedQueue, io: Io) void {
        while (q.putters.popFirst()) |putter_node| {
            const putter: *Put = @alignCast(@fieldParentPtr("node", putter_node));
            while (q.puttableSlice()) |slice| {
                const copy_len = @min(slice.len, putter.remaining.len);
                assert(copy_len > 0);
                @memcpy(slice[0..copy_len], putter.remaining[0..copy_len]);
                q.len += copy_len;
                putter.remaining = putter.remaining[copy_len..];
                putter.needed -|= copy_len;
                if (putter.needed == 0) {
                    putter.condition.signal(io);
                    break;
                }
            } else {
                q.putters.prepend(putter_node);
                break;
            }
        }
    }
};

/// Many producer, many consumer, thread-safe, runtime configurable buffer size.
/// When buffer is empty, consumers suspend and are resumed by producers.
/// When buffer is full, producers suspend and are resumed by consumers.
pub fn Queue(Elem: type) type {
    return struct {
        type_erased: TypeErasedQueue,

        pub fn init(buffer: []Elem) @This() {
            return .{ .type_erased = .init(@ptrCast(buffer)) };
        }

        pub fn close(q: *@This(), io: Io) void {
            q.type_erased.close(io);
        }

        /// Appends elements to the end of the queue, potentially blocking if
        /// there is insufficient capacity. Returns when any one of the
        /// following conditions is satisfied:
        ///
        /// * At least `target` elements have been added to the queue
        /// * The queue is closed
        /// * The current task is canceled
        ///
        /// Returns how many of `elements` have been added to the queue, if any.
        /// If an error is returned, no elements have been added.
        ///
        /// If the queue is closed or the task is canceled, but some items were
        /// already added before the closure or cancelation, then `put` may
        /// return a number lower than `target`, in which case future calls are
        /// guaranteed to return `error.Canceled` or `error.Closed`.
        ///
        /// A return value of 0 is only possible if `target` is 0, in which case
        /// the call is guaranteed to queue as many of `elements` as is possible
        /// *without* blocking.
        ///
        /// Asserts that `elements.len >= target`.
        pub fn put(q: *@This(), io: Io, elements: []const Elem, target: usize) (QueueClosedError || Cancelable)!usize {
            return @divExact(try q.type_erased.put(io, @ptrCast(elements), target * @sizeOf(Elem)), @sizeOf(Elem));
        }

        /// Same as `put` but blocks until all elements have been added to the queue.
        ///
        /// If the queue is closed or canceled, `error.Closed` or `error.Canceled`
        /// is returned, and it is unspecified how many, if any, of `elements` were
        /// added to the queue prior to cancelation or closure.
        pub fn putAll(q: *@This(), io: Io, elements: []const Elem) (QueueClosedError || Cancelable)!void {
            const n = try q.put(io, elements, elements.len);
            if (n != elements.len) {
                _ = try q.put(io, elements[n..], elements.len - n);
                unreachable; // partial `put` implies queue was closed or we were canceled
            }
        }

        /// Same as `put`, except does not introduce a cancelation point.
        ///
        /// For a description of cancelation and cancelation points, see `Future.cancel`.
        pub fn putUncancelable(q: *@This(), io: Io, elements: []const Elem, min: usize) QueueClosedError!usize {
            return @divExact(try q.type_erased.putUncancelable(io, @ptrCast(elements), min * @sizeOf(Elem)), @sizeOf(Elem));
        }

        /// Appends `item` to the end of the queue, blocking if the queue is full.
        pub fn putOne(q: *@This(), io: Io, item: Elem) (QueueClosedError || Cancelable)!void {
            assert(try q.put(io, &.{item}, 1) == 1);
        }

        /// Same as `putOne`, except does not introduce a cancelation point.
        ///
        /// For a description of cancelation and cancelation points, see `Future.cancel`.
        pub fn putOneUncancelable(q: *@This(), io: Io, item: Elem) QueueClosedError!void {
            assert(try q.putUncancelable(io, &.{item}, 1) == 1);
        }

        /// Receives elements from the beginning of the queue, potentially blocking
        /// if there are insufficient elements currently in the queue. Returns when
        /// any one of the following conditions is satisfied:
        ///
        /// * At least `target` elements have been received from the queue
        /// * The queue is closed and contains no buffered elements
        /// * The current task is canceled
        ///
        /// Returns how many elements of `buffer` have been populated, if any.
        /// If an error is returned, no elements have been populated.
        ///
        /// If the queue is closed or the task is canceled, but some items were
        /// already received before the closure or cancelation, then `get` may
        /// return a number lower than `target`, in which case future calls are
        /// guaranteed to return `error.Canceled` or `error.Closed`.
        ///
        /// A return value of 0 is only possible if `target` is 0, in which case
        /// the call is guaranteed to fill as much of `buffer` as is possible
        /// *without* blocking.
        ///
        /// Asserts that `buffer.len >= target`.
        pub fn get(q: *@This(), io: Io, buffer: []Elem, target: usize) (QueueClosedError || Cancelable)!usize {
            return @divExact(try q.type_erased.get(io, @ptrCast(buffer), target * @sizeOf(Elem)), @sizeOf(Elem));
        }

        /// Same as `get`, except does not introduce a cancelation point.
        ///
        /// For a description of cancelation and cancelation points, see `Future.cancel`.
        pub fn getUncancelable(q: *@This(), io: Io, buffer: []Elem, min: usize) QueueClosedError!usize {
            return @divExact(try q.type_erased.getUncancelable(io, @ptrCast(buffer), min * @sizeOf(Elem)), @sizeOf(Elem));
        }

        /// Receives one element from the beginning of the queue, blocking if the queue is empty.
        pub fn getOne(q: *@This(), io: Io) (QueueClosedError || Cancelable)!Elem {
            var buf: [1]Elem = undefined;
            assert(try q.get(io, &buf, 1) == 1);
            return buf[0];
        }

        /// Same as `getOne`, except does not introduce a cancelation point.
        ///
        /// For a description of cancelation and cancelation points, see `Future.cancel`.
        pub fn getOneUncancelable(q: *@This(), io: Io) QueueClosedError!Elem {
            var buf: [1]Elem = undefined;
            assert(try q.getUncancelable(io, &buf, 1) == 1);
            return buf[0];
        }

        /// Returns buffer length in `Elem` units.
        pub fn capacity(q: *const @This()) usize {
            return @divExact(q.type_erased.buffer.len, @sizeOf(Elem));
        }
    };
}

/// Calls `function` with `args`, such that the return value of the function is
/// not guaranteed to be available until `await` is called.
///
/// `function` *may* be called immediately, before `async` returns. This has
/// weaker guarantees than `concurrent`, making more portable and reusable.
///
/// When this function returns, it is guaranteed that `function` has already
/// been called and completed, or it has successfully been assigned a unit of
/// concurrency.
///
/// See also:
/// * `Group`
pub fn async(
    io: Io,
    function: anytype,
    args: std.meta.ArgsTuple(@TypeOf(function)),
) Future(@typeInfo(@TypeOf(function)).@"fn".return_type.?) {
    const Result = @typeInfo(@TypeOf(function)).@"fn".return_type.?;
    const Args = @TypeOf(args);
    const TypeErased = struct {
        fn start(context: *const anyopaque, result: *anyopaque) void {
            const args_casted: *const Args = @ptrCast(@alignCast(context));
            const result_casted: *Result = @ptrCast(@alignCast(result));
            result_casted.* = @call(.auto, function, args_casted.*);
        }
    };
    var future: Future(Result) = undefined;
    future.any_future = io.vtable.async(
        io.userdata,
        @ptrCast(&future.result),
        .of(Result),
        @ptrCast(&args),
        .of(Args),
        TypeErased.start,
    );
    return future;
}

pub const ConcurrentError = error{
    /// May occur due to a temporary condition such as resource exhaustion, or
    /// to the Io implementation not supporting concurrency.
    ConcurrencyUnavailable,
};

/// Calls `function` with `args`, such that the return value of the function is
/// not guaranteed to be available until `await` is called, allowing the caller
/// to progress while waiting for any `Io` operations.
///
/// This has stronger guarantee than `async`, placing restrictions on what kind
/// of `Io` implementations are supported. By calling `async` instead, one
/// allows, for example, stackful single-threaded blocking I/O.
pub fn concurrent(
    io: Io,
    function: anytype,
    args: std.meta.ArgsTuple(@TypeOf(function)),
) ConcurrentError!Future(@typeInfo(@TypeOf(function)).@"fn".return_type.?) {
    const Result = @typeInfo(@TypeOf(function)).@"fn".return_type.?;
    const Args = @TypeOf(args);
    const TypeErased = struct {
        fn start(context: *const anyopaque, result: *anyopaque) void {
            const args_casted: *const Args = @ptrCast(@alignCast(context));
            const result_casted: *Result = @ptrCast(@alignCast(result));
            result_casted.* = @call(.auto, function, args_casted.*);
        }
    };
    var future: Future(Result) = undefined;
    future.any_future = try io.vtable.concurrent(
        io.userdata,
        @sizeOf(Result),
        .of(Result),
        @ptrCast(&args),
        .of(Args),
        TypeErased.start,
    );
    return future;
}

pub const SleepError = error{UnsupportedClock} || UnexpectedError || Cancelable;

pub fn sleep(io: Io, duration: Duration, clock: Clock) SleepError!void {
    return io.vtable.sleep(io.userdata, .{ .duration = .{
        .raw = duration,
        .clock = clock,
    } });
}

/// Given a struct with each field a `*Future`, returns a union with the same
/// fields, each field type the future's result.
pub fn SelectUnion(S: type) type {
    const struct_fields = @typeInfo(S).@"struct".fields;
    var names: [struct_fields.len][]const u8 = undefined;
    var types: [struct_fields.len]type = undefined;
    for (struct_fields, &names, &types) |struct_field, *union_field_name, *UnionFieldType| {
        const FieldFuture = @typeInfo(struct_field.type).pointer.child;
        union_field_name.* = struct_field.name;
        UnionFieldType.* = @FieldType(FieldFuture, "result");
    }
    return @Union(.auto, std.meta.FieldEnum(S), &names, &types, &@splat(.{}));
}

/// `s` is a struct with every field a `*Future(T)`, where `T` can be any type,
/// and can be different for each field.
pub fn select(io: Io, s: anytype) Cancelable!SelectUnion(@TypeOf(s)) {
    const U = SelectUnion(@TypeOf(s));
    const S = @TypeOf(s);
    const fields = @typeInfo(S).@"struct".fields;
    var futures: [fields.len]*AnyFuture = undefined;
    inline for (fields, &futures) |field, *any_future| {
        const future = @field(s, field.name);
        any_future.* = future.any_future orelse return @unionInit(U, field.name, future.result);
    }
    switch (try io.vtable.select(io.userdata, &futures)) {
        inline 0...(fields.len - 1) => |selected_index| {
            const field_name = fields[selected_index].name;
            return @unionInit(U, field_name, @field(s, field_name).await(io));
        },
        else => unreachable,
    }
}

pub const LockedStderr = struct {
    file_writer: *File.Writer,
    terminal_mode: Terminal.Mode,

    pub fn terminal(ls: LockedStderr) Terminal {
        return .{
            .writer = &ls.file_writer.interface,
            .mode = ls.terminal_mode,
        };
    }
};

/// For doing application-level writes to the standard error stream.
/// Coordinates also with debug-level writes that are ignorant of Io interface
/// and implementations. When this returns, `std.process.stderr_thread_mutex`
/// will be locked.
///
/// See also:
/// * `tryLockStderr`
pub fn lockStderr(io: Io, buffer: []u8, terminal_mode: ?Terminal.Mode) Cancelable!LockedStderr {
    return io.vtable.lockStderr(io.userdata, buffer, terminal_mode);
}

/// Same as `lockStderr` but non-blocking.
pub fn tryLockStderr(io: Io, buffer: []u8, terminal_mode: ?Terminal.Mode) Cancelable!?LockedStderr {
    return io.vtable.tryLockStderr(io.userdata, buffer, terminal_mode);
}

pub fn unlockStderr(io: Io) void {
    return io.vtable.unlockStderr(io.userdata);
}
