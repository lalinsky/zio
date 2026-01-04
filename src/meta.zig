// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

const std = @import("std");

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

/// Extract the error set from an error union type.
/// Returns anyerror if it's not an error union.
pub fn ErrorSet(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .error_union => |eu| eu.error_set,
        else => anyerror,
    };
}

/// Convenience function that combines ReturnType and Payload.
/// Extracts the return type from a function and unwraps any error union.
pub fn Result(func: anytype) type {
    return Payload(ReturnType(func));
}
