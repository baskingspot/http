//! HTTP/1.1 parsing, the connection machine, and the HTTP/1 server engines.
//!
//! The parser APIs are sans-I/O: the parser takes the bytes read so far and
//! reports either a head, `error.Incomplete`, or `error.Invalid`. It allocates
//! nothing and borrows every returned slice from the input. The caller owns the
//! buffer and the storage for the field lines. `engine` is the optional server
//! layer; the parser files do not import a socket.
//!
//! Lifetimes: the returned head borrows the input buffer and the caller's
//! header storage. It is valid only while both are unchanged. A buffered
//! reader may move its bytes when it refills, so copy the fields that must
//! outlive the head before the next read or rebase.
//!
//! Where RFC 9112 permits more than one behavior, this parser picks one and
//! keeps it:
//! - A line end is LF or CRLF. RFC 9112 §2.2 permits recognizing a single LF
//!   as a line terminator, and deployed servers do. A bare CR is invalid.
//! - Start lines require exactly one SP between components. RFC 9112 §3 and
//!   §4 permit whitespace-delimited parsing but warn about smuggling.
//! - obs-fold is rejected. RFC 9112 §5.2 permits reject-or-unfold.
//! - A line before the first field that starts with SP/HTAB is rejected.
//!   RFC 9112 §2.2 permits rejecting or consuming it.
//!
//! The line-ending rule covers the start line and field lines. Framing in the
//! body is strict: `chunked` requires CRLF around a chunk, because those bytes
//! decide where the next message starts.
//!
//! `SearchState` carries the number of bytes already searched for the end of
//! the head. Keep one per connection buffer. The parser records the search
//! length on `error.Incomplete` and clears it after a complete parse; the
//! caller never passes a length. This lets the completeness check look only at
//! the new bytes, so a client trickling one octet at a time cannot force a
//! rescan of the whole buffer. Parsing itself always starts at the beginning.
//! Invalid syntax before a terminator is reported on the first call; after
//! that the gate returns `error.Incomplete` until the terminator arrives.

const std = @import("std");
const compat = @import("../compat.zig");
const testing = std.testing;
const assert = std.debug.assert;
const mem = std.mem;
const fmt = std.fmt;
const math = std.math;

const Cursor = @import("../Cursor.zig");
const Header = @import("../header.zig").Header;
const Headers = @import("../header.zig").Headers;
const Method = @import("../method.zig").Method;
const ows = @import("../ows.zig");
const simd = @import("../simd.zig");
const Status = @import("../status.zig").Status;
const version_mod = @import("../version.zig");
pub const WireVersion = version_mod.WireVersion;
pub const Version = version_mod.Version;
const effectiveVersion = version_mod.effective;
pub const chunked = @import("chunked.zig");
pub const ServerConn = @import("ServerConn.zig");
pub const ClientConn = @import("ClientConn.zig");
pub const client = @import("client/root.zig");
pub const engine = @import("engine/root.zig");
pub const framing = @import("framing.zig");
pub const persistent = @import("persistence.zig").persistent;
const syntax = @import("syntax.zig");
pub const Writer = @import("Writer.zig");

pub const Error = error{
    /// The buffer ends before the head does. Read more and retry.
    Incomplete,
    /// The bytes cannot form an HTTP/1.1 message. The caller should send 400.
    Invalid,
    /// A well-formed HTTP-version this parser does not handle. 505.
    UnsupportedVersion,
    /// The caller's field storage is full. The caller should send 431.
    TooManyHeaders,
};

/// The incremental search state for a head or field section.
///
/// Keep one per connection buffer. Pass `&state` to `parseRequest`,
/// `parseResponse`, or `parseFieldSection`. The parser records how much it
/// searched on `error.Incomplete` and clears the state after a complete parse,
/// so the caller never passes a length and never resets it for the next
/// message.
pub const SearchState = struct {
    searched: u32,

    pub const init: SearchState = .{ .searched = 0 };
};

/// A parsed request head.
///
/// The head borrows. `method_token`, `target`, and every `headers.items` name
/// and value point into the buffer passed to `parseRequest`; `headers.items`
/// itself points into the caller's `Header` storage. The value is valid only
/// while both are unchanged: reading more bytes into the buffer, rebasing it,
/// or reusing the storage invalidates it. Copy anything that must outlive the
/// parse.
///
/// `method`, `version`, and `wire_version` are plain values.
pub const RequestHead = struct {
    /// The common method, or null when the wire token is not one of them.
    method: ?Method,
    /// The exact wire token, always. Methods are case-sensitive (RFC 9110
    /// §9.1), and the registry is open.
    method_token: []const u8,
    target: []const u8,
    /// The effective version, after RFC 9110 §6.2.
    version: Version,
    /// The exact digits from the wire. `HTTP/1.9` is `.{ .major = 1, .minor = 9 }`
    /// here, while `version` is `HTTP/1.1`.
    wire_version: WireVersion,
    headers: Headers,
};

/// A parsed response head.
///
/// The same lifetime rule as `RequestHead`: `reason` and the field lines
/// borrow the input buffer, and `headers.items` borrows the caller's storage.
/// Copy anything that must outlive the parse.
pub const ResponseHead = struct {
    /// The effective version, after RFC 9110 §6.2.
    version: Version,
    /// The exact digits from the wire.
    wire_version: WireVersion,
    /// The three digits as an open `Status`. RFC 9110 §15 makes 100..599 the
    /// meaningful range; this parser returns what the wire said and leaves the
    /// range check to the caller.
    status: Status,
    reason: []const u8,
    headers: Headers,
};

/// A request head and the number of bytes it occupied.
///
/// The head borrows the input buffer and the caller's header storage; see
/// `RequestHead`.
pub const ParsedRequest = struct {
    head: RequestHead,
    /// Bytes consumed, including any leading empty lines.
    consumed: u32,
};

/// A response head and the number of bytes it occupied.
///
/// The head borrows the input buffer and the caller's header storage; see
/// `ResponseHead`.
pub const ParsedResponse = struct {
    head: ResponseHead,
    consumed: u32,
};

/// The request-target forms RFC 9112 §3.2 defines.
pub const TargetForm = enum {
    /// `absolute-path [ "?" query ]`, for an origin server.
    origin,
    /// An absolute URI, for a proxy.
    absolute,
    /// `uri-host ":" port`, for CONNECT.
    authority,
    /// `*`, for OPTIONS.
    asterisk,
};

/// Classify the request-target by the form RFC 9112 §3.2 allows for `method`.
/// Returns null when the bytes do not fit an allowed form. This is syntax only:
/// it does not resolve the authority or normalize the path.
pub fn targetForm(method: ?Method, target: []const u8) ?TargetForm {
    if (target.len == 0) return null;

    if (method == .CONNECT) {
        return if (isAuthorityForm(target)) .authority else null;
    }
    if (target[0] == '/') return .origin;
    if (target.len == 1 and target[0] == '*') {
        return if (method == .OPTIONS) .asterisk else null;
    }
    if (mem.find(u8, target, "://") != null) return .absolute;
    return null;
}

fn isAuthorityForm(target: []const u8) bool {
    if (target.len == 0) return false;

    const port_start: usize = if (target[0] == '[') blk: {
        const close = mem.findScalar(u8, target, ']') orelse return false;
        if (close + 1 >= target.len or target[close + 1] != ':') return false;
        break :blk close + 2;
    } else blk: {
        const colon = mem.findScalarLast(u8, target, ':') orelse return false;
        if (colon == 0 or colon + 1 >= target.len) return false;
        // A bare IPv6 address has more than one colon and needs brackets.
        if (mem.findScalar(u8, target[0..colon], ':') != null) return false;
        break :blk colon + 1;
    };

    if (port_start >= target.len) return false;
    for (target[port_start..]) |byte| {
        if (byte < '0' or byte > '9') return false;
    }
    return true;
}

pub const HostError = error{DuplicateHost};

/// The single `Host` value, or null when the field is absent. More than one
/// field line is `error.DuplicateHost`. RFC 9112 §3.2 requires exactly one
/// Host in an HTTP/1.1 request; the caller applies that rule.
pub const FieldLineError = error{
    /// The line has no colon.
    MissingColon,
    /// The name is empty, or holds a byte outside `tchar`.
    InvalidName,
    /// The value holds a byte outside `field-vchar`, SP, and HTAB.
    InvalidValue,
};

/// Parse one `name: value` field line into a borrowed `Header`, with OWS around
/// the value trimmed.
///
/// The line must not include its CRLF: the caller splits lines. This is the
/// shape for a field a caller holds as text, such as a command-line
/// `--header` flag. A message head goes through `parseRequest` or
/// `parseResponse`, which enforce the same grammar over the whole section.
///
/// Space or tab between the name and the colon is `error.InvalidName`, which
/// is the field-name rule and the anti-smuggling rule at once.
pub fn parseFieldLine(line: []const u8) FieldLineError!Header {
    const colon = mem.findScalar(u8, line, ':') orelse return error.MissingColon;
    const name = line[0..colon];
    if (name.len == 0) return error.InvalidName;
    for (name) |byte| {
        if (!syntax.tchar_table[byte]) return error.InvalidName;
    }
    const value = ows.trim(line[colon + 1 ..]);
    for (value) |byte| {
        if (!syntax.isFieldValueByte(byte)) return error.InvalidValue;
    }
    return .{ .name = name, .value = value };
}

pub fn host(headers: Headers) HostError!?[]const u8 {
    var values = headers.values("Host");
    const first = values.next() orelse return null;
    if (values.next() != null) return error.DuplicateHost;
    return first;
}

/// Parse a request head from `buf`.
///
/// `storage` receives the field lines; the returned `head.headers.items` is
/// the used prefix. The head borrows `buf` and `storage`; see `RequestHead`
/// for what invalidates it.
///
/// `state` is the incremental search state for this buffer; see
/// `SearchState`. `buf` must be shorter than 4 GiB; a real head limit is far
/// smaller.
pub fn parseRequest(
    buf: []const u8,
    state: *SearchState,
    storage: []Header,
) Error!ParsedRequest {
    assert(buf.len <= math.maxInt(u32));
    if (state.searched != 0 and !headComplete(buf, state.searched)) {
        state.searched = @intCast(buf.len);
        return error.Incomplete;
    }
    const parsed = parseRequestInner(buf, storage) catch |err| {
        if (err == error.Incomplete) state.searched = @intCast(buf.len);
        return err;
    };
    state.searched = 0;
    return parsed;
}

fn parseRequestInner(buf: []const u8, storage: []Header) Error!ParsedRequest {
    var cursor: Cursor = .init(buf);
    // RFC 9112 §2.2: a server SHOULD ignore empty lines before the request-line.
    try skipLeadingEmptyLines(&cursor);

    const method_token = try scanToken(&cursor, ' ');
    try expect(&cursor, ' ');
    const target = try scanTarget(&cursor);
    try expect(&cursor, ' ');
    const wire_version = try parseVersion(&cursor);
    const version = try effectiveVersion(wire_version);
    try expectLineEnd(&cursor);

    const headers = try parseHeaders(&cursor, storage);
    return .{
        .head = .{
            .method = Method.parse(method_token),
            .method_token = method_token,
            .target = target,
            .version = version,
            .wire_version = wire_version,
            .headers = headers,
        },
        .consumed = cursor.pos,
    };
}

/// Parse a response head from `buf`.
///
/// A 1xx head is a complete message head. `parseResponse` returns it like any
/// other; a client that wants the final response calls it again on the
/// remaining bytes. `Status.class()` identifies the interim class.
///
/// The head borrows `buf` and `storage`; see `ResponseHead`. `state` works as
/// in `parseRequest`.
pub fn parseResponse(
    buf: []const u8,
    state: *SearchState,
    storage: []Header,
) Error!ParsedResponse {
    assert(buf.len <= math.maxInt(u32));
    if (state.searched != 0 and !headComplete(buf, state.searched)) {
        state.searched = @intCast(buf.len);
        return error.Incomplete;
    }
    const parsed = parseResponseInner(buf, storage) catch |err| {
        if (err == error.Incomplete) state.searched = @intCast(buf.len);
        return err;
    };
    state.searched = 0;
    return parsed;
}

fn parseResponseInner(buf: []const u8, storage: []Header) Error!ParsedResponse {
    var cursor: Cursor = .init(buf);
    const wire_version = try parseVersion(&cursor);
    const version = try effectiveVersion(wire_version);
    try expect(&cursor, ' ');
    const status = try parseStatus(&cursor);
    // RFC 9112 §4: the space is required even when the reason is absent.
    try expect(&cursor, ' ');
    const reason = try scanReason(&cursor);
    try expectLineEnd(&cursor);

    const headers = try parseHeaders(&cursor, storage);
    return .{
        .head = .{
            .version = version,
            .wire_version = wire_version,
            .status = status,
            .reason = reason,
            .headers = headers,
        },
        .consumed = cursor.pos,
    };
}

/// A parsed field section and the number of bytes it occupied.
///
/// The headers borrow the input buffer and the caller's storage, exactly as a
/// `RequestHead` does; see that type for the lifetime rule.
pub const ParsedFieldSection = struct {
    headers: Headers,
    /// Bytes consumed, including the terminating empty line.
    consumed: u32,
};

/// Parse a standalone field section: `*( field-line CRLF ) CRLF`.
///
/// This is the trailer parser and the entry point for a caller that already
/// has a start line. The section is complete at the first empty line; an empty
/// section is a single CRLF. The returned headers borrow `buf` and `storage`;
/// see `RequestHead`.
pub fn parseFieldSection(
    buf: []const u8,
    state: *SearchState,
    storage: []Header,
) Error!ParsedFieldSection {
    assert(buf.len <= math.maxInt(u32));
    if (state.searched != 0 and !fieldSectionComplete(buf, state.searched)) {
        state.searched = @intCast(buf.len);
        return error.Incomplete;
    }
    var cursor: Cursor = .init(buf);
    const headers = parseHeaders(&cursor, storage) catch |err| {
        if (err == error.Incomplete) state.searched = @intCast(buf.len);
        return err;
    };
    state.searched = 0;
    return .{ .headers = headers, .consumed = cursor.pos };
}

/// Whether a complete field section is present. A section can end with the
/// empty line alone, which the head terminator search does not catch.
fn fieldSectionComplete(buf: []const u8, last_len: u32) bool {
    assert(@as(usize, last_len) <= buf.len);
    // One line end with nothing behind it ends the section.
    if (buf.len >= 1 and buf[0] == '\n') return true;
    if (buf.len >= 2 and buf[0] == '\r' and buf[1] == '\n') return true;
    const start: u32 = if (last_len > 4) last_len - 4 else 0;
    return hasHeadEnd(buf, start);
}

/// Consume `byte`, or report why not. The shared cursor is infallible; this
/// is where HTTP/1.1 decides that running out is `Incomplete` and a wrong
/// byte is `Invalid`.
fn expect(cursor: *Cursor, byte: u8) Error!void {
    const got = cursor.next() orelse return error.Incomplete;
    if (got != byte) return error.Invalid;
}

fn expectDigit(cursor: *Cursor) Error!u8 {
    const got = cursor.next() orelse return error.Incomplete;
    if (got < '0' or got > '9') return error.Invalid;
    return got - '0';
}

/// A line end: LF, or CR LF. RFC 9112 §2.2 permits a recipient to recognize
/// a single LF as a line terminator and ignore a preceding CR; this parser
/// does. A bare CR is invalid, as §2.2 requires.
fn expectLineEnd(cursor: *Cursor) Error!void {
    const first = cursor.next() orelse return error.Incomplete;
    if (first == '\n') return;
    if (first != '\r') return error.Invalid;

    const second = cursor.next() orelse return error.Incomplete;
    if (second != '\n') return error.Invalid;
}

/// Whether a complete head terminator is present. A terminator is two line
/// ends in a row, each LF or CRLF, so the shortest is `LF LF`. Starts at
/// `last_len - 4` because a terminator completed by the newest bytes can begin
/// no earlier.
fn headComplete(buf: []const u8, last_len: u32) bool {
    assert(@as(usize, last_len) <= buf.len);
    const start: u32 = if (last_len > 4) last_len - 4 else 0;
    return hasHeadEnd(buf, start);
}

/// Whether a line end that is immediately followed by another line end starts
/// at or after `start`. Every line end contains an LF, so the vector path finds
/// LF candidates. The scalar reference is kept for the tests.
fn hasHeadEnd(buf: []const u8, start: u32) bool {
    var index: usize = start;
    while (simd.first(buf, index, syntax.lfMask, syntax.lfStop)) |at| {
        if (lineEndsAt(buf, at + 1)) return true;
        index = at + 1;
    }
    return false;
}

fn hasHeadEndScalar(buf: []const u8, start: usize) bool {
    var index = start;
    while (index < buf.len) : (index += 1) {
        if (buf[index] != '\n') continue;
        if (lineEndsAt(buf, index + 1)) return true;
    }
    return false;
}

/// Whether a line end starts at `at`: LF, or CR LF. `at` may be the end of the
/// buffer, which is not a line end yet.
fn lineEndsAt(buf: []const u8, at: usize) bool {
    assert(at <= buf.len);
    if (at == buf.len) return false;
    if (buf[at] == '\n') return true;
    return buf[at] == '\r' and at + 1 < buf.len and buf[at + 1] == '\n';
}

/// RFC 9112 §2.2: a server SHOULD ignore at least one empty line before the
/// request-line. An empty line is a line end on its own. More than one is
/// tolerated; a flood is bounded by the caller's buffer limit.
fn skipLeadingEmptyLines(cursor: *Cursor) Error!void {
    while (true) {
        if (cursor.atEnd()) return error.Incomplete;
        switch (cursor.at(cursor.pos)) {
            '\n' => cursor.pos += 1,
            '\r' => {
                if (!cursor.has(2)) return error.Incomplete;
                if (cursor.at(cursor.pos + 1) != '\n') return error.Invalid;
                cursor.pos += 2;
            },
            else => return,
        }
    }
}

/// `token` from RFC 9110 §5.6.2, which is also `method` (RFC 9112 §3.1) and
/// `field-name` (RFC 9112 §5). The delimiter is consumed by the caller.
///
/// One scalar pass, not `findScalarPos` followed by a validation pass. Tokens
/// are short in practice, and the call into std's vector search costs more than
/// the table lookups it replaces. Measured on the bench corpus; a long name is
/// still faster this way than the two-pass version.
fn scanToken(cursor: *Cursor, delimiter: u8) Error![]const u8 {
    const start = cursor.pos;
    var index = start;

    while (@as(usize, index) < cursor.buf.len) : (index += 1) {
        const byte = cursor.at(index);
        if (byte == delimiter) {
            if (index == start) return error.Invalid;
            cursor.pos = index;
            return cursor.slice(start, index);
        }
        if (!syntax.tchar_table[byte]) return error.Invalid;
    }
    return error.Incomplete;
}

/// RFC 9112 §3.2: no whitespace is allowed in the request-target. The form
/// itself (origin, absolute, authority, asterisk) is routing policy and is not
/// validated here. The scan stops at SP and rejects anything outside printable
/// US-ASCII in the same pass.
fn scanTarget(cursor: *Cursor) Error![]const u8 {
    const start = cursor.pos;
    const at = simd.first(cursor.buf, start, syntax.targetMask, syntax.targetStop) orelse
        return error.Incomplete;
    if (cursor.buf[at] != ' ' or at == start) return error.Invalid;
    cursor.pos = @intCast(at);
    return cursor.slice(start, @intCast(at));
}

/// One line up to, but not including, its line end. The line end is LF or
/// CRLF and the caller consumes it with `expectLineEnd`, so a CR is never part
/// of the returned slice. Validation is the field-value or reason-phrase
/// character set; the caller decides whether to trim OWS. The scan stops at CR
/// or LF and rejects any other invalid byte in the same pass.
inline fn scanLine(cursor: *Cursor) Error![]const u8 {
    const start = cursor.pos;
    const at = simd.first(cursor.buf, start, syntax.lineMask, syntax.lineStop) orelse
        return error.Incomplete;
    const byte = cursor.buf[at];
    if (byte != '\r' and byte != '\n') return error.Invalid;
    cursor.pos = @intCast(at);
    return cursor.slice(start, @intCast(at));
}

/// `HTTP/1.0` and `HTTP/1.1` as little-endian `u64`s, for the common case.
const http_1_0 = littleEndianU64("HTTP/1.0");
const http_1_1 = littleEndianU64("HTTP/1.1");

fn littleEndianU64(comptime text: []const u8) u64 {
    var value: u64 = 0;
    for (text, 0..) |byte, index| {
        value |= @as(u64, byte) << @as(u6, @intCast(8 * index));
    }
    return value;
}

/// `HTTP-version` from RFC 9112 §2.3: `%s"HTTP" "/" DIGIT "." DIGIT`, exactly
/// one digit each and case-sensitive. Returns the wire pair; `effectiveVersion`
/// applies the recipient rule.
fn parseVersion(cursor: *Cursor) Error!WireVersion {
    // The two versions this parser implements are one 8-byte compare. Anything
    // else, including 1.2 through 1.9, falls through to the general parser.
    if (cursor.has(8)) {
        const chunk = mem.readVarInt(u64, cursor.buf[@intCast(cursor.pos)..][0..8], .little);
        // 1.1 is the common case; 1.0 is next.
        if (chunk == http_1_1) {
            cursor.pos += 8;
            return .{ .major = 1, .minor = 1 };
        }
        if (chunk == http_1_0) {
            cursor.pos += 8;
            return .{ .major = 1, .minor = 0 };
        }
    }
    return parseVersionSlow(cursor);
}

fn parseVersionSlow(cursor: *Cursor) Error!WireVersion {
    @branchHint(.unlikely);
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

    const major = try expectDigit(cursor);
    try expect(cursor, '.');
    const minor = try expectDigit(cursor);

    return .{ .major = major, .minor = minor };
}

/// RFC 9112 §4: `status-code = 3DIGIT`.
fn parseStatus(cursor: *Cursor) Error!Status {
    const hundreds = try expectDigit(cursor);
    const tens = try expectDigit(cursor);
    const ones = try expectDigit(cursor);
    const value = @as(u16, hundreds) * 100 + @as(u16, tens) * 10 + ones;
    return compat.enumFromInt(Status, @intCast(value));
}

/// RFC 9112 §4: `reason-phrase = 1*( HTAB / SP / VCHAR / obs-text )`, made
/// optional by `[ reason-phrase ]`. Empty is allowed; the separating SP is
/// required and consumed by the caller. Unlike a field value, trailing SP is
/// part of the phrase and is not trimmed.
fn scanReason(cursor: *Cursor) Error![]const u8 {
    return scanLine(cursor);
}

/// `*( field-line CRLF ) CRLF` from RFC 9112 §2.1.
fn parseHeaders(cursor: *Cursor, storage: []Header) Error!Headers {
    var count: u32 = 0;
    while (true) {
        if (cursor.atEnd()) return error.Incomplete;
        const first = cursor.buf[cursor.pos];

        if (first == '\r' or first == '\n') {
            try expectLineEnd(cursor);
            return .{ .items = storage[0..@intCast(count)] };
        }
        // A line beginning with SP/HTAB is obs-fold or whitespace before the
        // first field. RFC 9112 §2.2 and §5.2 let a server reject both; this
        // parser does.
        if (first == ' ' or first == '\t') return error.Invalid;

        const name = try scanToken(cursor, ':');
        // RFC 9112 §5.1: no whitespace between field name and colon.
        try expect(cursor, ':');

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

        try expectLineEnd(cursor);

        if (@as(usize, count) == storage.len) return error.TooManyHeaders;
        storage[@intCast(count)] = .{ .name = name, .value = raw[0..@intCast(value_end)] };
        count += 1;
    }
}

test "target form: the four RFC 9112 §3.2 forms" {
    try testing.expectEqual(TargetForm.origin, targetForm(.GET, "/where?q=now").?);
    try testing.expectEqual(
        TargetForm.absolute,
        targetForm(.GET, "http://www.example.org/pub/WWW/TheProject.html").?,
    );
    try testing.expectEqual(TargetForm.authority, targetForm(.CONNECT, "www.example.com:80").?);
    try testing.expectEqual(TargetForm.authority, targetForm(.CONNECT, "[::1]:443").?);
    try testing.expectEqual(TargetForm.asterisk, targetForm(.OPTIONS, "*").?);
    try testing.expectEqual(TargetForm.absolute, targetForm(null, "http://example.com/").?);

    try testing.expect(targetForm(.GET, "*") == null);
    try testing.expect(targetForm(.GET, "www.example.com:80") == null);
    try testing.expect(targetForm(.CONNECT, "http://example.com/") == null);
    try testing.expect(targetForm(.CONNECT, "example.com") == null);
    try testing.expect(targetForm(.CONNECT, "::1:443") == null);
    try testing.expect(targetForm(.CONNECT, "[::1]") == null);
    try testing.expect(targetForm(.GET, "") == null);
}

test "fuzz target form" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) anyerror!void {
            var buf: [128]u8 = undefined;
            const target = buf[0..smith.slice(&buf)];

            _ = targetForm(null, target);
            _ = targetForm(.CONNECT, target);
            _ = targetForm(.OPTIONS, target);
            _ = targetForm(.GET, target);
        }
    }.run, .{
        .corpus = &.{
            "",
            "/",
            "*",
            "http://example.com/",
            "example.com:443",
            "[::1]:443",
        },
    });
}

test "host: absent, single, and duplicate (RFC 9112 §3.2)" {
    const none: Headers = .{ .items = &.{} };
    try testing.expect(try host(none) == null);

    const one: Headers = .{ .items = &.{
        .{ .name = "Host", .value = "example.com" },
    } };
    try testing.expectEqualStrings("example.com", (try host(one)).?);

    const two: Headers = .{ .items = &.{
        .{ .name = "Host", .value = "a.example" },
        .{ .name = "host", .value = "b.example" },
    } };
    try testing.expectError(error.DuplicateHost, host(two));
}

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

fn parseRequestOnce(buf: []const u8, storage: []Header) Error!ParsedRequest {
    var state: SearchState = .init;
    return parseRequest(buf, &state, storage);
}

fn parseResponseOnce(buf: []const u8, storage: []Header) Error!ParsedResponse {
    var state: SearchState = .init;
    return parseResponse(buf, &state, storage);
}

fn parseFieldSectionOnce(buf: []const u8, storage: []Header) Error!ParsedFieldSection {
    var state: SearchState = .init;
    return parseFieldSection(buf, &state, storage);
}

test "request: a typical head (RFC 9112 §2.1, §3, §5)" {
    var storage: [8]Header = undefined;
    const parsed = try parseRequestOnce(typical, &storage);

    try testing.expectEqualStrings("GET", parsed.head.method_token);
    try testing.expect(parsed.head.method == .GET);
    try testing.expectEqualStrings("/metrics?x=1", parsed.head.target);
    try testing.expectEqual(.@"HTTP/1.1", parsed.head.version);
    try testing.expectEqual(typical.len, parsed.consumed);
    try testing.expectEqual(4, parsed.head.headers.len());

    try testing.expectEqualStrings("Host", parsed.head.headers.items[0].name);
    try testing.expectEqualStrings("example.com", parsed.head.headers.items[0].value);
    try testing.expectEqualStrings("Accept-Encoding", parsed.head.headers.items[3].name);
    try testing.expectEqualStrings("gzip, br", parsed.head.headers.items[3].value);
}

test "request: method is a token (RFC 9112 §3.1, RFC 9110 §5.6.2)" {
    const valid = [_][]const u8{ "GET", "POST", "PRI", "M-SEARCH", "get", "-" };
    for (valid) |method| {
        const buf = try fmt.allocPrint(testing.allocator, "{s} / HTTP/1.1\r\n\r\n", .{method});
        defer testing.allocator.free(buf);
        var storage: [1]Header = undefined;
        const parsed = try parseRequestOnce(buf, &storage);
        try testing.expectEqualStrings(method, parsed.head.method_token);
    }

    for ([_][]const u8{ "GE(T", "GE T", "" }) |method| {
        const buf = try fmt.allocPrint(testing.allocator, "{s} / HTTP/1.1\r\n\r\n", .{method});
        defer testing.allocator.free(buf);
        var storage: [1]Header = undefined;
        try testing.expectError(error.Invalid, parseRequestOnce(buf, &storage));
    }
}

test "request: exactly one SP between components (RFC 9112 §3)" {
    var storage: [1]Header = undefined;
    // §3 permits lenient whitespace-delimited parsing; this parser is strict.
    try testing.expectError(error.Invalid, parseRequestOnce("GET  / HTTP/1.1\r\n\r\n", &storage));
    try testing.expectError(error.Invalid, parseRequestOnce("GET\t/ HTTP/1.1\r\n\r\n", &storage));
    try testing.expectError(error.Invalid, parseRequestOnce("GET /  HTTP/1.1\r\n\r\n", &storage));
}

test "request-target: no whitespace, and non-empty (RFC 9112 §3.2)" {
    var storage: [1]Header = undefined;
    try testing.expectError(error.Invalid, parseRequestOnce("GET /a b HTTP/1.1\r\n\r\n", &storage));
    try testing.expectError(error.Invalid, parseRequestOnce("GET  HTTP/1.1\r\n\r\n", &storage));
    try testing.expectError(
        error.Invalid,
        parseRequestOnce("GET /\x7f HTTP/1.1\r\n\r\n", &storage),
    );
    try testing.expectError(
        error.Invalid,
        parseRequestOnce("GET /\xff HTTP/1.1\r\n\r\n", &storage),
    );
}

test "HTTP-version: syntax, wire pair, and support (RFC 9112 §2.3, RFC 9110 §6.2)" {
    var storage: [1]Header = undefined;

    const v10 = try parseRequestOnce("GET / HTTP/1.0\r\n\r\n", &storage);
    try testing.expectEqual(Version.@"HTTP/1.0", v10.head.version);
    try testing.expectEqual(WireVersion{ .major = 1, .minor = 0 }, v10.head.wire_version);

    // A higher minor within major 1 is processed as the highest supported
    // minor, and the wire pair is kept.
    const v19 = try parseRequestOnce("GET / HTTP/1.9\r\n\r\n", &storage);
    try testing.expectEqual(Version.@"HTTP/1.1", v19.head.version);
    try testing.expectEqual(WireVersion{ .major = 1, .minor = 9 }, v19.head.wire_version);

    // The name is case-sensitive and each component is one digit.
    try testing.expectError(error.Invalid, parseRequestOnce("GET / http/1.1\r\n\r\n", &storage));
    try testing.expectError(error.Invalid, parseRequestOnce("GET / HTTP/1.10\r\n\r\n", &storage));
    try testing.expectError(error.Invalid, parseRequestOnce("GET / HTTP/11.1\r\n\r\n", &storage));

    // A well-formed version with another major is unsupported, not malformed.
    try testing.expectError(
        error.UnsupportedVersion,
        parseRequestOnce("GET / HTTP/2.0\r\n\r\n", &storage),
    );
    try testing.expectError(
        error.UnsupportedVersion,
        parseRequestOnce("GET / HTTP/0.9\r\n\r\n", &storage),
    );
}

test "request: leading empty lines are skipped (RFC 9112 §2.2)" {
    var storage: [1]Header = undefined;
    const buf = "\r\n\r\nGET / HTTP/1.1\r\n\r\n";
    const parsed = try parseRequestOnce(buf, &storage);
    try testing.expectEqual(buf.len, parsed.consumed);
    try testing.expectEqualStrings("GET", parsed.head.method_token);

    // An empty line is LF or CRLF, on its own and mixed.
    const lf = try parseRequestOnce("\n\nGET / HTTP/1.1\n\n", &storage);
    try testing.expectEqual(18, lf.consumed);
    const mixed = try parseRequestOnce("\r\n\nGET / HTTP/1.1\n\n", &storage);
    try testing.expectEqual(19, mixed.consumed);
    try testing.expectEqualStrings("GET", mixed.head.method_token);
}

test "field-line: name colon OWS value OWS (RFC 9112 §5, §5.1)" {
    var storage: [4]Header = undefined;
    const buf =
        "GET / HTTP/1.1\r\n" ++
        "Name: value\r\n" ++
        "Empty:\r\n" ++
        "Padded: \t spaced \t \r\n" ++
        "\r\n";
    const parsed = try parseRequestOnce(buf, &storage);

    try testing.expectEqual(3, parsed.head.headers.len());
    try testing.expectEqualStrings("Name", parsed.head.headers.items[0].name);
    try testing.expectEqualStrings("value", parsed.head.headers.items[0].value);
    try testing.expectEqualStrings("Empty", parsed.head.headers.items[1].name);
    try testing.expectEqualStrings("", parsed.head.headers.items[1].value);
    try testing.expectEqualStrings("Padded", parsed.head.headers.items[2].name);
    try testing.expectEqualStrings("spaced", parsed.head.headers.items[2].value);
}

test "field-line: whitespace before the colon is rejected (RFC 9112 §5.1)" {
    var storage: [1]Header = undefined;
    try testing.expectError(
        error.Invalid,
        parseRequestOnce("GET / HTTP/1.1\r\nName : value\r\n\r\n", &storage),
    );
    try testing.expectError(
        error.Invalid,
        parseRequestOnce("GET / HTTP/1.1\r\nName\t: value\r\n\r\n", &storage),
    );
}

test "field-line: obs-fold is rejected (RFC 9112 §5.2)" {
    var storage: [2]Header = undefined;
    try testing.expectError(
        error.Invalid,
        parseRequestOnce("GET / HTTP/1.1\r\nX: a\r\n b: c\r\n\r\n", &storage),
    );
    // Whitespace between the start-line and the first field is also rejected.
    try testing.expectError(
        error.Invalid,
        parseRequestOnce("GET / HTTP/1.1\r\n Host: x\r\n\r\n", &storage),
    );
}

test "line endings: a bare LF ends a line (RFC 9112 §2.2)" {
    var storage: [2]Header = undefined;
    const parsed = try parseRequestOnce("GET / HTTP/1.1\nHost: x\n\n", &storage);
    try testing.expectEqualStrings("GET", parsed.head.method_token);
    try testing.expectEqual(@as(usize, 1), parsed.head.headers.len());
    try testing.expectEqualStrings("Host", parsed.head.headers.items[0].name);
    try testing.expectEqualStrings("x", parsed.head.headers.items[0].value);
    try testing.expectEqual(24, parsed.consumed);

    // Line ends stand alone: CRLF on one line and LF on the next is not a
    // mixed message, it is two line ends.
    const mixed = try parseRequestOnce("GET / HTTP/1.1\r\nHost: x\n\r\n", &storage);
    try testing.expectEqual(@as(usize, 1), mixed.head.headers.len());

    const response = try parseResponseOnce("HTTP/1.1 200 OK\nA: 1\n\n", &storage);
    try testing.expectEqualStrings("OK", response.head.reason);
    try testing.expectEqualStrings("1", response.head.headers.items[0].value);

    // A field section on its own, which is also the trailer parser.
    var section_state: SearchState = .init;
    const section = try parseFieldSection("A: 1\n\n", &section_state, &storage);
    try testing.expectEqualStrings("1", section.headers.items[0].value);
    try testing.expectEqual(6, section.consumed);
}

test "line endings: a bare CR is invalid (RFC 9112 §2.2)" {
    var storage: [2]Header = undefined;
    try testing.expectError(
        error.Invalid,
        parseRequestOnce("GET / HTTP/1.1\rHost: x\r\n\r\n", &storage),
    );
    try testing.expectError(
        error.Invalid,
        parseRequestOnce("GET / HTTP/1.1\r\nX: a\rb\r\n\r\n", &storage),
    );
    try testing.expectError(
        error.Invalid,
        parseRequestOnce("GET / HTTP/1.1\r\nX: a\r\r\n\r\n", &storage),
    );
    try testing.expectError(error.Invalid, parseResponseOnce("HTTP/1.1 200 OK\r\r\n", &storage));
}

test "line endings: a truncated line end is incomplete" {
    var storage: [1]Header = undefined;
    try testing.expectError(error.Incomplete, parseResponseOnce("HTTP/1.1 200 OK\n", &storage));
    try testing.expectError(error.Incomplete, parseResponseOnce("HTTP/1.1 200 OK\r", &storage));
    try testing.expectError(
        error.Incomplete,
        parseRequestOnce("GET / HTTP/1.1\nHost: x\n", &storage),
    );
}

test "field value: CTLs and NUL are invalid (RFC 9110 §5.5)" {
    var storage: [1]Header = undefined;
    for ([_][]const u8{ "a\x00b", "a\x01b", "a\x0bb", "a\x7fb" }) |value| {
        const buf = try fmt.allocPrint(
            testing.allocator,
            "GET / HTTP/1.1\r\nX: {s}\r\n\r\n",
            .{value},
        );
        defer testing.allocator.free(buf);
        try testing.expectError(error.Invalid, parseRequestOnce(buf, &storage));
    }
}

test "field value: obs-text and HTAB are allowed (RFC 9110 §5.5)" {
    var storage: [2]Header = undefined;
    const parsed = try parseRequestOnce(
        "GET / HTTP/1.1\r\nX: caf\xc3\xa9\r\nY: a\tb\r\n\r\n",
        &storage,
    );
    try testing.expectEqualStrings("caf\xc3\xa9", parsed.head.headers.items[0].value);
    try testing.expectEqualStrings("a\tb", parsed.head.headers.items[1].value);
}

test "fields: order and duplicates are preserved" {
    var storage: [3]Header = undefined;
    const parsed = try parseRequestOnce(
        "GET / HTTP/1.1\r\nSet-Cookie: a=1\r\nX: y\r\nset-cookie: b=2\r\n\r\n",
        &storage,
    );
    try testing.expectEqual(3, parsed.head.headers.len());
    try testing.expectEqualStrings("Set-Cookie", parsed.head.headers.items[0].name);
    try testing.expectEqualStrings("set-cookie", parsed.head.headers.items[2].name);
}

test "fields: storage exhaustion is distinct from invalid syntax" {
    var storage: [1]Header = undefined;
    try testing.expectError(
        error.TooManyHeaders,
        parseRequestOnce("GET / HTTP/1.1\r\nA: 1\r\nB: 2\r\n\r\n", &storage),
    );
}

test "SearchState: an LF-terminated head is found before the last byte (RFC 9112 §2.2)" {
    var storage: [8]Header = undefined;
    var state: SearchState = .init;
    const buf = "GET / HTTP/1.1\nHost: x\n\n";

    for (0..buf.len) |len| {
        try testing.expectError(error.Incomplete, parseRequest(buf[0..len], &state, &storage));
    }
    const parsed = try parseRequest(buf, &state, &storage);
    try testing.expectEqual(buf.len, parsed.consumed);
}

test "incomplete: every strict prefix of a valid request" {
    var storage: [8]Header = undefined;
    for (0..typical.len) |len| {
        try testing.expectError(error.Incomplete, parseRequestOnce(typical[0..len], &storage));
    }
}

test "SearchState: the completeness check sees only new bytes (RFC 9112 §2.2)" {
    var storage: [8]Header = undefined;
    var state: SearchState = .init;
    const prefix = typical.len - 8;
    try testing.expectError(error.Incomplete, parseRequest(typical[0..prefix], &state, &storage));
    try testing.expectEqual(@as(u32, prefix), state.searched);

    const parsed = try parseRequest(typical, &state, &storage);
    try testing.expectEqual(typical.len, parsed.consumed);
    try testing.expectEqual(@as(u32, 0), state.searched);

    // A complete head clears the state for the next message.
    const again = try parseRequest(typical, &state, &storage);
    try testing.expectEqual(typical.len, again.consumed);
}

test "response: a typical head (RFC 9112 §4, §5)" {
    var storage: [4]Header = undefined;
    const parsed = try parseResponseOnce(typical_response, &storage);

    try testing.expectEqual(.@"HTTP/1.1", parsed.head.version);
    try testing.expectEqual(Status.ok, parsed.head.status);
    try testing.expect(parsed.head.status == .ok);
    try testing.expectEqualStrings("OK", parsed.head.reason);
    try testing.expectEqual(2, parsed.head.headers.len());
    try testing.expectEqualStrings("Content-Length", parsed.head.headers.items[1].name);
    try testing.expectEqualStrings("0", parsed.head.headers.items[1].value);
}

test "status-line: the second SP is required, even with no reason (RFC 9112 §4)" {
    var storage: [1]Header = undefined;
    const no_reason = try parseResponseOnce("HTTP/1.1 204 \r\n\r\n", &storage);
    try testing.expectEqual(Status.no_content, no_reason.head.status);
    try testing.expectEqualStrings("", no_reason.head.reason);

    try testing.expectError(error.Invalid, parseResponseOnce("HTTP/1.1 204\r\n\r\n", &storage));
    try testing.expectError(error.Invalid, parseResponseOnce("HTTP/1.1 20 \r\n\r\n", &storage));
    try testing.expectError(error.Invalid, parseResponseOnce("HTTP/1.1 2040 \r\n\r\n", &storage));
}

test "status code: three digits are returned; the range is the caller's (RFC 9110 §15)" {
    var storage: [1]Header = undefined;
    try testing.expectEqual(
        999,
        (try parseResponseOnce("HTTP/1.1 999 X\r\n\r\n", &storage)).head.status.code(),
    );
    try testing.expectEqual(
        0,
        (try parseResponseOnce("HTTP/1.1 000 X\r\n\r\n", &storage)).head.status.code(),
    );
}

test "reason-phrase: HTAB, SP, VCHAR, and obs-text are allowed (RFC 9112 §4)" {
    var storage: [1]Header = undefined;
    const parsed = try parseResponseOnce("HTTP/1.1 200 a\tb caf\xc3\xa9 \r\n\r\n", &storage);
    try testing.expectEqualStrings("a\tb caf\xc3\xa9 ", parsed.head.reason);
}

test "incomplete: every strict prefix of a valid response" {
    var storage: [4]Header = undefined;
    for (0..typical_response.len) |len| {
        try testing.expectError(
            error.Incomplete,
            parseResponseOnce(typical_response[0..len], &storage),
        );
    }
}

test "head terminator: every placement, vector and scalar (RFC 9112 §2.1)" {
    var buf: [4 * simd.Block.width + 8]u8 = undefined;
    for (0..buf.len - 3) |at| {
        @memset(&buf, 'a');
        @memcpy(buf[at..][0..4], "\r\n\r\n");

        try testing.expect(hasHeadEnd(&buf, 0));
        try testing.expect(hasHeadEnd(&buf, @intCast(at)));
        try testing.expect(hasHeadEndScalar(&buf, 0));

        // Two bare LFs are the shortest terminator.
        @memset(&buf, 'a');
        @memcpy(buf[at..][0..2], "\n\n");
        try testing.expect(hasHeadEnd(&buf, 0));
        try testing.expect(hasHeadEndScalar(&buf, 0));

        // The line ends may differ from each other.
        @memset(&buf, 'a');
        @memcpy(buf[at..][0..3], "\r\n\n");
        try testing.expect(hasHeadEnd(&buf, 0));
        try testing.expect(hasHeadEndScalar(&buf, 0));

        @memset(&buf, 'a');
        @memcpy(buf[at..][0..3], "\n\r\n");
        try testing.expect(hasHeadEnd(&buf, 0));
        try testing.expect(hasHeadEndScalar(&buf, 0));
    }

    @memset(&buf, 'a');
    try testing.expect(!hasHeadEnd(&buf, 0));
    try testing.expect(!hasHeadEndScalar(&buf, 0));

    // One CRLF is not the end of the head, and neither is one bare LF.
    @memset(&buf, 'a');
    buf[3] = '\r';
    buf[4] = '\n';
    try testing.expect(!hasHeadEnd(&buf, 0));
    try testing.expect(!hasHeadEndScalar(&buf, 0));

    @memset(&buf, 'a');
    buf[3] = '\n';
    try testing.expect(!hasHeadEnd(&buf, 0));
    try testing.expect(!hasHeadEndScalar(&buf, 0));
}

test "target scanner: every byte at every position (RFC 9112 §3.2)" {
    var buf: [simd.Block.width + 3]u8 = undefined;
    for (0..256) |value| {
        for (0..buf.len) |at| {
            @memset(&buf, 'a');
            buf[at] = @intCast(value);

            var cursor: Cursor = .init(&buf);
            const byte: u8 = @intCast(value);

            if (byte == ' ') {
                if (at == 0) {
                    try testing.expectError(error.Invalid, scanTarget(&cursor));
                } else {
                    const target = try scanTarget(&cursor);
                    try testing.expectEqual(at, target.len);
                    try testing.expectEqual(at, @as(usize, cursor.pos));
                }
            } else if (!syntax.target_set.isSet(byte)) {
                try testing.expectError(error.Invalid, scanTarget(&cursor));
            } else {
                try testing.expectError(error.Incomplete, scanTarget(&cursor));
            }
        }
    }
}

test "line scanner: every byte at every position (RFC 9110 §5.5)" {
    var buf: [simd.Block.width + 3]u8 = undefined;
    for (0..256) |value| {
        for (0..buf.len) |at| {
            @memset(&buf, 'a');
            buf[at] = @intCast(value);

            var cursor: Cursor = .init(&buf);
            const byte: u8 = @intCast(value);

            if (byte == '\r' or byte == '\n') {
                const line = try scanLine(&cursor);
                try testing.expectEqual(at, line.len);
                try testing.expectEqual(at, @as(usize, cursor.pos));
            } else if (!syntax.field_value_set.isSet(byte)) {
                try testing.expectError(error.Invalid, scanLine(&cursor));
            } else {
                try testing.expectError(error.Incomplete, scanLine(&cursor));
            }
        }
    }
}

test "fuzz head terminator against a model" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) anyerror!void {
            var buf: [256]u8 = undefined;
            const input = buf[0..smith.slice(&buf)];

            const want: bool = blk: {
                var index: usize = 0;
                while (index + 1 < input.len) : (index += 1) {
                    if (input[index] != '\n') continue;
                    const next = input[index + 1];
                    if (next == '\n' or
                        (next == '\r' and index + 2 < input.len and input[index + 2] == '\n'))
                    {
                        break :blk true;
                    }
                }
                break :blk false;
            };
            try testing.expectEqual(want, hasHeadEnd(input, 0));
            try testing.expectEqual(want, hasHeadEndScalar(input, 0));
        }
    }.run, .{
        .corpus = &.{
            "",
            "\r\n\r\n",
            "\n\n",
            "\n\r\n",
            "\r\n\n",
            "abc\r\n\r\ndef",
            "\r\r\n\r\n",
            "GET / HTTP/1.1\r\n\r\n",
            "GET / HTTP/1.1\n\n",
        },
    });
}

test "fuzz request head" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) anyerror!void {
            var buf: [256]u8 = undefined;
            const input = buf[0..smith.slice(&buf)];
            var storage: [8]Header = undefined;

            const parsed = parseRequestOnce(input, &storage) catch |err| switch (err) {
                error.Incomplete,
                error.Invalid,
                error.UnsupportedVersion,
                error.TooManyHeaders,
                => return,
            };

            try testing.expect(parsed.consumed <= input.len);
            try testing.expect(parsed.head.method_token.len != 0);
            try testing.expect(parsed.head.target.len != 0);
            for (parsed.head.headers.items) |header| {
                try testing.expect(within(input, header.name));
                try testing.expect(within(input, header.value));
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
            var storage: [8]Header = undefined;

            const parsed = parseResponseOnce(input, &storage) catch |err| switch (err) {
                error.Incomplete,
                error.Invalid,
                error.UnsupportedVersion,
                error.TooManyHeaders,
                => return,
            };

            try testing.expect(parsed.consumed <= input.len);
            try testing.expect(parsed.head.status.code() <= 999);
            for (parsed.head.headers.items) |header| {
                try testing.expect(within(input, header.name));
                try testing.expect(within(input, header.value));
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

test {
    _ = framing;
    _ = @import("persistence.zig");
    _ = chunked;
    _ = Writer;
    _ = ServerConn;
    _ = ClientConn;
    _ = client;
    _ = engine;
}
