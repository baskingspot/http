//! Chunked transfer coding, RFC 9112 §7.1 through §7.1.3.
//!
//! The decoder is resumable and allocates nothing. Feed it the body bytes
//! available so far; it consumes from the front and returns borrowed chunk
//! data, a trailer section, or `need_more`. Call `next` again with the
//! unconsumed bytes after a read. A chunk data slice may end before the chunk
//! does; the decoder remembers the remaining count across calls.
//!
//! The caller owns the trailer storage and the size limit. The decoder parses
//! and ignores chunk extensions, rejects a chunk-size overflow, and returns
//! trailers separately so the caller can decide which ones are mergeable
//! (RFC 9110 §6.5.1).

const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;
const math = std.math;

const Cursor = @import("../Cursor.zig");
const Header = @import("../header.zig").Header;
const Headers = @import("../header.zig").Headers;
const h1 = @import("root.zig");

pub const Error = error{
    /// The bytes so far do not complete the next chunk-size line, data, or
    /// trailer section. Read more and retry with the unconsumed bytes.
    Incomplete,
    /// The chunk grammar is malformed.
    Invalid,
    /// The chunk size does not fit in `u64`.
    Overflow,
    /// The trailer section does not fit in the caller's `Header` storage.
    TooManyHeaders,
};

pub const Event = union(enum) {
    /// A borrowed slice of chunk data from the front of the input.
    data: []const u8,
    /// The trailer section, after the last chunk. This is the final event;
    /// `isDone()` is true. The headers borrow the input buffer and the
    /// caller's trailer storage.
    trailers: Headers,
    /// The input ended in the middle of a unit. Read more and call again with
    /// the unconsumed bytes.
    need_more,
};

pub const Step = struct {
    /// Bytes consumed from the front of the input, even when `need_more`.
    consumed: u32,
    event: Event,
};

/// A resumable chunked body decoder. The state is caller-owned and survives
/// reads; the trailer storage is caller-owned and must outlive the decoder.
pub const Decoder = struct {
    state: State = .size,
    remaining: u64 = 0,
    trailer_storage: []Header,
    trailer_state: h1.SearchState = .init,

    const State = enum { size, data, data_crlf, trailers, done };

    pub fn init(trailer_storage: []Header) Decoder {
        return .{ .trailer_storage = trailer_storage };
    }

    pub fn isDone(self: *const Decoder) bool {
        return self.state == .done;
    }

    pub fn next(self: *Decoder, buf: []const u8) Error!Step {
        assert(buf.len <= math.maxInt(u32));
        return switch (self.state) {
            .size => self.parseSize(buf),
            .data => self.parseData(buf),
            .data_crlf => self.parseDataCrlf(buf),
            .trailers => self.parseTrailers(buf),
            // The body is complete; the caller should stop on `isDone`.
            .done => .{ .consumed = 0, .event = .need_more },
        };
    }

    fn parseSize(self: *Decoder, buf: []const u8) Error!Step {
        const line_end = findLineEnd(buf) catch |err| switch (err) {
            error.Incomplete => return .{ .consumed = 0, .event = .need_more },
            error.Invalid => return error.Invalid,
        };

        var line: Cursor = .init(buf[0..line_end]);
        var digits: u32 = 0;
        var value: u64 = 0;
        while (line.peek()) |byte| {
            const digit: u8 = switch (byte) {
                '0'...'9' => byte - '0',
                'a'...'f' => byte - 'a' + 10,
                'A'...'F' => byte - 'A' + 10,
                else => break,
            };
            if (value > (math.maxInt(u64) - @as(u64, digit)) / 16) return error.Overflow;
            value = value * 16 + digit;
            _ = line.next();
            digits += 1;
        }
        if (digits == 0) return error.Invalid;

        skipOws(&line);
        if (!line.atEnd()) try skipExtensions(&line);

        self.remaining = value;
        self.state = if (value == 0) .trailers else .data;
        return .{ .consumed = @intCast(line_end + 2), .event = .need_more };
    }

    fn parseData(self: *Decoder, buf: []const u8) Error!Step {
        if (buf.len == 0) return .{ .consumed = 0, .event = .need_more };
        const available: u64 = @intCast(buf.len);
        const n: u32 = @intCast(@min(available, self.remaining));
        const data = buf[0..n];

        self.remaining -= n;
        if (self.remaining == 0) self.state = .data_crlf;
        return .{ .consumed = n, .event = .{ .data = data } };
    }

    fn parseDataCrlf(self: *Decoder, buf: []const u8) Error!Step {
        if (buf.len == 0) return .{ .consumed = 0, .event = .need_more };
        if (buf[0] != '\r') return error.Invalid;
        if (buf.len == 1) return .{ .consumed = 0, .event = .need_more };
        if (buf[1] != '\n') return error.Invalid;

        self.state = .size;
        return .{ .consumed = 2, .event = .need_more };
    }

    fn parseTrailers(self: *Decoder, buf: []const u8) Error!Step {
        const parsed = h1.parseFieldSection(
            buf,
            &self.trailer_state,
            self.trailer_storage,
        ) catch |err| switch (err) {
            error.Incomplete => return .{ .consumed = 0, .event = .need_more },
            error.Invalid => return error.Invalid,
            error.TooManyHeaders => return error.TooManyHeaders,
            error.UnsupportedVersion => unreachable,
        };

        self.state = .done;
        return .{ .consumed = parsed.consumed, .event = .{ .trailers = parsed.headers } };
    }
};

/// Find the CR before the LF. A bare LF is rejected; a trailing CR is
/// incomplete.
fn findLineEnd(buf: []const u8) error{ Incomplete, Invalid }!usize {
    const found = std.mem.findAnyPos(u8, buf, 0, "\r\n") orelse return error.Incomplete;
    if (buf[found] == '\n') return error.Invalid;
    if (found + 1 == buf.len) return error.Incomplete;
    if (buf[found + 1] != '\n') return error.Invalid;
    return found;
}

/// `chunk-ext = *( BWS ";" BWS chunk-ext-name [ BWS "=" BWS chunk-ext-val ] )`.
fn skipExtensions(cursor: *Cursor) Error!void {
    while (!cursor.atEnd()) {
        skipOws(cursor);
        if (cursor.atEnd()) return;
        if (cursor.next() != ';') return error.Invalid;

        skipOws(cursor);
        _ = try scanToken(cursor);
        skipOws(cursor);

        if (cursor.peek() == '=') {
            _ = cursor.next();
            skipOws(cursor);
            if (cursor.peek() == '"') {
                try skipQuotedString(cursor);
            } else {
                _ = try scanToken(cursor);
            }
        }
    }
}

fn skipOws(cursor: *Cursor) void {
    while (cursor.peek()) |byte| {
        if (byte != ' ' and byte != '\t') return;
        _ = cursor.next();
    }
}

fn scanToken(cursor: *Cursor) Error![]const u8 {
    const start = cursor.pos;
    while (cursor.peek()) |byte| {
        if (!isTchar(byte)) break;
        _ = cursor.next();
    }
    if (cursor.pos == start) return error.Invalid;
    return cursor.slice(start, cursor.pos);
}

fn skipQuotedString(cursor: *Cursor) Error!void {
    if (cursor.next() != '"') return error.Invalid;
    while (cursor.next()) |byte| {
        if (byte == '"') return;
        if (byte == '\\') {
            const escaped = cursor.next() orelse return error.Invalid;
            if (!isQuotedPair(escaped)) return error.Invalid;
        } else if (!isQdtext(byte)) {
            return error.Invalid;
        }
    }
    return error.Invalid;
}

/// RFC 9110 §5.6.2.
fn isTchar(byte: u8) bool {
    return switch (byte) {
        '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => true,
        '0'...'9', 'A'...'Z', 'a'...'z' => true,
        else => false,
    };
}

/// RFC 9110 §5.6.4: `qdtext = HTAB / SP / %x21 / %x23-5B / %x5D-7E / obs-text`.
fn isQdtext(byte: u8) bool {
    return byte == '\t' or
        byte == ' ' or
        byte == '!' or
        (byte >= '#' and byte <= '[') or
        (byte >= ']' and byte <= '~') or
        byte >= 0x80;
}

/// RFC 9110 §5.6.4: `quoted-pair = "\" ( HTAB / SP / VCHAR / obs-text )`.
fn isQuotedPair(byte: u8) bool {
    return byte == '\t' or byte == ' ' or (byte >= 0x21 and byte <= 0x7e) or byte >= 0x80;
}

fn decodeAll(input: []const u8, storage: []Header, out: []u8) ![]const u8 {
    var decoder: Decoder = .init(storage);
    var rest = input;
    var len: usize = 0;

    while (!decoder.isDone()) {
        const step = try decoder.next(rest);
        rest = rest[step.consumed..];
        switch (step.event) {
            .data => |data| {
                @memcpy(out[len..][0..data.len], data);
                len += data.len;
            },
            .trailers => {},
            .need_more => if (step.consumed == 0) return error.TestUnexpectedResult,
        }
    }
    return out[0..len];
}

test "one chunk and the last chunk" {
    var storage: [4]Header = undefined;
    var out: [64]u8 = undefined;
    const body = try decodeAll("5\r\nhello\r\n0\r\n\r\n", &storage, &out);
    try testing.expectEqualStrings("hello", body);
}

test "several chunks" {
    var storage: [4]Header = undefined;
    var out: [64]u8 = undefined;
    const body = try decodeAll("5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n", &storage, &out);
    try testing.expectEqualStrings("hello world", body);
}

test "an empty body" {
    var storage: [4]Header = undefined;
    var out: [64]u8 = undefined;
    const body = try decodeAll("0\r\n\r\n", &storage, &out);
    try testing.expectEqualStrings("", body);
}

test "chunk extensions are parsed and ignored" {
    var storage: [4]Header = undefined;
    var out: [64]u8 = undefined;
    const body = try decodeAll(
        "5;foo=bar;q=\"a;b\"\r\nhello\r\n0;last\r\n\r\n",
        &storage,
        &out,
    );
    try testing.expectEqualStrings("hello", body);
}

test "trailers are returned separately" {
    var storage: [4]Header = undefined;
    var decoder: Decoder = .init(&storage);
    var rest: []const u8 = "0\r\nX-Checksum: abc\r\n\r\n";
    var saw_trailers = false;

    while (!decoder.isDone()) {
        const step = try decoder.next(rest);
        rest = rest[step.consumed..];
        switch (step.event) {
            .trailers => |trailers| {
                saw_trailers = true;
                try testing.expectEqual(@as(usize, 1), trailers.len());
                try testing.expectEqualStrings("X-Checksum", trailers.items[0].name);
                try testing.expectEqualStrings("abc", trailers.items[0].value);
            },
            .data => return error.TestUnexpectedResult,
            .need_more => {},
        }
    }
    try testing.expect(saw_trailers);
}

test "a chunk split at every byte still decodes" {
    var storage: [4]Header = undefined;
    var out: [64]u8 = undefined;
    const input: []const u8 = "5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n";

    var decoder: Decoder = .init(&storage);
    var rest = input;
    var len: usize = 0;
    var offered: usize = 1;

    while (!decoder.isDone()) {
        const take = @min(rest.len, offered);
        const step = try decoder.next(rest[0..take]);
        rest = rest[step.consumed..];
        switch (step.event) {
            .data => |data| {
                @memcpy(out[len..][0..data.len], data);
                len += data.len;
            },
            .trailers => {},
            .need_more => {},
        }
        if (step.consumed == 0 and step.event == .need_more) {
            if (offered >= rest.len) return error.TestUnexpectedResult;
            offered += 1;
        } else {
            offered = 1;
        }
    }
    try testing.expectEqualStrings("hello world", out[0..len]);
}

test "chunk-size overflow" {
    var storage: [4]Header = undefined;
    var decoder: Decoder = .init(&storage);
    try testing.expectError(
        error.Overflow,
        decoder.next("10000000000000000\r\n"),
    );
}

test "malformed chunk lines" {
    var storage: [4]Header = undefined;
    const cases = [_][]const u8{
        "z\r\n",
        "5x\r\n",
        "5\rX",
        "5\r\nhello\rX",
        "5\r\nhello\n",
        "5;\r\n",
        "5;foo=\r\n",
        "5;foo=\"unterminated\r\n",
        "0\r\nBad Fold: x\r\n\r\n",
    };
    for (cases) |input| {
        var decoder: Decoder = .init(&storage);
        try testing.expectError(error.Invalid, decodeInvalid(&decoder, input));
    }
}

fn decodeInvalid(decoder: *Decoder, input: []const u8) !void {
    var rest = input;
    while (!decoder.isDone()) {
        const step = try decoder.next(rest);
        rest = rest[step.consumed..];
        if (step.event == .need_more and step.consumed == 0) return error.Incomplete;
    }
}

test "trailer storage exhaustion" {
    var storage: [0]Header = undefined;
    var decoder: Decoder = .init(&storage);
    const input = "0\r\nA: b\r\n\r\n";
    const size = try decoder.next(input);
    try testing.expectEqual(@as(u32, 3), size.consumed);
    try testing.expectError(error.TooManyHeaders, decoder.next(input[size.consumed..]));
}

test "fuzz chunked bodies" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) anyerror!void {
            var buf: [256]u8 = undefined;
            const input = buf[0..smith.slice(&buf)];
            var storage: [8]Header = undefined;
            var decoder: Decoder = .init(&storage);
            var rest = input;
            var data_len: usize = 0;

            while (!decoder.isDone()) {
                const step = decoder.next(rest) catch |err| switch (err) {
                    error.Invalid, error.Incomplete, error.Overflow, error.TooManyHeaders => return,
                };
                try testing.expect(step.consumed <= rest.len);
                rest = rest[step.consumed..];
                switch (step.event) {
                    .data => |data| {
                        try testing.expect(data.len <= input.len);
                        data_len += data.len;
                        try testing.expect(data_len <= input.len);
                    },
                    .trailers => {},
                    .need_more => if (step.consumed == 0) return,
                }
            }
        }
    }.run, .{
        .corpus = &.{
            "",
            "0\r\n\r\n",
            "5\r\nhello\r\n0\r\n\r\n",
            "5;foo=bar\r\nhello\r\n0\r\n\r\n",
            "0\r\nA: b\r\n\r\n",
            "z\r\n",
        },
    });
}
