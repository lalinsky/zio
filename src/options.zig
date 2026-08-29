// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

//! Compile-time configuration, declared by the root module:
//!
//! ```zig
//! // main.zig
//! pub const zio_options: @import("zio").Options = .{ .scheduling = .pinned };
//! ```
//!
//! Because the options live in the root module rather than in a build-time
//! options module, every zio in a binary (the app's, and any library's that
//! depends on zio) sees the same configuration. Passing them as `b.dependency`
//! arguments instead would produce a distinct module per argument set, and a
//! binary that ended up with two of them would have two incompatible `Runtime`
//! types.
//!
//! The `-D` build options of zio's own `build.zig` supply the defaults when the
//! root module declares nothing. They exist so zio's test and example builds can
//! sweep the configuration matrix from the command line; a root declaration
//! always wins over them.

const std = @import("std");
const builtin = @import("builtin");
const root = @import("root");
const build_options = @import("zio_build_options");

/// How tasks are scheduled onto executors. This is the ceiling on what the
/// scheduler compiles in, so each step down removes machinery rather than
/// merely disabling it.
pub const Scheduling = enum {
    /// One executor. No stealing, no migration, and no executor topology: the
    /// executor count is comptime-known, so the run-queue routing, the
    /// round-robin in `getNextExecutor`, the idle mask and the per-executor
    /// metrics fold all collapse.
    ///
    /// This is about executors, not threads: unless the build is also
    /// `-fsingle-threaded`, the blocking thread pool still exists and foreign
    /// threads can still wake tasks, so the cross-thread wake path stays.
    single_executor,
    /// Many executors, but a task stays on the executor it was spawned on for
    /// its entire life. Drops the steal machinery and the atomics that exist
    /// only to move a running task between threads, at the cost of no
    /// rebalancing when load is uneven.
    pinned,
    /// Many executors, and idle ones steal work from busy ones.
    work_stealing,

    /// Whether more than one executor can exist.
    pub inline fn multiExecutor(self: Scheduling) bool {
        return self != .single_executor;
    }

    /// Whether a task can move between executors after it starts running.
    pub inline fn migrates(self: Scheduling) bool {
        return self == .work_stealing;
    }
};

/// Event loop backend. The default is the best one for the target.
pub const BackendType = enum { poll, linux, epoll, kqueue, io_uring, iocp };

/// How to handle `resolve_beneath` on platforms without kernel support.
pub const ResolveBeneathMode = enum {
    /// Fail with `error.Unsupported`.
    strict,
    /// Log a warning and continue.
    best_effort,
};

pub const Options = struct {
    /// Scheduling discipline, and thus the scheduler machinery compiled in.
    /// Defaults to `.single_executor`, matching the default runtime, which runs
    /// one executor. Programs that want more than one executor set this to
    /// `.pinned` or `.work_stealing`; `RuntimeOptions.exact()` is a compile
    /// error until they do.
    scheduling: Scheduling = default_scheduling,
    /// Override the event loop backend. Null picks the target's default.
    backend: ?BackendType = default_backend,
    resolve_beneath_mode: ResolveBeneathMode = default_resolve_beneath_mode,
    /// Avoid unsafe performance tricks (bool smuggling, etc.).
    no_hacks: bool = default_no_hacks,
    /// Count scheduler events (parks, steals, wake batches) in per-executor
    /// counters readable via `Runtime.schedulerMetrics`. The counters sit on
    /// executor-local paths and cost one plain increment per event.
    scheduler_metrics: bool = default_scheduler_metrics,
};

/// The resolved configuration. Everything in zio reads this.
pub const options: Options = if (@hasDecl(root, "zio_options")) root.zio_options else .{};

comptime {
    if (builtin.single_threaded and options.scheduling.multiExecutor()) {
        @compileError("zio: a -fsingle-threaded build cannot spawn executors; " ++
            "set zio_options.scheduling = .single_executor");
    }
}

/// The build options carry enums as tag names, so map them back here.
fn fromBuildName(comptime T: type, comptime name: []const u8) T {
    return std.meta.stringToEnum(T, name) orelse
        @compileError("zio: unknown " ++ @typeName(T) ++ " build option: " ++ name);
}

/// The discipline zio's own `-Dscheduling` build option asked for, if any.
/// This exists for zio's test runner and examples, which are root modules of
/// builds driven from the command line; consumers declare `zio_options`.
pub const build_scheduling: ?Scheduling = if (build_options.scheduling) |s|
    fromBuildName(Scheduling, s)
else
    null;

const default_scheduling: Scheduling = build_scheduling orelse .single_executor;

const default_backend: ?BackendType = if (build_options.backend) |b|
    fromBuildName(BackendType, b)
else
    null;

const default_resolve_beneath_mode: ResolveBeneathMode = if (build_options.resolve_beneath_mode) |m|
    fromBuildName(ResolveBeneathMode, m)
else
    .strict;

const default_no_hacks: bool = build_options.no_hacks orelse false;

const default_scheduler_metrics: bool = build_options.scheduler_metrics orelse true;
