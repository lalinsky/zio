// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

//! Internal logging and printing for the zio runtime.
//!
//! Runtime code can log from anywhere: the event loop, the thread pool, the
//! scheduler, or a task's own stack while it is inside runtime machinery.
//! Writing a log line from those places through the normal task path would
//! park on the event loop, and it would take the stderr lock as a task, both
//! of which are unsafe when the code doing it is the machinery that has to
//! resume the parked tasks.
//!
//! These wrappers mark the region as scheduler context and then call `std.log`
//! (or `std.debug.print`), so `std.options.logFn` still applies: custom log
//! functions and the test runner's log capture keep working. The marking does
//! two things:
//!
//!  * `Executor.current_task` is cleared, so the write inside the stderr lock
//!    takes the blocking path in `waitForIo` instead of parking. Doing it this
//!    way, rather than by consulting a flag inside `getCurrentTaskOrNull`,
//!    keeps every I/O operation's hot path unchanged.
//!  * a threadlocal flag records scheduler context for the stderr lock, which
//!    needs the answer on threads that have no executor at all (thread-pool
//!    workers, and the crash handler on any thread).
//!
//! Runtime code must log and print only through these wrappers. A `std.log` or
//! `std.debug.print` call from scheduler context that skips them is a latent
//! deadlock.
//!
//! The first of those two, clearing the task marker, is what keeps the
//! scheduler stderr lock's holder from parking, which is the invariant that
//! makes waiting for that lock bounded. It is enforced by only two places
//! (this file and `runtime.markCrashed`) plus an assertion where the scheduler
//! writer is handed out, since everything else reaching it has no task to
//! begin with. Note that assertion only runs in programs that install
//! `zio.debug_io`: the test runner does not, so `zig build test` does not
//! reach the stderr vtable at all, and the examples are what exercise it.
//!
//! TODO: if that turns out to be fragile, the scheduler writer could enforce
//! it by construction instead, by replacing its drain with one that calls
//! `ev.executeBlocking` directly rather than going through `waitForIo`, which
//! would be blocking regardless of the task marker. It is about 25 lines
//! (`Io.Writer.consume` and `fillBuf` do the bookkeeping), but it is new code
//! on the panic path, so it is not worth it until the marking proves
//! unreliable.

const std = @import("std");
const runtime = @import("runtime.zig");
const AnyTask = @import("task.zig").AnyTask;

const scoped = std.log.scoped(.zio);

/// Set while this thread is inside a marked scheduler region. Read by the
/// stderr lock to decide whether waiting for the lock is safe.
threadlocal var in_scheduler: bool = false;

/// Whether this thread is inside a marked scheduler region.
///
/// Note this is only the part that `Executor.current_task` cannot express:
/// an executor thread outside task execution is scheduler context too, and
/// the stderr lock derives that separately from the absence of a task.
pub fn inSchedulerContext() bool {
    return in_scheduler;
}

/// Saved state of a scheduler region, restored by `exitSchedulerContext`.
pub const Region = struct {
    prev_in_scheduler: bool,
    executor: ?*runtime.Executor,
    prev_task: ?*AnyTask,
};

/// Enter a scheduler region. Regions nest, and must not contain a suspension
/// point: the task marker is restored by address, so a context switch inside
/// the region would restore it onto the wrong stack.
pub fn enterSchedulerContext() Region {
    const prev_in_scheduler = in_scheduler;
    in_scheduler = true;

    const executor = runtime.getCurrentExecutorOrNull();
    const prev_task = if (executor) |exec| exec.current_task else null;
    if (executor) |exec| exec.current_task = null;

    return .{
        .prev_in_scheduler = prev_in_scheduler,
        .executor = executor,
        .prev_task = prev_task,
    };
}

pub fn exitSchedulerContext(region: Region) void {
    if (region.executor) |exec| exec.current_task = region.prev_task;
    in_scheduler = region.prev_in_scheduler;
}

/// Log an error message.
pub fn err(comptime format: []const u8, args: anytype) void {
    const region = enterSchedulerContext();
    defer exitSchedulerContext(region);
    scoped.err(format, args);
}

/// Log a warning message.
pub fn warn(comptime format: []const u8, args: anytype) void {
    const region = enterSchedulerContext();
    defer exitSchedulerContext(region);
    scoped.warn(format, args);
}

/// Log an info message.
pub fn info(comptime format: []const u8, args: anytype) void {
    const region = enterSchedulerContext();
    defer exitSchedulerContext(region);
    scoped.info(format, args);
}

/// Log a debug message.
pub fn debug(comptime format: []const u8, args: anytype) void {
    const region = enterSchedulerContext();
    defer exitSchedulerContext(region);
    scoped.debug(format, args);
}

/// `std.debug.print` for runtime code, marked the same way as the log
/// wrappers. Unlike them it is unconditional and unformatted by any log
/// function, so it is for temporary debugging rather than shipped
/// diagnostics.
pub fn print(comptime format: []const u8, args: anytype) void {
    const region = enterSchedulerContext();
    defer exitSchedulerContext(region);
    std.debug.print(format, args);
}
