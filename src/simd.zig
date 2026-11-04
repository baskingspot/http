//! Shared byte-vector width and mask types.
//!
//! `Block` is the unit: a fixed number of bytes processed per vector pass.
//! Callers use `Block.width`, `Block.Vec`, and `Block.Mask`; the capability
//! flags say whether the vector path is usable on this target.

const std = @import("std");
const builtin = @import("builtin");

pub const Block = struct {
    /// Bytes per byte-vector scan. The fallback is the machine word; it is only
    /// a type width when `available` is false.
    pub const width = std.simd.suggestVectorLength(u8) orelse @sizeOf(usize);

    /// The byte vector for `width` lanes.
    pub const Vec = @Vector(width, u8);

    /// One bit per lane of `Vec`.
    pub const Mask = @Int(.unsigned, width);
};

/// Whether the target has a suggested vector width. When false, use the scalar
/// path.
pub const available = std.simd.suggestVectorLength(u8) != null;

/// Whether a `Mask` bit index follows lane order. The scanners use `@ctz` to
/// find the first stop byte, so they need little-endian. The validators use
/// `@reduce(.Or)` and do not need this flag.
pub const lanes_in_order = available and builtin.cpu.arch.endian() == .little;
