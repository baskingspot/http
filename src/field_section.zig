//! Field-section syntax shared by HTTP/2 and HTTP/3 (RFC 9110 §5.5,
//! RFC 9113 §8.2, RFC 9114 §4.3).
//!
//! The input is a decoded field list, pseudo-headers included and in wire
//! order. The name and value rules, the pseudo-header order, the forbidden
//! connection-specific fields, the response, and the trailer section are the
//! same for both versions. Each version owns its request rules: HTTP/2 has no
//! `Host`/`:authority` equality check, and HTTP/3 does.
//!
//! Every slice is borrowed; nothing allocates. Cookie fields are not combined
//! here; the caller decides where the combined value lives.

const std = @import("std");
const simd = @import("simd.zig");
const testing = std.testing;
const mem = std.mem;
const ascii = std.ascii;
const stringToEnum = std.meta.stringToEnum;

const Header = @import("header.zig").Header;
const Headers = @import("header.zig").Headers;
const Method = @import("method.zig").Method;
const response_mod = @import("response.zig");
const Status = @import("status.zig").Status;

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

/// The pseudo-header names HTTP/2 and HTTP/3 define (RFC 9113 §8.3,
/// RFC 9114 §4.3, RFC 8441, RFC 9220). An undefined name is `UnknownPseudo`.
pub const Pseudo = enum {
    @":method",
    @":scheme",
    @":authority",
    @":path",
    @":protocol",
    @":status",

    pub fn fromString(str: []const u8) error{UnknownPseudo}!Pseudo {
        return stringToEnum(Pseudo, str) orelse error.UnknownPseudo;
    }
};

pub const RequestHead = struct {
    /// The method. A token outside the named set is `.other`.
    method: Method,
    scheme: ?[]const u8,
    authority: ?[]const u8,
    path: ?[]const u8,
    /// Extended CONNECT (RFC 8441, RFC 9220).
    protocol: ?[]const u8,
    /// The regular fields, in wire order. Pseudo-headers are not included.
    headers: Headers,
};

pub const ResponseHead = struct {
    status: Status,
    /// The regular fields, in wire order. `:status` is not included.
    headers: Headers,
};

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
            switch (try Pseudo.fromString(field.name)) {
                .@":status" => {
                    if (status != null) return error.DuplicatePseudo;
                    status = try parseStatus(field.value);
                },
                else => return error.UnknownPseudo,
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

    return .{
        .status = status orelse return error.MissingPseudo,
        .headers = .{ .items = fields.items[regular_start..] },
    };
}

pub fn validateFieldName(name: []const u8) Error!void {
    if (name.len == 0) return error.InvalidFieldName;
    if (anyBad(name, notLowerTchar, notLowerTcharMask)) return error.InvalidFieldName;
}

pub fn validateValue(value: []const u8) Error!void {
    if (value.len == 0) return;
    if (isOws(value[0]) or isOws(value[value.len - 1])) return error.InvalidFieldValue;
    if (anyBad(value, notValueByte, notValueByteMask)) return error.InvalidFieldValue;
}

pub fn validateRegularField(field: Header) Error!void {
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

pub fn parseStatus(value: []const u8) Error!Status {
    if (value.len != 3) return error.InvalidStatus;
    for (value) |byte| {
        if (byte < '0' or byte > '9') return error.InvalidStatus;
    }
    const code = @as(u16, value[0] - '0') * 100 +
        @as(u16, value[1] - '0') * 10 +
        (value[2] - '0');
    return Status.parse(code) orelse error.InvalidStatus;
}

pub fn validPath(path: []const u8, method: Method) bool {
    if (path.len == 0) return false;
    if (path[0] == '/') return true;
    return method == .OPTIONS and mem.eql(u8, path, "*");
}

pub fn validToken(token: []const u8) bool {
    if (token.len == 0) return false;
    return !anyBad(token, notTchar, notTcharMask);
}

pub fn validScheme(scheme: []const u8) bool {
    if (scheme.len == 0) return false;
    if (!ascii.isAlphabetic(scheme[0])) return false;
    for (scheme[1..]) |byte| {
        if (!ascii.isAlphanumeric(byte) and byte != '+' and byte != '-' and byte != '.') {
            return false;
        }
    }
    return true;
}

pub fn isHttpScheme(scheme: []const u8) bool {
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

// The validators only ask whether any byte is bad, never which one, so the
// offender is not reported and the vector and scalar paths cannot disagree on
// it. Each mask is the lane form of the scalar predicate beside it.

fn splat(comptime byte: u8) simd.Block.Vec {
    return @splat(byte);
}

/// True when any byte of `bytes` fails `stop`.
///
/// Below one SIMD block the scalar loop runs directly: the vector call's
/// setup costs more than the scan saves on the short names, values, and
/// tokens a typical request carries, and the per-field guard keeps those
/// exactly at the old scalar cost. At a block or more, the vector path
/// takes the whole blocks and the scalar tail finishes the remainder. The
/// function is inline, so the guard costs a branch, not a call.
inline fn anyBad(
    bytes: []const u8,
    comptime stop: fn (u8) bool,
    comptime mask: fn (simd.Block.Vec) simd.Block.BoolVec,
) bool {
    if (bytes.len < width) {
        for (bytes) |byte| if (stop(byte)) return true;
        return false;
    }
    return simd.first(bytes, 0, mask, stop) != null;
}

fn inRange(lanes: simd.Block.Vec, comptime lo: u8, comptime hi: u8) simd.Block.BoolVec {
    return (lanes >= splat(lo)) & (lanes <= splat(hi));
}

fn lowerTcharMask(lanes: simd.Block.Vec) simd.Block.BoolVec {
    var ok = inRange(lanes, 'a', 'z') | inRange(lanes, '0', '9');
    inline for ("!#$%&'*+-.^_`|~") |special| ok |= lanes == splat(special);
    return ok;
}

/// A true lane where the byte is not lowercase `tchar`.
fn notLowerTcharMask(lanes: simd.Block.Vec) simd.Block.BoolVec {
    return ~lowerTcharMask(lanes);
}

fn notLowerTchar(byte: u8) bool {
    return !isLowerTchar(byte);
}

/// A true lane where the byte is not `tchar`.
fn notTcharMask(lanes: simd.Block.Vec) simd.Block.BoolVec {
    return ~(lowerTcharMask(lanes) | inRange(lanes, 'A', 'Z'));
}

fn notTchar(byte: u8) bool {
    return !isTchar(byte);
}

/// A true lane on a CTL other than HTAB, or DEL. Bytes >= 0x80 are accepted,
/// as the scalar loop always did.
fn notValueByteMask(lanes: simd.Block.Vec) simd.Block.BoolVec {
    return ((lanes < splat(0x20)) & (lanes != splat('\t'))) | (lanes == splat(0x7f));
}

fn notValueByte(byte: u8) bool {
    return (byte < 0x20 and byte != '\t') or byte == 0x7f;
}

const width = simd.Block.width;

/// Lengths that straddle the vector width: empty, one lane, a full block,
/// and one either side.
const boundary_lengths = [_]usize{ 0, 1, width - 1, width, width + 1, 2 * width, 2 * width + 1 };

fn expectValueError(value: []const u8, expected: ?Error) !void {
    if (expected) |err| {
        try testing.expectError(err, validateValue(value));
    } else {
        try validateValue(value);
    }
}

test "vector field values: a bad byte at every position of every boundary length" {
    var buf: [2 * width + 1]u8 = undefined;
    for (boundary_lengths) |len| {
        @memset(buf[0..len], 'a');
        try expectValueError(buf[0..len], null);
        // Interior tab and high-bit bytes are allowed at every position.
        for (1..@max(len, 2) - 1) |at| {
            for ([_]u8{ '\t', 0x80, 0xff }) |ok| {
                buf[at] = ok;
                try expectValueError(buf[0..len], null);
            }
            buf[at] = 'a';
        }
        // CTLs and DEL are rejected at every position, edges included.
        for (0..len) |at| {
            for ([_]u8{ 0x00, 0x0a, 0x1f, 0x7f }) |bad| {
                buf[at] = bad;
                try expectValueError(buf[0..len], error.InvalidFieldValue);
            }
            buf[at] = 'a';
        }
        // Everything invalid.
        @memset(buf[0..len], 0x01);
        try expectValueError(buf[0..len], if (len == 0) null else error.InvalidFieldValue);
    }
}

test "vector field values: edge whitespace and high-bit runs" {
    var buf: [2 * width + 1]u8 = undefined;
    for (boundary_lengths) |len| {
        @memset(buf[0..len], 0xc3);
        try expectValueError(buf[0..len], null);
        if (len == 0) continue;
        @memset(buf[0..len], 'a');
        buf[0] = ' ';
        try expectValueError(buf[0..len], error.InvalidFieldValue);
        buf[0] = 'a';
        buf[len - 1] = '\t';
        try expectValueError(buf[0..len], error.InvalidFieldValue);
    }
}

test "vector field names: every byte value at every boundary position" {
    var buf: [2 * width + 1]u8 = undefined;
    for (boundary_lengths) |len| {
        @memset(buf[0..len], 'a');
        try testing.expectEqual(len != 0, if (validateFieldName(buf[0..len])) true else |_| false);
        for (0..len) |at| {
            for (0..256) |raw| {
                const byte: u8 = @intCast(raw);
                buf[at] = byte;
                const result = validateFieldName(buf[0..len]);
                if (isLowerTchar(byte)) {
                    try result;
                } else {
                    try testing.expectError(error.InvalidFieldName, result);
                }
            }
            buf[at] = 'a';
        }
        @memset(buf[0..len], 0xff);
        try testing.expectError(error.InvalidFieldName, validateFieldName(buf[0..len]));
    }
    try testing.expectError(error.InvalidFieldName, validateFieldName(""));
}

test "vector tokens: every byte value at every boundary position" {
    var buf: [2 * width + 1]u8 = undefined;
    try testing.expect(!validToken(""));
    for (boundary_lengths[1..]) |len| {
        @memset(buf[0..len], 'G');
        try testing.expect(validToken(buf[0..len]));
        for (0..len) |at| {
            for (0..256) |raw| {
                const byte: u8 = @intCast(raw);
                buf[at] = byte;
                try testing.expectEqual(isTchar(byte), validToken(buf[0..len]));
            }
            buf[at] = 'G';
        }
        @memset(buf[0..len], 0x80);
        try testing.expect(!validToken(buf[0..len]));
    }
}
