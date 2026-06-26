// TCP benchmark: ping-pong (request/response) or one-directional streaming.
//
//   zig build examples -Dexample=tcp-pingpong-bench -Doptimize=ReleaseFast \
//       -Dbackend=epoll -- [count] [msg_bytes] [executors] [conns] [mode]
//
// mode: "pingpong" (default) or "stream".
//   pingpong: `conns` pairs each round-trip a `msg`-byte message `count` times.
//   stream:   `conns` clients each send `count` chunks of `msg` bytes one way to
//             a draining server (no reply); measures bulk throughput. This is the
//             case that stresses the deferred-send path (a send-heavy producer).
//
const std = @import("std");
const zio = @import("zio");

pub const std_options_debug_io = zio.debug_io;

const max_msg = 256 * 1024;

const Mode = enum { pingpong, stream };

const Config = struct {
    count: usize = 64 * 1024,
    msg: usize = 64,
    executors: u8 = 1,
    conns: u32 = 1,
    mode: Mode = .pingpong,
};

const Shared = struct {
    cfg: Config,
    port_ch: *zio.Channel(u16),
    port: std.atomic.Value(u16) = .init(0),
    done: std.atomic.Value(bool) = .init(false),
    errors: std.atomic.Value(u32) = .init(0),
};

fn readExact(stream: zio.net.Stream, buf: []u8) !void {
    var off: usize = 0;
    while (off < buf.len) {
        const n = try stream.read(buf[off..], .none);
        if (n == 0) return error.EndOfStream;
        off += n;
    }
}

// Server side of one connection.
fn handler(stream: zio.net.Stream, sh: *Shared) void {
    defer stream.close();
    var buf: [max_msg]u8 = undefined;
    const msg = sh.cfg.msg;
    switch (sh.cfg.mode) {
        .pingpong => while (true) {
            readExact(stream, buf[0..msg]) catch return; // EOF when client is done
            stream.writeAll(buf[0..msg], .none) catch {
                _ = sh.errors.fetchAdd(1, .monotonic);
                return;
            };
        },
        .stream => while (true) {
            // Drain as fast as possible until the client closes its send side.
            const n = stream.read(&buf, .none) catch {
                _ = sh.errors.fetchAdd(1, .monotonic);
                return;
            };
            if (n == 0) return;
        },
    }
}

fn server(sh: *Shared) void {
    const addr = zio.net.IpAddress.parseIp4("127.0.0.1", 0) catch {
        _ = sh.errors.fetchAdd(1, .monotonic);
        sh.port_ch.send(0) catch {};
        return;
    };
    const srv = addr.listen(.{ .reuse_address = true }) catch {
        _ = sh.errors.fetchAdd(1, .monotonic);
        sh.port_ch.send(0) catch {};
        return;
    };
    defer srv.close();
    sh.port_ch.send(srv.socket.address.ip.getPort()) catch return;

    var handlers: zio.Group = .init;
    defer handlers.wait() catch {};
    while (!sh.done.load(.acquire)) {
        const stream = srv.accept(.{ .timeout = zio.Timeout.fromMilliseconds(50) }) catch |err| {
            if (err == error.Timeout) continue;
            break;
        };
        handlers.spawn(handler, .{ stream, sh }) catch stream.close();
    }
}

// Client side of one connection.
fn client(sh: *Shared) void {
    const port = sh.port.load(.acquire);
    const addr = zio.net.IpAddress.parseIp4("127.0.0.1", port) catch return;
    const stream = addr.connect(.{}) catch {
        _ = sh.errors.fetchAdd(1, .monotonic);
        return;
    };
    defer stream.close();

    var buf: [max_msg]u8 = undefined;
    const msg = sh.cfg.msg;
    for (0..msg) |i| buf[i] = @truncate(i);

    switch (sh.cfg.mode) {
        .pingpong => for (0..sh.cfg.count) |_| {
            stream.writeAll(buf[0..msg], .none) catch {
                _ = sh.errors.fetchAdd(1, .monotonic);
                return;
            };
            readExact(stream, buf[0..msg]) catch {
                _ = sh.errors.fetchAdd(1, .monotonic);
                return;
            };
        },
        .stream => for (0..sh.cfg.count) |_| {
            stream.writeAll(buf[0..msg], .none) catch {
                _ = sh.errors.fetchAdd(1, .monotonic);
                return;
            };
        },
        // The deferred close flushes the kernel send buffer and signals EOF, so
        // the server drains the tail before its handler exits.
    }
}

pub fn main(init: std.process.Init) !void {
    var cfg = Config{};
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len > 1) cfg.count = try std.fmt.parseInt(usize, args[1], 10);
    if (args.len > 2) cfg.msg = try std.fmt.parseInt(usize, args[2], 10);
    if (args.len > 3) cfg.executors = try std.fmt.parseInt(u8, args[3], 10);
    if (args.len > 4) cfg.conns = try std.fmt.parseInt(u32, args[4], 10);
    if (args.len > 5) {
        if (std.mem.eql(u8, args[5], "pingpong")) {
            cfg.mode = .pingpong;
        } else if (std.mem.eql(u8, args[5], "stream")) {
            cfg.mode = .stream;
        } else {
            return error.BadMode;
        }
    }
    if (cfg.count == 0) return error.BadCount;
    if (cfg.msg == 0 or cfg.msg > max_msg) return error.BadMsgSize;
    if (cfg.conns == 0) return error.BadConns;

    const rt = try zio.Runtime.init(init.gpa, .{ .executors = .exact(cfg.executors) });
    defer rt.deinit();

    var port_buf: [1]u16 = undefined;
    var port_ch = zio.Channel(u16).init(&port_buf);
    var sh = Shared{ .cfg = cfg, .port_ch = &port_ch };

    var server_group: zio.Group = .init;
    try server_group.spawn(server, .{&sh});
    defer {
        sh.done.store(true, .release);
        server_group.wait() catch {};
    }

    const port = try port_ch.receive();
    if (port == 0) return error.BenchFailed;
    sh.port.store(port, .release);

    var sw = zio.time.Stopwatch.start();
    var clients: zio.Group = .init;
    var i: u32 = 0;
    while (i < cfg.conns) : (i += 1) try clients.spawn(client, .{&sh});
    try clients.wait();
    const ns: u64 = @intCast(sw.read().toNanoseconds());

    if (sh.errors.load(.monotonic) != 0) {
        std.debug.print("benchmark FAILED ({d} errors)\n", .{sh.errors.load(.monotonic)});
        return error.BenchFailed;
    }

    const secs: f64 = @as(f64, @floatFromInt(ns)) / std.time.ns_per_s;
    switch (cfg.mode) {
        .pingpong => {
            const total_rt: f64 = @floatFromInt(@as(u64, cfg.conns) * cfg.count);
            std.debug.print(
                "pingpong  msg={d}B  count={d}  executors={d}  conns={d}  {d:.3}s  {d:.0} req/s  {d:.3} us/round-trip\n",
                .{ cfg.msg, cfg.count, cfg.executors, cfg.conns, secs, total_rt / secs, (@as(f64, @floatFromInt(ns)) / std.time.ns_per_us) / total_rt },
            );
        },
        .stream => {
            const total_bytes: f64 = @floatFromInt(@as(u64, cfg.conns) * cfg.count * cfg.msg);
            const gbps = (total_bytes / secs) / (1024.0 * 1024.0 * 1024.0);
            std.debug.print(
                "stream    chunk={d}B  chunks={d}  executors={d}  conns={d}  {d:.3}s  {d:.2} GiB/s  {d:.0} MB/s\n",
                .{ cfg.msg, cfg.count, cfg.executors, cfg.conns, secs, gbps, (total_bytes / secs) / 1_000_000.0 },
            );
        },
    }
}
