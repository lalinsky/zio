const std = @import("std");

const Loop = @import("loop.zig").Loop;
const Backend = @import("backend.zig").Backend;

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
    state: State,

    userdata: ?*anyopaque = null,
    callback: ?*const CallbackFn,

    /// Intrusive queue of completions.
    next: ?*Completion = null,

    pub const State = enum { active, dead };

    pub const CallbackAction = enum { disarm, rearm };
    pub const CallbackFn = fn (
        userdata: ?*anyopaque,
        loop: *Loop,
        completion: *Completion,
    ) CallbackAction;

    pub fn init(op: OperationType) Completion {
        return .{
            .op = op,
            .state = .dead,
            .callback = null,
            .userdata = null,
        };
    }

    pub fn call(c: *Completion, loop: *Loop) CallbackAction {
        if (c.callback) |func| {
            return func(c.userdata, loop, c);
        }
        return .disarm;
    }
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
