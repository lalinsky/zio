// SPDX-PipeCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const builtin = @import("builtin");
const xev = @import("xev");
const StreamReader = @import("../stream.zig").StreamReader;
const StreamWriter = @import("../stream.zig").StreamWriter;
const Runtime = @import("../runtime.zig").Runtime;
const Cancelable = @import("../common.zig").Cancelable;
const runIo = @import("base.zig").runIo;

const Handle = std.fs.File.Handle;

pub const Pipe = struct {
    fd: Handle,

    pub fn init(std_file: std.fs.File) Pipe {
        return Pipe{
            .fd = std_file.handle,
        };
    }

    pub fn initFd(fd: Handle) Pipe {
        return Pipe{
            .fd = fd,
        };
    }

    pub fn read(self: *Pipe, rt: *Runtime, buffer: []u8) !usize {
        var completion: xev.Completion = .{ .op = .{
            .read = .{
                .fd = self.fd,
                .buffer = .{ .slice = buffer },
            },
        } };

        return try runIo(rt, &completion, "read");
    }

    pub fn write(self: *Pipe, rt: *Runtime, data: []const u8) !usize {
        var completion: xev.Completion = .{ .op = .{
            .write = .{
                .fd = self.fd,
                .buffer = .{ .slice = data },
            },
        } };

        return try runIo(rt, &completion, "write");
    }

    /// Low-level read function that accepts xev.ReadBuffer directly.
    /// Returns std.Io.Reader compatible errors.
    pub fn readBuf(self: *Pipe, rt: *Runtime, buffer: *xev.ReadBuffer) (Cancelable || std.Io.Reader.Error)!usize {
        var completion: xev.Completion = .{ .op = .{
            .read = .{
                .fd = self.fd,
                .buffer = buffer.*,
            },
        } };

        const bytes_read = runIo(rt, &completion, "read") catch |err| switch (err) {
            error.EOF => return error.EndOfStream,
            else => return error.ReadFailed,
        };

        // Copy array data back to caller's buffer if needed
        if (buffer.* == .array) {
            buffer.array = completion.op.read.buffer.array;
        }

        return bytes_read;
    }

    /// Low-level write function that accepts xev.WriteBuffer directly.
    /// Returns std.Io.Writer compatible errors.
    pub fn writeBuf(self: *Pipe, rt: *Runtime, buffer: xev.WriteBuffer) (Cancelable || std.Io.Writer.Error)!usize {
        var completion: xev.Completion = .{ .op = .{
            .write = .{
                .fd = self.fd,
                .buffer = buffer,
            },
        } };

        return runIo(rt, &completion, "write") catch return error.WriteFailed;
    }

    pub fn close(self: *Pipe, rt: *Runtime) void {
        var completion: xev.Completion = .{ .op = .{
            .close = .{
                .fd = self.fd,
            },
        } };

        rt.beginShield();
        defer rt.endShield();

        // Ignore close errors, following Zig std lib pattern
        runIo(rt, &completion, "close") catch {};
    }

    // Zig 0.15+ streaming interface
    pub const Reader = StreamReader(*Pipe);
    pub const Writer = StreamWriter(*Pipe);

    pub fn reader(self: *Pipe, rt: *Runtime, buffer: []u8) Reader {
        return Reader.init(self, rt, buffer);
    }

    pub fn writer(self: *Pipe, rt: *Runtime, buffer: []u8) Writer {
        return Writer.init(self, rt, buffer);
    }
};
