//! HTTP/1.1 message head parsing (RFC 9112).
//!
//! Sans-I/O: the parser takes the bytes read so far and reports either a head,
//! `error.Incomplete`, or `error.Invalid`. It allocates nothing and borrows
//! every returned slice from the input. The caller owns the buffer and the
//! storage for the field lines.
//!
//! Chooses strict behavior where RFC 9112 permits leniency:
//! - Bare LF is rejected. RFC 9112 §2.2 says a recipient MAY recognize it.
//! - Start lines require exactly one SP between components. RFC 9112 §3 and
//!   §4 permit whitespace-delimited parsing but warn about smuggling.
//! - obs-fold is rejected. RFC 9112 §5.2 permits reject-or-unfold.
//! - A line before the first field that starts with SP/HTAB is rejected.
//!   RFC 9112 §2.2 permits rejecting or consuming it.
//!
//! `last_len` is the number of bytes already searched for the end of the head
//! (normally the buffer length on the previous call). It lets the completeness
//! check look only at the new bytes, so a client trickling one octet at a time
//! cannot force a rescan of the whole buffer. Parsing itself always starts at
//! the beginning. Invalid syntax before a terminator is reported on the first
//! call (`last_len == 0`); after that the gate returns `error.Incomplete`
//! until the terminator arrives.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const assert = std.debug.assert;
const mem = std.mem;
const fmt = std.fmt;
const math = std.math;

const Field = @import("../field.zig").Field;

pub const Error = error{
    /// The buffer ends before the head does. Read more and retry.
    Incomplete,
    /// The bytes cannot form an HTTP/1.1 message. The caller should send 400.
    Invalid,
    /// A well-formed HTTP-version this parser does not handle. 505.
    UnsupportedVersion,
    /// The caller's field storage is full. The caller should send 431.
    TooManyFields,
};

/// `std.http.Version`, whose tags are the start-line spelling. A message with
/// major version 1 and a higher minor version is processed as 1.1
/// (RFC 9110 §2.5).
pub const Version = std.http.Version;

pub const RequestHead = struct {
    method: []const u8,
    target: []const u8,
    version: Version,
    fields: []const Field,
};

pub const ResponseHead = struct {
    version: Version,
    /// The three decimal digits as a number. RFC 9110 §15 makes 100..599 the
    /// valid range; this parser returns what the wire said and leaves the
    /// range check to the caller.
    status: u16,
    reason: []const u8,
    fields: []const Field,
};

pub const ParsedRequest = struct {
    head: RequestHead,
    /// Bytes consumed, including any leading empty lines.
    consumed: u32,
};

pub const ParsedResponse = struct {
    head: ResponseHead,
    consumed: u32,
};

/// Parse a request head from `buf`.
///
/// `storage` receives the field lines; the returned `head.fields` is the used
/// prefix. `last_len` is the previously searched length, or 0 on the first
/// call. `buf` must be shorter than 4 GiB; a real head limit is far smaller.
pub fn parseRequest(buf: []const u8, last_len: u32, storage: []Field) Error!ParsedRequest {
    assert(buf.len <= math.maxInt(u32));
    if (last_len != 0 and !headComplete(buf, last_len)) return error.Incomplete;

    var cursor: Cursor = .{ .buf = buf };
    // RFC 9112 §2.2: a server SHOULD ignore empty lines before the request-line.
    try skipLeadingEmptyLines(&cursor);

    const method = try scanToken(&cursor, ' ');
    try cursor.expect(' ');
    const target = try scanTarget(&cursor);
    try cursor.expect(' ');
    const version = try parseVersion(&cursor);
    try cursor.expectCrlf();

    const fields = try parseFields(&cursor, storage);
    return .{
        .head = .{
            .method = method,
            .target = target,
            .version = version,
            .fields = fields,
        },
        .consumed = cursor.pos,
    };
}

/// Parse a response head from `buf`. `last_len` works as in `parseRequest`.
pub fn parseResponse(buf: []const u8, last_len: u32, storage: []Field) Error!ParsedResponse {
    assert(buf.len <= math.maxInt(u32));
    if (last_len != 0 and !headComplete(buf, last_len)) return error.Incomplete;

    var cursor: Cursor = .{ .buf = buf };
    const version = try parseVersion(&cursor);
    try cursor.expect(' ');
    const status = try parseStatus(&cursor);
    // RFC 9112 §4: the space is required even when the reason is absent.
    try cursor.expect(' ');
    const reason = try scanReason(&cursor);
    try cursor.expectCrlf();

    const fields = try parseFields(&cursor, storage);
    return .{
        .head = .{
            .version = version,
            .status = status,
            .reason = reason,
            .fields = fields,
        },
        .consumed = cursor.pos,
    };
}

/// Not `stdx.buffer.Queue`: that type panics when a read overruns, while an
/// incomplete HTTP head must return `error.Incomplete` and wait for more
/// bytes. This cursor never owns or refills storage.
const Cursor = struct {
    buf: []const u8,
    pos: u32 = 0,

    fn atEnd(self: Cursor) bool {
        return @as(usize, self.pos) == self.buf.len;
    }

    fn has(self: Cursor, count: u32) bool {
        return @as(usize, self.pos) + count <= self.buf.len;
    }

    /// The byte at `index`. The casts are the one place a head offset becomes
    /// a slice index; `parseRequest` asserts the buffer fits `u32`.
    fn at(self: Cursor, index: u32) u8 {
        return self.buf[@intCast(index)];
    }

    fn slice(self: Cursor, start: u32, end: u32) []const u8 {
        return self.buf[@intCast(start)..@intCast(end)];
    }

    fn expect(self: *Cursor, byte: u8) Error!void {
        if (self.atEnd()) return error.Incomplete;
        if (self.at(self.pos) != byte) return error.Invalid;
        self.pos += 1;
    }

    fn expectDigit(self: *Cursor) Error!u8 {
        if (self.atEnd()) return error.Incomplete;
        const byte = self.at(self.pos);
        if (byte < '0' or byte > '9') return error.Invalid;
        self.pos += 1;
        return byte - '0';
    }

    /// CRLF, and only CRLF. A bare LF is rejected even though RFC 9112 §2.2
    /// permits recognizing one.
    fn expectCrlf(self: *Cursor) Error!void {
        if (self.atEnd()) return error.Incomplete;
        const first = self.at(self.pos);
        if (first == '\n') return error.Invalid;
        if (first != '\r') return error.Invalid;
        self.pos += 1;

        if (self.atEnd()) return error.Incomplete;
        if (self.at(self.pos) != '\n') return error.Invalid;
        self.pos += 1;
    }
};

/// Whether a complete head terminator is present. Starts at `last_len - 4`
/// because a terminator completed by the newest bytes can begin no earlier.
fn headComplete(buf: []const u8, last_len: u32) bool {
    assert(@as(usize, last_len) <= buf.len);
    const start: u32 = if (last_len > 4) last_len - 4 else 0;
    return findHeadEnd(buf, start) != null;
}

/// Bytes per vector scan. A target without vectors, or a big-endian one, uses
/// the scalar path: the mask bit order below assumes lane 0 is the low bit.
const block = std.simd.suggestVectorLength(u8) orelse 8;
const Vec = @Vector(block, u8);
const Mask = @Int(.unsigned, block);
const vector_scans = builtin.cpu.arch.endian() == .little and
    std.simd.suggestVectorLength(u8) != null;

/// The first index of `CRLF CRLF` at or after `start`, or null. The vector
/// path scans for CR and checks the three following bytes; the scalar path
/// covers the tail and every target without vectors.
fn findHeadEnd(buf: []const u8, start: u32) ?u32 {
    if (comptime !vector_scans) return findHeadEndScalar(buf, @intCast(start));

    var index: usize = start;
    while (index + block <= buf.len) : (index += block) {
        const chunk: Vec = buf[index..][0..block].*;
        var mask: Mask = @bitCast(chunk == @as(Vec, @splat('\r')));
        while (mask != 0) : (mask &= mask - 1) {
            const at = index + @as(usize, @ctz(mask));
            if (at + 4 <= buf.len and
                buf[at + 1] == '\n' and
                buf[at + 2] == '\r' and
                buf[at + 3] == '\n')
            {
                return @intCast(at);
            }
        }
    }
    return findHeadEndScalarFrom(buf, index);
}

fn findHeadEndScalar(buf: []const u8, start: usize) ?u32 {
    return findHeadEndScalarFrom(buf, start);
}

fn findHeadEndScalarFrom(buf: []const u8, from: usize) ?u32 {
    var index = from;
    while (index + 4 <= buf.len) : (index += 1) {
        if (buf[index] == '\r' and
            buf[index + 1] == '\n' and
            buf[index + 2] == '\r' and
            buf[index + 3] == '\n')
        {
            return @intCast(index);
        }
    }
    return null;
}

/// RFC 9112 §2.2: a server SHOULD ignore at least one empty line before the
/// request-line. More than one is tolerated; a flood is bounded by the
/// caller's buffer limit.
fn skipLeadingEmptyLines(cursor: *Cursor) Error!void {
    while (true) {
        if (cursor.atEnd()) return error.Incomplete;
        if (cursor.at(cursor.pos) != '\r') return;
        if (@as(usize, cursor.pos) + 1 == cursor.buf.len) return error.Incomplete;
        if (cursor.at(cursor.pos + 1) != '\n') return error.Invalid;
        cursor.pos += 2;
    }
}

/// `token` from RFC 9110 §5.6.2, which is also `method` (RFC 9112 §3.1) and
/// `field-name` (RFC 9112 §5). The delimiter is consumed by the caller.
fn scanToken(cursor: *Cursor, delimiter: u8) Error![]const u8 {
    const start = cursor.pos;
    const found = mem.findScalarPos(u8, cursor.buf, @intCast(start), delimiter);
    const end: u32 = if (found) |index| @intCast(index) else @intCast(cursor.buf.len);

    var index = start;
    while (index < end) : (index += 1) {
        if (!tchar_table[cursor.at(index)]) return error.Invalid;
    }
    if (found == null) return error.Incomplete;
    if (end == start) return error.Invalid;

    cursor.pos = end;
    return cursor.slice(start, end);
}

/// RFC 9112 §3.2: no whitespace is allowed in the request-target. The form
/// itself (origin, absolute, authority, asterisk) is routing policy and is not
/// validated here.
fn scanTarget(cursor: *Cursor) Error![]const u8 {
    const start = cursor.pos;
    const found = mem.findScalarPos(u8, cursor.buf, @intCast(start), ' ');
    const end: u32 = if (found) |index| @intCast(index) else @intCast(cursor.buf.len);

    if (found == null) return error.Incomplete;
    if (end == start) return error.Invalid;

    const target = cursor.slice(start, end);
    if (target.len >= block) {
        if (!allTargetBytes(target)) return error.Invalid;
    } else {
        for (target) |byte| if (!target_table[byte]) return error.Invalid;
    }

    cursor.pos = end;
    return target;
}

/// One line up to, but not including, its CR. Validation is the field-value or
/// reason-phrase character set; the caller decides whether to trim OWS.
fn scanLine(cursor: *Cursor) Error![]const u8 {
    const start = cursor.pos;
    const found = mem.findScalarPos(u8, cursor.buf, @intCast(start), '\r');
    const end: u32 = if (found) |index| @intCast(index) else @intCast(cursor.buf.len);

    if (found == null) return error.Incomplete;

    const line = cursor.slice(start, end);
    if (line.len >= block) {
        if (!allFieldValueBytes(line)) return error.Invalid;
    } else {
        for (line) |byte| if (!field_value_table[byte]) return error.Invalid;
    }

    cursor.pos = end;
    return line;
}

/// `HTTP-version` from RFC 9112 §2.3: `%s"HTTP" "/" DIGIT "." DIGIT`, exactly
/// one digit each and case-sensitive.
///
/// RFC 9110 §2.5 says a recipient that implements a major version should
/// process a higher minor version as its highest supported minor, so 1.2
/// through 1.9 become 1.1.
fn parseVersion(cursor: *Cursor) Error!Version {
    // RFC 9112 §2.3: the name is case-sensitive. A little-endian read of the
    // five bytes is one compare instead of five branches.
    const http_prefix: u40 = 'H' |
        (@as(u40, 'T') << 8) |
        (@as(u40, 'T') << 16) |
        (@as(u40, 'P') << 24) |
        (@as(u40, '/') << 32);
    if (!cursor.has(5)) return error.Incomplete;
    const prefix = mem.readVarInt(u40, cursor.buf[@intCast(cursor.pos)..][0..5], .little);
    if (prefix != http_prefix) return error.Invalid;
    cursor.pos += 5;

    const major = try cursor.expectDigit();
    try cursor.expect('.');
    const minor = try cursor.expectDigit();

    return switch (major) {
        1 => if (minor == 0) .@"HTTP/1.0" else .@"HTTP/1.1",
        else => error.UnsupportedVersion,
    };
}

/// RFC 9112 §4: `status-code = 3DIGIT`.
fn parseStatus(cursor: *Cursor) Error!u16 {
    const hundreds = try cursor.expectDigit();
    const tens = try cursor.expectDigit();
    const ones = try cursor.expectDigit();
    return @as(u16, hundreds) * 100 + @as(u16, tens) * 10 + ones;
}

/// RFC 9112 §4: `reason-phrase = 1*( HTAB / SP / VCHAR / obs-text )`, made
/// optional by `[ reason-phrase ]`. Empty is allowed; the separating SP is
/// required and consumed by the caller. Unlike a field value, trailing SP is
/// part of the phrase and is not trimmed.
fn scanReason(cursor: *Cursor) Error![]const u8 {
    return scanLine(cursor);
}

/// `*( field-line CRLF ) CRLF` from RFC 9112 §2.1.
fn parseFields(cursor: *Cursor, storage: []Field) Error![]const Field {
    var count: u32 = 0;
    while (true) {
        if (cursor.atEnd()) return error.Incomplete;
        const first = cursor.buf[cursor.pos];

        if (first == '\r') {
            try cursor.expectCrlf();
            return storage[0..@intCast(count)];
        }
        // A leading bare LF is not an empty line, and a line beginning with
        // SP/HTAB is obs-fold or whitespace before the first field. RFC 9112
        // §2.2 and §5.2 let a server reject both; this parser does.
        if (first == '\n') return error.Invalid;
        if (first == ' ' or first == '\t') return error.Invalid;

        const name = try scanToken(cursor, ':');
        // RFC 9112 §5.1: no whitespace between field name and colon.
        try cursor.expect(':');

        // RFC 9112 §5.1: OWS before the value is not part of the value.
        while (!cursor.atEnd()) : (cursor.pos += 1) {
            const byte = cursor.at(cursor.pos);
            if (byte != ' ' and byte != '\t') break;
        }

        // RFC 9110 §5.5: field content is VCHAR / obs-text / SP / HTAB.
        // NUL, other CTLs, and DEL are invalid.
        const raw = try scanLine(cursor);

        // RFC 9112 §5.1: trailing OWS is not part of the value.
        var value_end: u32 = @intCast(raw.len);
        while (value_end > 0) : (value_end -= 1) {
            const byte = raw[@intCast(value_end - 1)];
            if (byte != ' ' and byte != '\t') break;
        }

        try cursor.expectCrlf();

        if (@as(usize, count) == storage.len) return error.TooManyFields;
        storage[@intCast(count)] = .{ .name = name, .value = raw[0..@intCast(value_end)] };
        count += 1;
    }
}

/// `tchar` from RFC 9110 §5.6.2.
fn isTchar(byte: u8) bool {
    return switch (byte) {
        '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => true,
        '0'...'9', 'A'...'Z', 'a'...'z' => true,
        else => false,
    };
}

/// RFC 9110 §5.5: `field-vchar` (VCHAR or obs-text), SP, and HTAB.
fn isFieldValueByte(byte: u8) bool {
    return byte == '\t' or (byte >= 0x20 and byte != 0x7f);
}

/// RFC 9112 §3.2: printable US-ASCII, and SP is the delimiter.
fn isTargetByte(byte: u8) bool {
    return byte >= 0x21 and byte <= 0x7e;
}

/// RFC 9112 §3.2: printable US-ASCII. The scalar tail uses `target_table`.
fn allTargetBytes(bytes: []const u8) bool {
    var index: usize = 0;
    if (comptime vector_scans) {
        while (index + block <= bytes.len) : (index += block) {
            const chunk: Vec = bytes[index..][0..block].*;
            const bad = (chunk < @as(Vec, @splat(0x21))) |
                (chunk > @as(Vec, @splat(0x7e)));
            if (@reduce(.Or, bad)) return false;
        }
    }
    while (index < bytes.len) : (index += 1) {
        if (!target_table[bytes[index]]) return false;
    }
    return true;
}

/// RFC 9110 §5.5: no NUL, other CTL, or DEL. The scalar tail uses
/// `field_value_table`.
fn allFieldValueBytes(bytes: []const u8) bool {
    var index: usize = 0;
    if (comptime vector_scans) {
        while (index + block <= bytes.len) : (index += block) {
            const chunk: Vec = bytes[index..][0..block].*;
            const ctl = (chunk < @as(Vec, @splat(0x20))) &
                (chunk != @as(Vec, @splat('\t')));
            const del = chunk == @as(Vec, @splat(0x7f));
            if (@reduce(.Or, ctl | del)) return false;
        }
    }
    while (index < bytes.len) : (index += 1) {
        if (!field_value_table[bytes[index]]) return false;
    }
    return true;
}

fn makeTable(comptime predicate: fn (u8) bool) [256]bool {
    var table: [256]bool = undefined;
    for (0..256) |index| table[index] = predicate(@intCast(index));
    return table;
}

const tchar_table = makeTable(isTchar);
const field_value_table = makeTable(isFieldValueByte);
const target_table = makeTable(isTargetByte);

const typical =
    "GET /metrics?x=1 HTTP/1.1\r\n" ++
    "Host: example.com\r\n" ++
    "User-Agent: test/1.0\r\n" ++
    "Accept: */*\r\n" ++
    "Accept-Encoding: gzip, br\r\n" ++
    "\r\n";

const typical_response =
    "HTTP/1.1 200 OK\r\n" ++
    "Content-Type: text/plain\r\n" ++
    "Content-Length: 0\r\n" ++
    "\r\n";

test "request: a typical head (RFC 9112 §2.1, §3, §5)" {
    var storage: [8]Field = undefined;
    const parsed = try parseRequest(typical, 0, &storage);

    try testing.expectEqualStrings("GET", parsed.head.method);
    try testing.expectEqualStrings("/metrics?x=1", parsed.head.target);
    try testing.expectEqual(.@"HTTP/1.1", parsed.head.version);
    try testing.expectEqual(typical.len, parsed.consumed);
    try testing.expectEqual(4, parsed.head.fields.len);

    try testing.expectEqualStrings("Host", parsed.head.fields[0].name);
    try testing.expectEqualStrings("example.com", parsed.head.fields[0].value);
    try testing.expectEqualStrings("Accept-Encoding", parsed.head.fields[3].name);
    try testing.expectEqualStrings("gzip, br", parsed.head.fields[3].value);
}

test "request: method is a token (RFC 9112 §3.1, RFC 9110 §5.6.2)" {
    const valid = [_][]const u8{ "GET", "POST", "PRI", "M-SEARCH", "get", "-" };
    for (valid) |method| {
        const buf = try fmt.allocPrint(testing.allocator, "{s} / HTTP/1.1\r\n\r\n", .{method});
        defer testing.allocator.free(buf);
        var storage: [1]Field = undefined;
        const parsed = try parseRequest(buf, 0, &storage);
        try testing.expectEqualStrings(method, parsed.head.method);
    }

    for ([_][]const u8{ "GE(T", "GE T", "" }) |method| {
        const buf = try fmt.allocPrint(testing.allocator, "{s} / HTTP/1.1\r\n\r\n", .{method});
        defer testing.allocator.free(buf);
        var storage: [1]Field = undefined;
        try testing.expectError(error.Invalid, parseRequest(buf, 0, &storage));
    }
}

test "request: exactly one SP between components (RFC 9112 §3)" {
    var storage: [1]Field = undefined;
    // §3 permits lenient whitespace-delimited parsing; this parser is strict.
    try testing.expectError(error.Invalid, parseRequest("GET  / HTTP/1.1\r\n\r\n", 0, &storage));
    try testing.expectError(error.Invalid, parseRequest("GET\t/ HTTP/1.1\r\n\r\n", 0, &storage));
    try testing.expectError(error.Invalid, parseRequest("GET /  HTTP/1.1\r\n\r\n", 0, &storage));
}

test "request-target: no whitespace, and non-empty (RFC 9112 §3.2)" {
    var storage: [1]Field = undefined;
    try testing.expectError(error.Invalid, parseRequest("GET /a b HTTP/1.1\r\n\r\n", 0, &storage));
    try testing.expectError(error.Invalid, parseRequest("GET  HTTP/1.1\r\n\r\n", 0, &storage));
    try testing.expectError(error.Invalid, parseRequest("GET /\x7f HTTP/1.1\r\n\r\n", 0, &storage));
    try testing.expectError(error.Invalid, parseRequest("GET /\xff HTTP/1.1\r\n\r\n", 0, &storage));
}

test "HTTP-version: syntax and support (RFC 9112 §2.3, RFC 9110 §2.5)" {
    var storage: [1]Field = undefined;

    try testing.expectEqual(
        Version.@"HTTP/1.0",
        (try parseRequest("GET / HTTP/1.0\r\n\r\n", 0, &storage)).head.version,
    );
    // Minor versions above 1 are processed as 1.1.
    try testing.expectEqual(
        Version.@"HTTP/1.1",
        (try parseRequest("GET / HTTP/1.9\r\n\r\n", 0, &storage)).head.version,
    );

    // The name is case-sensitive and each component is one digit.
    try testing.expectError(error.Invalid, parseRequest("GET / http/1.1\r\n\r\n", 0, &storage));
    try testing.expectError(error.Invalid, parseRequest("GET / HTTP/1.10\r\n\r\n", 0, &storage));
    try testing.expectError(error.Invalid, parseRequest("GET / HTTP/11.1\r\n\r\n", 0, &storage));

    // A well-formed version with another major is unsupported, not malformed.
    try testing.expectError(
        error.UnsupportedVersion,
        parseRequest("GET / HTTP/2.0\r\n\r\n", 0, &storage),
    );
    try testing.expectError(
        error.UnsupportedVersion,
        parseRequest("GET / HTTP/0.9\r\n\r\n", 0, &storage),
    );
}

test "request: leading empty lines are skipped (RFC 9112 §2.2)" {
    var storage: [1]Field = undefined;
    const buf = "\r\n\r\nGET / HTTP/1.1\r\n\r\n";
    const parsed = try parseRequest(buf, 0, &storage);
    try testing.expectEqual(buf.len, parsed.consumed);
    try testing.expectEqualStrings("GET", parsed.head.method);
}

test "field-line: name colon OWS value OWS (RFC 9112 §5, §5.1)" {
    var storage: [4]Field = undefined;
    const buf =
        "GET / HTTP/1.1\r\n" ++
        "Name: value\r\n" ++
        "Empty:\r\n" ++
        "Padded: \t spaced \t \r\n" ++
        "\r\n";
    const parsed = try parseRequest(buf, 0, &storage);

    try testing.expectEqual(3, parsed.head.fields.len);
    try testing.expectEqualStrings("Name", parsed.head.fields[0].name);
    try testing.expectEqualStrings("value", parsed.head.fields[0].value);
    try testing.expectEqualStrings("Empty", parsed.head.fields[1].name);
    try testing.expectEqualStrings("", parsed.head.fields[1].value);
    try testing.expectEqualStrings("Padded", parsed.head.fields[2].name);
    try testing.expectEqualStrings("spaced", parsed.head.fields[2].value);
}

test "field-line: whitespace before the colon is rejected (RFC 9112 §5.1)" {
    var storage: [1]Field = undefined;
    try testing.expectError(
        error.Invalid,
        parseRequest("GET / HTTP/1.1\r\nName : value\r\n\r\n", 0, &storage),
    );
    try testing.expectError(
        error.Invalid,
        parseRequest("GET / HTTP/1.1\r\nName\t: value\r\n\r\n", 0, &storage),
    );
}

test "field-line: obs-fold is rejected (RFC 9112 §5.2)" {
    var storage: [2]Field = undefined;
    try testing.expectError(
        error.Invalid,
        parseRequest("GET / HTTP/1.1\r\nX: a\r\n b: c\r\n\r\n", 0, &storage),
    );
    // Whitespace between the start-line and the first field is also rejected.
    try testing.expectError(
        error.Invalid,
        parseRequest("GET / HTTP/1.1\r\n Host: x\r\n\r\n", 0, &storage),
    );
}

test "field-line: bare LF is rejected; bare CR is invalid (RFC 9112 §2.2)" {
    var storage: [2]Field = undefined;
    // RFC 9112 §2.2 permits recognizing bare LF; this parser does not.
    try testing.expectError(
        error.Invalid,
        parseRequest("GET / HTTP/1.1\nHost: x\n\n", 0, &storage),
    );
    // A bare CR not followed by LF must be treated as invalid.
    try testing.expectError(
        error.Invalid,
        parseRequest("GET / HTTP/1.1\rHost: x\r\n\r\n", 0, &storage),
    );
}

test "field value: CTLs and NUL are invalid (RFC 9110 §5.5)" {
    var storage: [1]Field = undefined;
    for ([_][]const u8{ "a\x00b", "a\x01b", "a\x0bb", "a\x7fb" }) |value| {
        const buf = try fmt.allocPrint(
            testing.allocator,
            "GET / HTTP/1.1\r\nX: {s}\r\n\r\n",
            .{value},
        );
        defer testing.allocator.free(buf);
        try testing.expectError(error.Invalid, parseRequest(buf, 0, &storage));
    }
}

test "field value: obs-text and HTAB are allowed (RFC 9110 §5.5)" {
    var storage: [2]Field = undefined;
    const parsed = try parseRequest(
        "GET / HTTP/1.1\r\nX: caf\xc3\xa9\r\nY: a\tb\r\n\r\n",
        0,
        &storage,
    );
    try testing.expectEqualStrings("caf\xc3\xa9", parsed.head.fields[0].value);
    try testing.expectEqualStrings("a\tb", parsed.head.fields[1].value);
}

test "fields: order and duplicates are preserved" {
    var storage: [3]Field = undefined;
    const parsed = try parseRequest(
        "GET / HTTP/1.1\r\nSet-Cookie: a=1\r\nX: y\r\nset-cookie: b=2\r\n\r\n",
        0,
        &storage,
    );
    try testing.expectEqual(3, parsed.head.fields.len);
    try testing.expectEqualStrings("Set-Cookie", parsed.head.fields[0].name);
    try testing.expectEqualStrings("set-cookie", parsed.head.fields[2].name);
}

test "fields: storage exhaustion is distinct from invalid syntax" {
    var storage: [1]Field = undefined;
    try testing.expectError(
        error.TooManyFields,
        parseRequest("GET / HTTP/1.1\r\nA: 1\r\nB: 2\r\n\r\n", 0, &storage),
    );
}

test "incomplete: every strict prefix of a valid request" {
    var storage: [8]Field = undefined;
    for (0..typical.len) |len| {
        try testing.expectError(error.Incomplete, parseRequest(typical[0..len], 0, &storage));
    }
}

test "last_len: the completeness check sees only new bytes (RFC 9112 §2.2)" {
    var storage: [8]Field = undefined;
    const prefix = typical.len - 8;
    try testing.expectError(error.Incomplete, parseRequest(typical[0..prefix], 0, &storage));
    const parsed = try parseRequest(typical, prefix, &storage);
    try testing.expectEqual(typical.len, parsed.consumed);
    // Passing the current length is still complete, not a rescan trap.
    const again = try parseRequest(typical, typical.len, &storage);
    try testing.expectEqual(typical.len, again.consumed);
}

test "response: a typical head (RFC 9112 §4, §5)" {
    var storage: [4]Field = undefined;
    const parsed = try parseResponse(typical_response, 0, &storage);

    try testing.expectEqual(.@"HTTP/1.1", parsed.head.version);
    try testing.expectEqual(200, parsed.head.status);
    try testing.expectEqualStrings("OK", parsed.head.reason);
    try testing.expectEqual(2, parsed.head.fields.len);
    try testing.expectEqualStrings("Content-Length", parsed.head.fields[1].name);
    try testing.expectEqualStrings("0", parsed.head.fields[1].value);
}

test "status-line: the second SP is required, even with no reason (RFC 9112 §4)" {
    var storage: [1]Field = undefined;
    const no_reason = try parseResponse("HTTP/1.1 204 \r\n\r\n", 0, &storage);
    try testing.expectEqual(204, no_reason.head.status);
    try testing.expectEqualStrings("", no_reason.head.reason);

    try testing.expectError(error.Invalid, parseResponse("HTTP/1.1 204\r\n\r\n", 0, &storage));
    try testing.expectError(error.Invalid, parseResponse("HTTP/1.1 20 \r\n\r\n", 0, &storage));
    try testing.expectError(error.Invalid, parseResponse("HTTP/1.1 2040 \r\n\r\n", 0, &storage));
}

test "status code: three digits are returned; the range is the caller's (RFC 9110 §15)" {
    var storage: [1]Field = undefined;
    try testing.expectEqual(
        999,
        (try parseResponse("HTTP/1.1 999 X\r\n\r\n", 0, &storage)).head.status,
    );
    try testing.expectEqual(
        0,
        (try parseResponse("HTTP/1.1 000 X\r\n\r\n", 0, &storage)).head.status,
    );
}

test "reason-phrase: HTAB, SP, VCHAR, and obs-text are allowed (RFC 9112 §4)" {
    var storage: [1]Field = undefined;
    const parsed = try parseResponse("HTTP/1.1 200 a\tb caf\xc3\xa9 \r\n\r\n", 0, &storage);
    try testing.expectEqualStrings("a\tb caf\xc3\xa9 ", parsed.head.reason);
}

test "incomplete: every strict prefix of a valid response" {
    var storage: [4]Field = undefined;
    for (0..typical_response.len) |len| {
        try testing.expectError(
            error.Incomplete,
            parseResponse(typical_response[0..len], 0, &storage),
        );
    }
}

test "head terminator: every placement, vector and scalar (RFC 9112 §2.1)" {
    var buf: [4 * block + 8]u8 = undefined;
    for (0..buf.len - 3) |at| {
        @memset(&buf, 'a');
        @memcpy(buf[at..][0..4], "\r\n\r\n");

        const want: ?u32 = @intCast(at);
        try testing.expectEqual(want, findHeadEnd(&buf, 0));
        try testing.expectEqual(want, findHeadEnd(&buf, @intCast(at)));
        try testing.expectEqual(want, findHeadEndScalar(&buf, 0));
    }

    @memset(&buf, 'a');
    try testing.expect(findHeadEnd(&buf, 0) == null);
    try testing.expect(findHeadEndScalar(&buf, 0) == null);

    // One CRLF is not the end of the head.
    @memset(&buf, 'a');
    buf[3] = '\r';
    buf[4] = '\n';
    try testing.expect(findHeadEnd(&buf, 0) == null);
}

test "value validation: vector and scalar agree (RFC 9110 §5.5, RFC 9112 §3.2)" {
    var buf: [block + 3]u8 = undefined;
    for (0..256) |value| {
        for (0..buf.len) |at| {
            @memset(&buf, 'a');
            buf[at] = @intCast(value);

            try testing.expectEqual(scalarTarget(&buf), allTargetBytes(&buf));
            try testing.expectEqual(scalarFieldValue(&buf), allFieldValueBytes(&buf));
        }
    }
}

fn scalarTarget(bytes: []const u8) bool {
    for (bytes) |byte| if (!target_table[byte]) return false;
    return true;
}

fn scalarFieldValue(bytes: []const u8) bool {
    for (bytes) |byte| if (!field_value_table[byte]) return false;
    return true;
}

test "fuzz head terminator against std" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) anyerror!void {
            var buf: [256]u8 = undefined;
            const input = buf[0..smith.slice(&buf)];

            const want: ?u32 = if (mem.findPos(u8, input, 0, "\r\n\r\n")) |at|
                @intCast(at)
            else
                null;
            try testing.expectEqual(want, findHeadEnd(input, 0));
        }
    }.run, .{
        .corpus = &.{
            "",
            "\r\n\r\n",
            "abc\r\n\r\ndef",
            "\r\r\n\r\n",
            "GET / HTTP/1.1\r\n\r\n",
        },
    });
}

test "fuzz request head" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) anyerror!void {
            var buf: [256]u8 = undefined;
            const input = buf[0..smith.slice(&buf)];
            var storage: [8]Field = undefined;

            const parsed = parseRequest(input, 0, &storage) catch |err| switch (err) {
                error.Incomplete,
                error.Invalid,
                error.UnsupportedVersion,
                error.TooManyFields,
                => return,
            };

            try testing.expect(parsed.consumed <= input.len);
            try testing.expect(parsed.head.method.len != 0);
            try testing.expect(parsed.head.target.len != 0);
            for (parsed.head.fields) |field| {
                try testing.expect(within(input, field.name));
                try testing.expect(within(input, field.value));
            }
        }
    }.run, .{
        .corpus = &.{
            typical,
            "GET / HTTP/1.1\r\n\r\n",
            "\r\nGET / HTTP/1.0\r\nX: y\r\n\r\n",
            "GET / HTTP/1.1\r\nA: b\r\n c: d\r\n\r\n",
        },
    });
}

test "fuzz response head" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) anyerror!void {
            var buf: [256]u8 = undefined;
            const input = buf[0..smith.slice(&buf)];
            var storage: [8]Field = undefined;

            const parsed = parseResponse(input, 0, &storage) catch |err| switch (err) {
                error.Incomplete,
                error.Invalid,
                error.UnsupportedVersion,
                error.TooManyFields,
                => return,
            };

            try testing.expect(parsed.consumed <= input.len);
            try testing.expect(parsed.head.status <= 999);
            for (parsed.head.fields) |field| {
                try testing.expect(within(input, field.name));
                try testing.expect(within(input, field.value));
            }
        }
    }.run, .{
        .corpus = &.{
            typical_response,
            "HTTP/1.0 204 \r\n\r\n",
            "HTTP/1.1 500 Internal\r\n\r\n",
        },
    });
}

fn within(outer: []const u8, inner: []const u8) bool {
    const base = @intFromPtr(outer.ptr);
    const start = @intFromPtr(inner.ptr);
    return start >= base and start + inner.len <= base + outer.len;
}
