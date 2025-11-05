const std = @import("std");
const builtin = @import("builtin");

pub const system = switch (builtin.os.tag) {
    .linux => std.os.linux,
    else => std.c,
};

pub const unexpected_error_tracing = builtin.mode == .Debug and switch (builtin.zig_backend) {
    .stage2_llvm, .stage2_x86_64 => true,
    else => false,
};

pub fn errno(rc: anytype) system.E {
    switch (system) {
        std.c => {
            return if (rc == -1) @enumFromInt(system._errno().*) else .SUCCESS;
        },
        std.os.linux => {
            const signed: isize = @bitCast(rc);
            const int = if (signed > -4096 and signed < 0) -signed else 0;
            return @enumFromInt(int);
        },
        else => @compileError("unsupported OS"),
    }
}

pub fn unexpectedErrno(err: system.E) error{Unexpected} {
    if (unexpected_error_tracing) {
        std.debug.print(
            \\unexpected errno: {d}
            \\please file a bug report: https://github.com/lalinsky/zio/issues/new
        , .{@intFromEnum(err)});
        std.debug.dumpCurrentStackTrace(null);
    }
    return error.Unexpected;
}
