const std = @import("std");

/// Extract the argument tuple type from a function.
pub fn ArgsType(func: anytype) type {
    return std.meta.ArgsTuple(@TypeOf(func));
}

/// Extract the return type from a function.
/// Returns void if the function has no return type.
pub fn ReturnType(func: anytype) type {
    return if (@typeInfo(@TypeOf(func)).@"fn".return_type) |ret| ret else void;
}

/// Unwrap an error union to get the payload type.
/// Returns the type unchanged if it's not an error union.
pub fn Payload(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .error_union => |eu| eu.payload,
        else => T,
    };
}

/// Convenience function that combines ReturnType and Payload.
/// Extracts the return type from a function and unwraps any error union.
pub fn Result(func: anytype) type {
    return Payload(ReturnType(func));
}
