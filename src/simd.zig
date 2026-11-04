//! Shared byte-vector width and mask types.
//!
//! Keep the target-dependent choices here. A caller uses `block`, `Vec`, and a
//! capability flag; it does not call `std.simd.suggestVectorLength` itself.
//! `available` is false on a target with no suggested width, even though `Vec`
//! exists; the caller takes the scalar path.

const std = @import("std");
const builtin = @import("builtin");

/// Bytes per byte-vector scan. The fallback is the machine word; it is only a
/// type width when `available` is false.
pub const block = std.simd.suggestVectorLength(u8) orelse @sizeOf(usize);

/// The byte vector for `block` lanes.
pub const Vec = @Vector(block, u8);

/// One bit per lane of `Vec`.
pub const Mask = @Int(.unsigned, block);

/// Whether the target has a suggested vector width. When false, use the scalar
/// path.
pub const available = std.simd.suggestVectorLength(u8) != null;

/// Whether a `Mask` bit index follows lane order. The scanners use `@ctz` to
/// find the first stop byte, so they need little-endian. The validators use
/// `@reduce(.Or)` and do not need this flag.
pub const lanes_in_order = available and builtin.cpu.arch.endian() == .little;
