const std = @import("std");
const Runtime = @import("runtime.zig").Runtime;

fn asyncImpl(userdata: ?*anyopaque, result: []u8, result_alignment: std.mem.Alignment, context: []const u8, context_alignment: std.mem.Alignment, start: *const fn (context: *const anyopaque, result: *anyopaque) void) ?*std.Io.AnyFuture {
    _ = userdata;
    _ = result;
    _ = result_alignment;
    _ = context;
    _ = context_alignment;
    _ = start;
    @panic("TODO");
}

fn concurrentImpl(userdata: ?*anyopaque, result_len: usize, result_alignment: std.mem.Alignment, context: []const u8, context_alignment: std.mem.Alignment, start: *const fn (context: *const anyopaque, result: *anyopaque) void) std.Io.ConcurrentError!*std.Io.AnyFuture {
    _ = userdata;
    _ = result_len;
    _ = result_alignment;
    _ = context;
    _ = context_alignment;
    _ = start;
    @panic("TODO");
}

fn awaitImpl(userdata: ?*anyopaque, any_future: *std.Io.AnyFuture, result: []u8, result_alignment: std.mem.Alignment) void {
    _ = userdata;
    _ = any_future;
    _ = result;
    _ = result_alignment;
    @panic("TODO");
}

fn cancelImpl(userdata: ?*anyopaque, any_future: *std.Io.AnyFuture, result: []u8, result_alignment: std.mem.Alignment) void {
    _ = userdata;
    _ = any_future;
    _ = result;
    _ = result_alignment;
    @panic("TODO");
}

fn cancelRequestedImpl(userdata: ?*anyopaque) bool {
    _ = userdata;
    @panic("TODO");
}

fn groupAsyncImpl(userdata: ?*anyopaque, group: *std.Io.Group, context: []const u8, context_alignment: std.mem.Alignment, start: *const fn (*std.Io.Group, context: *const anyopaque) void) void {
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
    _ = userdata;
    _ = prev_state;
    _ = mutex;
    @panic("TODO");
}

fn mutexLockUncancelableImpl(userdata: ?*anyopaque, prev_state: std.Io.Mutex.State, mutex: *std.Io.Mutex) void {
    _ = userdata;
    _ = prev_state;
    _ = mutex;
    @panic("TODO");
}

fn mutexUnlockImpl(userdata: ?*anyopaque, prev_state: std.Io.Mutex.State, mutex: *std.Io.Mutex) void {
    _ = userdata;
    _ = prev_state;
    _ = mutex;
    @panic("TODO");
}

fn conditionWaitImpl(userdata: ?*anyopaque, cond: *std.Io.Condition, mutex: *std.Io.Mutex) std.Io.Cancelable!void {
    _ = userdata;
    _ = cond;
    _ = mutex;
    @panic("TODO");
}

fn conditionWaitUncancelableImpl(userdata: ?*anyopaque, cond: *std.Io.Condition, mutex: *std.Io.Mutex) void {
    _ = userdata;
    _ = cond;
    _ = mutex;
    @panic("TODO");
}

fn conditionWakeImpl(userdata: ?*anyopaque, cond: *std.Io.Condition, wake: std.Io.Condition.Wake) void {
    _ = userdata;
    _ = cond;
    _ = wake;
    @panic("TODO");
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
    _ = userdata;
    _ = file;
    @panic("TODO");
}

fn fileWriteStreamingImpl(userdata: ?*anyopaque, file: std.Io.File, buffer: [][]const u8) std.Io.File.WriteStreamingError!usize {
    _ = userdata;
    _ = file;
    _ = buffer;
    @panic("TODO");
}

fn fileWritePositionalImpl(userdata: ?*anyopaque, file: std.Io.File, buffer: [][]const u8, offset: u64) std.Io.File.WritePositionalError!usize {
    _ = userdata;
    _ = file;
    _ = buffer;
    _ = offset;
    @panic("TODO");
}

fn fileReadStreamingImpl(userdata: ?*anyopaque, file: std.Io.File, data: [][]u8) std.Io.File.Reader.Error!usize {
    _ = userdata;
    _ = file;
    _ = data;
    @panic("TODO");
}

fn fileReadPositionalImpl(userdata: ?*anyopaque, file: std.Io.File, data: [][]u8, offset: u64) std.Io.File.ReadPositionalError!usize {
    _ = userdata;
    _ = file;
    _ = data;
    _ = offset;
    @panic("TODO");
}

fn fileSeekByImpl(userdata: ?*anyopaque, file: std.Io.File, relative_offset: i64) std.Io.File.SeekError!void {
    _ = userdata;
    _ = file;
    _ = relative_offset;
    @panic("TODO");
}

fn fileSeekToImpl(userdata: ?*anyopaque, file: std.Io.File, absolute_offset: u64) std.Io.File.SeekError!void {
    _ = userdata;
    _ = file;
    _ = absolute_offset;
    @panic("TODO");
}

fn openSelfExeImpl(userdata: ?*anyopaque, flags: std.Io.File.OpenFlags) std.Io.File.OpenSelfExeError!std.Io.File {
    _ = userdata;
    _ = flags;
    @panic("TODO");
}

fn nowImpl(userdata: ?*anyopaque, clock: std.Io.Clock) std.Io.Clock.Error!std.Io.Timestamp {
    _ = userdata;
    _ = clock;
    @panic("TODO");
}

fn sleepImpl(userdata: ?*anyopaque, timeout: std.Io.Timeout) std.Io.SleepError!void {
    _ = userdata;
    _ = timeout;
    @panic("TODO");
}

fn netListenIpImpl(userdata: ?*anyopaque, address: std.Io.net.IpAddress, options: std.Io.net.IpAddress.ListenOptions) std.Io.net.IpAddress.ListenError!std.Io.net.Server {
    _ = userdata;
    _ = address;
    _ = options;
    @panic("TODO");
}

fn netAcceptImpl(userdata: ?*anyopaque, server: std.Io.net.Socket.Handle) std.Io.net.Server.AcceptError!std.Io.net.Stream {
    _ = userdata;
    _ = server;
    @panic("TODO");
}

fn netBindIpImpl(userdata: ?*anyopaque, address: *const std.Io.net.IpAddress, options: std.Io.net.IpAddress.BindOptions) std.Io.net.IpAddress.BindError!std.Io.net.Socket {
    _ = userdata;
    _ = address;
    _ = options;
    @panic("TODO");
}

fn netConnectIpImpl(userdata: ?*anyopaque, address: *const std.Io.net.IpAddress, options: std.Io.net.IpAddress.ConnectOptions) std.Io.net.IpAddress.ConnectError!std.Io.net.Stream {
    _ = userdata;
    _ = address;
    _ = options;
    @panic("TODO");
}

fn netListenUnixImpl(userdata: ?*anyopaque, address: *const std.Io.net.UnixAddress, options: std.Io.net.UnixAddress.ListenOptions) std.Io.net.UnixAddress.ListenError!std.Io.net.Socket.Handle {
    _ = userdata;
    _ = address;
    _ = options;
    @panic("TODO");
}

fn netConnectUnixImpl(userdata: ?*anyopaque, address: *const std.Io.net.UnixAddress) std.Io.net.UnixAddress.ConnectError!std.Io.net.Socket.Handle {
    _ = userdata;
    _ = address;
    @panic("TODO");
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
    _ = userdata;
    _ = src;
    _ = data;
    @panic("TODO");
}

fn netWriteImpl(userdata: ?*anyopaque, dest: std.Io.net.Socket.Handle, header: []const u8, data: []const []const u8, splat: usize) std.Io.net.Stream.Writer.Error!usize {
    _ = userdata;
    _ = dest;
    _ = header;
    _ = data;
    _ = splat;
    @panic("TODO");
}

fn netCloseImpl(userdata: ?*anyopaque, handle: std.Io.net.Socket.Handle) void {
    _ = userdata;
    _ = handle;
    @panic("TODO");
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
    _ = userdata;
    _ = hostname;
    _ = queue;
    _ = options;
    @panic("TODO");
}

pub const vtable = std.Io.VTable{
    .async = asyncImpl,
    .concurrent = concurrentImpl,
    .await = awaitImpl,
    .cancel = cancelImpl,
    .cancelRequested = cancelRequestedImpl,
    .groupAsync = groupAsyncImpl,
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
