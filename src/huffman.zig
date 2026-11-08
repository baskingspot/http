//! The static Huffman code from RFC 7541 Appendix B.
//!
//! HPACK uses it for string literals; QPACK reuses it unchanged (RFC 9204
//! §4.1.3). The code is canonical: symbols of one length hold consecutive
//! code values, so decoding is an 8-bit root table for the short codes and a
//! canonical scan for the rest. Every letter, digit, and most punctuation in
//! a field value is eight bits or shorter, so the scan is the rare path.
//!
//! Decoding enforces RFC 7541 §5.2: EOS is an error, padding longer than
//! seven bits is an error, and padding must be the leading bits of EOS.

const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;
const mem = std.mem;

const Cursor = @import("Cursor.zig");
const compat = @import("compat.zig");

pub const Error = error{
    /// Not a code, an encoded EOS symbol, or padding that is not EOS's prefix.
    InvalidCode,
    /// The destination buffer is too small.
    NoSpace,
};

/// `encode` cannot fail on the input, only on the destination.
pub const EncodeError = error{NoSpace};

pub const Code = struct { bits: u32, len: u5 };

/// Indexed by symbol; 256 is EOS. `bits` is right-aligned.
pub const table: [257]Code = .{
    .{ .bits = 0x1ff8, .len = 13 }, // 0x00
    .{ .bits = 0x7fffd8, .len = 23 }, // 0x01
    .{ .bits = 0xfffffe2, .len = 28 }, // 0x02
    .{ .bits = 0xfffffe3, .len = 28 }, // 0x03
    .{ .bits = 0xfffffe4, .len = 28 }, // 0x04
    .{ .bits = 0xfffffe5, .len = 28 }, // 0x05
    .{ .bits = 0xfffffe6, .len = 28 }, // 0x06
    .{ .bits = 0xfffffe7, .len = 28 }, // 0x07
    .{ .bits = 0xfffffe8, .len = 28 }, // 0x08
    .{ .bits = 0xffffea, .len = 24 }, // 0x09
    .{ .bits = 0x3ffffffc, .len = 30 }, // 0x0a
    .{ .bits = 0xfffffe9, .len = 28 }, // 0x0b
    .{ .bits = 0xfffffea, .len = 28 }, // 0x0c
    .{ .bits = 0x3ffffffd, .len = 30 }, // 0x0d
    .{ .bits = 0xfffffeb, .len = 28 }, // 0x0e
    .{ .bits = 0xfffffec, .len = 28 }, // 0x0f
    .{ .bits = 0xfffffed, .len = 28 }, // 0x10
    .{ .bits = 0xfffffee, .len = 28 }, // 0x11
    .{ .bits = 0xfffffef, .len = 28 }, // 0x12
    .{ .bits = 0xffffff0, .len = 28 }, // 0x13
    .{ .bits = 0xffffff1, .len = 28 }, // 0x14
    .{ .bits = 0xffffff2, .len = 28 }, // 0x15
    .{ .bits = 0x3ffffffe, .len = 30 }, // 0x16
    .{ .bits = 0xffffff3, .len = 28 }, // 0x17
    .{ .bits = 0xffffff4, .len = 28 }, // 0x18
    .{ .bits = 0xffffff5, .len = 28 }, // 0x19
    .{ .bits = 0xffffff6, .len = 28 }, // 0x1a
    .{ .bits = 0xffffff7, .len = 28 }, // 0x1b
    .{ .bits = 0xffffff8, .len = 28 }, // 0x1c
    .{ .bits = 0xffffff9, .len = 28 }, // 0x1d
    .{ .bits = 0xffffffa, .len = 28 }, // 0x1e
    .{ .bits = 0xffffffb, .len = 28 }, // 0x1f
    .{ .bits = 0x14, .len = 6 }, // 0x20
    .{ .bits = 0x3f8, .len = 10 }, // 0x21
    .{ .bits = 0x3f9, .len = 10 }, // 0x22
    .{ .bits = 0xffa, .len = 12 }, // 0x23
    .{ .bits = 0x1ff9, .len = 13 }, // 0x24
    .{ .bits = 0x15, .len = 6 }, // 0x25
    .{ .bits = 0xf8, .len = 8 }, // 0x26
    .{ .bits = 0x7fa, .len = 11 }, // 0x27
    .{ .bits = 0x3fa, .len = 10 }, // 0x28
    .{ .bits = 0x3fb, .len = 10 }, // 0x29
    .{ .bits = 0xf9, .len = 8 }, // 0x2a
    .{ .bits = 0x7fb, .len = 11 }, // 0x2b
    .{ .bits = 0xfa, .len = 8 }, // 0x2c
    .{ .bits = 0x16, .len = 6 }, // 0x2d
    .{ .bits = 0x17, .len = 6 }, // 0x2e
    .{ .bits = 0x18, .len = 6 }, // 0x2f
    .{ .bits = 0x0, .len = 5 }, // 0x30
    .{ .bits = 0x1, .len = 5 }, // 0x31
    .{ .bits = 0x2, .len = 5 }, // 0x32
    .{ .bits = 0x19, .len = 6 }, // 0x33
    .{ .bits = 0x1a, .len = 6 }, // 0x34
    .{ .bits = 0x1b, .len = 6 }, // 0x35
    .{ .bits = 0x1c, .len = 6 }, // 0x36
    .{ .bits = 0x1d, .len = 6 }, // 0x37
    .{ .bits = 0x1e, .len = 6 }, // 0x38
    .{ .bits = 0x1f, .len = 6 }, // 0x39
    .{ .bits = 0x5c, .len = 7 }, // 0x3a
    .{ .bits = 0xfb, .len = 8 }, // 0x3b
    .{ .bits = 0x7ffc, .len = 15 }, // 0x3c
    .{ .bits = 0x20, .len = 6 }, // 0x3d
    .{ .bits = 0xffb, .len = 12 }, // 0x3e
    .{ .bits = 0x3fc, .len = 10 }, // 0x3f
    .{ .bits = 0x1ffa, .len = 13 }, // 0x40
    .{ .bits = 0x21, .len = 6 }, // 0x41
    .{ .bits = 0x5d, .len = 7 }, // 0x42
    .{ .bits = 0x5e, .len = 7 }, // 0x43
    .{ .bits = 0x5f, .len = 7 }, // 0x44
    .{ .bits = 0x60, .len = 7 }, // 0x45
    .{ .bits = 0x61, .len = 7 }, // 0x46
    .{ .bits = 0x62, .len = 7 }, // 0x47
    .{ .bits = 0x63, .len = 7 }, // 0x48
    .{ .bits = 0x64, .len = 7 }, // 0x49
    .{ .bits = 0x65, .len = 7 }, // 0x4a
    .{ .bits = 0x66, .len = 7 }, // 0x4b
    .{ .bits = 0x67, .len = 7 }, // 0x4c
    .{ .bits = 0x68, .len = 7 }, // 0x4d
    .{ .bits = 0x69, .len = 7 }, // 0x4e
    .{ .bits = 0x6a, .len = 7 }, // 0x4f
    .{ .bits = 0x6b, .len = 7 }, // 0x50
    .{ .bits = 0x6c, .len = 7 }, // 0x51
    .{ .bits = 0x6d, .len = 7 }, // 0x52
    .{ .bits = 0x6e, .len = 7 }, // 0x53
    .{ .bits = 0x6f, .len = 7 }, // 0x54
    .{ .bits = 0x70, .len = 7 }, // 0x55
    .{ .bits = 0x71, .len = 7 }, // 0x56
    .{ .bits = 0x72, .len = 7 }, // 0x57
    .{ .bits = 0xfc, .len = 8 }, // 0x58
    .{ .bits = 0x73, .len = 7 }, // 0x59
    .{ .bits = 0xfd, .len = 8 }, // 0x5a
    .{ .bits = 0x1ffb, .len = 13 }, // 0x5b
    .{ .bits = 0x7fff0, .len = 19 }, // 0x5c
    .{ .bits = 0x1ffc, .len = 13 }, // 0x5d
    .{ .bits = 0x3ffc, .len = 14 }, // 0x5e
    .{ .bits = 0x22, .len = 6 }, // 0x5f
    .{ .bits = 0x7ffd, .len = 15 }, // 0x60
    .{ .bits = 0x3, .len = 5 }, // 0x61
    .{ .bits = 0x23, .len = 6 }, // 0x62
    .{ .bits = 0x4, .len = 5 }, // 0x63
    .{ .bits = 0x24, .len = 6 }, // 0x64
    .{ .bits = 0x5, .len = 5 }, // 0x65
    .{ .bits = 0x25, .len = 6 }, // 0x66
    .{ .bits = 0x26, .len = 6 }, // 0x67
    .{ .bits = 0x27, .len = 6 }, // 0x68
    .{ .bits = 0x6, .len = 5 }, // 0x69
    .{ .bits = 0x74, .len = 7 }, // 0x6a
    .{ .bits = 0x75, .len = 7 }, // 0x6b
    .{ .bits = 0x28, .len = 6 }, // 0x6c
    .{ .bits = 0x29, .len = 6 }, // 0x6d
    .{ .bits = 0x2a, .len = 6 }, // 0x6e
    .{ .bits = 0x7, .len = 5 }, // 0x6f
    .{ .bits = 0x2b, .len = 6 }, // 0x70
    .{ .bits = 0x76, .len = 7 }, // 0x71
    .{ .bits = 0x2c, .len = 6 }, // 0x72
    .{ .bits = 0x8, .len = 5 }, // 0x73
    .{ .bits = 0x9, .len = 5 }, // 0x74
    .{ .bits = 0x2d, .len = 6 }, // 0x75
    .{ .bits = 0x77, .len = 7 }, // 0x76
    .{ .bits = 0x78, .len = 7 }, // 0x77
    .{ .bits = 0x79, .len = 7 }, // 0x78
    .{ .bits = 0x7a, .len = 7 }, // 0x79
    .{ .bits = 0x7b, .len = 7 }, // 0x7a
    .{ .bits = 0x7ffe, .len = 15 }, // 0x7b
    .{ .bits = 0x7fc, .len = 11 }, // 0x7c
    .{ .bits = 0x3ffd, .len = 14 }, // 0x7d
    .{ .bits = 0x1ffd, .len = 13 }, // 0x7e
    .{ .bits = 0xffffffc, .len = 28 }, // 0x7f
    .{ .bits = 0xfffe6, .len = 20 }, // 0x80
    .{ .bits = 0x3fffd2, .len = 22 }, // 0x81
    .{ .bits = 0xfffe7, .len = 20 }, // 0x82
    .{ .bits = 0xfffe8, .len = 20 }, // 0x83
    .{ .bits = 0x3fffd3, .len = 22 }, // 0x84
    .{ .bits = 0x3fffd4, .len = 22 }, // 0x85
    .{ .bits = 0x3fffd5, .len = 22 }, // 0x86
    .{ .bits = 0x7fffd9, .len = 23 }, // 0x87
    .{ .bits = 0x3fffd6, .len = 22 }, // 0x88
    .{ .bits = 0x7fffda, .len = 23 }, // 0x89
    .{ .bits = 0x7fffdb, .len = 23 }, // 0x8a
    .{ .bits = 0x7fffdc, .len = 23 }, // 0x8b
    .{ .bits = 0x7fffdd, .len = 23 }, // 0x8c
    .{ .bits = 0x7fffde, .len = 23 }, // 0x8d
    .{ .bits = 0xffffeb, .len = 24 }, // 0x8e
    .{ .bits = 0x7fffdf, .len = 23 }, // 0x8f
    .{ .bits = 0xffffec, .len = 24 }, // 0x90
    .{ .bits = 0xffffed, .len = 24 }, // 0x91
    .{ .bits = 0x3fffd7, .len = 22 }, // 0x92
    .{ .bits = 0x7fffe0, .len = 23 }, // 0x93
    .{ .bits = 0xffffee, .len = 24 }, // 0x94
    .{ .bits = 0x7fffe1, .len = 23 }, // 0x95
    .{ .bits = 0x7fffe2, .len = 23 }, // 0x96
    .{ .bits = 0x7fffe3, .len = 23 }, // 0x97
    .{ .bits = 0x7fffe4, .len = 23 }, // 0x98
    .{ .bits = 0x1fffdc, .len = 21 }, // 0x99
    .{ .bits = 0x3fffd8, .len = 22 }, // 0x9a
    .{ .bits = 0x7fffe5, .len = 23 }, // 0x9b
    .{ .bits = 0x3fffd9, .len = 22 }, // 0x9c
    .{ .bits = 0x7fffe6, .len = 23 }, // 0x9d
    .{ .bits = 0x7fffe7, .len = 23 }, // 0x9e
    .{ .bits = 0xffffef, .len = 24 }, // 0x9f
    .{ .bits = 0x3fffda, .len = 22 }, // 0xa0
    .{ .bits = 0x1fffdd, .len = 21 }, // 0xa1
    .{ .bits = 0xfffe9, .len = 20 }, // 0xa2
    .{ .bits = 0x3fffdb, .len = 22 }, // 0xa3
    .{ .bits = 0x3fffdc, .len = 22 }, // 0xa4
    .{ .bits = 0x7fffe8, .len = 23 }, // 0xa5
    .{ .bits = 0x7fffe9, .len = 23 }, // 0xa6
    .{ .bits = 0x1fffde, .len = 21 }, // 0xa7
    .{ .bits = 0x7fffea, .len = 23 }, // 0xa8
    .{ .bits = 0x3fffdd, .len = 22 }, // 0xa9
    .{ .bits = 0x3fffde, .len = 22 }, // 0xaa
    .{ .bits = 0xfffff0, .len = 24 }, // 0xab
    .{ .bits = 0x1fffdf, .len = 21 }, // 0xac
    .{ .bits = 0x3fffdf, .len = 22 }, // 0xad
    .{ .bits = 0x7fffeb, .len = 23 }, // 0xae
    .{ .bits = 0x7fffec, .len = 23 }, // 0xaf
    .{ .bits = 0x1fffe0, .len = 21 }, // 0xb0
    .{ .bits = 0x1fffe1, .len = 21 }, // 0xb1
    .{ .bits = 0x3fffe0, .len = 22 }, // 0xb2
    .{ .bits = 0x1fffe2, .len = 21 }, // 0xb3
    .{ .bits = 0x7fffed, .len = 23 }, // 0xb4
    .{ .bits = 0x3fffe1, .len = 22 }, // 0xb5
    .{ .bits = 0x7fffee, .len = 23 }, // 0xb6
    .{ .bits = 0x7fffef, .len = 23 }, // 0xb7
    .{ .bits = 0xfffea, .len = 20 }, // 0xb8
    .{ .bits = 0x3fffe2, .len = 22 }, // 0xb9
    .{ .bits = 0x3fffe3, .len = 22 }, // 0xba
    .{ .bits = 0x3fffe4, .len = 22 }, // 0xbb
    .{ .bits = 0x7ffff0, .len = 23 }, // 0xbc
    .{ .bits = 0x3fffe5, .len = 22 }, // 0xbd
    .{ .bits = 0x3fffe6, .len = 22 }, // 0xbe
    .{ .bits = 0x7ffff1, .len = 23 }, // 0xbf
    .{ .bits = 0x3ffffe0, .len = 26 }, // 0xc0
    .{ .bits = 0x3ffffe1, .len = 26 }, // 0xc1
    .{ .bits = 0xfffeb, .len = 20 }, // 0xc2
    .{ .bits = 0x7fff1, .len = 19 }, // 0xc3
    .{ .bits = 0x3fffe7, .len = 22 }, // 0xc4
    .{ .bits = 0x7ffff2, .len = 23 }, // 0xc5
    .{ .bits = 0x3fffe8, .len = 22 }, // 0xc6
    .{ .bits = 0x1ffffec, .len = 25 }, // 0xc7
    .{ .bits = 0x3ffffe2, .len = 26 }, // 0xc8
    .{ .bits = 0x3ffffe3, .len = 26 }, // 0xc9
    .{ .bits = 0x3ffffe4, .len = 26 }, // 0xca
    .{ .bits = 0x7ffffde, .len = 27 }, // 0xcb
    .{ .bits = 0x7ffffdf, .len = 27 }, // 0xcc
    .{ .bits = 0x3ffffe5, .len = 26 }, // 0xcd
    .{ .bits = 0xfffff1, .len = 24 }, // 0xce
    .{ .bits = 0x1ffffed, .len = 25 }, // 0xcf
    .{ .bits = 0x7fff2, .len = 19 }, // 0xd0
    .{ .bits = 0x1fffe3, .len = 21 }, // 0xd1
    .{ .bits = 0x3ffffe6, .len = 26 }, // 0xd2
    .{ .bits = 0x7ffffe0, .len = 27 }, // 0xd3
    .{ .bits = 0x7ffffe1, .len = 27 }, // 0xd4
    .{ .bits = 0x3ffffe7, .len = 26 }, // 0xd5
    .{ .bits = 0x7ffffe2, .len = 27 }, // 0xd6
    .{ .bits = 0xfffff2, .len = 24 }, // 0xd7
    .{ .bits = 0x1fffe4, .len = 21 }, // 0xd8
    .{ .bits = 0x1fffe5, .len = 21 }, // 0xd9
    .{ .bits = 0x3ffffe8, .len = 26 }, // 0xda
    .{ .bits = 0x3ffffe9, .len = 26 }, // 0xdb
    .{ .bits = 0xffffffd, .len = 28 }, // 0xdc
    .{ .bits = 0x7ffffe3, .len = 27 }, // 0xdd
    .{ .bits = 0x7ffffe4, .len = 27 }, // 0xde
    .{ .bits = 0x7ffffe5, .len = 27 }, // 0xdf
    .{ .bits = 0xfffec, .len = 20 }, // 0xe0
    .{ .bits = 0xfffff3, .len = 24 }, // 0xe1
    .{ .bits = 0xfffed, .len = 20 }, // 0xe2
    .{ .bits = 0x1fffe6, .len = 21 }, // 0xe3
    .{ .bits = 0x3fffe9, .len = 22 }, // 0xe4
    .{ .bits = 0x1fffe7, .len = 21 }, // 0xe5
    .{ .bits = 0x1fffe8, .len = 21 }, // 0xe6
    .{ .bits = 0x7ffff3, .len = 23 }, // 0xe7
    .{ .bits = 0x3fffea, .len = 22 }, // 0xe8
    .{ .bits = 0x3fffeb, .len = 22 }, // 0xe9
    .{ .bits = 0x1ffffee, .len = 25 }, // 0xea
    .{ .bits = 0x1ffffef, .len = 25 }, // 0xeb
    .{ .bits = 0xfffff4, .len = 24 }, // 0xec
    .{ .bits = 0xfffff5, .len = 24 }, // 0xed
    .{ .bits = 0x3ffffea, .len = 26 }, // 0xee
    .{ .bits = 0x7ffff4, .len = 23 }, // 0xef
    .{ .bits = 0x3ffffeb, .len = 26 }, // 0xf0
    .{ .bits = 0x7ffffe6, .len = 27 }, // 0xf1
    .{ .bits = 0x3ffffec, .len = 26 }, // 0xf2
    .{ .bits = 0x3ffffed, .len = 26 }, // 0xf3
    .{ .bits = 0x7ffffe7, .len = 27 }, // 0xf4
    .{ .bits = 0x7ffffe8, .len = 27 }, // 0xf5
    .{ .bits = 0x7ffffe9, .len = 27 }, // 0xf6
    .{ .bits = 0x7ffffea, .len = 27 }, // 0xf7
    .{ .bits = 0x7ffffeb, .len = 27 }, // 0xf8
    .{ .bits = 0xffffffe, .len = 28 }, // 0xf9
    .{ .bits = 0x7ffffec, .len = 27 }, // 0xfa
    .{ .bits = 0x7ffffed, .len = 27 }, // 0xfb
    .{ .bits = 0x7ffffee, .len = 27 }, // 0xfc
    .{ .bits = 0x7ffffef, .len = 27 }, // 0xfd
    .{ .bits = 0x7fffff0, .len = 27 }, // 0xfe
    .{ .bits = 0x3ffffee, .len = 26 }, // 0xff
    .{ .bits = 0x3fffffff, .len = 30 }, // EOS
};

const eos: u9 = 256;

/// The longest code: EOS, and three control symbols, at 30 bits.
const max_len: u5 = 30;

const Root = packed struct(u14) {
    symbol: u9,
    /// Zero when the code occupying this prefix is longer than eight bits.
    len: u5,
};

/// The first eight bits of the code stream, for every value. A short code
/// fills every index that shares its prefix; a longer code leaves `len` zero.
const root: [256]Root = blk: {
    var entries = compat.filled(Root, 256, .{ .symbol = 0, .len = 0 });
    for (table, 0..) |code, symbol| {
        if (code.len > 8) continue;
        const shift: u5 = 8 - code.len;
        const base: u32 = code.bits << shift;
        for (0..@as(u32, 1) << shift) |suffix| {
            entries[(base | @as(u32, @intCast(suffix)))] = .{
                .symbol = @intCast(symbol),
                .len = code.len,
            };
        }
    }
    break :blk entries;
};

/// How many symbols have each code length.
const length_count: [31]u32 = blk: {
    var counts = compat.filled(u32, 31, 0);
    for (table) |code| counts[code.len] += 1;
    break :blk counts;
};

/// The lowest code value of each length, which is where a rank starts.
const length_first: [31]u32 = blk: {
    var first = compat.filled(u32, 31, 0);
    var seen = compat.filled(bool, 31, false);
    for (table) |code| {
        const len: usize = code.len;
        if (!seen[len] or code.bits < first[len]) {
            first[len] = code.bits;
            seen[len] = true;
        }
    }
    break :blk first;
};

/// Where each length's symbols start in `canonical`.
const length_base: [31]u32 = blk: {
    var base = compat.filled(u32, 31, 0);
    var next: u32 = 0;
    for (0..31) |len| {
        base[len] = next;
        next += length_count[len];
    }
    break :blk base;
};

/// Symbols ordered by code length, then by code value.
const canonical: [257]u9 = blk: {
    var symbols: [257]u9 = undefined;
    var placed = compat.filled(bool, 257, false);
    for (table, 0..) |code, symbol| {
        const len: usize = code.len;
        const rank = code.bits - length_first[len];
        if (rank >= length_count[len]) @compileError("HPACK Huffman table is not canonical");
        const at: usize = length_base[len] + rank;
        symbols[at] = @intCast(symbol);
        placed[at] = true;
    }
    for (placed) |ok| {
        if (!ok) @compileError("HPACK Huffman table has a hole");
    }
    break :blk symbols;
};

/// Decode `encoded` into `out`, returning the number of bytes written.
pub fn decode(encoded: []const u8, out: []u8) Error!usize {
    var bits: Bits = .{ .bytes = .init(encoded) };
    var written: usize = 0;

    while (true) {
        bits.fill(8);

        // Codes of eight bits or less are the common case and the root table
        // resolves them in one lookup.
        if (bits.len >= 8) {
            const short = root[@intCast(bits.peek(8))];
            if (short.len != 0) {
                if (written == out.len) return error.NoSpace;
                out[written] = @intCast(short.symbol);
                written += 1;
                bits.drop(short.len);
                continue;
            }
        }

        // A longer code, or a short one with fewer than eight bits left at the
        // end of the string. Fill to the longest code so neither is mistaken
        // for padding.
        bits.fill(max_len);
        const found = scan(bits);
        if (found) |at| {
            if (at.symbol == eos) return error.InvalidCode;
            if (written == out.len) return error.NoSpace;
            out[written] = @intCast(at.symbol);
            written += 1;
            bits.drop(at.len);
            continue;
        }

        // Nothing left that is a code. The tail is padding, or the string is
        // malformed.
        try bits.expectPadding();
        return written;
    }
}

const Found = struct { symbol: u9, len: u5 };

/// The canonical scan for a code at the front of `bits`. Short codes start at
/// five bits when the string is nearly spent, and at nine otherwise because
/// the root table owns 8 and below.
fn scan(bits: Bits) ?Found {
    const shortest: u5 = if (bits.len < 8) 5 else 9;
    const available: u5 = @intCast(@min(max_len, bits.len));

    var len: u5 = shortest;
    while (len <= available) : (len += 1) {
        const count = length_count[len];
        if (count == 0) continue;
        const code = bits.peek(len);
        if (code < length_first[len]) continue;
        const rank = code - length_first[len];
        if (rank >= count) continue;
        return .{ .symbol = canonical[length_base[len] + rank], .len = len };
    }
    return null;
}

/// Encode `src` into `out`, returning the number of bytes written. The last
/// octet is padded with the leading bits of EOS, as RFC 7541 §5.2 requires.
pub fn encode(src: []const u8, out: []u8) EncodeError!usize {
    var acc: u64 = 0;
    var len: u8 = 0;
    var written: usize = 0;

    for (src) |byte| {
        const code = table[byte];
        const shift: u6 = @intCast(64 - (len + code.len));
        acc |= @as(u64, code.bits) << shift;
        len += code.len;

        while (len >= 8) {
            if (written == out.len) return error.NoSpace;
            out[written] = @intCast(acc >> 56);
            written += 1;
            acc <<= 8;
            len -= 8;
        }
    }

    if (len != 0) {
        acc |= ~@as(u64, 0) >> @intCast(len);
        if (written == out.len) return error.NoSpace;
        out[written] = @intCast(acc >> 56);
        written += 1;
    }
    return written;
}

/// The number of octets `encode` writes for `src`.
pub fn encodedLen(src: []const u8) usize {
    var bits: usize = 0;
    for (src) |byte| bits += table[byte].len;
    return (bits + 7) / 8;
}

/// The bit stream, read most significant bit first. `acc` holds the unread
/// bits left-aligned; `len` is how many.
const Bits = struct {
    bytes: Cursor,
    acc: u64 = 0,
    len: u8 = 0,

    fn fill(self: *Bits, need: u5) void {
        while (self.len < need) {
            const byte = self.bytes.next() orelse break;
            self.acc |= @as(u64, byte) << @intCast(56 - self.len);
            self.len += 8;
        }
    }

    fn peek(self: Bits, n: u5) u32 {
        assert(n >= 1);
        assert(@as(u8, n) <= self.len);
        return @intCast(self.acc >> @intCast(64 - @as(u8, n)));
    }

    fn drop(self: *Bits, n: u5) void {
        assert(@as(u8, n) <= self.len);
        self.acc <<= @intCast(n);
        self.len -= @as(u8, n);
    }

    /// The bits left over at the end of the string are padding: at most seven,
    /// and the leading bits of the EOS code, which are all ones.
    fn expectPadding(self: *Bits) Error!void {
        if (self.len == 0) return;
        if (self.len > 7) return error.InvalidCode;
        const remaining: u64 = self.acc >> @intCast(64 - self.len);
        if (remaining != (@as(u64, 1) << @intCast(self.len)) - 1) return error.InvalidCode;
    }
};

test "every octet round-trips on its own" {
    var encoded: [4]u8 = undefined;
    var decoded: [1]u8 = undefined;
    for (0..256) |byte| {
        const n = try encode(&.{@intCast(byte)}, &encoded);
        try testing.expectEqual(n, encodedLen(&.{@intCast(byte)}));

        const m = try decode(encoded[0..n], &decoded);
        try testing.expectEqual(1, m);
        try testing.expectEqual(@as(u8, @intCast(byte)), decoded[0]);
    }
}

test "every octet round-trips in one string" {
    var src: [256]u8 = undefined;
    for (0..256) |byte| src[byte] = @intCast(byte);

    var encoded: [1024]u8 = undefined;
    const n = try encode(&src, &encoded);
    try testing.expectEqual(encodedLen(&src), n);

    var decoded: [256]u8 = undefined;
    const m = try decode(encoded[0..n], &decoded);
    try testing.expectEqualStrings(&src, decoded[0..m]);
}

test "the codes RFC 7541 Appendix C pins" {
    const cases = [_]struct { text: []const u8, hex: []const u8 }{
        .{ .text = "www.example.com", .hex = "\xf1\xe3\xc2\xe5\xf2\x3a\x6b\xa0\xab\x90\xf4\xff" },
        .{ .text = "no-cache", .hex = "\xa8\xeb\x10\x64\x9c\xbf" },
        .{ .text = "custom-key", .hex = "\x25\xa8\x49\xe9\x5b\xa9\x7d\x7f" },
        .{ .text = "custom-value", .hex = "\x25\xa8\x49\xe9\x5b\xb8\xe8\xb4\xbf" },
        .{ .text = "302", .hex = "\x64\x02" },
    };

    var encoded: [64]u8 = undefined;
    var decoded: [64]u8 = undefined;
    for (cases) |case| {
        const n = try encode(case.text, &encoded);
        try testing.expectEqualSlices(u8, case.hex, encoded[0..n]);

        const m = try decode(case.hex, &decoded);
        try testing.expectEqualStrings(case.text, decoded[0..m]);
    }
}

test "the code is canonical, prefix-free, and complete" {
    // Canonical: equal lengths hold consecutive code values.
    var seen = compat.filled(bool, 257, false);
    for (1..31) |len| {
        const count = length_count[len];
        if (count == 0) continue;
        const first = length_first[len];
        for (0..count) |rank| {
            var found: ?u9 = null;
            for (table, 0..) |code, symbol| {
                if (code.len == len and code.bits == first + rank) {
                    try testing.expect(found == null);
                    found = @intCast(symbol);
                }
            }
            try testing.expect(found != null);
            seen[found.?] = true;
        }
    }
    for (seen) |ok| try testing.expect(ok);

    // Prefix-free: no code is a prefix of another.
    for (table, 0..) |a, i| {
        for (table, 0..) |b, j| {
            if (i == j or a.len > b.len) continue;
            const prefix = b.bits >> @intCast(b.len - a.len);
            try testing.expect(prefix != a.bits);
        }
    }
}

test "EOS in the stream is an error (RFC 7541 §5.2)" {
    // EOS is 30 one bits; four octets carry it plus two bits of padding.
    try testing.expectError(error.InvalidCode, decode("\xff\xff\xff\xff", &.{}));
    // The same, with room to write, must not emit EOS or overflow.
    var out: [8]u8 = undefined;
    try testing.expectError(error.InvalidCode, decode("\xff\xff\xff\xff", &out));
}

test "padding longer than seven bits is an error (RFC 7541 §5.2)" {
    // 0xff decodes as no code at all; eight bits cannot be padding.
    var out: [8]u8 = undefined;
    try testing.expectError(error.InvalidCode, decode("\xff", &out));
}

test "padding that is not a prefix of EOS is an error (RFC 7541 §5.2)" {
    // '0' is 00000; the three remaining zero bits are not ones.
    var out: [8]u8 = undefined;
    try testing.expectError(error.InvalidCode, decode("\x00", &out));
}

test "an exact-size output buffer is enough" {
    const text = "0123456789";
    var encoded: [8]u8 = undefined;
    const n = try encode(text, &encoded);

    var exact: [10]u8 = undefined;
    try testing.expectEqual(10, try decode(encoded[0..n], &exact));
    try testing.expectEqualStrings(text, &exact);

    var short: [9]u8 = undefined;
    try testing.expectError(error.NoSpace, decode(encoded[0..n], &short));
}

test "encode refuses a short destination" {
    var out: [2]u8 = undefined;
    try testing.expectError(error.NoSpace, encode("www.example.com", &out));
}

test "fuzz encoding round-trips" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) anyerror!void {
            var src: [128]u8 = undefined;
            const text = src[0..smith.slice(&src)];

            var encoded: [256]u8 = undefined;
            const n = encode(text, &encoded) catch return;
            try testing.expectEqual(encodedLen(text), n);

            var decoded: [128]u8 = undefined;
            const m = try decode(encoded[0..n], &decoded);
            try testing.expectEqualStrings(text, decoded[0..m]);
        }
    }.run, .{});
}

test "fuzz decoding arbitrary bytes never overruns" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) anyerror!void {
            var src: [128]u8 = undefined;
            const text = src[0..smith.slice(&src)];

            var decoded: [256]u8 = undefined;
            const m = decode(text, &decoded) catch return;
            // The shortest code is five bits, so the expansion is at most 8/5.
            try testing.expect(m <= text.len * 8 / 5 + 1);
        }
    }.run, .{
        .corpus = &.{
            "",
            "\xf1\xe3\xc2\xe5\xf2\x3a\x6b\xa0\xab\x90\xf4\xff",
            "\xff\xff\xff\xff",
            "\x00",
        },
    });
}
