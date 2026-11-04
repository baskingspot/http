//! HTTP/1 character predicates and their vector masks.
//!
//! The scalar predicate is the source of truth. A mask returns one true lane
//! per byte that must stop a scan or fails validation. The parser and writer
//! share both forms so a character rule is written once.

const std = @import("std");
const simd = @import("../simd.zig");

/// `tchar` from RFC 9110 §5.6.2.
pub fn isTchar(byte: u8) bool {
    return switch (byte) {
        '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => true,
        '0'...'9', 'A'...'Z', 'a'...'z' => true,
        else => false,
    };
}

/// RFC 9110 §5.5: `field-vchar` (VCHAR or obs-text), SP, and HTAB.
pub fn isFieldValueByte(byte: u8) bool {
    return byte == '\t' or (byte >= 0x20 and byte != 0x7f);
}

/// RFC 9112 §3.2: printable US-ASCII, and SP is the delimiter.
pub fn isTargetByte(byte: u8) bool {
    return byte >= 0x21 and byte <= 0x7e;
}

fn makeSet(comptime predicate: fn (u8) bool) std.StaticBitSet(256) {
    @setEvalBranchQuota(10_000);
    var set: std.StaticBitSet(256) = .initEmpty();
    for (0..256) |index| {
        if (predicate(@intCast(index))) set.set(index);
    }
    return set;
}

fn makeTable(comptime predicate: fn (u8) bool) [256]bool {
    var table: [256]bool = undefined;
    for (0..256) |index| table[index] = predicate(@intCast(index));
    return table;
}

pub const tchar_table = makeTable(isTchar);
pub const field_value_set = makeSet(isFieldValueByte);
pub const target_set = makeSet(isTargetByte);

/// A true lane where the byte is not part of a field value or reason phrase:
/// CR, LF, any other CTL except HTAB, or DEL.
pub fn lineMask(lanes: simd.Block.Vec) simd.Block.BoolVec {
    const ctl = (lanes < @as(simd.Block.Vec, @splat(0x20))) &
        (lanes != @as(simd.Block.Vec, @splat('\t')));
    const del = lanes == @as(simd.Block.Vec, @splat(0x7f));
    return ctl | del;
}

/// The scalar form of `lineMask`.
pub fn lineStop(byte: u8) bool {
    return !isFieldValueByte(byte);
}

pub const fieldValueMask = lineMask;
pub const fieldValueStop = lineStop;

/// A true lane where the byte is outside printable US-ASCII.
pub fn targetMask(lanes: simd.Block.Vec) simd.Block.BoolVec {
    return (lanes < @as(simd.Block.Vec, @splat(0x21))) |
        (lanes > @as(simd.Block.Vec, @splat(0x7e)));
}

/// The scalar form of `targetMask`.
pub fn targetStop(byte: u8) bool {
    return !isTargetByte(byte);
}

/// A true lane on CR, for the head-terminator search.
pub fn crMask(lanes: simd.Block.Vec) simd.Block.BoolVec {
    return lanes == @as(simd.Block.Vec, @splat('\r'));
}

/// The scalar form of `crMask`.
pub fn crStop(byte: u8) bool {
    return byte == '\r';
}
