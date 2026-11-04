//! Shared byte-vector width and mask types.
//!
//! `Block` is the unit: a fixed number of bytes processed per vector pass.
//! Callers use `Block.width`, `Block.Vec`, and `Block.Mask`; the capability
//! flags say whether the vector path is usable on this target.

const std = @import("std");
const simd = std.simd;
const builtin = @import("builtin");

pub const Block = struct {
    /// Bytes per byte-vector scan. The fallback is the machine word; it is only
    /// a type width when `available` is false.
    pub const width = simd.suggestVectorLength(u8) orelse @sizeOf(usize);

    /// The byte vector for `width` lanes.
    pub const Vec = @Vector(width, u8);

    /// The comparison result for `Vec`: one bool per lane.
    pub const BoolVec = @Vector(width, bool);

    /// One bit per lane of `Vec`.
    pub const Mask = @Int(.unsigned, width);
};

/// Whether the target has a suggested vector width. When false, use the scalar
/// path.
pub const available = simd.suggestVectorLength(u8) != null;

/// The first index at or after `start` where `stop` is true, or null.
///
/// `mask` is the vector form of `stop`: it must return a true lane for the same
/// bytes. The vector path is used only when the target has a suggested width
/// and lane order; otherwise the scalar loop runs directly.
pub fn first(
    bytes: []const u8,
    start: usize,
    comptime mask: fn (Block.Vec) Block.BoolVec,
    comptime stop: fn (u8) bool,
) ?usize {
    var index = start;
    if (comptime (available and lanes_in_order)) {
        while (index + Block.width <= bytes.len) : (index += Block.width) {
            const lanes: Block.Vec = bytes[index..][0..Block.width].*;
            const hits = @call(.always_inline, mask, .{lanes});
            if (@reduce(.Or, hits)) {
                const bits: Block.Mask = @bitCast(hits);
                return index + @as(usize, @ctz(bits));
            }
        }
    }
    while (index < bytes.len) : (index += 1) {
        if (@call(.always_inline, stop, .{bytes[index]})) return index;
    }
    return null;
}

/// Whether a `Mask` bit index follows lane order. The scanners use `@ctz` to
/// find the first stop byte, so they need little-endian. The validators use
/// `@reduce(.Or)` and do not need this flag.
pub const lanes_in_order = available and builtin.cpu.arch.endian() == .little;
