//! HTTP field sections: borrowed name/value pairs and lookups over them.
//!
//! `Header` borrows both slices from the message buffer. `Headers` is a view
//! over the parser's list; it owns nothing and allocates nothing.
//!
//! A `Header.value` is the span the parser produced. `Headers` lookups trim
//! OWS from it, because OWS is not part of the field value (RFC 9110 §5.5).
//! Iterating `Headers.items` directly bypasses that trimming.
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

/// One field line, as the parser found it. `std.http.Header` is the same pair;
/// the contract above describes how this package treats the value.
pub const Header = std.http.Header;

/// A borrowed view of every field line in a message, in wire order.
pub const Headers = struct {
    items: []const Header,

    /// The first value named `name`, or null. Use this only for fields the RFC
    /// defines as a singleton (`Host`, `Content-Length`). A list-valued field
    /// may repeat, and duplicates combine; use `values` and feed them to the
    /// family parser.
    pub fn get(self: Headers, name: []const u8) ?[]const u8 {
        var iterator = self.values(name);
        return iterator.next();
    }

    /// Every value named `name`, in wire order, with OWS trimmed.
    ///
    /// Each field line is yielded separately. `Set-Cookie` needs this; so does
    /// anything that distinguishes "one field with a comma" from "two fields".
    pub fn values(self: Headers, name: []const u8) Values {
        return .{ .headers = self, .name = name };
    }

    /// True when any line named `name` contains `token` as a list element.
    ///
    /// This is the shape for `Connection`, `Upgrade`, and `Vary`: every line
    /// is checked, so a duplicated field cannot hide a token.
    pub fn containsToken(self: Headers, name: []const u8, token: []const u8) bool {
        var iterator = self.values(name);
        while (iterator.next()) |value| {
            if (token_list.contains(value, token)) return true;
        }
        return false;
    }
};

pub const Values = struct {
    headers: Headers,
    name: []const u8,
    index: u32 = 0,

    pub fn next(self: *Values) ?[]const u8 {
        while (@as(usize, self.index) < self.headers.items.len) {
            const header = self.headers.items[@intCast(self.index)];
            self.index += 1;
            if (ascii.eqlIgnoreCase(header.name, self.name)) return ows.trim(header.value);
        }
        return null;
    }
};

test "get: first match, case-insensitive, OWS trimmed" {
    const headers: Headers = .{ .items = &.{
        .{ .name = "Host", .value = " example.com " },
        .{ .name = "Content-Length", .value = "42" },
        .{ .name = "content-length", .value = "42" },
    } };

    try testing.expectEqualStrings("example.com", headers.get("host").?);
    try testing.expectEqualStrings("42", headers.get("CONTENT-LENGTH").?);
}

test "values: every line, in order, duplicates not combined" {
    const headers: Headers = .{ .items = &.{
        .{ .name = "Set-Cookie", .value = "a=1; Path=/" },
        .{ .name = "accept-encoding", .value = "br" },
        .{ .name = "set-cookie", .value = "b=2" },
    } };

    var cookies = headers.values("Set-Cookie");
    try testing.expectEqualStrings("a=1; Path=/", cookies.next().?);
    try testing.expectEqualStrings("b=2", cookies.next().?);
    try testing.expect(cookies.next() == null);

    var encodings = headers.values("ACCEPT-ENCODING");
    try testing.expectEqualStrings("br", encodings.next().?);
    try testing.expect(encodings.next() == null);
}

test "absent and empty are different" {
    const headers: Headers = .{ .items = &.{
        .{ .name = "X-Empty", .value = " \t " },
    } };

    try testing.expect(headers.get("X-Absent") == null);
    try testing.expectEqualStrings("", headers.get("x-empty").?);
}

test "a comma in a value is not split here" {
    const headers: Headers = .{ .items = &.{
        .{ .name = "Accept-Encoding", .value = "gzip, br" },
    } };

    try testing.expectEqualStrings("gzip, br", headers.get("accept-encoding").?);
    var iterator = headers.values("accept-encoding");
    try testing.expectEqualStrings("gzip, br", iterator.next().?);
    try testing.expect(iterator.next() == null);
}

test "the raw value keeps its OWS" {
    const header: Header = .{ .name = "Host", .value = " example.com " };
    const headers: Headers = .{ .items = &.{header} };

    try testing.expectEqualStrings(" example.com ", headers.items[0].value);
    try testing.expectEqualStrings("example.com", headers.get("host").?);
}

test "an empty section finds nothing" {
    const headers: Headers = .{ .items = &.{} };
    try testing.expect(headers.get("Host") == null);
    var iterator = headers.values("Host");
    try testing.expect(iterator.next() == null);
}

test "containsToken: checks every line" {
    const headers: Headers = .{ .items = &.{
        .{ .name = "Connection", .value = "keep-alive" },
        .{ .name = "connection", .value = "Upgrade, close" },
    } };

    try testing.expect(headers.containsToken("connection", "upgrade"));
    try testing.expect(headers.containsToken("CONNECTION", "close"));
    try testing.expect(!headers.containsToken("connection", "te"));
    try testing.expect(!headers.containsToken("transfer-encoding", "chunked"));
}
