const builtin = @import("builtin");

pub const Backend = switch (builtin.os.tag) {
    // TODO: implement io_uring, kqueue, iocp
    // TODO: add build option for explicit selection
    else => @import("backends/poll.zig"),
};
