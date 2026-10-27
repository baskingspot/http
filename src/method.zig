//! The common request methods, as a caller-facing vocabulary.
//!
//! The parser returns the wire token, because `method = token` is case-
//! sensitive and the IANA registry is open (RFC 9110 §9.1, §16.1.1). This enum
//! names the methods a general client or server routes in practice; it is not
//! the registry, and anything else stays a token.
//!
//! The tags are the wire spelling, so `Method.GET.token()` is `"GET"`. No
//! mapping table, no case folding.

const std = @import("std");
const meta = std.meta;
const testing = std.testing;

pub const Method = enum {
    GET,
    HEAD,
    POST,
    PUT,
    PATCH,
    DELETE,
    CONNECT,
    OPTIONS,
    TRACE,

    /// The exact wire token. Methods are case-sensitive (RFC 9110 §9.1).
    pub fn token(self: Method) []const u8 {
        return @tagName(self);
    }

    /// The method with this exact token, or null. `get` is not `GET`.
    pub fn parse(wire: []const u8) ?Method {
        return meta.stringToEnum(Method, wire);
    }
};

test "token and parse round-trip every tag" {
    inline for (meta.fields(Method)) |field| {
        const method: Method = @field(Method, field.name);
        try testing.expectEqualStrings(field.name, method.token());
        try testing.expectEqual(method, Method.parse(method.token()).?);
    }
}

test "parse is case-sensitive (RFC 9110 §9.1)" {
    try testing.expectEqual(Method.GET, Method.parse("GET").?);
    try testing.expect(Method.parse("get") == null);
    try testing.expect(Method.parse("Get") == null);
}

test "parse leaves unlisted methods as tokens" {
    try testing.expect(Method.parse("QUERY") == null);
    try testing.expect(Method.parse("M-SEARCH") == null);
    try testing.expect(Method.parse("PROPFIND") == null);
    try testing.expect(Method.parse("") == null);
}
