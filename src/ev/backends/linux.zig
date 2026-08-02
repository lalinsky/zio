const std = @import("std");

const IoUring = @import("linux/io_uring.zig");
const Epoll = @import("linux/epoll.zig");
const Completion = @import("../completion.zig").Completion;
const Op = @import("../completion.zig").Op;
const Support = @import("../completion.zig").Support;
const LoopState = @import("../loop.zig").LoopState;
const Duration = @import("../../time.zig").Duration;
const Clock = @import("../../time.zig").Clock;
const os = @import("../../os/root.zig");

/// Compile-time Linux backend policy. `auto` prefers io_uring and falls back to
/// epoll only when ring setup itself is unavailable; explicit engine selections
/// remain useful for tests and for diagnosing engine-specific behavior.
pub const Mode = enum {
    auto,
    io_uring,
    epoll,
};

pub fn Backend(comptime mode: Mode) type {
    return struct {
        const Self = @This();

        pub const Engine = enum {
            io_uring,
            epoll,
        };

        const Selection = enum {
            undecided,
            io_uring,
            epoll,
        };

        pub const NetHandle = IoUring.NetHandle;
        pub const native_wall_timers = true;
        // In auto mode a delegated open means epoll was selected; probePollable
        // applies O_NONBLOCK after opening, matching the old epoll behavior.
        pub const supports_nonblocking_file_io = mode == .io_uring;

        // io_uring needs these operation-owned syscall arguments to outlive SQE
        // submission. Epoll has no corresponding per-operation scratch.
        pub const NetRecvData = if (mode == .epoll) struct {} else IoUring.NetRecvData;
        pub const NetSendData = if (mode == .epoll) struct {} else IoUring.NetSendData;
        pub const NetRecvFromData = if (mode == .epoll) struct {} else IoUring.NetRecvFromData;
        pub const NetSendToData = if (mode == .epoll) struct {} else IoUring.NetSendToData;
        pub const NetRecvMsgData = if (mode == .epoll) struct {} else IoUring.NetRecvMsgData;
        pub const NetSendMsgData = if (mode == .epoll) struct {} else IoUring.NetSendMsgData;
        pub const FileOpenData = IoUring.FileOpenData;
        pub const FileCreateData = IoUring.FileCreateData;
        pub const DirCreateDirData = IoUring.DirCreateDirData;
        pub const DirRenameData = IoUring.DirRenameData;
        pub const DirRenamePreserveData = IoUring.DirRenamePreserveData;
        pub const DirDeleteFileData = IoUring.DirDeleteFileData;
        pub const DirDeleteDirData = IoUring.DirDeleteDirData;
        pub const FileSizeData = IoUring.FileSizeData;
        pub const FileStatData = IoUring.FileStatData;
        pub const DirOpenData = IoUring.DirOpenData;
        pub const NetSendFileData = IoUring.NetSendFileData;
        pub const ProcessWaitData = switch (mode) {
            .auto => struct {
                siginfo: @FieldType(IoUring.ProcessWaitData, "siginfo") = undefined,
                pidfd: @FieldType(Epoll.ProcessWaitData, "pidfd") = -1,
            },
            .io_uring => IoUring.ProcessWaitData,
            .epoll => Epoll.ProcessWaitData,
        };

        pub const SharedState = struct {
            selection_mutex: os.Mutex = .init(),
            selection: Selection = .undecided,
            io_uring: IoUring.SharedState = .{},
            epoll: Epoll.SharedState = .{},
        };

        engine: union(Engine) {
            io_uring: IoUring,
            epoll: Epoll,
        },

        pub fn capability(comptime op: Op) Support {
            return switch (mode) {
                .io_uring => IoUring.capability(op),
                .epoll => Epoll.capability(op),
                .auto => combine(IoUring.capability(op), Epoll.capability(op)),
            };
        }

        fn combine(a: Support, b: Support) Support {
            if (a == b) return a;
            return .maybe;
        }

        fn ringUnavailable(err: anyerror) bool {
            return err == error.SystemOutdated or
                err == error.PermissionDenied or
                err == error.ArgumentsInvalid;
        }

        fn initIoUring(
            self: *Self,
            allocator: std.mem.Allocator,
            queue_size: u16,
            shared_state: *SharedState,
        ) !void {
            var engine: IoUring = undefined;
            try engine.init(allocator, queue_size, &shared_state.io_uring);
            self.* = .{ .engine = .{ .io_uring = engine } };
            shared_state.selection = .io_uring;
        }

        fn initEpoll(
            self: *Self,
            allocator: std.mem.Allocator,
            queue_size: u16,
            shared_state: *SharedState,
        ) !void {
            var engine: Epoll = undefined;
            try engine.init(allocator, queue_size, &shared_state.epoll);
            self.* = .{ .engine = .{ .epoll = engine } };
            shared_state.selection = .epoll;
        }

        pub fn init(
            self: *Self,
            allocator: std.mem.Allocator,
            queue_size: u16,
            shared_state: *SharedState,
        ) !void {
            // The decision belongs to the LoopGroup. Holding this mutex through
            // initialization prevents two first loops from selecting different
            // engines and also serializes publication of io_uring's master WQ.
            shared_state.selection_mutex.lock();
            defer shared_state.selection_mutex.unlock();

            switch (shared_state.selection) {
                .io_uring => {
                    std.debug.assert(mode != .epoll);
                    return self.initIoUring(allocator, queue_size, shared_state);
                },
                .epoll => {
                    std.debug.assert(mode != .io_uring);
                    return self.initEpoll(allocator, queue_size, shared_state);
                },
                .undecided => switch (mode) {
                    .io_uring => return self.initIoUring(allocator, queue_size, shared_state),
                    .epoll => return self.initEpoll(allocator, queue_size, shared_state),
                    .auto => {
                        self.initIoUring(allocator, queue_size, shared_state) catch |err| {
                            if (!ringUnavailable(err)) return err;
                            return self.initEpoll(allocator, queue_size, shared_state);
                        };
                    },
                },
            }
        }

        pub fn deinit(self: *Self) void {
            switch (mode) {
                .io_uring => self.engine.io_uring.deinit(),
                .epoll => self.engine.epoll.deinit(),
                .auto => switch (self.engine) {
                    .io_uring => |*engine| engine.deinit(),
                    .epoll => |*engine| engine.deinit(),
                },
            }
        }

        pub fn selectedEngine(self: *const Self) Engine {
            return switch (mode) {
                .io_uring => .io_uring,
                .epoll => .epoll,
                .auto => std.meta.activeTag(self.engine),
            };
        }

        pub fn supports(self: *const Self, comptime op: Op, data: *op.toType()) bool {
            comptime std.debug.assert(capability(op) == .maybe);
            return switch (mode) {
                .io_uring => self.engine.io_uring.supports(op, data),
                .epoll => self.engine.epoll.supports(op, data),
                .auto => switch (self.engine) {
                    .io_uring => |*engine| switch (comptime IoUring.capability(op)) {
                        .yes => true,
                        .no => false,
                        .maybe => engine.supports(op, data),
                    },
                    .epoll => |*engine| switch (comptime Epoll.capability(op)) {
                        .yes => true,
                        .no => false,
                        .maybe => engine.supports(op, data),
                    },
                },
            };
        }

        pub fn wake(self: *Self, state: *LoopState) void {
            switch (mode) {
                .io_uring => self.engine.io_uring.wake(state),
                .epoll => self.engine.epoll.wake(state),
                .auto => switch (self.engine) {
                    .io_uring => |*engine| engine.wake(state),
                    .epoll => |*engine| engine.wake(state),
                },
            }
        }

        pub fn syncWallTimer(self: *Self, clock: Clock, deadline: ?u64) bool {
            return switch (mode) {
                .io_uring => self.engine.io_uring.syncWallTimer(clock, deadline),
                .epoll => self.engine.epoll.syncWallTimer(clock, deadline),
                .auto => switch (self.engine) {
                    .io_uring => |*engine| engine.syncWallTimer(clock, deadline),
                    .epoll => |*engine| engine.syncWallTimer(clock, deadline),
                },
            };
        }

        pub fn decrInflight(self: *Self) void {
            switch (mode) {
                .io_uring => self.engine.io_uring.decrInflight(),
                .epoll => self.engine.epoll.decrInflight(),
                .auto => switch (self.engine) {
                    .io_uring => |*engine| engine.decrInflight(),
                    .epoll => |*engine| engine.decrInflight(),
                },
            }
        }

        pub fn hasInflight(self: *const Self) bool {
            return switch (mode) {
                .io_uring => self.engine.io_uring.hasInflight(),
                .epoll => self.engine.epoll.hasInflight(),
                .auto => switch (self.engine) {
                    .io_uring => |*engine| engine.hasInflight(),
                    .epoll => |*engine| engine.hasInflight(),
                },
            };
        }

        pub fn submit(self: *Self, state: *LoopState, completion: *Completion) void {
            switch (mode) {
                .io_uring => self.engine.io_uring.submit(state, completion),
                .epoll => self.engine.epoll.submit(state, completion),
                .auto => switch (self.engine) {
                    .io_uring => |*engine| engine.submit(state, completion),
                    .epoll => |*engine| engine.submit(state, completion),
                },
            }
        }

        pub fn cancel(self: *Self, state: *LoopState, completion: *Completion) void {
            switch (mode) {
                .io_uring => self.engine.io_uring.cancel(state, completion),
                .epoll => self.engine.epoll.cancel(state, completion),
                .auto => switch (self.engine) {
                    .io_uring => |*engine| engine.cancel(state, completion),
                    .epoll => |*engine| engine.cancel(state, completion),
                },
            }
        }

        pub fn poll(self: *Self, state: *LoopState, timeout: Duration) !bool {
            return switch (mode) {
                .io_uring => self.engine.io_uring.poll(state, timeout),
                .epoll => self.engine.epoll.poll(state, timeout),
                .auto => switch (self.engine) {
                    .io_uring => |*engine| engine.poll(state, timeout),
                    .epoll => |*engine| engine.poll(state, timeout),
                },
            };
        }
    };
}
