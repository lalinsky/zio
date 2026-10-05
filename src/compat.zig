// SPDX-FileCopyrightText: 2026 Lukáš Lalinský
// SPDX-License-Identifier: MIT

//! Language and reflection differences between Zig 0.16 and 0.17, so that code
//! outside the `std.Io` implementation reads the same on both. The shape is
//! detected from the standard library rather than from the version number, so
//! 0.17 dev builds work too.

const std = @import("std");
const builtin = @import("builtin");

const Type = std.builtin.Type;

/// 0.17 renamed the optimize modes to `debug`/`safe`/`fast`/`small`.
const has_lowercase_modes = @hasField(std.builtin.OptimizeMode, "debug");

/// 0.17 replaced the per-field info structs with parallel `field_names`/`field_types` lists.
const has_field_lists = @hasField(Type.Struct, "field_names");

pub const is_debug = builtin.mode == if (has_lowercase_modes) .debug else .Debug;

/// Debug or ReleaseSafe.
pub const is_safe = is_debug or builtin.mode == if (has_lowercase_modes) .safe else .ReleaseSafe;

pub const StructFieldAttributes = if (has_field_lists) Type.Struct.FieldAttributes else Type.StructField.Attributes;
pub const UnionFieldAttributes = if (has_field_lists) Type.Union.FieldAttributes else Type.UnionField.Attributes;

/// Field names of a struct or union, in declaration order.
pub inline fn fieldNames(comptime T: type) []const [:0]const u8 {
    const info = switch (@typeInfo(T)) {
        .@"struct" => |s| s,
        .@"union" => |u| u,
        else => @compileError("expected a struct or union, found " ++ @typeName(T)),
    };
    if (has_field_lists) return info.field_names;
    return comptime blk: {
        var names: [info.fields.len][:0]const u8 = undefined;
        for (&names, info.fields) |*name, field| name.* = field.name;
        const final = names;
        break :blk &final;
    };
}

/// Field types of a struct or union, in declaration order.
pub inline fn fieldTypes(comptime T: type) []const type {
    const info = switch (@typeInfo(T)) {
        .@"struct" => |s| s,
        .@"union" => |u| u,
        else => @compileError("expected a struct or union, found " ++ @typeName(T)),
    };
    if (has_field_lists) return info.field_types;
    return comptime blk: {
        var types: [info.fields.len]type = undefined;
        for (&types, info.fields) |*ty, field| ty.* = field.type;
        const final = types;
        break :blk &final;
    };
}

/// Names of the errors in an error set, or null for `anyerror`.
pub inline fn errorNames(comptime E: type) ?[]const [:0]const u8 {
    const errors = @typeInfo(E).error_set;
    if (has_field_lists) return errors.error_names;
    const list = errors orelse return null;
    return comptime blk: {
        var names: [list.len][:0]const u8 = undefined;
        for (&names, list) |*name, err| name.* = err.name;
        const final = names;
        break :blk &final;
    };
}

test "fieldNames and fieldTypes" {
    const S = struct { a: u8, b: u16 };
    const U = union { x: u32 };
    try std.testing.expectEqual(2, fieldNames(S).len);
    try std.testing.expectEqualStrings("a", fieldNames(S)[0]);
    try std.testing.expectEqualStrings("b", fieldNames(S)[1]);
    try std.testing.expectEqualStrings("x", fieldNames(U)[0]);
    try std.testing.expect(comptime fieldTypes(S)[1] == u16);
    try std.testing.expect(comptime fieldTypes(U)[0] == u32);
}

test "errorNames" {
    const names = errorNames(error{ Foo, Bar }).?;
    try std.testing.expectEqual(2, names.len);
    try std.testing.expectEqualStrings("Foo", names[0]);
    try std.testing.expectEqualStrings("Bar", names[1]);
    try std.testing.expectEqual(null, errorNames(anyerror));
}
