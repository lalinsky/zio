const std = @import("std");

// Re-export coroutine functionality
pub const coroutines = @import("coroutines.zig");
pub const Coroutine = coroutines.Coroutine;
pub const CoroutineState = coroutines.CoroutineState;
pub const CoroutineOptions = coroutines.CoroutineOptions;

// Re-export runtime functionality
const runtime = @import("runtime.zig");
pub const Runtime = runtime.Runtime;
pub const ZioError = runtime.ZioError;
pub const JoinHandle = runtime.JoinHandle;

// Re-export I/O functionality
pub const File = @import("file.zig").File;
pub const fs = @import("fs.zig");

// Re-export network functionality
pub const TcpListener = @import("tcp.zig").TcpListener;
pub const TcpStream = @import("tcp.zig").TcpStream;
pub const UdpSocket = @import("udp.zig").UdpSocket;
pub const UdpRecvResult = @import("udp.zig").UdpReadResult;
pub const Address = @import("address.zig").Address;
pub const net = @import("net.zig");

// Re-export synchronization functionality
pub const Mutex = @import("sync.zig").Mutex;
pub const Condition = @import("sync.zig").Condition;
pub const ResetEvent = @import("sync.zig").ResetEvent;

test {
    std.testing.refAllDecls(@This());
}
