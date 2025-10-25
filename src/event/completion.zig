/// The callback of the main Loop operations. Higher level interfaces may
/// use a different callback mechanism.
pub fn Callback(comptime T: type) type {
    return *const fn (
        userdata: ?*anyopaque,
        loop: *T.Loop,
        completion: *T.Completion,
    ) CallbackAction;
}

/// The result type for callbacks. This should be used by all loop
/// implementations and higher level abstractions in order to control
/// what to do after the loop completes.
pub const CallbackAction = enum(c_int) {
    /// The request is complete and is not repeated. For example, a read
    /// callback only fires once and is no longer watched for reads. You
    /// can always free memory associated with the completion prior to
    /// returning this.
    disarm = 0,

    /// Requeue the same operation request with the same parameters
    /// with the event loop. This makes it easy to repeat a read, timer,
    /// etc. This rearms the request EXACTLY as-is. For example, the
    /// low-level timer interface for io_uring uses an absolute timeout.
    /// If you rearm the timer, it will fire immediately because the absolute
    /// timeout will be in the past.
    ///
    /// The completion is reused so it is not safe to use the same completion
    /// for anything else.
    rearm = 1,
};

/// The state that a completion can be in.
pub const CompletionState = enum(c_int) {
    /// The completion is not being used and is ready to be configured
    /// for new work.
    dead = 0,

    /// The completion is part of an event loop. This may be already waited
    /// on or in the process of being registered.
    active = 1,
};

pub const OperationType = enum {
    noop,
    timer,
    cancel,
    accept,
    connect,
    poll,
    read,
    write,
    send,
    recv,
    sendmsg,
    recvmsg,
    shutdown,
    close,
};

pub const Completion = struct {
    op: OperationType,

    userdata: ?*anyopaque,
    callback: Callback(Self),

    /// Intrusive queue of completions.
    next: ?*Completion = null,
};

pub const Cancelable = error{Canceled};

pub const TimerError = Cancelable;

pub const TimerCompletion = struct {
    /// Parent completion.
    base: Completion,

    result: TimerError!void = undefined,

    pub fn fromBase(c: *Completion) *TimerCompletion {
        std.debug.assert(c.op == .timer);
        return @fieldParentPtr("base", c);
    }
};
