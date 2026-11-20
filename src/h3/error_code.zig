//! HTTP/3 and QPACK error codes (RFC 9114 §8.1, RFC 9204 §6).
//!
//! The enum is open: QUIC carries a 62-bit application error code, and a peer
//! may use one this version does not name. `isKnown` separates the assigned
//! codes from the rest; an unknown code is equivalent to H3_NO_ERROR on
//! receipt (RFC 9114 §9).

const std = @import("std");
const testing = std.testing;

pub const Code = enum(u62) {
    no_error = 0x100,
    general_protocol_error = 0x101,
    internal_error = 0x102,
    stream_creation_error = 0x103,
    closed_critical_stream = 0x104,
    frame_unexpected = 0x105,
    frame_error = 0x106,
    excessive_load = 0x107,
    id_error = 0x108,
    settings_error = 0x109,
    missing_settings = 0x10a,
    request_rejected = 0x10b,
    request_cancelled = 0x10c,
    request_incomplete = 0x10d,
    message_error = 0x10e,
    connect_error = 0x10f,
    version_fallback = 0x110,
    qpack_decompression_failed = 0x200,
    qpack_encoder_stream_error = 0x201,
    qpack_decoder_stream_error = 0x202,
    _,
};

/// Whether `value` is an error code this document assigns.
pub fn isKnown(value: u62) bool {
    return switch (value) {
        0x100...0x110, 0x200...0x202 => true,
        else => false,
    };
}

/// Whether `value` is one of the exercise-and-ignore codes, 0x1f * N + 0x21
/// (RFC 9114 §8.1). They are equivalent to H3_NO_ERROR.
pub fn isReserved(value: u62) bool {
    return value >= 0x21 and (value - 0x21) % 0x1f == 0;
}

test "the assigned codes and the reserved space" {
    try testing.expectEqual(@as(u62, 0x100), @backingInt(Code.no_error));
    try testing.expectEqual(@as(u62, 0x10e), @backingInt(Code.message_error));
    try testing.expectEqual(@as(u62, 0x202), @backingInt(Code.qpack_decoder_stream_error));

    try testing.expect(isKnown(0x100));
    try testing.expect(isKnown(0x110));
    try testing.expect(isKnown(0x200));
    try testing.expect(!isKnown(0x111));
    try testing.expect(!isKnown(0x203));

    try testing.expect(isReserved(0x21));
    try testing.expect(isReserved(0x40));
    try testing.expect(isReserved(0x5f));
    try testing.expect(!isReserved(0x22));
    try testing.expect(!isReserved(0x100));
}
