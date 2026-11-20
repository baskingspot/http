//! QPACK string literals (RFC 9204 §4.1.2).
//!
//! A string literal is a Huffman flag and a length prefix, then the bytes. The
//! prefix size `n` is the width of the string's header in the first octet: the
//! H bit plus `n - 1` length bits. `n` is 8 for a standalone string, 6 for a
//! name after the `01` instruction tag, and 4 for a name after `001 N` in a
//! field line. The high `8 - n` bits belong to the representation that precedes
//! the string, so the caller ORs its tag into the first octet after `write`.
//!
//! Decoding copies the string into the caller's buffer. Huffman strings have a
//! different decoded length, and a borrowed slice into the input would not have
//! one lifetime rule. The HPACK decoder copies for the same reason.

const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;

const Cursor = @import("../Cursor.zig");
const huffman = @import("../huffman.zig");
const prefix_int = @import("../prefix_int.zig");

pub const WriteError = error{
    /// The destination buffer cannot hold the string.
    NoSpace,
};

pub const Error = error{
    /// The input ended inside the length or the bytes.
    Truncated,
    /// The decoded string does not fit the output buffer.
    NoSpace,
    /// The length does not fit 62 bits.
    InvalidLength,
    /// The Huffman bytes are not a valid code.
    InvalidHuffman,
};

/// Read one string literal whose header occupies the low `n` bits of the next
/// octet, and copy it into `out`.
pub fn decode(cursor: *Cursor, comptime n: u4, out: []u8) Error![]const u8 {
    assert(n >= 2);
    assert(n <= 8);

    const first = cursor.peek() orelse return error.Truncated;
    const huffman_flag = first & (@as(u8, 1) << @intCast(n - 1)) != 0;

    const encoded_len = prefix_int.decodeWide(cursor, n - 1) catch |err| switch (err) {
        error.Truncated => return error.Truncated,
        error.TooLarge => return error.InvalidLength,
    };
    if (encoded_len > cursor.remaining()) return error.Truncated;
    const encoded = cursor.take(@intCast(encoded_len)).?;

    if (!huffman_flag) {
        if (encoded.len > out.len) return error.NoSpace;
        @memcpy(out[0..encoded.len], encoded);
        return out[0..encoded.len];
    }

    const written = huffman.decode(encoded, out) catch |err| switch (err) {
        error.InvalidCode => return error.InvalidHuffman,
        error.NoSpace => return error.NoSpace,
    };
    return out[0..written];
}

/// The bytes `write` needs for `value` with an `n`-bit header.
pub fn encodedLen(value: []const u8, comptime n: u4) usize {
    assert(n >= 2);
    assert(n <= 8);
    const payload = choose(value);
    const len = payloadLen(payload);
    return prefix_int.encodedLenWide(@intCast(len), n - 1) + len;
}

/// Write one string literal. The high `8 - n` bits of the first octet are zero;
/// the caller ORs its representation tag into them.
pub fn write(buf: []u8, value: []const u8, comptime n: u4) WriteError![]u8 {
    assert(n >= 2);
    assert(n <= 8);

    const payload = choose(value);
    if (buf.len < encodedLen(value, n)) return error.NoSpace;

    var pos: usize = 0;
    const length = try prefix_int.encodeWide(buf, @intCast(payloadLen(payload)), n - 1);
    pos += length.len;

    switch (payload) {
        .plain => |bytes| {
            @memcpy(buf[pos..][0..bytes.len], bytes);
            pos += bytes.len;
        },
        .huffman => |encoded| {
            buf[0] |= @as(u8, 1) << @intCast(n - 1);
            pos += huffman.encode(encoded.value, buf[pos..]) catch return error.NoSpace;
        },
    }
    return buf[0..pos];
}

const Payload = union(enum) {
    plain: []const u8,
    huffman: struct {
        value: []const u8,
        len: usize,
    },
};

/// Huffman only when strictly shorter, the same rule the HPACK encoder uses.
fn choose(value: []const u8) Payload {
    const len = huffman.encodedLen(value);
    if (len < value.len) return .{ .huffman = .{ .value = value, .len = len } };
    return .{ .plain = value };
}

fn payloadLen(payload: Payload) usize {
    return switch (payload) {
        .plain => |bytes| bytes.len,
        .huffman => |encoded| encoded.len,
    };
}

test "an 8-bit literal round-trips" {
    var buf: [32]u8 = undefined;
    const written = try write(&buf, "hello", 8);
    try testing.expectEqual(encodedLen("hello", 8), written.len);

    var cursor: Cursor = .init(written);
    var out: [32]u8 = undefined;
    try testing.expectEqualStrings("hello", try decode(&cursor, 8, &out));
    try testing.expect(cursor.atEnd());
}

test "a 6-bit name after a tag gets its tag bits back from the caller" {
    var buf: [32]u8 = undefined;
    const written = try write(&buf, "custom-key", 6);
    written[0] |= 0x40;

    var cursor: Cursor = .init(written);
    var out: [32]u8 = undefined;
    try testing.expectEqualStrings("custom-key", try decode(&cursor, 6, &out));
}

test "a Huffman string decodes to its plain form" {
    var buf: [64]u8 = undefined;
    const written = try write(&buf, "www.example.com", 8);
    try testing.expect(written[0] & 0x80 != 0);
    try testing.expect(written.len < 1 + "www.example.com".len);

    var cursor: Cursor = .init(written);
    var out: [64]u8 = undefined;
    try testing.expectEqualStrings("www.example.com", try decode(&cursor, 8, &out));
}

test "RFC 9204 Appendix B.2, the encoded values decode" {
    const authority = [_]u8{
        0x0f, 'w', 'w', 'w', '.', 'e', 'x', 'a', 'm',
        'p',  'l', 'e', '.', 'c', 'o', 'm',
    };
    var cursor: Cursor = .init(&authority);
    var out: [64]u8 = undefined;
    try testing.expectEqualStrings("www.example.com", try decode(&cursor, 8, &out));
    try testing.expect(cursor.atEnd());

    const path = [_]u8{ 0x0c, '/', 's', 'a', 'm', 'p', 'l', 'e', '/', 'p', 'a', 't', 'h' };
    var path_cursor: Cursor = .init(&path);
    try testing.expectEqualStrings("/sample/path", try decode(&path_cursor, 8, &out));
    try testing.expect(path_cursor.atEnd());
}

test "a truncated length or body is Truncated" {
    var out: [8]u8 = undefined;

    var empty: Cursor = .init("");
    try testing.expectError(error.Truncated, decode(&empty, 8, &out));

    var length_only: Cursor = .init(&.{0x05});
    try testing.expectError(error.Truncated, decode(&length_only, 8, &out));

    var short: Cursor = .init(&.{ 0x05, 'a', 'b' });
    try testing.expectError(error.Truncated, decode(&short, 8, &out));
}

test "a literal larger than the output is NoSpace" {
    const bytes = [_]u8{ 0x05, 'a', 'b', 'c', 'd', 'e' };
    var cursor: Cursor = .init(&bytes);
    var out: [4]u8 = undefined;
    try testing.expectError(error.NoSpace, decode(&cursor, 8, &out));
}
