const builtin = @import("builtin");

/// Whether TSan fiber instrumentation is active in this build.
pub const enabled = builtin.sanitize_thread;

/// Opaque TSan fiber handle. Zero-sized when instrumentation is disabled so it
/// adds no storage to `Context`.
pub const Fiber = if (enabled) ?*anyopaque else void;

/// The "no fiber" value for the active `Fiber` representation.
pub const none: Fiber = if (enabled) null else {};

const c = if (enabled) struct {
    extern fn __tsan_get_current_fiber() ?*anyopaque;
    extern fn __tsan_create_fiber(flags: c_uint) ?*anyopaque;
    extern fn __tsan_destroy_fiber(fiber: ?*anyopaque) void;
    extern fn __tsan_switch_to_fiber(fiber: ?*anyopaque, flags: c_uint) void;
} else struct {};

/// The fiber currently executing on this OS thread. For the scheduler's native
/// thread context this is the thread's own (non-created) fiber.
pub inline fn currentFiber() Fiber {
    return if (enabled) c.__tsan_get_current_fiber() else {};
}

/// Register a new coroutine as its own TSan fiber. Call once when a coroutine's
/// context is set up.
pub inline fn createFiber() Fiber {
    return if (enabled) c.__tsan_create_fiber(0) else {};
}

/// Retire a coroutine's fiber. Must not be called while `fiber` is the running
/// fiber (destroy from a different context after the coroutine has finished).
pub inline fn destroyFiber(fiber: Fiber) void {
    if (enabled) {
        if (fiber) |f| c.__tsan_destroy_fiber(f);
    }
}

/// Tell TSan that `fiber` is now the running fiber on this OS thread. Call at
/// the moment of a context switch, just before the stacks are swapped. flags ==
/// 0 (rather than the no-sync flag) makes the switch a release/acquire pair, so
/// what the outgoing fiber did happens-before the incoming fiber resumes — the
/// ordering a cooperative scheduler needs. It does not create false cross-thread
/// edges, since fibers on different executor threads never share a switch.
pub inline fn switchToFiber(fiber: Fiber) void {
    if (enabled) {
        if (fiber) |f| c.__tsan_switch_to_fiber(f, 0);
    }
}
