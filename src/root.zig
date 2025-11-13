pub const Coroutine = @import("coroutines.zig").Coroutine;
pub const Closure = @import("coroutines.zig").Closure;

pub const Context = @import("coroutines.zig").Context;
pub const switchContext = @import("coroutines.zig").switchContext;

pub const Stack = @import("stack.zig").Stack;

test {
    _ = @import("coroutines.zig");
    _ = @import("stack.zig");
}
