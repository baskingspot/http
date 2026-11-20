//! HTTP/2 request-head validation (RFC 9113 §8.2, §8.3).
//!
//! The shared field syntax, the response head, the trailer section, and the
//! outbound response check live in `field_section`. This module owns the
//! request rules: the HTTP/2 pseudo-header set, CONNECT, and extended CONNECT.
//! The input is the field list HPACK produced, pseudo-headers included and in
//! wire order; every slice is borrowed.

const std = @import("std");
const testing = std.testing;
const mem = std.mem;

const Header = @import("../header.zig").Header;
const Headers = @import("../header.zig").Headers;
const Method = @import("../method.zig").Method;
const Status = @import("../status.zig").Status;
const field_section = @import("../field_section.zig");

pub const Error = field_section.Error;
pub const RequestHead = field_section.RequestHead;
pub const ResponseHead = field_section.ResponseHead;
pub const response = field_section.response;
pub const trailers = field_section.trailers;
pub const validateResponse = field_section.validateResponse;

const Pseudo = field_section.Pseudo;
const validateFieldName = field_section.validateFieldName;
const validateValue = field_section.validateValue;
const validateRegularField = field_section.validateRegularField;
const validPath = field_section.validPath;
const validToken = field_section.validToken;
const validScheme = field_section.validScheme;
const isHttpScheme = field_section.isHttpScheme;

pub fn request(fields: Headers) Error!RequestHead {
    var method: ?[]const u8 = null;
    var scheme: ?[]const u8 = null;
    var authority: ?[]const u8 = null;
    var path: ?[]const u8 = null;
    var protocol: ?[]const u8 = null;
    var seen_regular = false;
    var regular_start = fields.items.len;

    for (fields.items, 0..) |field, index| {
        try validateValue(field.value);
        if (field.name.len != 0 and field.name[0] == ':') {
            if (seen_regular) return error.PseudoAfterField;
            switch (try Pseudo.fromString(field.name)) {
                .@":method" => {
                    if (method != null) return error.DuplicatePseudo;
                    if (!validToken(field.value)) return error.InvalidMethod;
                    method = field.value;
                },
                .@":scheme" => {
                    if (scheme != null) return error.DuplicatePseudo;
                    if (!validScheme(field.value)) return error.InvalidScheme;
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
                    if (!validToken(field.value)) return error.InvalidProtocol;
                    protocol = field.value;
                },
                .@":status" => return error.UnknownPseudo,
            }
        } else {
            try validateFieldName(field.name);
            try validateRegularField(field);
            if (!seen_regular) {
                seen_regular = true;
                regular_start = index;
            }
        }
    }

    const method_token = method orelse return error.MissingPseudo;
    const request_method = Method.parse(method_token);

    if (request_method == .CONNECT) {
        if (protocol) |_| {
            // RFC 8441: extended CONNECT carries scheme, path, and authority.
            if (scheme == null or path == null) return error.MissingPseudo;
            if (authority == null) return error.MissingPseudo;
            if (!validPath(path.?, request_method)) return error.InvalidPath;
        } else {
            // RFC 9113 §8.5: CONNECT omits scheme and path.
            if (scheme != null) return error.InvalidScheme;
            if (path != null) return error.InvalidPath;
            if (authority == null) return error.MissingPseudo;
        }
    } else {
        if (protocol != null) return error.InvalidProtocol;
        if (scheme == null or path == null) return error.MissingPseudo;
        if (!validPath(path.?, request_method)) return error.InvalidPath;
    }

    if (scheme) |s| {
        if (authority) |a| {
            if (isHttpScheme(s) and mem.findScalar(u8, a, '@') != null) {
                return error.InvalidAuthority;
            }
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

const request_fields = [_]Header{
    .{ .name = ":method", .value = "GET" },
    .{ .name = ":scheme", .value = "https" },
    .{ .name = ":path", .value = "/metrics?x=1" },
    .{ .name = ":authority", .value = "example.com" },
    .{ .name = "user-agent", .value = "test/1.0" },
    .{ .name = "accept", .value = "*/*" },
};

test "request: pseudo-headers ahead of the regular fields" {
    const head = try request(.{ .items = &request_fields });
    try testing.expectEqual(Method.GET, head.method);
    try testing.expectEqualStrings("https", head.scheme.?);
    try testing.expectEqualStrings("/metrics?x=1", head.path.?);
    try testing.expectEqualStrings("example.com", head.authority.?);
    try testing.expect(head.protocol == null);
    try testing.expectEqual(@as(usize, 2), head.headers.len());
    try testing.expectEqualStrings("user-agent", head.headers.items[0].name);
}

test "request: an unlisted method keeps its token" {
    const fields = [_]Header{
        .{ .name = ":method", .value = "QUERY" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":path", .value = "/" },
    };
    const head = try request(.{ .items = &fields });
    try testing.expect(std.meta.activeTag(head.method) == .other);
    try testing.expectEqualStrings("QUERY", head.method.token());
}

test "response: status is three digits, regular fields follow" {
    const fields = [_]Header{
        .{ .name = ":status", .value = "200" },
        .{ .name = "content-type", .value = "text/plain" },
    };
    const head = try response(.{ .items = &fields });
    try testing.expectEqual(Status.ok, head.status);
    try testing.expectEqual(@as(usize, 1), head.headers.len());
    try testing.expectEqualStrings("content-type", head.headers.items[0].name);
}

test "pseudo-header order, duplication, and direction" {
    try testing.expectError(error.PseudoAfterField, request(.{ .items = &.{
        .{ .name = "user-agent", .value = "x" },
        .{ .name = ":method", .value = "GET" },
    } }));
    try testing.expectError(error.DuplicatePseudo, request(.{ .items = &.{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":method", .value = "POST" },
    } }));
    try testing.expectError(error.UnknownPseudo, request(.{ .items = &.{
        .{ .name = ":status", .value = "200" },
    } }));
    try testing.expectError(error.UnknownPseudo, response(.{ .items = &.{
        .{ .name = ":method", .value = "GET" },
    } }));
    try testing.expectError(error.MissingPseudo, request(.{ .items = &.{
        .{ .name = ":method", .value = "GET" },
    } }));
    try testing.expectError(error.MissingPseudo, response(.{ .items = &.{} }));
}

test "request: required pseudo-headers and path forms" {
    const base = [_]Header{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":path", .value = "/" },
    };
    _ = try request(.{ .items = &base });

    try testing.expectError(error.MissingPseudo, request(.{ .items = base[0..2] }));
    try testing.expectError(error.InvalidPath, request(.{ .items = base[0..1] ++ [_]Header{
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":path", .value = "" },
    } }));
    try testing.expectError(error.InvalidPath, request(.{ .items = &.{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":path", .value = "relative" },
    } }));
}

test "request: OPTIONS may use the asterisk form" {
    const options = [_]Header{
        .{ .name = ":method", .value = "OPTIONS" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":path", .value = "*" },
    };
    const head = try request(.{ .items = &options });
    try testing.expectEqualStrings("*", head.path.?);

    const get = [_]Header{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":path", .value = "*" },
    };
    try testing.expectError(error.InvalidPath, request(.{ .items = &get }));
}

test "request: CONNECT omits scheme and path" {
    const connect = [_]Header{
        .{ .name = ":method", .value = "CONNECT" },
        .{ .name = ":authority", .value = "example.com:443" },
    };
    const head = try request(.{ .items = &connect });
    try testing.expect(head.method == .CONNECT);
    try testing.expect(head.scheme == null);
    try testing.expect(head.path == null);

    try testing.expectError(error.InvalidPath, request(.{ .items = connect[0..1] ++ [_]Header{
        .{ .name = ":authority", .value = "example.com:443" },
        .{ .name = ":path", .value = "/" },
    } }));
    try testing.expectError(error.MissingPseudo, request(.{ .items = connect[0..1] }));
}

test "request: extended CONNECT carries scheme, path, and protocol" {
    const fields = [_]Header{
        .{ .name = ":method", .value = "CONNECT" },
        .{ .name = ":protocol", .value = "websocket" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":path", .value = "/chat" },
        .{ .name = ":authority", .value = "example.com" },
    };
    const head = try request(.{ .items = &fields });
    try testing.expectEqualStrings("websocket", head.protocol.?);
    try testing.expectEqualStrings("https", head.scheme.?);

    try testing.expectError(error.InvalidProtocol, request(.{ .items = &.{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":protocol", .value = "websocket" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":path", .value = "/" },
    } }));
}

test "field names: lowercase tchar only" {
    try testing.expectError(error.InvalidFieldName, request(.{ .items = &.{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":path", .value = "/" },
        .{ .name = "User-Agent", .value = "x" },
    } }));
    try testing.expectError(error.InvalidFieldName, request(.{ .items = &.{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":path", .value = "/" },
        .{ .name = "x:y", .value = "x" },
    } }));
    try testing.expectError(error.InvalidFieldName, request(.{ .items = &.{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":path", .value = "/" },
        .{ .name = "", .value = "x" },
    } }));
}

test "field values: no CTLs and no edge whitespace" {
    const prefix = [_]Header{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":path", .value = "/" },
    };
    for ([_][]const u8{ "a\x00b", "a\rb", "a\nb", "a\x01b", "a\x7fb", " a", "a ", "a\t" }) |value| {
        try testing.expectError(error.InvalidFieldValue, request(.{ .items = &(prefix ++ [_]Header{
            .{ .name = "x-test", .value = value },
        }) }));
    }
    // HTAB inside a value is allowed.
    _ = try request(.{ .items = &(prefix ++ [_]Header{
        .{ .name = "x-test", .value = "a\tb" },
    }) });
}

test "connection-specific fields are forbidden; TE may only say trailers" {
    const prefix = [_]Header{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":path", .value = "/" },
    };
    for ([_][]const u8{
        "connection", "keep-alive", "proxy-connection", "transfer-encoding", "upgrade",
    }) |name| {
        try testing.expectError(error.ForbiddenField, request(.{ .items = &(prefix ++ [_]Header{
            .{ .name = name, .value = "x" },
        }) }));
    }
    _ = try request(.{ .items = &(prefix ++ [_]Header{
        .{ .name = "te", .value = "trailers" },
    }) });
    try testing.expectError(error.ForbiddenField, request(.{ .items = &(prefix ++ [_]Header{
        .{ .name = "te", .value = "gzip" },
    }) }));
}

test "method, scheme, status, and authority syntax" {
    try testing.expectError(error.InvalidMethod, request(.{ .items = &.{
        .{ .name = ":method", .value = "GE T" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":path", .value = "/" },
    } }));
    try testing.expectError(error.InvalidScheme, request(.{ .items = &.{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "1http" },
        .{ .name = ":path", .value = "/" },
    } }));
    try testing.expectError(error.InvalidStatus, response(.{ .items = &.{
        .{ .name = ":status", .value = "20" },
    } }));
    try testing.expectError(error.InvalidStatus, response(.{ .items = &.{
        .{ .name = ":status", .value = "abc" },
    } }));
    try testing.expectError(error.InvalidAuthority, request(.{ .items = &.{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":path", .value = "/" },
        .{ .name = ":authority", .value = "user@example.com" },
    } }));
    try testing.expectError(error.InvalidAuthority, request(.{ .items = &.{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":path", .value = "/" },
        .{ .name = ":authority", .value = "" },
    } }));
}

test "fuzz field sections never overrun the input" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) anyerror!void {
            var name_buf: [8][16]u8 = undefined;
            var value_buf: [8][16]u8 = undefined;
            var fields: [8]Header = undefined;
            const count = smith.valueRangeAtMost(u8, 0, 8);
            for (0..count) |i| {
                fields[i] = .{
                    .name = name_buf[i][0..smith.slice(&name_buf[i])],
                    .value = value_buf[i][0..smith.slice(&value_buf[i])],
                };
            }
            const items: Headers = .{ .items = fields[0..count] };
            if (request(items)) |head| {
                try testing.expect(head.headers.items.len <= count);
            } else |_| {}
            if (response(items)) |head| {
                try testing.expect(head.headers.items.len <= count);
            } else |_| {}
        }
    }.run, .{ .corpus = &.{
        "",
        "GET",
        "GET / HTTP/1.1",
    } });
}

test "outbound response validation" {
    try validateResponse(.{ .status = .ok });
    try validateResponse(.{
        .status = .ok,
        .content_type = "text/plain",
        .content_length = 5,
        .headers = &.{.{ .name = "x-check", .value = "done" }},
    });
    try testing.expectError(error.DuplicateContentLength, validateResponse(.{
        .status = .ok,
        .headers = &.{.{ .name = "content-length", .value = "5" }},
    }));
    try testing.expectError(error.InvalidStatus, validateResponse(.{
        .status = @fromBackingInt(99),
    }));
    try testing.expectError(error.InvalidFieldName, validateResponse(.{
        .status = .ok,
        .headers = &.{.{ .name = ":status", .value = "200" }},
    }));
}
