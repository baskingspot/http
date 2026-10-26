//! HTTP field sections: borrowed name/value pairs and lookups over them.
//!
//! `Field` borrows both slices from the message buffer. `Fields` is a view
//! over the parser's list; it owns nothing and allocates nothing.
//!
//! A `Field.value` is the span the parser produced. `Fields` lookups trim OWS
//! from it, because OWS is not part of the field value (RFC 9110 §5.5).
//! Iterating `Fields.items` directly bypasses that trimming.
//!
//! Duplicate field lines are yielded separately and in order. Combining them
//! with commas is a property of the field family, not of the section: most
//! lists combine, `Set-Cookie` never does, and a singleton field must not
//! appear twice at all.

const std = @import("std");
const ascii = std.ascii;
const testing = std.testing;
const ows = @import("ows.zig");
const token_list = @import("token_list.zig");

/// One field line, as the parser found it.
pub const Field = struct {
    /// The name exactly as received. Comparisons fold ASCII case.
    name: []const u8,
    /// The value exactly as received, without the name, colon, or line
    /// terminator. Lookups through `Fields` trim surrounding OWS.
    value: []const u8,
};

/// A borrowed view of every field line in a message, in wire order.
pub const Fields = struct {
    items: []const Field,

    /// The first value named `name`, or null. Use this only for fields the RFC
    /// defines as a singleton (`Host`, `Content-Length`). A list-valued field
    /// may repeat, and duplicates combine; use `values` and feed them to the
    /// family parser.
    pub fn get(self: Fields, name: []const u8) ?[]const u8 {
        var iterator = self.values(name);
        return iterator.next();
    }

    /// Every value named `name`, in wire order, with OWS trimmed.
    ///
    /// Each field line is yielded separately. `Set-Cookie` needs this; so does
    /// anything that distinguishes "one field with a comma" from "two fields".
    pub fn values(self: Fields, name: []const u8) Values {
        return .{ .fields = self, .name = name };
    }

    /// True when any line named `name` contains `token` as a list element.
    ///
    /// This is the shape for `Connection`, `Upgrade`, and `Vary`: every line
    /// is checked, so a duplicated field cannot hide a token.
    pub fn containsToken(self: Fields, name: []const u8, token: []const u8) bool {
        var iterator = self.values(name);
        while (iterator.next()) |value| {
            if (token_list.contains(value, token)) return true;
        }
        return false;
    }
};

pub const Values = struct {
    fields: Fields,
    name: []const u8,
    index: u32 = 0,

    pub fn next(self: *Values) ?[]const u8 {
        while (@as(usize, self.index) < self.fields.items.len) {
            const field = self.fields.items[@intCast(self.index)];
            self.index += 1;
            if (ascii.eqlIgnoreCase(field.name, self.name)) return ows.trim(field.value);
        }
        return null;
    }
};

test "get: first match, case-insensitive, OWS trimmed" {
    const fields: Fields = .{ .items = &.{
        .{ .name = "Host", .value = " example.com " },
        .{ .name = "Content-Length", .value = "42" },
        .{ .name = "content-length", .value = "42" },
    } };

    try testing.expectEqualStrings("example.com", fields.get("host").?);
    try testing.expectEqualStrings("42", fields.get("CONTENT-LENGTH").?);
}

test "values: every line, in order, duplicates not combined" {
    const fields: Fields = .{ .items = &.{
        .{ .name = "Set-Cookie", .value = "a=1; Path=/" },
        .{ .name = "accept-encoding", .value = "br" },
        .{ .name = "set-cookie", .value = "b=2" },
    } };

    var cookies = fields.values("Set-Cookie");
    try testing.expectEqualStrings("a=1; Path=/", cookies.next().?);
    try testing.expectEqualStrings("b=2", cookies.next().?);
    try testing.expect(cookies.next() == null);

    var encodings = fields.values("ACCEPT-ENCODING");
    try testing.expectEqualStrings("br", encodings.next().?);
    try testing.expect(encodings.next() == null);
}

test "absent and empty are different" {
    const fields: Fields = .{ .items = &.{
        .{ .name = "X-Empty", .value = " \t " },
    } };

    try testing.expect(fields.get("X-Absent") == null);
    try testing.expectEqualStrings("", fields.get("x-empty").?);
}

test "a comma in a value is not split here" {
    const fields: Fields = .{ .items = &.{
        .{ .name = "Accept-Encoding", .value = "gzip, br" },
    } };

    try testing.expectEqualStrings("gzip, br", fields.get("accept-encoding").?);
    var iterator = fields.values("accept-encoding");
    try testing.expectEqualStrings("gzip, br", iterator.next().?);
    try testing.expect(iterator.next() == null);
}

test "the raw value keeps its OWS" {
    const field: Field = .{ .name = "Host", .value = " example.com " };
    const fields: Fields = .{ .items = &.{field} };

    try testing.expectEqualStrings(" example.com ", fields.items[0].value);
    try testing.expectEqualStrings("example.com", fields.get("host").?);
}

test "an empty section finds nothing" {
    const fields: Fields = .{ .items = &.{} };
    try testing.expect(fields.get("Host") == null);
    var iterator = fields.values("Host");
    try testing.expect(iterator.next() == null);
}

test "containsToken: checks every line" {
    const fields: Fields = .{ .items = &.{
        .{ .name = "Connection", .value = "keep-alive" },
        .{ .name = "connection", .value = "Upgrade, close" },
    } };

    try testing.expect(fields.containsToken("connection", "upgrade"));
    try testing.expect(fields.containsToken("CONNECTION", "close"));
    try testing.expect(!fields.containsToken("connection", "te"));
    try testing.expect(!fields.containsToken("transfer-encoding", "chunked"));
}
