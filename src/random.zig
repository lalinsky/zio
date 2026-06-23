// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

//! Random number generation.
//!
//! Two primitives, aligned with the `std.Io` interface:
//!
//! * `random` — fast, non-cryptographic bytes from a per-executor CSPRNG that
//!   is seeded once at executor startup and then fills with no syscalls. The
//!   CSPRNG is purely an async-path optimization; outside an executor it falls
//!   back to the secure syscall.
//! * `randomSecure` — cryptographically secure entropy obtained fresh from the
//!   OS on every call. The blocking syscall is delegated to a thread-pool
//!   worker so the event loop is never stalled.

const std = @import("std");

const os = @import("os/root.zig");
const runtime = @import("runtime.zig");
const time = @import("time.zig");
const common = @import("common.zig");
const Cancelable = common.Cancelable;
const blockInPlace = common.blockInPlace;
const getCurrentExecutorOrNull = runtime.getCurrentExecutorOrNull;

/// Fill `buffer` with non-cryptographic random bytes from the current
/// executor's CSPRNG (a `std.Random.DefaultCsprng` seeded once at executor
/// startup). Fast, never blocks, performs no syscalls.
///
/// Outside an executor there is no seeded CSPRNG, so we read the OS directly;
/// if that somehow fails we fall back to an ad-hoc PRNG seeded from the
/// monotonic clock (always available) so we never hand back predictable zeros.
///
/// For cryptographically secure entropy, use `randomSecure` instead.
pub fn random(buffer: []u8) void {
    if (getCurrentExecutorOrNull()) |exec| {
        exec.csprng.fill(buffer);
    } else {
        os.getrandom(buffer) catch {
            const seed = time.Timestamp.now(.monotonic).toNanoseconds();
            var prng = std.Random.DefaultPrng.init(seed);
            prng.fill(buffer);
        };
    }
}

pub const RandomSecureError = error{EntropyUnavailable} || Cancelable;

/// Fill `buffer` with cryptographically secure entropy obtained fresh from the
/// OS on every call. Unlike `random`, this never relies on cached process
/// state. The blocking syscall is delegated to a thread-pool worker so the
/// event loop is not blocked; when called outside a task it runs inline.
///
/// Future per-backend optimizations can skip the thread pool entirely: async
/// reads from /dev/urandom on io_uring, and \Device\CNG via IOCP on Windows.
pub fn randomSecure(buffer: []u8) RandomSecureError!void {
    // Result lives on our stack, defaulted to Canceled, so that if the work is
    // canceled before it runs we surface cancellation instead of a bogus value.
    var result: RandomSecureError!void = error.Canceled;
    blockInPlace(struct {
        fn run(buf: []u8, out: *RandomSecureError!void) void {
            out.* = os.getrandom(buf);
        }
    }.run, .{ buffer, &result });
    return result;
}

/// The per-executor non-cryptographic CSPRNG type.
pub const Csprng = std.Random.DefaultCsprng;

/// Create a freshly-seeded per-executor CSPRNG from OS entropy. Called by the
/// runtime at executor startup; not part of the public `zio` API. Each executor
/// gets an independent seed so per-thread streams are independent. Fails if the
/// OS cannot provide entropy rather than running with a predictable seed.
pub fn setup() os.GetRandomError!Csprng {
    var seed: [Csprng.secret_seed_length]u8 = undefined;
    try os.getrandom(&seed);
    return Csprng.init(seed);
}

const Runtime = runtime.Runtime;
const spawn = runtime.spawn;

test "random: fills buffer with varying bytes" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var buf: [64]u8 = @splat(0);
    random(&buf);
    // Probabilistically asserts we actually filled the buffer.
    var nonzero: usize = 0;
    for (buf) |b| if (b != 0) {
        nonzero += 1;
    };
    try std.testing.expect(nonzero > 32);
}

test "random: successive calls produce different output" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var a: [64]u8 = undefined;
    var b: [64]u8 = undefined;
    random(&a);
    random(&b);
    try std.testing.expect(!std.mem.eql(u8, &a, &b));
}

test "randomSecure: fills buffer with varying bytes" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var buf: [64]u8 = @splat(0);
    try randomSecure(&buf);
    var nonzero: usize = 0;
    for (buf) |b| if (b != 0) {
        nonzero += 1;
    };
    try std.testing.expect(nonzero > 32);
}

test "randomSecure: works inside a spawned task (thread pool path)" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const Task = struct {
        fn run() anyerror!void {
            var buf: [64]u8 = @splat(0);
            try randomSecure(&buf);
            var nonzero: usize = 0;
            for (buf) |b| if (b != 0) {
                nonzero += 1;
            };
            try std.testing.expect(nonzero > 32);
        }
    };

    var handle = try spawn(Task.run, .{});
    try handle.join();
}
