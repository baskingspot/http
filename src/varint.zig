//! QUIC variable-length integers (RFC 9000 §16).
//!
//! The two most significant bits of the first octet give the width: 1, 2, 4,
//! or 8 bytes, carrying 6, 14, 30, or 62 bits. The value is the remaining bits
//! in network byte order.
//!
//! Non-minimal encodings are legal everywhere except one field. §16: "Values
//! do not need to be encoded on the minimum number of bytes necessary, with the
//! sole exception of the Frame Type field". `decode` accepts every width.
//! `decodeMinimal` rejects the wider encoding, and QUIC calls it for its frame
//! type. An HTTP/3 frame type has no such rule, so `h3.frame` uses `decode`.
//!
//! This is the integer format HTTP/3 frames use. RFC 7541 §5.1's prefix
//! integer is a different encoding, and `prefix_int` owns that one.

const std = @import("std");
const testing = std.testing;
const mem = std.mem;

const Cursor = @import("Cursor.zig");

/// The largest value the encoding can carry: 2^62 - 1.
pub const max: u62 = (1 << 62) - 1;

/// What a plain `decode` can report. `NonMinimal` belongs to `decodeMinimal`
/// alone, so it is not here: an error a function cannot return is a branch
/// every caller writes and no test reaches.
pub const Error = error{
    /// The buffer ended inside the integer. Nothing moved.
    Truncated,
};

pub const DecodeError = error{
    /// The buffer ended inside the integer. Nothing moved.
    Truncated,
    /// The integer does not use the shortest encoding for its value (§16).
    NonMinimal,
};

/// `encode` cannot fail on the value, only on the destination.
pub const EncodeError = error{NoSpace};

/// The width of the encoding of `value`, in bytes: 1, 2, 4, or 8.
///
/// The parameter is `u62`, which is `max`: the type carries the range, so this
/// function needs no assertion and no caller can pass a value with no encoding.
pub fn encodedLen(value: u62) usize {
    if (value < 1 << 6) return 1;
    if (value < 1 << 14) return 2;
    if (value < 1 << 30) return 4;
    return 8;
}

/// Read one integer of any width, advancing `cursor` past it. On
/// `error.Truncated` the cursor does not move.
pub fn decode(cursor: *Cursor) Error!u62 {
    const rest = cursor.rest();
    if (rest.len == 0) return error.Truncated;
    const width = widthOfPrefix(rest[0]);
    if (rest.len < width) return error.Truncated;
    const value = assemble(rest[0..width]);
    _ = cursor.skip(@intCast(width));
    return value;
}

/// Read one integer and reject a width wider than its value needs.
///
/// RFC 9000 §12.4 requires the Frame Type field to use the shortest encoding,
/// and §16 names that field as the sole exception to the non-minimal rule. On
/// `error.NonMinimal` the cursor does not move.
pub fn decodeMinimal(cursor: *Cursor) DecodeError!u62 {
    const rest = cursor.rest();
    if (rest.len == 0) return error.Truncated;
    const width = widthOfPrefix(rest[0]);
    if (rest.len < width) return error.Truncated;
    const value = assemble(rest[0..width]);
    if (width != encodedLen(value)) return error.NonMinimal;
    _ = cursor.skip(@intCast(width));
    return value;
}

/// Write `value` in the shortest encoding that carries it, and return the
/// octets written. A short buffer is `error.NoSpace` and writes nothing.
pub fn encode(buf: []u8, value: u62) EncodeError![]u8 {
    const width = encodedLen(value);
    if (buf.len < width) return error.NoSpace;

    var octets: [8]u8 = undefined;
    mem.writeInt(u64, &octets, @as(u64, value), .big);
    const start = octets.len - width;
    octets[start] |= switch (width) {
        1 => 0x00,
        2 => 0x40,
        4 => 0x80,
        else => 0xc0,
    };

    @memcpy(buf[0..width], octets[start..]);
    return buf[0..width];
}

/// The width in bytes that the first octet's two-bit prefix announces.
fn widthOfPrefix(first: u8) usize {
    return @as(usize, 1) << @intCast(first >> 6);
}

/// The integer carried by a slice whose width matches the prefix. The prefix
/// drops the top two bits, so every width assembles into the 62-bit range.
fn assemble(bytes: []const u8) u62 {
    var value: u62 = bytes[0] & 0x3f;
    for (bytes[1..]) |byte| value = (value << 8) | byte;
    return value;
}

fn expectDecode(bytes: []const u8, expected: u62) !void {
    var cursor: Cursor = .init(bytes);
    try testing.expectEqual(expected, try decode(&cursor));
    try testing.expectEqual(@as(u32, @intCast(bytes.len)), cursor.pos);
}

fn expectEncoded(value: u62, expected: []const u8) !void {
    var buf: [8]u8 = undefined;
    const encoded = try encode(&buf, value);
    try testing.expectEqualSlices(u8, expected, encoded);
    try expectDecode(expected, value);
}

test "RFC 9000 §16 Table 4, the four widths and their boundaries" {
    try expectEncoded(0, &.{0x00});
    try expectEncoded(37, &.{0x25});
    try expectEncoded(63, &.{0x3f});

    try expectEncoded(64, &.{ 0x40, 0x40 });
    try expectEncoded(15293, &.{ 0x7b, 0xbd });
    try expectEncoded(16383, &.{ 0x7f, 0xff });

    try expectEncoded(16384, &.{ 0x80, 0x00, 0x40, 0x00 });
    try expectEncoded(494878333, &.{ 0x9d, 0x7f, 0x3e, 0x7d });
    try expectEncoded(1073741823, &.{ 0xbf, 0xff, 0xff, 0xff });

    try expectEncoded(1073741824, &.{ 0xc0, 0x00, 0x00, 0x00, 0x40, 0x00, 0x00, 0x00 });
    try expectEncoded(151288809941952652, &.{ 0xc2, 0x19, 0x7c, 0x5e, 0xff, 0x14, 0xe8, 0x8c });
    try expectEncoded(max, &.{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff });
}

test "RFC 9000 Appendix A.1, the sample encodings decode" {
    try expectDecode(&.{0x25}, 37);
    try expectDecode(&.{ 0x7b, 0xbd }, 15293);
    try expectDecode(&.{ 0x9d, 0x7f, 0x3e, 0x7d }, 494878333);
    try expectDecode(&.{ 0xc2, 0x19, 0x7c, 0x5e, 0xff, 0x14, 0xe8, 0x8c }, 151288809941952652);
}

test "RFC 9000 §16, a value may use a wider encoding than it needs" {
    try expectDecode(&.{ 0x40, 0x25 }, 37);
    try expectDecode(&.{ 0x80, 0x00, 0x00, 0x25 }, 37);
    try expectDecode(&.{ 0xc0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x25 }, 37);
    try expectDecode(&.{ 0x7f, 0xff }, 16383);
}

test "RFC 9000 §12.4, the frame type field must use the shortest encoding" {
    var cursor: Cursor = .init(&.{0x25});
    try testing.expectEqual(@as(u62, 0x25), try decodeMinimal(&cursor));
    try testing.expectEqual(@as(u32, 1), cursor.pos);

    const padded = [_][]const u8{
        &.{ 0x40, 0x25 },
        &.{ 0x80, 0x00, 0x00, 0x25 },
        &.{ 0xc0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x25 },
    };
    for (padded) |bytes| {
        var padded_cursor: Cursor = .init(bytes);
        try testing.expectError(error.NonMinimal, decodeMinimal(&padded_cursor));
        try testing.expectEqual(@as(u32, 0), padded_cursor.pos);
    }
}

test "RFC 9000 §16, a truncated integer is an error and moves nothing" {
    const truncated = [_][]const u8{
        &.{},
        &.{0x40},
        &.{0x80},
        &.{ 0x80, 0x00 },
        &.{ 0x80, 0x00, 0x00 },
        &.{0xc0},
        &.{ 0xc0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 },
    };
    for (truncated) |bytes| {
        var cursor: Cursor = .init(bytes);
        try testing.expectError(error.Truncated, decode(&cursor));
        try testing.expectEqual(@as(u32, 0), cursor.pos);
    }
}

test "a value that does not fit leaves the buffer untouched" {
    var buf: [1]u8 = undefined;
    try testing.expectError(error.NoSpace, encode(&buf, 16384));
    try testing.expectEqual(@as(u8, 0x3f), (try encode(&buf, 63))[0]);
}

test "decode reads only the integer, leaving the rest for the caller" {
    var cursor: Cursor = .init(&.{ 0x7b, 0xbd, 0xaa, 0xbb });
    try testing.expectEqual(@as(u62, 15293), try decode(&cursor));
    try testing.expectEqual(@as(u32, 2), cursor.pos);
    try testing.expectEqualSlices(u8, &.{ 0xaa, 0xbb }, cursor.rest());
}

test "fuzz decode against a bounded model" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) anyerror!void {
            var buf: [16]u8 = undefined;
            const input = buf[0..smith.slice(&buf)];

            var cursor: Cursor = .init(input);
            const value = decode(&cursor) catch |err| {
                try testing.expect(err == error.Truncated);
                try testing.expectEqual(@as(u32, 0), cursor.pos);
                return;
            };
            try testing.expect(value <= max);

            // A successful decode consumed exactly the width the prefix
            // announced, which is at least the width the value needs.
            const announced: u32 = @intCast(widthOfPrefix(input[0]));
            try testing.expectEqual(announced, cursor.pos);
            try testing.expect(cursor.pos >= @as(u32, @intCast(encodedLen(value))));

            var out: [8]u8 = undefined;
            const encoded = try encode(&out, value);
            var round: Cursor = .init(encoded);
            try testing.expectEqual(value, try decode(&round));
            try testing.expectEqual(@as(u32, @intCast(encoded.len)), round.pos);
        }
    }.run, .{
        .corpus = &.{
            "",
            "\x25",
            "\x7b\xbd",
            "\xc2\x19\x7c\x5e\xff\x14\xe8\x8c",
            "\xff\xff\xff\xff\xff\xff\xff\xff",
        },
    });
}
