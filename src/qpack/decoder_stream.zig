//! QPACK decoder-stream instructions (RFC 9204 §4.4).
//!
//! The decoder stream is an unframed sequence of instructions. The parser
//! returns the wire values; the encoder-side state machine decides whether a
//! Section Acknowledgment names a live stream, or whether an Insert Count
//! Increment is zero or past what it sent. Those are protocol errors of type
//! QPACK_DECODER_STREAM_ERROR (§4.4.3), not syntax errors.
//!
//! A caller that feeds the stream in pieces keeps a copy of the cursor and
//! commits it only when an instruction parses.

const std = @import("std");
const testing = std.testing;

const Cursor = @import("../Cursor.zig");
const prefix_int = @import("../prefix_int.zig");

pub const Error = error{
    /// The input ended inside an instruction.
    Truncated,
    /// A numeric field does not fit 62 bits.
    InvalidLength,
    /// The destination buffer cannot hold the instruction.
    NoSpace,
};

pub const Instruction = union(enum) {
    /// The field section on `stream_id` was processed (§4.4.1).
    section_ack: u62,
    /// The field section on `stream_id` was abandoned (§4.4.2).
    stream_cancel: u62,
    /// The Known Received Count grows by this much (§4.4.3).
    insert_count_increment: u62,
};

pub fn parse(cursor: *Cursor) Error!Instruction {
    const first = cursor.peek() orelse return error.Truncated;

    if (first & 0x80 != 0) {
        return .{ .section_ack = try decodeIndex(cursor, 7) };
    }
    if (first & 0x40 != 0) {
        return .{ .stream_cancel = try decodeIndex(cursor, 6) };
    }
    return .{ .insert_count_increment = try decodeIndex(cursor, 6) };
}

pub fn encodedLen(instruction: Instruction) usize {
    return switch (instruction) {
        .section_ack => |stream_id| prefix_int.encodedLenWide(stream_id, 7),
        .stream_cancel => |stream_id| prefix_int.encodedLenWide(stream_id, 6),
        .insert_count_increment => |count| prefix_int.encodedLenWide(count, 6),
    };
}

/// Write one instruction. A short buffer is `error.NoSpace` and writes nothing.
pub fn write(buf: []u8, instruction: Instruction) Error![]u8 {
    if (buf.len < encodedLen(instruction)) return error.NoSpace;

    return switch (instruction) {
        .section_ack => |stream_id| blk: {
            const written = try prefix_int.encodeWide(buf, stream_id, 7);
            written[0] |= 0x80;
            break :blk written;
        },
        .stream_cancel => |stream_id| blk: {
            const written = try prefix_int.encodeWide(buf, stream_id, 6);
            written[0] |= 0x40;
            break :blk written;
        },
        .insert_count_increment => |count| try prefix_int.encodeWide(buf, count, 6),
    };
}

fn decodeIndex(cursor: *Cursor, bits: u4) Error!u62 {
    return prefix_int.decodeWide(cursor, bits) catch |err| switch (err) {
        error.Truncated => error.Truncated,
        error.TooLarge => error.InvalidLength,
    };
}

test "RFC 9204 Appendix B, the three decoder instructions parse" {
    var ack: Cursor = .init(&.{0x84});
    try testing.expectEqual(@as(u62, 4), (try parse(&ack)).section_ack);
    try testing.expect(ack.atEnd());

    var cancel: Cursor = .init(&.{0x48});
    try testing.expectEqual(@as(u62, 8), (try parse(&cancel)).stream_cancel);
    try testing.expect(cancel.atEnd());

    var increment: Cursor = .init(&.{0x01});
    try testing.expectEqual(@as(u62, 1), (try parse(&increment)).insert_count_increment);
    try testing.expect(increment.atEnd());
}

test "every decoder instruction round-trips through the writer" {
    const cases = [_]Instruction{
        .{ .section_ack = 0 },
        .{ .section_ack = 4 },
        .{ .section_ack = 1000 },
        .{ .stream_cancel = 8 },
        .{ .stream_cancel = 63 },
        .{ .insert_count_increment = 0 },
        .{ .insert_count_increment = 1 },
        .{ .insert_count_increment = 1000 },
    };

    var buf: [16]u8 = undefined;
    for (cases) |case| {
        const written = try write(&buf, case);
        try testing.expectEqual(encodedLen(case), written.len);

        var cursor: Cursor = .init(written);
        const decoded = try parse(&cursor);
        try testing.expect(cursor.atEnd());

        switch (case) {
            .section_ack => |stream_id| try testing.expectEqual(stream_id, decoded.section_ack),
            .stream_cancel => |stream_id| try testing.expectEqual(stream_id, decoded.stream_cancel),
            .insert_count_increment => |count| try testing.expectEqual(
                count,
                decoded.insert_count_increment,
            ),
        }
    }
}

test "a truncated instruction is Truncated" {
    var cursor: Cursor = .init(&.{ 0xff, 0x80 });
    try testing.expectError(error.Truncated, parse(&cursor));
}

test "a short destination is NoSpace and writes nothing" {
    var buf: [1]u8 = undefined;
    buf = .{0xaa};
    try testing.expectError(error.NoSpace, write(&buf, .{ .section_ack = 1000 }));
    try testing.expectEqual(@as(u8, 0xaa), buf[0]);
}

test "fuzz the decoder stream" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) anyerror!void {
            var bytes: [16]u8 = undefined;
            const input = bytes[0..smith.slice(&bytes)];

            var cursor: Cursor = .init(input);
            _ = parse(&cursor) catch |err| {
                try testing.expect(err == error.Truncated or err == error.InvalidLength);
                return;
            };
            try testing.expect(cursor.pos <= input.len);
        }
    }.run, .{ .corpus = &.{ "", "\x84", "\x48", "\x01" } });
}
