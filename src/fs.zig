// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const builtin = @import("builtin");

const Runtime = @import("runtime.zig").Runtime;

pub const Dir = @import("fs/dir.zig").Dir;
pub const File = @import("fs/file.zig").File;

pub const cwd = Dir.cwd;

test "fs: openFile and createFile with different modes" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const rt = try Runtime.init(allocator);
    defer rt.deinit();

    const dir = cwd();
    const file_path = "test_fs_demo.txt";

    var file = try dir.createFile(rt, file_path);

    const write_data = "Hello, zio fs!";
    _ = try file.write(rt, write_data, 0);
    file.close(rt);

    var read_file = try dir.openFile(rt, file_path, .{ .mode = .read_only });

    var buffer: [100]u8 = undefined;
    const bytes_read = try read_file.read(rt, &buffer, 0);
    try testing.expectEqualStrings(write_data, buffer[0..bytes_read]);
    read_file.close(rt);

    try dir.deleteFile(rt, file_path);
}
