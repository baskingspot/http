//! HTTP/3 request-head validation (RFC 9114 §4.2–4.4).
//!
//! The shared field syntax, the response head, the trailer section, and the
//! outbound response check live in `field_section`. This module owns the
//! request rules that differ from HTTP/2:
//!
//! - A request whose scheme has a mandatory authority (`http` and `https`)
//!   carries `:authority`, `Host`, or both, and both must match (§4.3.1).
//!   `Host` is an ordinary field and stays in `headers`; `RequestHead.authority`
//!   is the pseudo-header alone, so a caller that wants the effective authority
//!   falls back to `headers.get("host")`.
//! - CONNECT omits `:scheme` and `:path` and requires `:authority` (§4.4).
//!   Extended CONNECT adds `:protocol` and the three fields (RFC 9220).
//!
//! The input is the decoded field list from QPACK, pseudo-headers included and
//! in wire order. Every slice is borrowed.

const std = @import("std");
const testing = std.testing;
const mem = std.mem;

const Header = @import("../header.zig").Header;
const Headers = @import("../header.zig").Headers;
const Method = @import("../method.zig").Method;
const field_section = @import("../field_section.zig");

pub const Error = field_section.Error || error{
    /// An http or https request has neither `:authority` nor `Host`.
    MissingAuthority,
    /// `:authority` and `Host` are both present and differ.
    MismatchedAuthority,
    /// More than one `Host` field.
    DuplicateHost,
};

pub const RequestHead = field_section.RequestHead;
pub const ResponseHead = field_section.ResponseHead;
pub const response = field_section.response;
pub const trailers = field_section.trailers;
pub const validateResponse = field_section.validateResponse;

const Pseudo = field_section.Pseudo;

pub fn request(fields: Headers) Error!RequestHead {
    var method: ?[]const u8 = null;
    var scheme: ?[]const u8 = null;
    var authority: ?[]const u8 = null;
    var path: ?[]const u8 = null;
    var protocol: ?[]const u8 = null;
    var host: ?[]const u8 = null;
    var seen_regular = false;
    var regular_start: usize = fields.items.len;

    for (fields.items, 0..) |field, index| {
        try field_section.validateValue(field.value);
        if (field.name.len != 0 and field.name[0] == ':') {
            if (seen_regular) return error.PseudoAfterField;
            switch (try Pseudo.fromString(field.name)) {
                .@":method" => {
                    if (method != null) return error.DuplicatePseudo;
                    if (!field_section.validToken(field.value)) return error.InvalidMethod;
                    method = field.value;
                },
                .@":scheme" => {
                    if (scheme != null) return error.DuplicatePseudo;
                    if (!field_section.validScheme(field.value)) return error.InvalidScheme;
                    scheme = field.value;
                },
                .@":authority" => {
                    if (authority != null) return error.DuplicatePseudo;
                    if (field.value.len == 0) return error.InvalidAuthority;
                    authority = field.value;
                },
                .@":path" => {
                    if (path != null) return error.DuplicatePseudo;
                    if (field.value.len == 0) return error.InvalidPath;
                    path = field.value;
                },
                .@":protocol" => {
                    if (protocol != null) return error.DuplicatePseudo;
                    if (!field_section.validToken(field.value)) return error.InvalidProtocol;
                    protocol = field.value;
                },
                .@":status" => return error.UnknownPseudo,
            }
        } else {
            try field_section.validateFieldName(field.name);
            try field_section.validateRegularField(field);
            if (mem.eql(u8, field.name, "host")) {
                if (host != null) return error.DuplicateHost;
                host = field.value;
            }
            if (!seen_regular) {
                seen_regular = true;
                regular_start = index;
            }
        }
    }

    const method_token = method orelse return error.MissingPseudo;
    const request_method = Method.parse(method_token);

    if (request_method == .CONNECT) {
        if (protocol != null) {
            // RFC 9220: extended CONNECT carries scheme, path, and authority.
            if (scheme == null or path == null) return error.MissingPseudo;
            if (authority == null) return error.MissingPseudo;
            if (!field_section.validPath(path.?, request_method)) return error.InvalidPath;
        } else {
            // RFC 9114 §4.4: CONNECT omits scheme and path.
            if (scheme != null) return error.InvalidScheme;
            if (path != null) return error.InvalidPath;
            if (authority == null) return error.MissingPseudo;
        }
    } else {
        if (protocol != null) return error.InvalidProtocol;
        if (scheme == null or path == null) return error.MissingPseudo;
        if (!field_section.validPath(path.?, request_method)) return error.InvalidPath;
    }

    if (authority != null and host != null) {
        if (!mem.eql(u8, authority.?, host.?)) return error.MismatchedAuthority;
    }

    if (scheme) |s| {
        if (field_section.isHttpScheme(s)) {
            const effective = authority orelse host orelse return error.MissingAuthority;
            if (effective.len == 0) return error.InvalidAuthority;
            if (mem.findScalar(u8, effective, '@') != null) return error.InvalidAuthority;
        }
    }

    return .{
        .method = request_method,
        .scheme = scheme,
        .authority = authority,
        .path = path,
        .protocol = protocol,
        .headers = .{ .items = fields.items[regular_start..] },
    };
}

test "a request with :authority validates" {
    const head = try request(.{ .items = &.{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":authority", .value = "example.com" },
        .{ .name = ":path", .value = "/index.html" },
        .{ .name = "user-agent", .value = "test/1.0" },
    } });
    try testing.expectEqual(Method.GET, head.method);
    try testing.expectEqualStrings("https", head.scheme.?);
    try testing.expectEqualStrings("example.com", head.authority.?);
    try testing.expectEqualStrings("/index.html", head.path.?);
    try testing.expectEqual(@as(usize, 1), head.headers.items.len);
}

test "Host substitutes for :authority, and both must match" {
    const via_host = try request(.{ .items = &.{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":path", .value = "/" },
        .{ .name = "host", .value = "example.com" },
    } });
    try testing.expect(via_host.authority == null);
    try testing.expectEqualStrings("example.com", via_host.headers.get("host").?);

    _ = try request(.{ .items = &.{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":authority", .value = "example.com" },
        .{ .name = ":path", .value = "/" },
        .{ .name = "host", .value = "example.com" },
    } });

    try testing.expectError(error.MismatchedAuthority, request(.{ .items = &.{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":authority", .value = "example.com" },
        .{ .name = ":path", .value = "/" },
        .{ .name = "host", .value = "other.example" },
    } }));
}

test "http and https require an authority; other schemes do not" {
    try testing.expectError(error.MissingAuthority, request(.{ .items = &.{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":path", .value = "/" },
    } }));

    const ftp = try request(.{ .items = &.{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "ftp" },
        .{ .name = ":path", .value = "/" },
    } });
    try testing.expect(ftp.authority == null);
}

test "an empty or repeated Host is invalid" {
    try testing.expectError(error.InvalidAuthority, request(.{ .items = &.{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":path", .value = "/" },
        .{ .name = "host", .value = "" },
    } }));

    try testing.expectError(error.DuplicateHost, request(.{ .items = &.{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":path", .value = "/" },
        .{ .name = "host", .value = "a.example" },
        .{ .name = "host", .value = "b.example" },
    } }));
}

test "CONNECT omits scheme and path" {
    const head = try request(.{ .items = &.{
        .{ .name = ":method", .value = "CONNECT" },
        .{ .name = ":authority", .value = "example.com:443" },
    } });
    try testing.expectEqual(Method.CONNECT, head.method);
    try testing.expect(head.scheme == null);
    try testing.expect(head.path == null);

    try testing.expectError(error.InvalidScheme, request(.{ .items = &.{
        .{ .name = ":method", .value = "CONNECT" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":authority", .value = "example.com:443" },
    } }));
    try testing.expectError(error.MissingPseudo, request(.{ .items = &.{
        .{ .name = ":method", .value = "CONNECT" },
    } }));
}

test "extended CONNECT carries :protocol, scheme, path, and authority" {
    const head = try request(.{ .items = &.{
        .{ .name = ":method", .value = "CONNECT" },
        .{ .name = ":protocol", .value = "websocket" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":path", .value = "/chat" },
        .{ .name = ":authority", .value = "example.com" },
    } });
    try testing.expectEqualStrings("websocket", head.protocol.?);

    try testing.expectError(error.InvalidProtocol, request(.{ .items = &.{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":protocol", .value = "websocket" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":path", .value = "/" },
        .{ .name = ":authority", .value = "example.com" },
    } }));
}

test "pseudo-header order, duplication, and direction" {
    try testing.expectError(error.PseudoAfterField, request(.{ .items = &.{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":path", .value = "/" },
        .{ .name = "x-first", .value = "v" },
        .{ .name = ":authority", .value = "example.com" },
    } }));

    try testing.expectError(error.DuplicatePseudo, request(.{ .items = &.{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":method", .value = "POST" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":path", .value = "/" },
        .{ .name = ":authority", .value = "example.com" },
    } }));

    try testing.expectError(error.UnknownPseudo, request(.{ .items = &.{
        .{ .name = ":status", .value = "200" },
    } }));

    try testing.expectError(error.InvalidFieldName, request(.{ .items = &.{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":path", .value = "/" },
        .{ .name = "X-Upper", .value = "v" },
    } }));
}

test "connection-specific fields and TE stay forbidden" {
    const base = [_]Header{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":path", .value = "/" },
        .{ .name = ":authority", .value = "example.com" },
    };

    try testing.expectError(error.ForbiddenField, request(.{ .items = &(base ++ [_]Header{
        .{ .name = "connection", .value = "close" },
    }) }));
    try testing.expectError(error.ForbiddenField, request(.{ .items = &(base ++ [_]Header{
        .{ .name = "te", .value = "gzip" },
    }) }));
    _ = try request(.{ .items = &(base ++ [_]Header{
        .{ .name = "te", .value = "trailers" },
    }) });
}

test "options may use the asterisk path form" {
    const head = try request(.{ .items = &.{
        .{ .name = ":method", .value = "OPTIONS" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":path", .value = "*" },
        .{ .name = ":authority", .value = "example.com" },
    } });
    try testing.expectEqualStrings("*", head.path.?);

    try testing.expectError(error.InvalidPath, request(.{ .items = &.{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":path", .value = "*" },
        .{ .name = ":authority", .value = "example.com" },
    } }));
}

test "the response and trailer rules are the shared ones" {
    const head = try response(.{ .items = &.{
        .{ .name = ":status", .value = "204" },
        .{ .name = "x-check", .value = "done" },
    } });
    try testing.expectEqual(@as(u16, 204), head.status.code());

    try testing.expectError(error.UnknownPseudo, trailers(.{ .items = &.{
        .{ .name = ":status", .value = "200" },
    } }));
}
