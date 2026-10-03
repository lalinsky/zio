// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

const std = @import("std");

/// Returns the next line, skipping any that do not fit the reader's buffer.
pub fn takeLine(reader: *std.Io.Reader) error{ReadFailed}!?[]u8 {
    while (true) {
        return reader.takeDelimiter('\n') catch |err| switch (err) {
            error.ReadFailed => |e| return e,
            error.StreamTooLong => {
                _ = reader.discardDelimiterInclusive('\n') catch |e| switch (e) {
                    error.ReadFailed => |read_err| return read_err,
                    error.EndOfStream => return null,
                };
                continue;
            },
        };
    }
}
