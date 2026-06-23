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
const common = @import("common.zig");
const Cancelable = common.Cancelable;
const blockInPlace = common.blockInPlace;
const getCurrentExecutorOrNull = runtime.getCurrentExecutorOrNull;

/// Per-executor non-cryptographic CSPRNG. Owned by `Executor`, seeded once at
/// startup from a secure source. Fills are synchronous and perform no syscalls.
/// The seed must come from a cryptographically secure source.
pub const Csprng = struct {
    rng: std.Random.DefaultCsprng,

    /// Length of the seed expected by `init`.
    pub const seed_len = std.Random.DefaultCsprng.secret_seed_length;

    pub fn init(seed: [seed_len]u8) Csprng {
        return .{ .rng = .init(seed) };
    }

    /// Fill `buffer` with random bytes. Never blocks; performs no syscalls.
    pub fn fill(self: *Csprng, buffer: []u8) void {
        self.rng.fill(buffer);
    }
};

/// Fill `buffer` with non-cryptographic random bytes from the current
/// executor's CSPRNG. Fast, never blocks, performs no syscalls; the CSPRNG is
/// seeded once at executor startup. When called outside any executor, falls
/// back to the secure syscall directly (best effort: zeros the buffer if
/// entropy is unavailable).
///
/// For cryptographically secure entropy, use `randomSecure` instead.
pub fn random(buffer: []u8) void {
    if (getCurrentExecutorOrNull()) |exec| {
        exec.csprng.fill(buffer);
    } else {
        os.getrandom(buffer) catch @memset(buffer, 0);
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
