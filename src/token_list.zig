//! Comma-separated token lists (RFC 9110 §5.6.1).
//!
//! `contains(field, token)` answers membership without allocating. `iterator`
//! yields each non-empty element with OWS trimmed, in the order it appears.
//!
//! Elements are returned whole. A field whose grammar allows parameters or
//! quoted strings (`TE`, `Expect`) needs more than this and is not covered.
//! Empty elements are ignored, as the list rule requires.

const std = @import("std");
const ascii = std.ascii;
const mem = std.mem;
const testing = std.testing;

const ows = @import("ows.zig");

/// Whether `field` contains `token` as an element, ignoring case and OWS.
pub fn contains(field: []const u8, token: []const u8) bool {
    if (token.len == 0 or field.len < token.len) return false;
    var elements = iterator(field);
    while (elements.next()) |element| {
        if (ascii.eqlIgnoreCase(element, token)) return true;
    }
    return false;
}

pub const Iterator = struct {
    field: []const u8,
    pos: usize = 0,

    pub fn next(self: *Iterator) ?[]const u8 {
        while (self.pos <= self.field.len) {
            const start = self.pos;
            var end = start;
            while (end < self.field.len and self.field[end] != ',') end += 1;
            self.pos = end + 1;
            const element = ows.trim(self.field[start..end]);
            if (element.len != 0) return element;
        }
        return null;
    }
};

pub fn iterator(field: []const u8) Iterator {
    return .{ .field = field };
}

/// The shape the tests compare against: split, trim, skip empties.
fn referenceContains(field: []const u8, token: []const u8) bool {
    var parts = mem.splitScalar(u8, field, ',');
    while (parts.next()) |raw| {
        const element = ows.trim(raw);
        if (element.len != 0 and ascii.eqlIgnoreCase(element, token)) return true;
    }
    return false;
}

test "contains: the field shapes a server actually sees" {
    try testing.expect(contains("keep-alive, Upgrade", "Upgrade"));
    try testing.expect(contains("keep-alive, Upgrade", "keep-alive"));
    try testing.expect(contains("KEEP-ALIVE,UPGRADE", "upgrade"));
    try testing.expect(contains(" upgrade ", "Upgrade"));
    try testing.expect(contains("\tupgrade\t", "Upgrade"));
    try testing.expect(contains(", , upgrade ,,", "upgrade"));
    try testing.expect(!contains("keep-alive, Upgrade", "close"));
    try testing.expect(!contains("", "close"));
    try testing.expect(!contains(", ,", "close"));
    try testing.expect(!contains("upgradex", "upgrade"));
    try testing.expect(!contains("xupgrade", "upgrade"));
    // A parameter is not part of the token; the element is returned whole.
    try testing.expect(!contains("upgrade;foo=1", "upgrade"));
}

test "iterator: trimmed non-empty elements in order" {
    var elements = iterator(" a ,\t,\t b\t, c ");
    try testing.expectEqualStrings("a", elements.next().?);
    try testing.expectEqualStrings("b", elements.next().?);
    try testing.expectEqualStrings("c", elements.next().?);
    try testing.expect(elements.next() == null);

    var empty = iterator("");
    try testing.expect(empty.next() == null);

    var commas = iterator(",,,");
    try testing.expect(commas.next() == null);
}

test "contains: every short string over a tiny alphabet agrees with the reference" {
    const alphabet = "aA, \t";
    var buf: [4]u8 = undefined;
    const tokens = [_][]const u8{ "a", "A", "aa", "aA", "b", "" };
    for (1..buf.len + 1) |len| {
        var code: usize = 0;
        var total: usize = 1;
        for (0..len) |_| total *= alphabet.len;
        while (code < total) : (code += 1) {
            var rest = code;
            for (0..len) |i| {
                buf[i] = alphabet[rest % alphabet.len];
                rest /= alphabet.len;
            }
            const field = buf[0..len];
            for (tokens) |token| {
                try testing.expectEqual(referenceContains(field, token), contains(field, token));
            }
        }
    }
}

test "fuzz token lists" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) anyerror!void {
            var field_buf: [256]u8 = undefined;
            const field = field_buf[0..smith.slice(&field_buf)];
            var token_buf: [16]u8 = undefined;
            const token = token_buf[0..smith.slice(&token_buf)];

            const got = contains(field, token);
            try testing.expectEqual(referenceContains(field, token), got);

            // Every yielded element appears in order, with no overlap.
            var rest = field;
            var elements = iterator(field);
            while (elements.next()) |element| {
                try testing.expect(element.len != 0);
                const at = mem.indexOf(u8, rest, element) orelse return error.TestUnexpectedResult;
                rest = rest[at + element.len ..];
            }
        }
    }.run, .{
        .corpus = &.{
            "",
            "a",
            "a,b",
            " a , b ",
            ",,",
            "upgrade",
            "keep-alive, Upgrade",
        },
    });
}
