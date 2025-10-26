const std = @import("std");
const builtin = @import("builtin");
const meta = @import("meta.zig");
const Runtime = @import("runtime.zig").Runtime;
const JoinHandle = @import("runtime.zig").JoinHandle;

const is_zig_0_15 = builtin.zig_version.order(.{ .major = 0, .minor = 16, .patch = 0 }) == .lt;

pub const Io = if (!is_zig_0_15) std.Io else struct {
    userdata: ?*anyopaque,

    pub fn async(self: Io, func: anytype, args: meta.ArgsType(func)) Future(meta.ReturnType(func)) {
        const rt: *Runtime = @ptrCast(@alignCast(self.userdata));
        const task = rt.spawn(func, args, .{}) catch {
            const result = @call(.auto, func, args);
            return .{ .task = null, .result = result };
        };
        return .{ .task = task, .result = undefined };
    }

    pub fn concurrent(self: Io, func: anytype, args: meta.ArgsType(func)) !Future(meta.ReturnType(func)) {
        const rt: *Runtime = @ptrCast(@alignCast(self.userdata));
        const task = try rt.spawn(func, args, .{});
        return .{ .task = task, .result = undefined };
    }

    pub fn Future(comptime T: type) type {
        return struct {
            task: ?JoinHandle(T),
            result: T,

            pub fn await(self: *@This(), io: Io) T {
                const rt = Runtime.fromIo(io);
                if (self.task) |*task| {
                    self.result = task.join(rt);
                    task.deinit();
                    self.task = null;
                }
                return self.result;
            }

            pub fn cancel(self: *@This(), io: Io) T {
                const rt = Runtime.fromIo(io);
                if (self.task) |*task| {
                    task.cancel(rt);
                }
                return self.await(io);
            }
        };
    }
};

test "Io: async/await" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const TestFunc = struct {
        fn func(a: i32, b: i32) i32 {
            return a + b;
        }

        fn main(io: Io) !void {
            var fut = io.async(func, .{ 1, 2 });
            defer _ = fut.cancel(io);

            const val = fut.await(io);
            try std.testing.expectEqual(3, val);
        }
    };

    try rt.runUntilComplete(TestFunc.main, .{rt.io()}, .{});
}
