//! A byte cursor: one read position over borrowed bytes.
//!
//! Every parser here walks a buffer from the front, so the position and the
//! bounds checks live in one place. The cursor is deliberately infallible: it
//! never decides whether running out is an error. `next`, `peek`, and `take`
//! say null and each protocol maps that to its own vocabulary (`Incomplete`
//! for HTTP/1.1, `Truncated` for HPACK). `at` and `slice` assert the bounds
//! the caller already checked, for scanners that look ahead before moving.
//!
//! Offsets are `u32`, so a buffer must be shorter than 4 GiB. That is not a
//! limitation for a message head or a header block, and it keeps offsets half
//! the size of a `usize` on a 64-bit target.

const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;
const math = std.math;

const Cursor = @This();

/// The bytes being read. Borrowed; the cursor owns nothing.
buf: []const u8,
/// The offset of the next byte to read.
pos: u32 = 0,

/// A cursor at the start of `buf`. `buf` must be shorter than 4 GiB.
pub fn init(buf: []const u8) Cursor {
    assert(buf.len <= math.maxInt(u32));
    return .{ .buf = buf };
}

pub fn atEnd(self: *const Cursor) bool {
    return @as(usize, self.pos) == self.buf.len;
}

/// The number of bytes not read yet.
pub fn remaining(self: *const Cursor) u32 {
    return @intCast(self.buf.len - self.pos);
}

/// Whether at least `count` bytes are left.
pub fn has(self: *const Cursor, count: u32) bool {
    return count <= self.remaining();
}

/// The next byte, without reading it.
pub fn peek(self: *const Cursor) ?u8 {
    if (self.atEnd()) return null;
    return self.buf[@intCast(self.pos)];
}

/// The byte at an absolute offset. The caller guarantees it is in bounds, as a
/// scanner that looked ahead with `has` already did.
pub fn at(self: *const Cursor, index: u32) u8 {
    assert(@as(usize, index) < self.buf.len);
    return self.buf[@intCast(index)];
}

/// Read one byte, or null at the end.
pub fn next(self: *Cursor) ?u8 {
    if (self.atEnd()) return null;
    const byte = self.buf[@intCast(self.pos)];
    self.pos += 1;
    return byte;
}

/// Read `count` bytes, or null when fewer are left. Nothing moves on null.
pub fn take(self: *Cursor, count: u32) ?[]const u8 {
    if (!self.has(count)) return null;
    const start: usize = self.pos;
    self.pos += count;
    return self.buf[start..@intCast(self.pos)];
}

/// Advance `count` bytes. False, and nothing moves, when fewer are left.
pub fn skip(self: *Cursor, count: u32) bool {
    if (!self.has(count)) return false;
    self.pos += count;
    return true;
}

/// A slice by absolute offsets. The caller guarantees the range.
pub fn slice(self: *const Cursor, start: u32, end: u32) []const u8 {
    assert(start <= end);
    assert(@as(usize, end) <= self.buf.len);
    return self.buf[@intCast(start)..@intCast(end)];
}

/// Everything from `pos` to the end.
pub fn rest(self: *const Cursor) []const u8 {
    return self.buf[@intCast(self.pos)..];
}

test "position, peek, next, and the end" {
    var cursor: Cursor = .init("abc");
    try testing.expect(!cursor.atEnd());
    try testing.expectEqual(@as(u32, 3), cursor.remaining());
    try testing.expect(cursor.has(3));
    try testing.expect(!cursor.has(4));

    try testing.expectEqual(@as(u8, 'a'), cursor.peek().?);
    try testing.expectEqual(@as(u8, 'b'), cursor.at(1));
    try testing.expectEqualStrings("abc", cursor.rest());
    try testing.expectEqual(@as(u8, 'a'), cursor.next().?);
    try testing.expectEqual(@as(u8, 'b'), cursor.next().?);
    try testing.expectEqual(@as(u32, 1), cursor.remaining());
    try testing.expectEqual(@as(u8, 'c'), cursor.next().?);
    try testing.expect(cursor.atEnd());
    try testing.expect(cursor.next() == null);
    try testing.expect(cursor.peek() == null);
    try testing.expectEqualStrings("", cursor.rest());
}

test "take and skip do not move when the buffer is short" {
    var cursor: Cursor = .init("abcdef");
    try testing.expectEqualStrings("abc", cursor.take(3).?);
    try testing.expectEqual(@as(u32, 3), cursor.pos);

    try testing.expect(cursor.take(4) == null);
    try testing.expectEqual(@as(u32, 3), cursor.pos);

    try testing.expect(cursor.skip(2));
    try testing.expectEqual(@as(u32, 5), cursor.pos);
    try testing.expect(!cursor.skip(2));
    try testing.expectEqual(@as(u32, 5), cursor.pos);

    try testing.expectEqualStrings("f", cursor.take(1).?);
    try testing.expectEqualStrings("", cursor.take(0).?);
    try testing.expect(cursor.atEnd());
}

test "slice is absolute, rest follows the position" {
    const cursor: Cursor = .init("abcdef");
    try testing.expectEqualStrings("cd", cursor.slice(2, 4));
    try testing.expectEqualStrings("", cursor.slice(3, 3));
    try testing.expectEqualStrings("abcdef", cursor.slice(0, 6));

    var moved: Cursor = .init("abcdef");
    _ = moved.take(2);
    try testing.expectEqualStrings("cdef", moved.rest());
    try testing.expectEqualStrings("bc", moved.slice(1, 3));
}

test "an empty buffer is at the end" {
    var cursor: Cursor = .init("");
    try testing.expect(cursor.atEnd());
    try testing.expectEqual(@as(u32, 0), cursor.remaining());
    try testing.expect(cursor.next() == null);
    try testing.expectEqualStrings("", cursor.rest());
    try testing.expectEqualStrings("", cursor.take(0).?);
}

test "fuzz the position against a model" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) anyerror!void {
            var buf: [64]u8 = undefined;
            const input = buf[0..smith.slice(&buf)];
            var cursor: Cursor = .init(input);

            var model: usize = 0;
            while (smith.value(bool)) {
                const count: u32 = smith.valueRangeAtMost(u32, 0, @intCast(input.len + 2));
                switch (smith.valueRangeAtMost(u8, 0, 3)) {
                    0 => {
                        const got = cursor.take(count);
                        if (count <= input.len - model) {
                            try testing.expectEqualStrings(input[model..][0..count], got.?);
                            model += count;
                        } else {
                            try testing.expect(got == null);
                        }
                    },
                    1 => {
                        const ok = cursor.skip(count);
                        try testing.expectEqual(count <= input.len - model, ok);
                        if (ok) model += count;
                    },
                    2 => {
                        const got = cursor.next();
                        if (model < input.len) {
                            try testing.expectEqual(input[model], got.?);
                            model += 1;
                        } else {
                            try testing.expect(got == null);
                        }
                    },
                    else => {
                        try testing.expectEqual(model < input.len, !cursor.atEnd());
                    },
                }
                try testing.expectEqual(model, cursor.pos);
                try testing.expectEqual(input.len - model, cursor.remaining());
            }
            try testing.expectEqualStrings(input[model..], cursor.rest());
        }
    }.run, .{ .corpus = &.{ "", "a", "abcdef" } });
}
