//! The common request methods, re-exported from `std.http`.
//!
//! `std.http.Method` is the conventional nine, with `safe`, `idempotent`, and
//! the body/cache helpers. The parser still returns the wire token, because
//! `method = token` is case-sensitive and the IANA registry is open (RFC 9110
//! §9.1, §16.1.1); `parse` and `token` are the bridge.

const std = @import("std");
const meta = std.meta;
const testing = std.testing;

pub const Method = std.http.Method;

/// The exact wire token. Methods are case-sensitive (RFC 9110 §9.1).
pub fn token(method: Method) []const u8 {
    return @tagName(method);
}

/// The method with this exact token, or null. `get` is not `GET`.
pub fn parse(wire: []const u8) ?Method {
    return meta.stringToEnum(Method, wire);
}

test "token and parse round-trip every tag" {
    inline for (meta.fields(Method)) |field| {
        const method: Method = @field(Method, field.name);
        try testing.expectEqualStrings(field.name, token(method));
        try testing.expectEqual(method, parse(token(method)).?);
    }
}

test "parse is case-sensitive (RFC 9110 §9.1)" {
    try testing.expectEqual(Method.GET, parse("GET").?);
    try testing.expect(parse("get") == null);
    try testing.expect(parse("Get") == null);
}

test "parse leaves unlisted methods as tokens" {
    try testing.expect(parse("QUERY") == null);
    try testing.expect(parse("M-SEARCH") == null);
    try testing.expect(parse("PROPFIND") == null);
    try testing.expect(parse("") == null);
}
