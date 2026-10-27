//! HTTP status codes as an exhaustive enum.
//!
//! `std.http.Status` is `enum(u10) { ..., _ }`: it can hold a value it does
//! not name, and `@tagName` is illegal on one. The parser returns the wire
//! number (`u16`), because RFC 9110 §15 lets any 3-digit code through and the
//! caller applies the class rule. This type is the caller-facing vocabulary,
//! and it is exhaustive, so `parse` returns null for a code it does not name.
//!
//! The field set mirrors `std.http.Status`, so the names are the ones Zig
//! callers already know. A code added to the registry later stays a number
//! until the field set grows.

const std = @import("std");
const enums = std.enums;
const testing = std.testing;

const status_fields = @typeInfo(std.http.Status).@"enum".fields;

const names: [status_fields.len][]const u8 = blk: {
    var out: [status_fields.len][]const u8 = undefined;
    for (status_fields, 0..) |field, index| out[index] = field.name;
    break :blk out;
};

const values: [status_fields.len]u10 = blk: {
    var out: [status_fields.len]u10 = undefined;
    for (status_fields, 0..) |field, index| out[index] = @intCast(field.value);
    break :blk out;
};

pub const StatusCode = @Enum(
    u10,
    .exhaustive,
    &names,
    &values,
);

/// The three-digit wire code.
pub fn code(status: StatusCode) u16 {
    return @intFromEnum(status);
}

/// The status with this number, or null when the enum does not name it.
pub fn parse(value: u16) ?StatusCode {
    return enums.fromInt(StatusCode, value);
}

/// The canonical reason phrase, or null for an unnamed code.
pub fn phrase(status: StatusCode) ?[]const u8 {
    return @as(std.http.Status, @enumFromInt(@intFromEnum(status))).phrase();
}

test "the enum is exhaustive and mirrors std's named statuses" {
    const info = @typeInfo(StatusCode).@"enum";
    try testing.expect(info.is_exhaustive);
    try testing.expectEqual(status_fields.len, info.fields.len);
}

test "code and parse round-trip every tag" {
    inline for (@typeInfo(StatusCode).@"enum".fields) |field| {
        const status: StatusCode = @field(StatusCode, field.name);
        try testing.expectEqual(@as(u16, @intCast(field.value)), code(status));
        try testing.expectEqual(status, parse(code(status)).?);
    }
}

test "parse rejects codes the enum does not name (RFC 9110 §15)" {
    try testing.expectEqual(StatusCode.ok, parse(200).?);
    try testing.expect(parse(0) == null);
    try testing.expect(parse(599) == null);
    try testing.expect(parse(999) == null);
}

test "phrase is the canonical text" {
    try testing.expectEqualStrings("OK", phrase(.ok).?);
    try testing.expectEqualStrings("Not Found", phrase(.not_found).?);
    try testing.expectEqualStrings("Switching Protocols", phrase(.switching_protocols).?);
}
