const std = @import("std");
const builtin = @import("builtin");
const Loop = @import("../loop.zig").Loop;
const ProcessWait = @import("../completion.zig").ProcessWait;
const ThreadPool = @import("../thread_pool.zig").ThreadPool;

// TODO: re-enable once process spawning is ported to Zig 0.16
// (std.process.Child.init was removed; need to use std.process.spawn(io, .{...}) or fork/execvp directly)
//
// fn processWaitCallback(loop: *Loop, c: *@import("../completion.zig").Completion) void {
//     _ = loop;
//     _ = c;
// }
//
// test "ProcessWait: wait for child process exit code 0" { ... }
// test "ProcessWait: wait for child process exit code 1" { ... }
// test "ProcessWait: wait for child process killed by signal" { ... }
