const std = @import("std");
const Runtime = @import("runtime.zig").Runtime;
const getNextExecutor = @import("runtime.zig").getNextExecutor;
const AnyTask = @import("core/task.zig").AnyTask;
const CreateOptions = @import("core/task.zig").CreateOptions;
const Awaitable = @import("core/awaitable.zig").Awaitable;
const select = @import("select.zig");
const zio_net = @import("net.zig");
const zio_file_io = @import("fs/file.zig");
const zio_mutex = @import("sync/Mutex.zig");
const zio_condition = @import("sync/Condition.zig");
const CompactWaitQueue = @import("utils/wait_queue.zig").CompactWaitQueue;
const WaitNode = @import("core/WaitNode.zig");

// Verify binary compatibility between std.Io.Mutex and zio.Mutex
comptime {
    if (@sizeOf(std.Io.Mutex) != @sizeOf(zio_mutex)) {
        @compileError("std.Io.Mutex and zio.Mutex must have the same size");
    }
    if (@alignOf(std.Io.Mutex) != @alignOf(zio_mutex)) {
        @compileError("std.Io.Mutex and zio.Mutex must have the same alignment");
    }
    // Verify sentinel values match between std.Io.Mutex and CompactWaitQueue
    const State = CompactWaitQueue(WaitNode).State;
    if (@intFromEnum(std.Io.Mutex.State.locked_once) != @intFromEnum(State.sentinel0)) {
        @compileError("std.Io.Mutex.State.locked_once must match CompactWaitQueue.State.sentinel0");
    }
    if (@intFromEnum(std.Io.Mutex.State.unlocked) != @intFromEnum(State.sentinel1)) {
        @compileError("std.Io.Mutex.State.unlocked must match CompactWaitQueue.State.sentinel1");
    }
}

// Verify binary compatibility between std.Io.Condition and zio.Condition
comptime {
    if (@sizeOf(std.Io.Condition) != @sizeOf(zio_condition)) {
        @compileError("std.Io.Condition and zio.Condition must have the same size");
    }
    if (@alignOf(std.Io.Condition) != @alignOf(zio_condition)) {
        @compileError("std.Io.Condition and zio.Condition must have the same alignment");
    }
}

fn asyncImpl(userdata: ?*anyopaque, result: []u8, result_alignment: std.mem.Alignment, context: []const u8, context_alignment: std.mem.Alignment, start: *const fn (context: *const anyopaque, result: *anyopaque) void) ?*std.Io.AnyFuture {
    return concurrentImpl(userdata, result.len, result_alignment, context, context_alignment, start) catch {
        // If we can't schedule asynchronously, execute synchronously
        start(context.ptr, result.ptr);
        return null;
    };
}

fn concurrentImpl(userdata: ?*anyopaque, result_len: usize, result_alignment: std.mem.Alignment, context: []const u8, context_alignment: std.mem.Alignment, start: *const fn (context: *const anyopaque, result: *anyopaque) void) std.Io.ConcurrentError!*std.Io.AnyFuture {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));

    // Check if runtime is shutting down
    if (rt.tasks.isClosed()) {
        return error.ConcurrencyUnavailable;
    }

    // Pick an executor (round-robin)
    const executor = getNextExecutor(rt);

    // Create the task using AnyTask.create
    const task = AnyTask.create(
        executor,
        result_len,
        result_alignment,
        context,
        context_alignment,
        start,
        CreateOptions{},
    ) catch return error.ConcurrencyUnavailable;
    errdefer task.closure.free(AnyTask, executor.allocator, task);

    // Add to global awaitable registry (can fail if runtime is shutting down)
    rt.tasks.add(&task.awaitable) catch return error.ConcurrencyUnavailable;
    errdefer _ = rt.tasks.remove(&task.awaitable);

    // Increment ref count for the Future BEFORE scheduling
    // This prevents race where task completes before we create the Future
    task.awaitable.ref_count.incr();
    errdefer _ = task.awaitable.ref_count.decr();

    // Schedule the task to run (handles cross-thread notification)
    executor.scheduleTask(task, .maybe_remote);

    // Return the awaitable as AnyFuture
    return @ptrCast(&task.awaitable);
}

fn awaitOrCancel(userdata: ?*anyopaque, any_future: *std.Io.AnyFuture, result: []u8, result_alignment: std.mem.Alignment, should_cancel: bool) void {
    _ = result_alignment;
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    const awaitable: *Awaitable = @ptrCast(@alignCast(any_future));

    // Request cancellation if needed
    if (should_cancel and !awaitable.done.load(.acquire)) {
        awaitable.cancel();
    }

    // Wait for completion
    _ = select.waitUntilComplete(rt, awaitable);

    // Copy result from task to result buffer
    const task = AnyTask.fromAwaitable(awaitable);
    const task_result = task.closure.getResultSlice(AnyTask, task);
    @memcpy(result, task_result);

    // Release the awaitable (decrements ref count, may destroy)
    rt.releaseAwaitable(awaitable, false);
}

fn awaitImpl(userdata: ?*anyopaque, any_future: *std.Io.AnyFuture, result: []u8, result_alignment: std.mem.Alignment) void {
    awaitOrCancel(userdata, any_future, result, result_alignment, false);
}

fn cancelImpl(userdata: ?*anyopaque, any_future: *std.Io.AnyFuture, result: []u8, result_alignment: std.mem.Alignment) void {
    awaitOrCancel(userdata, any_future, result, result_alignment, true);
}

fn cancelRequestedImpl(userdata: ?*anyopaque) bool {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    rt.checkCanceled() catch return true;
    return false;
}

fn groupAsyncImpl(userdata: ?*anyopaque, group: *std.Io.Group, context: []const u8, context_alignment: std.mem.Alignment, start: *const fn (*std.Io.Group, context: *const anyopaque) void) void {
    _ = userdata;
    _ = group;
    _ = context;
    _ = context_alignment;
    _ = start;
    @panic("TODO");
}

fn groupConcurrentImpl(userdata: ?*anyopaque, group: *std.Io.Group, context: []const u8, context_alignment: std.mem.Alignment, start: *const fn (*std.Io.Group, context: *const anyopaque) void) std.Io.ConcurrentError!void {
    _ = userdata;
    _ = group;
    _ = context;
    _ = context_alignment;
    _ = start;
    @panic("TODO");
}

fn groupWaitImpl(userdata: ?*anyopaque, group: *std.Io.Group, token: *anyopaque) void {
    _ = userdata;
    _ = group;
    _ = token;
    @panic("TODO");
}

fn groupCancelImpl(userdata: ?*anyopaque, group: *std.Io.Group, token: *anyopaque) void {
    _ = userdata;
    _ = group;
    _ = token;
    @panic("TODO");
}

fn selectImpl(userdata: ?*anyopaque, futures: []const *std.Io.AnyFuture) std.Io.Cancelable!usize {
    _ = userdata;
    _ = futures;
    @panic("TODO");
}

fn mutexLockImpl(userdata: ?*anyopaque, prev_state: std.Io.Mutex.State, mutex: *std.Io.Mutex) std.Io.Cancelable!void {
    _ = prev_state;
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    const zio_mtx: *zio_mutex = @ptrCast(mutex);
    try zio_mtx.lock(rt);
}

fn mutexLockUncancelableImpl(userdata: ?*anyopaque, prev_state: std.Io.Mutex.State, mutex: *std.Io.Mutex) void {
    _ = prev_state;
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    const zio_mtx: *zio_mutex = @ptrCast(mutex);
    zio_mtx.lockUncancelable(rt);
}

fn mutexUnlockImpl(userdata: ?*anyopaque, prev_state: std.Io.Mutex.State, mutex: *std.Io.Mutex) void {
    _ = prev_state;
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    const zio_mtx: *zio_mutex = @ptrCast(mutex);
    zio_mtx.unlock(rt);
}

fn conditionWaitImpl(userdata: ?*anyopaque, cond: *std.Io.Condition, mutex: *std.Io.Mutex) std.Io.Cancelable!void {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    const zio_cond: *zio_condition = @ptrCast(cond);
    const zio_mtx: *zio_mutex = @ptrCast(mutex);
    try zio_cond.wait(rt, zio_mtx);
}

fn conditionWaitUncancelableImpl(userdata: ?*anyopaque, cond: *std.Io.Condition, mutex: *std.Io.Mutex) void {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    const zio_cond: *zio_condition = @ptrCast(cond);
    const zio_mtx: *zio_mutex = @ptrCast(mutex);
    zio_cond.waitUncancelable(rt, zio_mtx);
}

fn conditionWakeImpl(userdata: ?*anyopaque, cond: *std.Io.Condition, wake: std.Io.Condition.Wake) void {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    const zio_cond: *zio_condition = @ptrCast(cond);
    switch (wake) {
        .one => zio_cond.signal(rt),
        .all => zio_cond.broadcast(rt),
    }
}

fn dirMakeImpl(userdata: ?*anyopaque, dir: std.Io.Dir, sub_path: []const u8, mode: std.Io.Dir.Mode) std.Io.Dir.MakeError!void {
    _ = userdata;
    _ = dir;
    _ = sub_path;
    _ = mode;
    @panic("TODO");
}

fn dirMakePathImpl(userdata: ?*anyopaque, dir: std.Io.Dir, sub_path: []const u8, mode: std.Io.Dir.Mode) std.Io.Dir.MakeError!void {
    _ = userdata;
    _ = dir;
    _ = sub_path;
    _ = mode;
    @panic("TODO");
}

fn dirMakeOpenPathImpl(userdata: ?*anyopaque, dir: std.Io.Dir, sub_path: []const u8, options: std.Io.Dir.OpenOptions) std.Io.Dir.MakeOpenPathError!std.Io.Dir {
    _ = userdata;
    _ = dir;
    _ = sub_path;
    _ = options;
    @panic("TODO");
}

fn dirStatImpl(userdata: ?*anyopaque, dir: std.Io.Dir) std.Io.Dir.StatError!std.Io.Dir.Stat {
    _ = userdata;
    _ = dir;
    @panic("TODO");
}

fn dirStatPathImpl(userdata: ?*anyopaque, dir: std.Io.Dir, sub_path: []const u8, options: std.Io.Dir.StatPathOptions) std.Io.Dir.StatPathError!std.Io.File.Stat {
    _ = userdata;
    _ = dir;
    _ = sub_path;
    _ = options;
    @panic("TODO");
}

fn dirAccessImpl(userdata: ?*anyopaque, dir: std.Io.Dir, sub_path: []const u8, options: std.Io.Dir.AccessOptions) std.Io.Dir.AccessError!void {
    _ = userdata;
    _ = dir;
    _ = sub_path;
    _ = options;
    @panic("TODO");
}

fn dirCreateFileImpl(userdata: ?*anyopaque, dir: std.Io.Dir, sub_path: []const u8, flags: std.Io.File.CreateFlags) std.Io.File.OpenError!std.Io.File {
    _ = userdata;
    _ = dir;
    _ = sub_path;
    _ = flags;
    @panic("TODO");
}

fn dirOpenFileImpl(userdata: ?*anyopaque, dir: std.Io.Dir, sub_path: []const u8, flags: std.Io.File.OpenFlags) std.Io.File.OpenError!std.Io.File {
    _ = userdata;
    _ = dir;
    _ = sub_path;
    _ = flags;
    @panic("TODO");
}

fn dirOpenDirImpl(userdata: ?*anyopaque, dir: std.Io.Dir, sub_path: []const u8, options: std.Io.Dir.OpenOptions) std.Io.Dir.OpenError!std.Io.Dir {
    _ = userdata;
    _ = dir;
    _ = sub_path;
    _ = options;
    @panic("TODO");
}

fn dirCloseImpl(userdata: ?*anyopaque, dir: std.Io.Dir) void {
    _ = userdata;
    _ = dir;
    @panic("TODO");
}

fn fileStatImpl(userdata: ?*anyopaque, file: std.Io.File) std.Io.File.StatError!std.Io.File.Stat {
    _ = userdata;
    _ = file;
    @panic("TODO");
}

fn fileCloseImpl(userdata: ?*anyopaque, file: std.Io.File) void {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    var zio_file = zio_file_io.File.fromFd(file.handle);
    zio_file.close(rt);
}

fn fileWriteStreamingImpl(userdata: ?*anyopaque, file: std.Io.File, buffer: [][]const u8) std.Io.File.WriteStreamingError!usize {
    _ = userdata;
    _ = file;
    _ = buffer;
    // Cannot track position with bare file handle - std.Io.File is just a handle
    return error.Unexpected;
}

fn fileWritePositionalImpl(userdata: ?*anyopaque, file: std.Io.File, buffer: [][]const u8, offset: u64) std.Io.File.WritePositionalError!usize {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));

    if (buffer.len == 0) return 0;

    return zio_file_io.fileWritePositional(rt, file.handle, buffer, offset) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return error.Unexpected,
    };
}

fn fileReadStreamingImpl(userdata: ?*anyopaque, file: std.Io.File, data: [][]u8) std.Io.File.Reader.Error!usize {
    _ = userdata;
    _ = file;
    _ = data;
    // Cannot track position with bare file handle - std.Io.File is just a handle
    return error.Unexpected;
}

fn fileReadPositionalImpl(userdata: ?*anyopaque, file: std.Io.File, data: [][]u8, offset: u64) std.Io.File.ReadPositionalError!usize {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));

    if (data.len == 0) return 0;

    return zio_file_io.fileReadPositional(rt, file.handle, data, offset) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return error.Unexpected,
    };
}

fn fileSeekByImpl(userdata: ?*anyopaque, file: std.Io.File, relative_offset: i64) std.Io.File.SeekError!void {
    _ = userdata;
    _ = file;
    _ = relative_offset;
    // Cannot seek without position tracking - std.Io.File is just a handle
    return error.Unseekable;
}

fn fileSeekToImpl(userdata: ?*anyopaque, file: std.Io.File, absolute_offset: u64) std.Io.File.SeekError!void {
    _ = userdata;
    _ = file;
    _ = absolute_offset;
    // Cannot seek without position tracking - std.Io.File is just a handle
    return error.Unseekable;
}

fn openSelfExeImpl(userdata: ?*anyopaque, flags: std.Io.File.OpenFlags) std.Io.File.OpenSelfExeError!std.Io.File {
    _ = userdata;
    _ = flags;
    @panic("TODO");
}

fn nowImpl(userdata: ?*anyopaque, clock: std.Io.Clock) std.Io.Clock.Error!std.Io.Timestamp {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));

    return switch (clock) {
        // libxev uses CLOCK_MONOTONIC which maps to .awake
        // We treat .boot the same since both are monotonic clocks
        .awake, .boot => {
            const ms = rt.now(); // Returns milliseconds from libxev
            const ns = ms * std.time.ns_per_ms;
            return .{ .nanoseconds = ns };
        },
        .real, .cpu_process, .cpu_thread => error.UnsupportedClock,
    };
}

fn sleepImpl(userdata: ?*anyopaque, timeout: std.Io.Timeout) std.Io.SleepError!void {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    const io = fromRuntime(rt);

    // Convert timeout to duration from now (handles none/duration/deadline cases)
    const duration = (try timeout.toDurationFromNow(io)) orelse return;

    // Convert nanoseconds to milliseconds
    const ns: i96 = duration.raw.nanoseconds;
    if (ns <= 0) return;
    const ms: u64 = @intCast(@divTrunc(ns, std.time.ns_per_ms));

    try rt.sleep(ms);
}

fn stdIoIpToZio(addr: std.Io.net.IpAddress) zio_net.IpAddress {
    return switch (addr) {
        .ip4 => |ip4| zio_net.IpAddress.initIp4(ip4.bytes, ip4.port),
        .ip6 => |ip6| zio_net.IpAddress.initIp6(ip6.bytes, ip6.port, ip6.flow, ip6.interface.index),
    };
}

fn zioIpToStdIo(addr: zio_net.IpAddress) std.Io.net.IpAddress {
    return switch (addr.any.family) {
        std.posix.AF.INET => .{ .ip4 = .{
            .bytes = @bitCast(addr.in.addr),
            .port = std.mem.bigToNative(u16, addr.in.port),
        } },
        std.posix.AF.INET6 => .{ .ip6 = .{
            .bytes = addr.in6.addr,
            .port = std.mem.bigToNative(u16, addr.in6.port),
            .flow = addr.in6.flowinfo,
            .interface = .{ .index = addr.in6.scope_id },
        } },
        else => unreachable,
    };
}

fn netListenIpImpl(userdata: ?*anyopaque, address: std.Io.net.IpAddress, options: std.Io.net.IpAddress.ListenOptions) std.Io.net.IpAddress.ListenError!std.Io.net.Server {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    const zio_addr = stdIoIpToZio(address);
    const zio_options: zio_net.IpAddress.ListenOptions = .{
        .reuse_address = options.reuse_address,
        .kernel_backlog = options.kernel_backlog,
    };
    const server = zio_net.netListenIp(rt, zio_addr, zio_options) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return error.Unexpected,
    };
    return .{
        .socket = .{
            .handle = server.socket.handle,
            .address = zioIpToStdIo(server.socket.address.ip),
        },
    };
}

fn netAcceptImpl(userdata: ?*anyopaque, server: std.Io.net.Socket.Handle) std.Io.net.Server.AcceptError!std.Io.net.Stream {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    const stream = zio_net.netAccept(rt, server) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return error.Unexpected,
    };

    // Convert address based on family
    // Note: std.Io.net.Stream.socket.address is IpAddress only, so for Unix sockets we use a fake address
    const std_addr: std.Io.net.IpAddress = switch (stream.socket.address.any.family) {
        std.posix.AF.INET, std.posix.AF.INET6 => zioIpToStdIo(stream.socket.address.ip),
        std.posix.AF.UNIX => .{ .ip4 = .{ .bytes = .{ 0, 0, 0, 0 }, .port = 0 } }, // Fake address for Unix sockets
        else => unreachable,
    };

    return .{
        .socket = .{
            .handle = stream.socket.handle,
            .address = std_addr,
        },
    };
}

fn netBindIpImpl(userdata: ?*anyopaque, address: *const std.Io.net.IpAddress, options: std.Io.net.IpAddress.BindOptions) std.Io.net.IpAddress.BindError!std.Io.net.Socket {
    _ = options; // No options used in zio yet
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    const zio_addr = stdIoIpToZio(address.*);
    const socket = zio_net.netBindIp(rt, zio_addr) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return error.Unexpected,
    };
    return .{
        .handle = socket.handle,
        .address = zioIpToStdIo(socket.address.ip),
    };
}

fn netConnectIpImpl(userdata: ?*anyopaque, address: *const std.Io.net.IpAddress, options: std.Io.net.IpAddress.ConnectOptions) std.Io.net.IpAddress.ConnectError!std.Io.net.Stream {
    _ = options; // No options used in zio yet
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    const zio_addr = stdIoIpToZio(address.*);
    const stream = zio_net.netConnectIp(rt, zio_addr) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return error.Unexpected,
    };
    return .{
        .socket = .{
            .handle = stream.socket.handle,
            .address = zioIpToStdIo(stream.socket.address.ip),
        },
    };
}

fn netListenUnixImpl(userdata: ?*anyopaque, address: *const std.Io.net.UnixAddress, options: std.Io.net.UnixAddress.ListenOptions) std.Io.net.UnixAddress.ListenError!std.Io.net.Socket.Handle {
    if (!zio_net.has_unix_sockets) return error.AddressFamilyUnsupported;
    const rt: *Runtime = @ptrCast(@alignCast(userdata));

    // Convert std.Io.net.UnixAddress (path) to zio UnixAddress (sockaddr)
    const zio_addr = zio_net.UnixAddress.init(address.path) catch {
        // NameTooLong isn't in the error set, so treat as Unexpected
        return error.Unexpected;
    };
    const zio_options: zio_net.UnixAddress.ListenOptions = .{
        .kernel_backlog = options.kernel_backlog,
    };

    const server = zio_net.netListenUnix(rt, zio_addr, zio_options) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.AddressInUse => return error.AddressInUse,
        error.SystemResources => return error.SystemResources,
        error.SymLinkLoop => return error.SymLinkLoop,
        error.FileNotFound => return error.FileNotFound,
        error.NotDir => return error.NotDir,
        error.ReadOnlyFileSystem => return error.ReadOnlyFileSystem,
        else => return error.Unexpected,
    };

    return server.socket.handle;
}

fn netConnectUnixImpl(userdata: ?*anyopaque, address: *const std.Io.net.UnixAddress) std.Io.net.UnixAddress.ConnectError!std.Io.net.Socket.Handle {
    if (!zio_net.has_unix_sockets) return error.AddressFamilyUnsupported;
    const rt: *Runtime = @ptrCast(@alignCast(userdata));

    // Convert std.Io.net.UnixAddress (path) to zio UnixAddress (sockaddr)
    const zio_addr = zio_net.UnixAddress.init(address.path) catch {
        // NameTooLong isn't in the error set, so treat as Unexpected
        return error.Unexpected;
    };

    const stream = zio_net.netConnectUnix(rt, zio_addr) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.SystemResources => return error.SystemResources,
        // Map any other error to Unexpected
        else => return error.Unexpected,
    };

    return stream.socket.handle;
}

fn netSendImpl(userdata: ?*anyopaque, handle: std.Io.net.Socket.Handle, messages: []std.Io.net.OutgoingMessage, flags: std.Io.net.SendFlags) struct { ?std.Io.net.Socket.SendError, usize } {
    _ = userdata;
    _ = handle;
    _ = messages;
    _ = flags;
    @panic("TODO");
}

fn netReceiveImpl(userdata: ?*anyopaque, handle: std.Io.net.Socket.Handle, message_buffer: []std.Io.net.IncomingMessage, data_buffer: []u8, flags: std.Io.net.ReceiveFlags, timeout: std.Io.Timeout) struct { ?std.Io.net.Socket.ReceiveTimeoutError, usize } {
    _ = userdata;
    _ = handle;
    _ = message_buffer;
    _ = data_buffer;
    _ = flags;
    _ = timeout;
    @panic("TODO");
}

fn netReadImpl(userdata: ?*anyopaque, src: std.Io.net.Socket.Handle, data: [][]u8) std.Io.net.Stream.Reader.Error!usize {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    return zio_net.netRead(rt, src, data) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return error.Unexpected,
    };
}

fn netWriteImpl(userdata: ?*anyopaque, dest: std.Io.net.Socket.Handle, header: []const u8, data: []const []const u8, splat: usize) std.Io.net.Stream.Writer.Error!usize {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    return zio_net.netWrite(rt, dest, header, data, splat) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return error.Unexpected,
    };
}

fn netCloseImpl(userdata: ?*anyopaque, handle: std.Io.net.Socket.Handle) void {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    zio_net.netClose(rt, handle);
}

fn netInterfaceNameResolveImpl(userdata: ?*anyopaque, name: *const std.Io.net.Interface.Name) std.Io.net.Interface.Name.ResolveError!std.Io.net.Interface {
    _ = userdata;
    _ = name;
    @panic("TODO");
}

fn netInterfaceNameImpl(userdata: ?*anyopaque, interface: std.Io.net.Interface) std.Io.net.Interface.NameError!std.Io.net.Interface.Name {
    _ = userdata;
    _ = interface;
    @panic("TODO");
}

fn netLookupImpl(userdata: ?*anyopaque, hostname: std.Io.net.HostName, queue: *std.Io.Queue(std.Io.net.HostName.LookupResult), options: std.Io.net.HostName.LookupOptions) void {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    const io = fromRuntime(rt);

    // Call the zio DNS lookup (uses thread pool internally)
    var iter = zio_net.lookupHost(rt, hostname.bytes, options.port) catch |err| {
        const mapped_err: std.Io.net.HostName.LookupError = switch (err) {
            error.UnknownHostName => error.UnknownHostName,
            error.NameServerFailure => error.NameServerFailure,
            error.HostLacksNetworkAddresses => error.UnknownHostName,
            error.TemporaryNameServerFailure => error.NameServerFailure,
            else => error.NameServerFailure,
        };
        queue.putOneUncancelable(io, .{ .end = mapped_err });
        return;
    };
    defer iter.deinit();

    // Push canonical name first (use the original hostname)
    @memcpy(options.canonical_name_buffer[0..hostname.bytes.len], hostname.bytes);
    const canonical_name = std.Io.net.HostName{
        .bytes = options.canonical_name_buffer[0..hostname.bytes.len],
    };
    queue.putOneUncancelable(io, .{ .canonical_name = canonical_name });

    // Iterate through resolved addresses
    while (iter.next()) |zio_addr| {
        // Filter by address family if specified
        if (options.family) |requested_family| {
            const addr_family: std.Io.net.IpAddress.Family = switch (zio_addr.any.family) {
                std.posix.AF.INET => .ip4,
                std.posix.AF.INET6 => .ip6,
                else => continue,
            };
            if (addr_family != requested_family) continue;
        }

        // Convert zio IpAddress to std.Io.net.IpAddress
        const std_addr = zioIpToStdIo(zio_addr);
        queue.putOneUncancelable(io, .{ .address = std_addr });
    }

    // Push end marker
    queue.putOneUncancelable(io, .{ .end = {} });
}

pub const vtable = std.Io.VTable{
    .async = asyncImpl,
    .concurrent = concurrentImpl,
    .await = awaitImpl,
    .cancel = cancelImpl,
    .cancelRequested = cancelRequestedImpl,
    .groupAsync = groupAsyncImpl,
    .groupConcurrent = groupConcurrentImpl,
    .groupWait = groupWaitImpl,
    .groupCancel = groupCancelImpl,
    .select = selectImpl,
    .mutexLock = mutexLockImpl,
    .mutexLockUncancelable = mutexLockUncancelableImpl,
    .mutexUnlock = mutexUnlockImpl,
    .conditionWait = conditionWaitImpl,
    .conditionWaitUncancelable = conditionWaitUncancelableImpl,
    .conditionWake = conditionWakeImpl,
    .dirMake = dirMakeImpl,
    .dirMakePath = dirMakePathImpl,
    .dirMakeOpenPath = dirMakeOpenPathImpl,
    .dirStat = dirStatImpl,
    .dirStatPath = dirStatPathImpl,
    .dirAccess = dirAccessImpl,
    .dirCreateFile = dirCreateFileImpl,
    .dirOpenFile = dirOpenFileImpl,
    .dirOpenDir = dirOpenDirImpl,
    .dirClose = dirCloseImpl,
    .fileStat = fileStatImpl,
    .fileClose = fileCloseImpl,
    .fileWriteStreaming = fileWriteStreamingImpl,
    .fileWritePositional = fileWritePositionalImpl,
    .fileReadStreaming = fileReadStreamingImpl,
    .fileReadPositional = fileReadPositionalImpl,
    .fileSeekBy = fileSeekByImpl,
    .fileSeekTo = fileSeekToImpl,
    .openSelfExe = openSelfExeImpl,
    .now = nowImpl,
    .sleep = sleepImpl,
    .netListenIp = netListenIpImpl,
    .netAccept = netAcceptImpl,
    .netBindIp = netBindIpImpl,
    .netConnectIp = netConnectIpImpl,
    .netListenUnix = netListenUnixImpl,
    .netConnectUnix = netConnectUnixImpl,
    .netSend = netSendImpl,
    .netReceive = netReceiveImpl,
    .netRead = netReadImpl,
    .netWrite = netWriteImpl,
    .netClose = netCloseImpl,
    .netInterfaceNameResolve = netInterfaceNameResolveImpl,
    .netInterfaceName = netInterfaceNameImpl,
    .netLookup = netLookupImpl,
};

pub fn fromRuntime(rt: *Runtime) std.Io {
    return std.Io{
        .userdata = @ptrCast(rt),
        .vtable = &vtable,
    };
}

pub fn toRuntime(io: std.Io) *Runtime {
    return @ptrCast(@alignCast(io.userdata));
}

test "Io: basic" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const io = fromRuntime(rt);
    try std.testing.expect(io.vtable == &vtable);
}

test "Io: async/await pattern" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const TestContext = struct {
        fn computeValue(x: i32) i32 {
            return x * 2 + 10;
        }

        fn mainTask(io: std.Io) !void {
            // Create async future
            var future = io.async(computeValue, .{21});
            defer _ = future.cancel(io);

            // Await the result
            const result = future.await(io);
            try std.testing.expectEqual(52, result);
        }
    };

    try rt.runUntilComplete(TestContext.mainTask, .{rt.io()}, .{});
}

test "Io: concurrent/await pattern" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const TestContext = struct {
        fn computeValue(x: i32) i32 {
            return x * 2 + 10;
        }

        fn mainTask(io: std.Io) !void {
            // Create concurrent future (guaranteed async)
            var future = try io.concurrent(computeValue, .{21});
            defer _ = future.cancel(io);

            // Await the result
            const result = future.await(io);
            try std.testing.expectEqual(52, result);
        }
    };

    try rt.runUntilComplete(TestContext.mainTask, .{rt.io()}, .{});
}

test "Io: now and sleep" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const TestContext = struct {
        fn mainTask(io: std.Io) !void {
            // Get current time
            const t1 = try std.Io.Clock.now(.awake, io);

            // Sleep for 10ms
            try io.sleep(.{ .nanoseconds = 10 * std.time.ns_per_ms }, .awake);

            // Get time after sleep
            const t2 = try std.Io.Clock.now(.awake, io);

            // Verify time moved forward
            const elapsed = t1.durationTo(t2);
            try std.testing.expect(elapsed.nanoseconds >= 10 * std.time.ns_per_ms);
        }
    };

    try rt.runUntilComplete(TestContext.mainTask, .{rt.io()}, .{});
}

test "Io: TCP listen/accept/connect/read/write IPv4" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const TestContext = struct {
        fn mainTask(io: std.Io) !void {
            const addr = std.Io.net.IpAddress{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = 0 } };
            var server = try addr.listen(io, .{});
            defer server.socket.close(io);

            var server_future = try io.concurrent(serverFn, .{ io, &server });
            defer server_future.cancel(io) catch {};

            var client_future = try io.concurrent(clientFn, .{ io, server });
            defer client_future.cancel(io) catch {};

            try server_future.await(io);
            try client_future.await(io);
        }

        fn serverFn(io: std.Io, server: *std.Io.net.Server) !void {
            const stream = try server.accept(io);
            defer stream.close(io);

            var buf: [32]u8 = undefined;
            var reader = stream.reader(io, &buf);
            const line = try reader.interface.takeDelimiterExclusive('\n');
            try std.testing.expectEqualStrings("hello", line);
        }

        fn clientFn(io: std.Io, server: std.Io.net.Server) !void {
            const stream = try server.socket.address.connect(io, .{ .mode = .stream });
            defer stream.close(io);

            var write_buf: [32]u8 = undefined;
            var writer = stream.writer(io, &write_buf);
            try writer.interface.writeAll("hello\n");
            try writer.interface.flush();
        }
    };

    try rt.runUntilComplete(TestContext.mainTask, .{rt.io()}, .{});
}

test "Io: TCP listen/accept/connect/read/write IPv6" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const TestContext = struct {
        fn mainTask(io: std.Io) !void {
            const addr = std.Io.net.IpAddress{
                .ip6 = .{
                    .bytes = .{0} ** 15 ++ .{1}, // ::1
                    .port = 0,
                },
            };
            var server = addr.listen(io, .{}) catch |err| {
                if (err == error.AddressNotAvailable) return error.SkipZigTest;
                return err;
            };
            defer server.socket.close(io);

            var server_future = try io.concurrent(serverFn, .{ io, &server });
            defer server_future.cancel(io) catch {};

            var client_future = try io.concurrent(clientFn, .{ io, server });
            defer client_future.cancel(io) catch {};

            try server_future.await(io);
            try client_future.await(io);
        }

        fn serverFn(io: std.Io, server: *std.Io.net.Server) !void {
            const stream = try server.accept(io);
            defer stream.close(io);

            var buf: [32]u8 = undefined;
            var reader = stream.reader(io, &buf);
            const line = try reader.interface.takeDelimiterExclusive('\n');
            try std.testing.expectEqualStrings("hello", line);
        }

        fn clientFn(io: std.Io, server: std.Io.net.Server) !void {
            const stream = try server.socket.address.connect(io, .{ .mode = .stream });
            defer stream.close(io);

            var write_buf: [32]u8 = undefined;
            var writer = stream.writer(io, &write_buf);
            try writer.interface.writeAll("hello\n");
            try writer.interface.flush();
        }
    };

    try rt.runUntilComplete(TestContext.mainTask, .{rt.io()}, .{});
}

test "Io: UDP bind IPv4" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const TestContext = struct {
        fn mainTask(io: std.Io) !void {
            const addr = std.Io.net.IpAddress{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = 0 } };
            const socket = try addr.bind(io, .{ .mode = .dgram });
            defer socket.close(io);

            // Verify we got a valid address with ephemeral port
            try std.testing.expect(socket.address.ip4.port != 0);
        }
    };

    try rt.runUntilComplete(TestContext.mainTask, .{rt.io()}, .{});
}

test "Io: UDP bind IPv6" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const TestContext = struct {
        fn mainTask(io: std.Io) !void {
            const addr = std.Io.net.IpAddress{
                .ip6 = .{
                    .bytes = .{0} ** 15 ++ .{1}, // ::1
                    .port = 0,
                },
            };
            const socket = addr.bind(io, .{ .mode = .dgram }) catch |err| {
                if (err == error.AddressNotAvailable) return error.SkipZigTest;
                return err;
            };
            defer socket.close(io);

            // Verify we got a valid address with ephemeral port
            try std.testing.expect(socket.address.ip6.port != 0);
        }
    };

    try rt.runUntilComplete(TestContext.mainTask, .{rt.io()}, .{});
}

test "Io: Mutex lock/unlock" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const TestContext = struct {
        fn mainTask(io: std.Io) !void {
            var mutex: std.Io.Mutex = .init;
            var shared_counter: u32 = 0;

            // Lock and increment counter
            try mutex.lock(io);
            shared_counter += 1;
            mutex.unlock(io);

            try std.testing.expectEqual(@as(u32, 1), shared_counter);

            // Test tryLock
            try std.testing.expect(mutex.tryLock());
            shared_counter += 1;
            mutex.unlock(io);

            try std.testing.expectEqual(@as(u32, 2), shared_counter);
        }
    };

    try rt.runUntilComplete(TestContext.mainTask, .{rt.io()}, .{});
}

test "Io: Mutex concurrent access" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const TestContext = struct {
        fn mainTask(io: std.Io) !void {
            var mutex: std.Io.Mutex = .init;
            var shared_counter: u32 = 0;

            var future1 = try io.concurrent(incrementTask, .{ io, &mutex, &shared_counter });
            defer future1.cancel(io) catch {};

            var future2 = try io.concurrent(incrementTask, .{ io, &mutex, &shared_counter });
            defer future2.cancel(io) catch {};

            try future1.await(io);
            try future2.await(io);

            try std.testing.expectEqual(@as(u32, 200), shared_counter);
        }

        fn incrementTask(io: std.Io, mutex: *std.Io.Mutex, counter: *u32) !void {
            for (0..100) |_| {
                try mutex.lock(io);
                defer mutex.unlock(io);
                counter.* += 1;
            }
        }
    };

    try rt.runUntilComplete(TestContext.mainTask, .{rt.io()}, .{});
}

test "Io: Condition wait/signal" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const TestContext = struct {
        fn mainTask(io: std.Io) !void {
            var mutex: std.Io.Mutex = .init;
            var condition: std.Io.Condition = .{};
            var ready = false;

            var waiter_future = try io.concurrent(waiterTask, .{ io, &mutex, &condition, &ready });
            defer waiter_future.cancel(io) catch {};

            var signaler_future = try io.concurrent(signalerTask, .{ io, &mutex, &condition, &ready });
            defer signaler_future.cancel(io) catch {};

            try waiter_future.await(io);
            try signaler_future.await(io);

            try std.testing.expect(ready);
        }

        fn waiterTask(io: std.Io, mutex: *std.Io.Mutex, condition: *std.Io.Condition, ready_flag: *bool) !void {
            try mutex.lock(io);
            defer mutex.unlock(io);

            while (!ready_flag.*) {
                try condition.wait(io, mutex);
            }
        }

        fn signalerTask(io: std.Io, mutex: *std.Io.Mutex, condition: *std.Io.Condition, ready_flag: *bool) !void {
            // Give waiter time to start waiting
            try io.sleep(.{ .nanoseconds = 10 * std.time.ns_per_ms }, .awake);

            try mutex.lock(io);
            ready_flag.* = true;
            mutex.unlock(io);

            condition.signal(io);
        }
    };

    try rt.runUntilComplete(TestContext.mainTask, .{rt.io()}, .{});
}

test "Io: Condition broadcast" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const TestContext = struct {
        fn mainTask(io: std.Io) !void {
            var mutex: std.Io.Mutex = .init;
            var condition: std.Io.Condition = .{};
            var ready = false;
            var count = std.atomic.Value(u32).init(0);

            var waiter1 = try io.concurrent(waiterTask, .{ io, &mutex, &condition, &ready, &count });
            defer waiter1.cancel(io) catch {};

            var waiter2 = try io.concurrent(waiterTask, .{ io, &mutex, &condition, &ready, &count });
            defer waiter2.cancel(io) catch {};

            var waiter3 = try io.concurrent(waiterTask, .{ io, &mutex, &condition, &ready, &count });
            defer waiter3.cancel(io) catch {};

            // Give waiters time to start waiting
            try io.sleep(.{ .nanoseconds = 10 * std.time.ns_per_ms }, .awake);

            try mutex.lock(io);
            ready = true;
            mutex.unlock(io);

            condition.broadcast(io);

            try waiter1.await(io);
            try waiter2.await(io);
            try waiter3.await(io);

            try std.testing.expectEqual(@as(u32, 3), count.load(.monotonic));
        }

        fn waiterTask(io: std.Io, mutex: *std.Io.Mutex, condition: *std.Io.Condition, ready_flag: *bool, counter: *std.atomic.Value(u32)) !void {
            try mutex.lock(io);
            defer mutex.unlock(io);

            while (!ready_flag.*) {
                try condition.wait(io, mutex);
            }

            _ = counter.fetchAdd(1, .monotonic);
        }
    };

    try rt.runUntilComplete(TestContext.mainTask, .{rt.io()}, .{});
}

test "Io: Unix domain socket listen/accept/connect/read/write" {
    if (!zio_net.has_unix_sockets) return error.SkipZigTest;

    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const TestContext = struct {
        fn mainTask(io: std.Io) !void {
            // Create a temporary path for the socket
            var tmp_dir = std.testing.tmpDir(.{});
            defer tmp_dir.cleanup();

            var path_buf1: [std.fs.max_path_bytes]u8 = undefined;
            var path_buf2: [std.fs.max_path_bytes]u8 = undefined;
            const socket_path = try tmp_dir.dir.realpath(".", &path_buf1);
            const full_path = try std.fmt.bufPrint(&path_buf2, "{s}/test.sock", .{socket_path});

            const addr = try std.Io.net.UnixAddress.init(full_path);
            var server = try addr.listen(io, .{});
            defer server.deinit(io);

            var server_future = try io.concurrent(serverFn, .{ io, &server });
            defer server_future.cancel(io) catch {};

            var client_future = try io.concurrent(clientFn, .{ io, addr });
            defer client_future.cancel(io) catch {};

            try server_future.await(io);
            try client_future.await(io);
        }

        fn serverFn(io: std.Io, server: *std.Io.net.Server) !void {
            const stream = try server.accept(io);
            defer stream.close(io);

            var buf: [32]u8 = undefined;
            var reader = stream.reader(io, &buf);
            const line = try reader.interface.takeDelimiterExclusive('\n');
            try std.testing.expectEqualStrings("hello unix", line);
        }

        fn clientFn(io: std.Io, addr: std.Io.net.UnixAddress) !void {
            const stream = try addr.connect(io);
            defer stream.close(io);

            var write_buf: [32]u8 = undefined;
            var writer = stream.writer(io, &write_buf);
            try writer.interface.writeAll("hello unix\n");
            try writer.interface.flush();
        }
    };

    try rt.runUntilComplete(TestContext.mainTask, .{rt.io()}, .{});
}

test "Io: File close" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const TestContext = struct {
        fn mainTask(io: std.Io) !void {
            const file_path = "test_stdio_file_close.txt";
            defer std.fs.cwd().deleteFile(file_path) catch {};

            // Create file using std.fs
            const std_file = try std.fs.cwd().createFile(file_path, .{});
            const file: std.Io.File = .{ .handle = std_file.handle };

            // Test that close works
            file.close(io);
        }
    };

    try rt.runUntilComplete(TestContext.mainTask, .{rt.io()}, .{});
}

test "Io: DNS lookup localhost" {
    const rt = try Runtime.init(std.testing.allocator, .{ .thread_pool = .{} });
    defer rt.deinit();

    const TestContext = struct {
        fn mainTask(io: std.Io) !void {
            const hostname = try std.Io.net.HostName.init("localhost");

            var canonical_name_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
            var lookup_buffer: [32]std.Io.net.HostName.LookupResult = undefined;
            var lookup_queue: std.Io.Queue(std.Io.net.HostName.LookupResult) = .init(&lookup_buffer);

            hostname.lookup(io, &lookup_queue, .{
                .port = 80,
                .canonical_name_buffer = &canonical_name_buffer,
            });

            var saw_canonical_name = false;
            var address_count: usize = 0;

            while (lookup_queue.getOne(io)) |result| {
                switch (result) {
                    .address => |_| {
                        address_count += 1;
                    },
                    .canonical_name => |_| {
                        saw_canonical_name = true;
                    },
                    .end => |end_result| {
                        try end_result;
                        break;
                    },
                }
            } else |err| switch (err) {
                error.Canceled => return err,
            }

            try std.testing.expect(saw_canonical_name);
            try std.testing.expect(address_count > 0);
        }
    };

    try rt.runUntilComplete(TestContext.mainTask, .{rt.io()}, .{});
}

test "Io: DNS lookup numeric IP" {
    const rt = try Runtime.init(std.testing.allocator, .{ .thread_pool = .{} });
    defer rt.deinit();

    const TestContext = struct {
        fn mainTask(io: std.Io) !void {
            const hostname = try std.Io.net.HostName.init("127.0.0.1");

            var canonical_name_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
            var lookup_buffer: [32]std.Io.net.HostName.LookupResult = undefined;
            var lookup_queue: std.Io.Queue(std.Io.net.HostName.LookupResult) = .init(&lookup_buffer);

            hostname.lookup(io, &lookup_queue, .{
                .port = 8080,
                .canonical_name_buffer = &canonical_name_buffer,
            });

            var saw_canonical_name = false;
            var address_count: usize = 0;
            var found_correct_port = false;

            while (lookup_queue.getOne(io)) |result| {
                switch (result) {
                    .address => |addr| {
                        address_count += 1;
                        if (addr.ip4.port == 8080) {
                            found_correct_port = true;
                        }
                    },
                    .canonical_name => |_| {
                        saw_canonical_name = true;
                    },
                    .end => |end_result| {
                        try end_result;
                        break;
                    },
                }
            } else |err| switch (err) {
                error.Canceled => return err,
            }

            try std.testing.expect(saw_canonical_name);
            try std.testing.expectEqual(@as(usize, 1), address_count);
            try std.testing.expect(found_correct_port);
        }
    };

    try rt.runUntilComplete(TestContext.mainTask, .{rt.io()}, .{});
}

test "Io: DNS lookup with family filter" {
    const rt = try Runtime.init(std.testing.allocator, .{ .thread_pool = .{} });
    defer rt.deinit();

    const TestContext = struct {
        fn mainTask(io: std.Io) !void {
            const hostname = try std.Io.net.HostName.init("localhost");

            var canonical_name_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
            var lookup_buffer: [32]std.Io.net.HostName.LookupResult = undefined;
            var lookup_queue: std.Io.Queue(std.Io.net.HostName.LookupResult) = .init(&lookup_buffer);

            hostname.lookup(io, &lookup_queue, .{
                .port = 80,
                .canonical_name_buffer = &canonical_name_buffer,
                .family = .ip4,
            });

            var address_count: usize = 0;

            while (lookup_queue.getOne(io)) |result| {
                switch (result) {
                    .address => |addr| {
                        address_count += 1;
                        // Verify it's IPv4
                        try std.testing.expect(addr == .ip4);
                    },
                    .canonical_name => {},
                    .end => |end_result| {
                        try end_result;
                        break;
                    },
                }
            } else |err| switch (err) {
                error.Canceled => return err,
            }

            try std.testing.expect(address_count > 0);
        }
    };

    try rt.runUntilComplete(TestContext.mainTask, .{rt.io()}, .{});
}
