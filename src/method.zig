//! The common request methods, as a caller-facing vocabulary.
//!
//! On the wire a method is a token, the comparison is case-sensitive, and the
//! IANA registry is open (RFC 9110 §9.1, §16.1.1). The h1 parser keeps the
//! exact bytes. This enum names the methods a general client or server routes
//! in practice; `parse` returns null for anything else, and the token stays
//! the source of truth.
//!
//! The tags are the wire spelling, so `Method.GET.token()` is `"GET"` and
//! `Method.parse("get")` is null.

const std = @import("std");
const meta = std.meta;
const testing = std.testing;

pub const Method = enum {
    GET,
    HEAD,
    POST,
    PUT,
    DELETE,
    CONNECT,
    OPTIONS,
    TRACE,
    PATCH,

    /// The exact wire token. Methods are case-sensitive (RFC 9110 §9.1).
    pub fn token(self: Method) []const u8 {
        return @tagName(self);
    }

    /// The method with this exact token, or null. `get` is not `GET`.
    pub fn parse(wire: []const u8) ?Method {
        return meta.stringToEnum(Method, wire);
    }

    /// Whether a request with this method normally carries content.
    pub fn requestHasBody(self: Method) bool {
        return switch (self) {
            .POST, .PUT, .PATCH => true,
            .GET, .HEAD, .DELETE, .CONNECT, .OPTIONS, .TRACE => false,
        };
    }

    /// Whether a response to this method normally carries content.
    pub fn responseHasBody(self: Method) bool {
        return switch (self) {
            .GET, .POST, .PUT, .DELETE, .CONNECT, .OPTIONS, .PATCH => true,
            .HEAD, .TRACE => false,
        };
    }

    /// Safe methods do not alter server state (RFC 9110 §9.2.1).
    pub fn safe(self: Method) bool {
        return switch (self) {
            .GET, .HEAD, .OPTIONS, .TRACE => true,
            .POST, .PUT, .DELETE, .CONNECT, .PATCH => false,
        };
    }

    /// Idempotent methods can repeat without a different effect
    /// (RFC 9110 §9.2.2).
    pub fn idempotent(self: Method) bool {
        return switch (self) {
            .GET, .HEAD, .PUT, .DELETE, .OPTIONS, .TRACE => true,
            .CONNECT, .POST, .PATCH => false,
        };
    }

    /// Cacheable methods (RFC 9110 §9.2.3).
    pub fn cacheable(self: Method) bool {
        return switch (self) {
            .GET, .HEAD => true,
            .POST, .PUT, .DELETE, .CONNECT, .OPTIONS, .TRACE, .PATCH => false,
        };
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

test "safe and idempotent agree with RFC 9110 §9.2" {
    inline for (meta.fields(Method)) |field| {
        const method: Method = @field(Method, field.name);
        // Safe implies idempotent, and GET and HEAD are both.
        if (method.safe()) try testing.expect(method.idempotent());
    }

    try testing.expect(Method.GET.safe());
    try testing.expect(!Method.POST.safe());
    try testing.expect(Method.PUT.idempotent());
    try testing.expect(!Method.POST.idempotent());
}

test "body and cache predicates" {
    try testing.expect(Method.GET.requestHasBody() == false);
    try testing.expect(Method.POST.requestHasBody());
    try testing.expect(Method.HEAD.responseHasBody() == false);
    try testing.expect(Method.GET.cacheable());
    try testing.expect(Method.POST.cacheable() == false);
}
