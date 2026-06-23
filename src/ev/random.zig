// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

//! Per-loop non-cryptographic CSPRNG.
//!
//! Owned by `Loop` and seeded once at `Loop.init`. Fills are synchronous and
//! never touch the completion queue — this lives in the ev layer only so the
//! RNG state has a natural per-loop (and therefore per-thread, lock-free) home,
//! not because it performs any I/O. The seed must come from a cryptographically
//! secure source; the ev layer takes it as an opaque input and leaves the
//! seeding policy to the caller.

const std = @import("std");

pub const Random = struct {
    rng: std.Random.DefaultCsprng,

    /// Length of the seed expected by `init`.
    pub const seed_len = std.Random.DefaultCsprng.secret_seed_length;

    pub fn init(seed: [seed_len]u8) Random {
        return .{ .rng = .init(seed) };
    }

    /// Fill `buffer` with random bytes. Never blocks; performs no syscalls.
    pub fn fill(self: *Random, buffer: []u8) void {
        self.rng.fill(buffer);
    }
};
