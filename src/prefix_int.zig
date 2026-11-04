//! Prefix integers, shared by HPACK and QPACK (RFC 7541 §5.1).
//!
//! An integer of up to 32 bits starts with an `N`-bit prefix in an octet and
//! continues into whole octets when the value does not fit. `N` is 1..8 and is
//! a property of the representation that owns the integer, not of this module.
//!
//! The caller keeps the high bits of the first octet. `decode` masks them off,
//! and `encode` leaves them zero, so the caller ORs in the representation tag:
//!
//! ```zig
//! var buf: [5]u8 = undefined;
//! const out = try prefix_int.encode(&buf, index, 7);
//! out[0] |= 0x80;
//! ```
//!
//! Input is bounded to `u32`, which covers every index and string length HPACK
//! or QPACK can express over a buffer that fits in memory. RFC 7541 §5.1
//! permits this: "Integer encodings that exceed implementation limits -- in
//! value or octet length -- MUST be treated as decoding errors." Encodings
//! longer than needed are accepted, as the RFC does not require minimal form.

const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;
const math = std.math;

const Cursor = @import("Cursor.zig");

pub const Error = error{
    /// The input ended inside an integer.
    Truncated,
    /// The value does not fit in 32 bits.
    TooLarge,
};

/// `encode` cannot fail on the value, only on the destination.
pub const EncodeError = error{NoSpace};

/// The largest prefix this representation has: 8 bits, the whole octet.
pub const max_bits: u4 = 8;

/// Decode the integer whose prefix is the low `bits` bits of the next octet,
/// advancing `cursor` past the prefix and any continuation octets.
pub fn decode(cursor: *Cursor, bits: u4) Error!u32 {
    assert(bits >= 1);
    assert(bits <= max_bits);
    assert(cursor.buf.len <= math.maxInt(u32));
    const mask: u8 = @intCast((@as(u16, 1) << @intCast(bits)) - 1);

    const first = cursor.next() orelse return error.Truncated;
    var value: u64 = first & mask;
    if (value < mask) return @intCast(value);

    // value - mask is encoded base 128, least significant group first. Cap the
    // shift at 28: a group above that cannot fit 32 bits.
    var shift: u6 = 0;
    while (true) {
        const byte = cursor.next() orelse return error.Truncated;
        if (shift > 28) return error.TooLarge;
        value += @as(u64, byte & 0x7f) << shift;
        if (value > math.maxInt(u32)) return error.TooLarge;
        if (byte & 0x80 == 0) return @intCast(value);
        shift += 7;
    }
}

/// The number of octets `encode` writes for `value` with a `bits`-wide prefix.
pub fn encodedLen(value: u32, bits: u4) usize {
    assert(bits >= 1);
    assert(bits <= max_bits);
    const mask: u32 = (@as(u32, 1) << @intCast(bits)) - 1;
    if (value < mask) return 1;

    var rest = value - mask;
    var len: usize = 1;
    while (rest >= 128) : (rest /= 128) len += 1;
    return len + 1;
}

/// Encode `value` with a `bits`-wide prefix. The high bits of the first octet
/// are zero; the caller ORs in the representation tag.
pub fn encode(buf: []u8, value: u32, bits: u4) EncodeError![]u8 {
    assert(bits >= 1);
    assert(bits <= max_bits);
    const mask: u32 = (@as(u32, 1) << @intCast(bits)) - 1;
    if (buf.len < encodedLen(value, bits)) return error.NoSpace;

    if (value < mask) {
        buf[0] = @intCast(value);
        return buf[0..1];
    }

    buf[0] = @intCast(mask);
    var rest = value - mask;
    var len: usize = 1;
    while (rest >= 128) : (rest /= 128) {
        buf[len] = @intCast(rest % 128 + 128);
        len += 1;
    }
    buf[len] = @intCast(rest);
    return buf[0 .. len + 1];
}

test "C.1.1: 10 with a 5-bit prefix fits the prefix (RFC 7541 §5.1)" {
    var buf: [1]u8 = undefined;
    const encoded = try encode(&buf, 10, 5);
    try testing.expectEqualSlices(u8, &.{0x0a}, encoded);

    var cursor: Cursor = .init(encoded);
    try testing.expectEqual(10, try decode(&cursor, 5));
    try testing.expect(cursor.atEnd());
}

test "C.1.2: 1337 with a 5-bit prefix continues (RFC 7541 §5.1)" {
    var buf: [3]u8 = undefined;
    const encoded = try encode(&buf, 1337, 5);
    try testing.expectEqualSlices(u8, &.{ 0x1f, 0x9a, 0x0a }, encoded);
    try testing.expectEqual(3, encodedLen(1337, 5));

    var cursor: Cursor = .init(encoded);
    try testing.expectEqual(1337, try decode(&cursor, 5));
    try testing.expect(cursor.atEnd());
}

test "C.1.3: 42 with an 8-bit prefix is one octet (RFC 7541 §5.1)" {
    var buf: [1]u8 = undefined;
    const encoded = try encode(&buf, 42, 8);
    try testing.expectEqualSlices(u8, &.{0x2a}, encoded);

    var cursor: Cursor = .init(encoded);
    try testing.expectEqual(42, try decode(&cursor, 8));
}

test "the prefix boundary: mask - 1, mask, mask + 1" {
    inline for (.{ 1, 4, 5, 7, 8 }) |bits| {
        const mask: u32 = (@as(u32, 1) << @intCast(bits)) - 1;
        const values = [_]u32{ mask - 1, mask, mask + 1 };
        for (values) |value| {
            var buf: [8]u8 = undefined;
            const encoded = try encode(&buf, value, bits);
            try testing.expectEqual(encodedLen(value, bits), encoded.len);

            var cursor: Cursor = .init(encoded);
            try testing.expectEqual(value, try decode(&cursor, bits));
            try testing.expect(cursor.atEnd());
        }
    }
}

test "the high bits of the first octet belong to the representation" {
    var buf: [3]u8 = undefined;
    const encoded = try encode(&buf, 1337, 5);
    encoded[0] |= 0xe0;
    try testing.expectEqual(0xff, encoded[0]);

    var cursor: Cursor = .init(encoded);
    try testing.expectEqual(1337, try decode(&cursor, 5));
}

test "every u32 round-trips at every prefix width" {
    const values = [_]u32{
        0,        1,         127,       128,        255,
        16383,    16384,     65535,     2097151,    2097152,
        16777215, 268435455, 268435456, 4294967294, math.maxInt(u32),
    };
    inline for (.{ 1, 2, 3, 4, 5, 6, 7, 8 }) |bits| {
        for (values) |value| {
            var buf: [8]u8 = undefined;
            const encoded = try encode(&buf, value, bits);
            var cursor: Cursor = .init(encoded);
            try testing.expectEqual(value, try decode(&cursor, bits));
            try testing.expect(cursor.atEnd());
        }
    }
}

test "u32 max with a 5-bit prefix needs five continuation octets" {
    var buf: [8]u8 = undefined;
    const encoded = try encode(&buf, math.maxInt(u32), 5);
    try testing.expectEqualSlices(u8, &.{ 0x1f, 0xe0, 0xff, 0xff, 0xff, 0x0f }, encoded);
}

test "truncation is distinct from an oversized value" {
    // A prefix of 31 says octets follow.
    var cursor: Cursor = .init(&.{0x1f});
    try testing.expectError(error.Truncated, decode(&cursor, 5));

    cursor = .init(&.{ 0x1f, 0x80 });
    try testing.expectError(error.Truncated, decode(&cursor, 5));

    // Zero-payload continuation octets can be repeated without moving value.
    cursor = .init(&.{ 0x1f, 0x80, 0x80, 0x80, 0x80, 0x80, 0x00 });
    try testing.expectError(error.TooLarge, decode(&cursor, 5));

    // A group at shift 28 that overflows u32.
    cursor = .init(&.{ 0x1f, 0x80, 0x80, 0x80, 0x80, 0x10 });
    try testing.expectError(error.TooLarge, decode(&cursor, 5));
}

test "encode refuses a short destination" {
    var buf: [2]u8 = undefined;
    try testing.expectError(error.NoSpace, encode(&buf, 1337, 5));
}

test "fuzz prefix integers against encode" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) anyerror!void {
            const bits: u4 = @intCast(smith.valueRangeAtMost(u8, 0, 7) + 1);
            const value = smith.value(u32);

            var buf: [8]u8 = undefined;
            const encoded = encode(&buf, value, bits) catch return;
            try testing.expectEqual(encodedLen(value, bits), encoded.len);

            var cursor: Cursor = .init(encoded);
            try testing.expectEqual(value, try decode(&cursor, bits));
            try testing.expect(cursor.atEnd());
        }
    }.run, .{});
}

test "fuzz arbitrary bytes never overruns" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) anyerror!void {
            var buf: [64]u8 = undefined;
            const input = buf[0..smith.slice(&buf)];
            for ([_]u4{ 1, 2, 3, 4, 5, 6, 7, 8 }) |bits| {
                var cursor: Cursor = .init(input);
                const value = decode(&cursor, bits) catch continue;
                try testing.expect(value <= math.maxInt(u32));
                try testing.expect(cursor.pos <= input.len);
            }
        }
    }.run, .{
        .corpus = &.{ "", "\x1f", "\x1f\x9a\x0a", "\xff\xff\xff\xff\xff\xff" },
    });
}
