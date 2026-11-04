//! HTTP/2 field-section validation and the request/response heads
//! (RFC 9113 §8.2, §8.3).
//!
//! The input is the decoded field list HPACK produced, pseudo-headers
//! included and in wire order. The output extracts the pseudo-headers into a
//! typed head and exposes the regular fields as a `Headers` view over the same
//! storage. Every slice is borrowed; nothing allocates.
//!
//! Validation follows RFC 9113 §8.2.1's minimal rules, with field names
//! restricted to lowercase `tchar` as HTTP/1.1's parser already does. A
//! malformed field section is a stream error of type PROTOCOL_ERROR
//! (RFC 9113 §8.1.1); the caller maps `Error`.
//!
//! Cookie fields are *not* combined here. RFC 9113 §8.2.3 says they combine
//! with `"; "` before processing; the caller decides where the combined value
//! lives.

const std = @import("std");
const testing = std.testing;
const mem = std.mem;
const ascii = std.ascii;

const Header = @import("../header.zig").Header;
const Headers = @import("../header.zig").Headers;
const Method = @import("../method.zig").Method;
const Status = @import("../status.zig").Status;
const response_mod = @import("../response.zig");

pub const Error = error{
    /// A field name is empty, has a colon, or is not lowercase tchar.
    InvalidFieldName,
    /// A field value has NUL, CR, LF, another control, or edge whitespace.
    InvalidFieldValue,
    /// A pseudo-header followed a regular field.
    PseudoAfterField,
    /// A pseudo-header appeared more than once.
    DuplicatePseudo,
    /// A pseudo-header this direction does not define.
    UnknownPseudo,
    /// A required pseudo-header is missing.
    MissingPseudo,
    /// `:method` is not a non-empty token.
    InvalidMethod,
    /// `:scheme` is not a valid scheme.
    InvalidScheme,
    /// `:path` is empty, not absolute, or `*` without OPTIONS.
    InvalidPath,
    /// `:authority` is empty or carries userinfo for http(s).
    InvalidAuthority,
    /// `:status` is not exactly three digits.
    InvalidStatus,
    /// `:protocol` is not a token, or is used without CONNECT.
    InvalidProtocol,
    /// A connection-specific field is present, or `TE` is not `trailers`.
    ForbiddenField,
    /// An outbound response put `content-length` in the extra fields.
    DuplicateContentLength,
};

/// The pseudo-header names this version defines (RFC 9113 §8.3, RFC 8441).
/// A future extension name is `UnknownPseudo`, which is what the current
/// validation requires for undefined pseudo-headers.
const Pseudo = enum {
    @":method",
    @":scheme",
    @":authority",
    @":path",
    @":protocol",
    @":status",
};

pub const RequestHead = struct {
    /// The common method, or null when the token is not one of them.
    method: ?Method,
    /// The exact `:method` token. Always present.
    method_token: []const u8,
    scheme: ?[]const u8,
    authority: ?[]const u8,
    path: ?[]const u8,
    /// RFC 8441 extended CONNECT.
    protocol: ?[]const u8,
    /// The regular fields, in wire order. Pseudo-headers are not included.
    headers: Headers,
};

pub const ResponseHead = struct {
    status: Status,
    /// The regular fields, in wire order. `:status` is not included.
    headers: Headers,
};

pub fn request(fields: Headers) Error!RequestHead {
    var method: ?[]const u8 = null;
    var scheme: ?[]const u8 = null;
    var authority: ?[]const u8 = null;
    var path: ?[]const u8 = null;
    var protocol: ?[]const u8 = null;
    var seen_regular = false;
    var regular_start: usize = fields.items.len;

    for (fields.items, 0..) |field, index| {
        try validateValue(field.value);
        if (field.name.len != 0 and field.name[0] == ':') {
            if (seen_regular) return error.PseudoAfterField;
            const pseudo = std.meta.stringToEnum(Pseudo, field.name) orelse
                return error.UnknownPseudo;
            switch (pseudo) {
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
    const method_enum = Method.parse(method_token);

    if (method_enum == .CONNECT) {
        if (protocol) |_| {
            // RFC 8441: extended CONNECT carries scheme, path, and authority.
            if (scheme == null or path == null) return error.MissingPseudo;
            if (authority == null) return error.MissingPseudo;
            if (!validPath(path.?, method_token)) return error.InvalidPath;
        } else {
            // RFC 9113 §8.5: CONNECT omits scheme and path.
            if (scheme != null) return error.InvalidScheme;
            if (path != null) return error.InvalidPath;
            if (authority == null) return error.MissingPseudo;
        }
    } else {
        if (protocol != null) return error.InvalidProtocol;
        if (scheme == null or path == null) return error.MissingPseudo;
        if (!validPath(path.?, method_token)) return error.InvalidPath;
    }

    if (scheme) |s| {
        if (authority) |a| {
            if (isHttpScheme(s) and mem.findScalar(u8, a, '@') != null) {
                return error.InvalidAuthority;
            }
        }
    }

    return .{
        .method = method_enum,
        .method_token = method_token,
        .scheme = scheme,
        .authority = authority,
        .path = path,
        .protocol = protocol,
        .headers = .{ .items = fields.items[regular_start..] },
    };
}

/// Validate a trailer section: regular fields only, no pseudo-headers.
pub fn trailers(fields: Headers) Error!Headers {
    for (fields.items) |field| {
        try validateValue(field.value);
        if (field.name.len != 0 and field.name[0] == ':') return error.UnknownPseudo;
        try validateFieldName(field.name);
        try validateRegularField(field);
    }
    return fields;
}

/// Validate the typed outbound response. The status is in range, the content
/// type is a legal field value, and every extra field is a regular field with
/// no connection-specific semantics.
pub fn validateResponse(value: response_mod.Response) Error!void {
    const code = value.status.code();
    if (code < 100 or code > 999) return error.InvalidStatus;
    if (value.content_type) |content_type| try validateValue(content_type);

    for (value.headers) |field| {
        try validateValue(field.value);
        try validateFieldName(field.name);
        try validateRegularField(field);
        if (mem.eql(u8, field.name, "content-length")) return error.DuplicateContentLength;
    }
}

pub fn response(fields: Headers) Error!ResponseHead {
    var status: ?Status = null;
    var seen_regular = false;
    var regular_start: usize = fields.items.len;

    for (fields.items, 0..) |field, index| {
        try validateValue(field.value);
        if (field.name.len != 0 and field.name[0] == ':') {
            if (seen_regular) return error.PseudoAfterField;
            const pseudo = std.meta.stringToEnum(Pseudo, field.name) orelse
                return error.UnknownPseudo;
            if (pseudo != .@":status") return error.UnknownPseudo;
            if (status != null) return error.DuplicatePseudo;
            status = try parseStatus(field.value);
        } else {
            try validateFieldName(field.name);
            try validateRegularField(field);
            if (!seen_regular) {
                seen_regular = true;
                regular_start = index;
            }
        }
    }

    return .{
        .status = status orelse return error.MissingPseudo,
        .headers = .{ .items = fields.items[regular_start..] },
    };
}

fn validateFieldName(name: []const u8) Error!void {
    if (name.len == 0) return error.InvalidFieldName;
    for (name) |byte| {
        if (!isLowerTchar(byte)) return error.InvalidFieldName;
    }
}

fn validateValue(value: []const u8) Error!void {
    if (value.len == 0) return;
    if (isOws(value[0]) or isOws(value[value.len - 1])) return error.InvalidFieldValue;
    for (value) |byte| {
        if (byte == '\t') continue;
        if (byte < 0x20) return error.InvalidFieldValue;
        if (byte == 0x7f) return error.InvalidFieldValue;
    }
}

fn validateRegularField(field: Header) Error!void {
    const name = field.name;
    if (mem.eql(u8, name, "connection") or
        mem.eql(u8, name, "keep-alive") or
        mem.eql(u8, name, "proxy-connection") or
        mem.eql(u8, name, "transfer-encoding") or
        mem.eql(u8, name, "upgrade"))
    {
        return error.ForbiddenField;
    }
    if (mem.eql(u8, name, "te")) {
        if (!ascii.eqlIgnoreCase(field.value, "trailers")) return error.ForbiddenField;
    }
}

fn parseStatus(value: []const u8) Error!Status {
    if (value.len != 3) return error.InvalidStatus;
    for (value) |byte| {
        if (byte < '0' or byte > '9') return error.InvalidStatus;
    }
    const code = @as(u16, value[0] - '0') * 100 +
        @as(u16, value[1] - '0') * 10 +
        (value[2] - '0');
    return Status.parse(code) orelse error.InvalidStatus;
}

fn validPath(path: []const u8, method_token: []const u8) bool {
    if (path.len == 0) return false;
    if (path[0] == '/') return true;
    return mem.eql(u8, path, "*") and mem.eql(u8, method_token, "OPTIONS");
}

fn validToken(token: []const u8) bool {
    if (token.len == 0) return false;
    for (token) |byte| {
        if (!isTchar(byte)) return false;
    }
    return true;
}

fn validScheme(scheme: []const u8) bool {
    if (scheme.len == 0) return false;
    if (!ascii.isAlphabetic(scheme[0])) return false;
    for (scheme[1..]) |byte| {
        if (!ascii.isAlphanumeric(byte) and byte != '+' and byte != '-' and byte != '.') {
            return false;
        }
    }
    return true;
}

fn isHttpScheme(scheme: []const u8) bool {
    return ascii.eqlIgnoreCase(scheme, "http") or ascii.eqlIgnoreCase(scheme, "https");
}

fn isOws(byte: u8) bool {
    return byte == ' ' or byte == '\t';
}

/// `tchar` from RFC 9110 §5.6.2, lowercase only.
fn isLowerTchar(byte: u8) bool {
    return switch (byte) {
        'a'...'z',
        '0'...'9',
        '!',
        '#',
        '$',
        '%',
        '&',
        '\'',
        '*',
        '+',
        '-',
        '.',
        '^',
        '_',
        '`',
        '|',
        '~',
        => true,
        else => false,
    };
}

/// `tchar` is case-sensitive; the uppercase letters are valid here, and the
/// field-name validator rejects them separately.
fn isTchar(byte: u8) bool {
    return isLowerTchar(byte) or (byte >= 'A' and byte <= 'Z');
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
    try testing.expectEqual(Method.GET, head.method.?);
    try testing.expectEqualStrings("GET", head.method_token);
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
    try testing.expect(head.method == null);
    try testing.expectEqualStrings("QUERY", head.method_token);
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
        .status = @enumFromInt(99),
    }));
    try testing.expectError(error.InvalidFieldName, validateResponse(.{
        .status = .ok,
        .headers = &.{.{ .name = ":status", .value = "200" }},
    }));
}
