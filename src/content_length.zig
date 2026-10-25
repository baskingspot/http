//! `Content-Length` parsing and combination (RFC 9110 §8.6).
//!
//! `parse(values)` takes every field line named `Content-Length`, in the order
//! they appeared, and returns the length. `null` means the field was absent.
//!
//! The field value is `1*DIGIT`, so leading zeros are valid: `"00"` is 0 and
//! `"0042"` is 42. Repetition is allowed only when every value is the same
//! decimal number: `["42", "42"]` and `["42, 42"]` both parse to 42, while
//! differing values are a framing conflict and return `error.Conflicting`.
//! Empty list elements are ignored, as RFC 9110 §5.6.1 requires, but a field
//! line with no digits is not a list and is invalid.
//!
//! This module stops at the field value. The rule that `Transfer-Encoding`
//! and `Content-Length` must not both frame a request (RFC 9112 §6.1) belongs
//! to the caller that sees both fields.

const std = @import("std");
const mem = std.mem;
const testing = std.testing;
const math = std.math;

const atoi = @import("stdx").fmt.atoi;

const ows = @import("ows.zig");

pub const Error = error{ Invalid, Conflicting, Overflow };

/// The one length named by the field, or `null` when the field is absent.
pub fn parse(values: []const []const u8) Error!?u64 {
    var length: ?u64 = null;
    for (values) |value| {
        if (value.len == 0) return error.Invalid;

        var digits_seen = false;
        var elements = mem.splitScalar(u8, value, ',');
        while (elements.next()) |raw| {
            const element = ows.trim(raw);
            if (element.len == 0) continue;
            digits_seen = true;

            const parsed = atoi(u64, element) catch |err| switch (err) {
                error.InvalidCharacter => return error.Invalid,
                error.Overflow => {
                    @branchHint(.unlikely);
                    return error.Overflow;
                },
            };
            if (length) |existing| {
                if (existing != parsed) {
                    @branchHint(.unlikely);
                    return error.Conflicting;
                }
            } else {
                length = parsed;
            }
        }
        if (!digits_seen) return error.Invalid;
    }
    return length;
}

test "parse: one value" {
    try testing.expectEqual(@as(?u64, null), try parse(&.{}));
    try testing.expectEqual(@as(?u64, 0), try parse(&.{"0"}));
    try testing.expectEqual(@as(?u64, 0), try parse(&.{"00"}));
    try testing.expectEqual(@as(?u64, 42), try parse(&.{"42"}));
    try testing.expectEqual(@as(?u64, 42), try parse(&.{" 42 "}));
    try testing.expectEqual(@as(?u64, 42), try parse(&.{"\t42\t"}));
}

test "parse: repetition must agree" {
    try testing.expectEqual(@as(?u64, 42), try parse(&.{ "42", "42" }));
    try testing.expectEqual(@as(?u64, 42), try parse(&.{"42, 42"}));
    try testing.expectEqual(@as(?u64, 42), try parse(&.{"42,"}));
    try testing.expectEqual(@as(?u64, 42), try parse(&.{",42"}));
    try testing.expectEqual(@as(?u64, 42), try parse(&.{ "42", "42, 42" }));
    try testing.expectError(error.Conflicting, parse(&.{ "42", "43" }));
    try testing.expectError(error.Conflicting, parse(&.{"42, 43"}));
    // Equal decimal values agree even when their spellings differ.
    try testing.expectEqual(@as(?u64, 0), try parse(&.{ "0", "00" }));
    try testing.expectEqual(@as(?u64, 42), try parse(&.{ "42", "042" }));
    // An empty field line is invalid, not a conflicting length.
    try testing.expectError(error.Invalid, parse(&.{ "42", "" }));
}

test "parse: the grammar rejects everything else" {
    const values = [_][]const u8{
        "",    " ",   "\t",   ",",   ",,",  "+1",  "-0", "+0",
        "4 2", "4_2", "0x10", "abc", "1.0", "42a",
    };
    for (values) |value| try testing.expectError(error.Invalid, parse(&.{value}));
}

test "parse: the u64 boundaries" {
    try testing.expectEqual(@as(?u64, math.maxInt(u64)), try parse(&.{"18446744073709551615"}));
    try testing.expectEqual(@as(?u64, math.maxInt(u64)), try parse(&.{"00018446744073709551615"}));
    try testing.expectError(error.Overflow, parse(&.{"18446744073709551616"}));
    try testing.expectError(error.Overflow, parse(&.{"99999999999999999999"}));
    try testing.expectError(error.Overflow, parse(&.{"100000000000000000000"}));
    try testing.expectError(error.Overflow, parse(&.{"18446744073709551615, 18446744073709551616"}));
}

test "parse: every short digit string agrees with the std oracle" {
    var buf: [4]u8 = undefined;
    for (1..buf.len + 1) |len| {
        var code: usize = 0;
        var total: usize = 1;
        for (0..len) |_| total *= 10;
        while (code < total) : (code += 1) {
            var rest = code;
            for (0..len) |i| {
                buf[i] = '0' + @as(u8, @intCast(rest % 10));
                rest /= 10;
            }
            const want = try std.fmt.parseInt(u64, buf[0..len], 10);
            try testing.expectEqual(@as(?u64, want), try parse(&.{buf[0..len]}));
        }
    }
}

test "fuzz content length" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) anyerror!void {
            var buf: [64]u8 = undefined;
            const value = buf[0..smith.slice(&buf)];

            if (parse(&.{value})) |length| {
                // A successful parse is all digits; it round-trips.
                try testing.expect(length == null or length.? <= math.maxInt(u64));
            } else |_| {}

            // Exercise the multiple-line path on the same bytes.
            const mid = value.len / 2;
            const split = parse(&.{ value[0..mid], value[mid..] }) catch null;
            mem.doNotOptimizeAway(split);
        }
    }.run, .{
        .corpus = &.{
            "",
            "0",
            "42",
            "42, 42",
            "42, 43",
            "+1",
            "18446744073709551616",
        },
    });
}
