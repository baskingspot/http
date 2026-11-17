//! The request method: the common vocabulary, plus the exact token for
//! anything else.
//!
//! On the wire a method is a token, the comparison is case-sensitive, and the
//! IANA registry is open (RFC 9110 §9.1, §16.1.1). The known tags are the wire
//! spelling, so the `token()` of `.GET` is `"GET"`; any other token is carried
//! verbatim in `.other`, which borrows the caller's bytes. One field therefore
//! holds both the routing vocabulary and the exact wire form.
//!
//! `Method.parse("get")` is `.{ .other = "get" }`: methods are case-sensitive.

const std = @import("std");
const mem = std.mem;
const testing = std.testing;

pub const Method = union(enum) {
    GET,
    HEAD,
    POST,
    PUT,
    DELETE,
    CONNECT,
    OPTIONS,
    TRACE,
    PATCH,
    /// Any other registered or private token, exactly as the wire carries it.
    /// The slice is borrowed, not copied.
    other: []const u8,

    /// The exact wire token. Methods are case-sensitive (RFC 9110 §9.1).
    pub fn token(self: Method) []const u8 {
        return switch (self) {
            .other => |wire| wire,
            else => @tagName(self),
        };
    }

    /// The named method for this exact token, or `.other` with the token.
    /// `get` is not `GET`.
    ///
    /// The length picks the integer width, then one little-endian load and one
    /// compare settle it, the same shape as `h1.parseVersion`. Anything that
    /// cannot be a named method is `.other` without a walk over the names.
    pub fn parse(wire: []const u8) Method {
        return switch (wire.len) {
            3 => switch (mem.readVarInt(u24, wire[0..3], .little)) {
                pack("GET") => .GET,
                pack("PUT") => .PUT,
                else => .{ .other = wire },
            },
            4 => switch (mem.readVarInt(u32, wire[0..4], .little)) {
                pack("HEAD") => .HEAD,
                pack("POST") => .POST,
                else => .{ .other = wire },
            },
            5 => switch (mem.readVarInt(u40, wire[0..5], .little)) {
                pack("TRACE") => .TRACE,
                pack("PATCH") => .PATCH,
                else => .{ .other = wire },
            },
            6 => switch (mem.readVarInt(u48, wire[0..6], .little)) {
                pack("DELETE") => .DELETE,
                else => .{ .other = wire },
            },
            7 => switch (mem.readVarInt(u56, wire[0..7], .little)) {
                pack("CONNECT") => .CONNECT,
                pack("OPTIONS") => .OPTIONS,
                else => .{ .other = wire },
            },
            else => .{ .other = wire },
        };
    }

    /// Whether a request with this method normally carries content. An
    /// unknown method is assumed not to.
    pub fn requestHasBody(self: Method) bool {
        return switch (self) {
            .POST, .PUT, .PATCH => true,
            else => false,
        };
    }

    /// Whether a response to this method normally carries content. An unknown
    /// method is assumed to allow one.
    pub fn responseHasBody(self: Method) bool {
        return switch (self) {
            .HEAD, .TRACE => false,
            else => true,
        };
    }

    /// Safe methods do not alter server state (RFC 9110 §9.2.1). An unknown
    /// method is not assumed safe.
    pub fn safe(self: Method) bool {
        return switch (self) {
            .GET, .HEAD, .OPTIONS, .TRACE => true,
            else => false,
        };
    }

    /// Idempotent methods can repeat without a different effect
    /// (RFC 9110 §9.2.2). An unknown method is not assumed idempotent.
    pub fn idempotent(self: Method) bool {
        return switch (self) {
            .GET, .HEAD, .PUT, .DELETE, .OPTIONS, .TRACE => true,
            else => false,
        };
    }

    /// Cacheable methods (RFC 9110 §9.2.3). An unknown method is not assumed
    /// cacheable.
    pub fn cacheable(self: Method) bool {
        return switch (self) {
            .GET, .HEAD => true,
            else => false,
        };
    }
};

/// A token's bytes as one little-endian integer, so a compare needs no walk.
fn pack(comptime token: []const u8) @Int(.unsigned, token.len * 8) {
    const T = @Int(.unsigned, token.len * 8);
    return mem.readInt(T, token, .little);
}

test "token and parse round-trip every named tag" {
    const info = @typeInfo(Method).@"union";
    inline for (info.field_names, info.field_types) |name, FieldType| {
        if (comptime FieldType != void) continue;
        const method = Method.parse(name);
        try testing.expectEqualStrings(name, method.token());
        try testing.expectEqualStrings(name, @tagName(method));
    }
}

test "parse is case-sensitive (RFC 9110 §9.1)" {
    try testing.expectEqual(Method.GET, Method.parse("GET"));
    try testing.expectEqualStrings("get", Method.parse("get").token());
    try testing.expect(std.meta.activeTag(Method.parse("get")) == .other);
    try testing.expect(std.meta.activeTag(Method.parse("Get")) == .other);
}

test "parse leaves unlisted methods as tokens" {
    const tokens = [_][]const u8{ "QUERY", "M-SEARCH", "PROPFIND", "" };
    for (tokens) |token| {
        const method = Method.parse(token);
        try testing.expect(std.meta.activeTag(method) == .other);
        try testing.expectEqualStrings(token, method.token());
    }
}

test "safe and idempotent agree with RFC 9110 §9.2" {
    const info = @typeInfo(Method).@"union";
    inline for (info.field_names, info.field_types) |name, FieldType| {
        if (comptime FieldType != void) continue;
        const method: Method = Method.parse(name);
        // Safe implies idempotent, and GET and HEAD are both.
        if (method.safe()) try testing.expect(method.idempotent());
    }

    const get: Method = .GET;
    const post: Method = .POST;
    const put: Method = .PUT;
    try testing.expect(get.safe());
    try testing.expect(!post.safe());
    try testing.expect(put.idempotent());
    try testing.expect(!post.idempotent());
}

test "body and cache predicates" {
    const get: Method = .GET;
    const post: Method = .POST;
    const head: Method = .HEAD;
    try testing.expect(get.requestHasBody() == false);
    try testing.expect(post.requestHasBody());
    try testing.expect(head.responseHasBody() == false);
    try testing.expect(get.cacheable());
    try testing.expect(post.cacheable() == false);
    try testing.expect(Method.parse("PROPFIND").requestHasBody() == false);
    try testing.expect(Method.parse("PROPFIND").responseHasBody());
}
