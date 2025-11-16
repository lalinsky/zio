const std = @import("std");
const aio = @import("aio");
const Runtime = @import("../runtime.zig").Runtime;
const File = @import("file.zig").File;
const waitForIo = @import("base.zig").waitForIo;
const genericCallback = @import("base.zig").genericCallback;

pub const Dir = struct {
    fd: aio.system.fs.fd_t,

    pub fn cwd() Dir {
        const dir = std.fs.cwd(); // TODO: avoid `std.fs`
        return .{ .fd = dir.fd };
    }

    pub fn openFile(self: Dir, rt: *Runtime, path: []const u8, flags: aio.system.fs.FileOpenFlags) !File {
        const task = rt.getCurrentTask() orelse @panic("no active task");
        const executor = task.getExecutor();

        var op = aio.FileOpen.init(self.fd, path, flags);
        op.c.userdata = task;
        op.c.callback = genericCallback;

        executor.loop.add(&op.c);
        try waitForIo(rt, &op.c);

        const fd = try op.getResult();
        return .initFd(fd);
    }

    pub fn createFile(self: Dir, rt: *Runtime, path: []const u8, flags: aio.system.fs.FileCreateFlags) !File {
        const task = rt.getCurrentTask() orelse @panic("no active task");
        const executor = task.getExecutor();

        var op = aio.FileCreate.init(self.fd, path, flags);
        op.c.userdata = task;
        op.c.callback = genericCallback;

        executor.loop.add(&op.c);
        try waitForIo(rt, &op.c);

        const fd = try op.getResult();
        return .initFd(fd);
    }

    pub fn rename(self: Dir, rt: *Runtime, old_path: []const u8, new_path: []const u8) !void {
        const task = rt.getCurrentTask() orelse @panic("no active task");
        const executor = task.getExecutor();

        var op = aio.FileRename.init(self.fd, old_path, new_path);
        op.c.userdata = task;
        op.c.callback = genericCallback;

        executor.loop.add(&op.c);
        try waitForIo(rt, &op.c);

        try op.getResult();
    }

    pub fn deleteFile(self: Dir, rt: *Runtime, path: []const u8) !void {
        const task = rt.getCurrentTask() orelse @panic("no active task");
        const executor = task.getExecutor();

        var op = aio.FileDelete.init(self.fd, path);
        op.c.userdata = task;
        op.c.callback = genericCallback;

        executor.loop.add(&op.c);
        try waitForIo(rt, &op.c);

        try op.getResult();
    }
};
