// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

//! Compile-time configuration, declared by the root module the way std reads
//! `std_options`:
//!
//! ```zig
//! pub const zio_options: zio.Options = .{ .scheduling = .work_stealing };
//! ```
//!
//! Every zio in a binary sees the same declaration, so libraries depending on
//! zio can never end up with a differently configured, incompatible copy.
//! The `-D` options of zio's own `build.zig` only supply the defaults, for its
//! test and example builds.

const std = @import("std");
const builtin = @import("builtin");
const root = @import("root");
const build_options = @import("zio_build_options");

/// How tasks are scheduled onto executors.
pub const Scheduling = enum {
    /// One executor. `RuntimeOptions.executors` always resolves to one. Forced
    /// in `-fsingle-threaded` builds.
    ///
    /// This is about executors, not threads: the blocking thread pool still
    /// exists and foreign threads can still wake tasks.
    single_executor,
    /// Many executors, and a task stays on the one it was spawned on.
    pinned,
    /// Many executors, and idle ones steal work from busy ones.
    work_stealing,

    /// Whether more than one executor can exist.
    pub fn multiExecutor(self: Scheduling) bool {
        return self != .single_executor;
    }

    /// Whether a task can move between executors after it starts running.
    pub fn migrates(self: Scheduling) bool {
        return self == .work_stealing;
    }
};

/// Event loop backend.
pub const BackendType = enum { poll, linux, epoll, kqueue, io_uring, iocp };

/// How to handle `resolve_beneath` on platforms without kernel support.
pub const ResolveBeneathMode = enum {
    /// Fail with `error.Unsupported`.
    strict,
    /// Log a warning and continue.
    best_effort,
};

pub const Options = struct {
    /// Defaults to `.single_executor`.
    scheduling: Scheduling = buildEnum(Scheduling, build_options.scheduling),
    /// Event loop backend. Null picks the best one for the target.
    backend: ?BackendType = if (build_options.backend) |name| buildEnum(BackendType, name) else null,
    resolve_beneath_mode: ResolveBeneathMode = buildEnum(ResolveBeneathMode, build_options.resolve_beneath_mode),
    /// Avoid unsafe performance tricks (bool smuggling, etc.).
    no_hacks: bool = build_options.no_hacks,
    /// Count scheduler events (parks, steals, wake batches) in per-executor
    /// counters readable via `Runtime.schedulerMetrics`.
    scheduler_metrics: bool = build_options.scheduler_metrics,
};

/// The resolved configuration. A `-fsingle-threaded` build has only one
/// executor, whatever the declaration says.
pub const options: Options = blk: {
    var resolved: Options = if (@hasDecl(root, "zio_options")) root.zio_options else .{};
    if (builtin.single_threaded) resolved.scheduling = .single_executor;
    break :blk resolved;
};

fn buildEnum(comptime T: type, comptime name: []const u8) T {
    return std.meta.stringToEnum(T, name) orelse @compileError("zio: unknown " ++ @typeName(T) ++ ": " ++ name);
}
