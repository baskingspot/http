//! Assemble one header block from HEADERS or PUSH_PROMISE and the
//! CONTINUATION frames that follow it (RFC 9113 §4.3, §6.2, §6.10).
//!
//! The caller owns the block buffer and feeds fragments in wire order. A
//! fragment for a single-frame block is returned borrowed; a split block is
//! copied into the buffer and returned when END_HEADERS arrives. While a block
//! is open, RFC 9113 §4.3 allows no other frame on the connection, so the
//! caller must check `isAssembling` before dispatching anything else.

const std = @import("std");
const testing = std.testing;
const mem = std.mem;

pub const Error = error{
    /// A new HEADERS or PUSH_PROMISE arrived while a block was open.
    Interleaved,
    /// A CONTINUATION arrived with no block open, or for another stream.
    UnexpectedContinuation,
    /// The assembled block does not fit the caller's buffer.
    TooLarge,
};

pub const Assembler = struct {
    buffer: []u8,
    len: usize,
    /// The stream whose block is open, or null when no block is open.
    stream_id: ?u31,

    pub fn init(buffer: []u8) Assembler {
        return .{ .buffer = buffer, .len = 0, .stream_id = null };
    }

    pub fn isAssembling(self: Assembler) bool {
        return self.stream_id != null;
    }

    /// Start a block from a HEADERS or PUSH_PROMISE fragment. Returns the
    /// block when END_HEADERS is set on that frame, or null when CONTINUATION
    /// frames follow.
    pub fn start(
        self: *Assembler,
        stream_id: u31,
        fragment: []const u8,
        end_headers: bool,
    ) Error!?[]const u8 {
        if (self.stream_id != null) return error.Interleaved;
        if (end_headers) return fragment;
        if (fragment.len > self.buffer.len) return error.TooLarge;

        @memcpy(self.buffer[0..fragment.len], fragment);
        self.len = fragment.len;
        self.stream_id = stream_id;
        return null;
    }

    /// Append a CONTINUATION fragment. Returns the block when END_HEADERS is
    /// set, or null for another fragment.
    pub fn continuation(
        self: *Assembler,
        stream_id: u31,
        fragment: []const u8,
        end_headers: bool,
    ) Error!?[]const u8 {
        const open = self.stream_id orelse return error.UnexpectedContinuation;
        if (stream_id != open) return error.UnexpectedContinuation;
        if (fragment.len > self.buffer.len - self.len) return error.TooLarge;

        @memcpy(self.buffer[self.len..][0..fragment.len], fragment);
        self.len += fragment.len;
        if (!end_headers) return null;

        const block = self.buffer[0..self.len];
        self.stream_id = null;
        self.len = 0;
        return block;
    }
};

test "a single-frame block is borrowed from the input" {
    var storage: [16]u8 = undefined;
    var assembler = Assembler.init(&storage);
    const fragment = "abc";

    const block = (try assembler.start(1, fragment, true)).?;
    try testing.expectEqualStrings("abc", block);
    try testing.expect(@intFromPtr(block.ptr) == @intFromPtr(fragment.ptr));
    try testing.expect(!assembler.isAssembling());
}

test "a split block is copied and returned on END_HEADERS" {
    var storage: [16]u8 = undefined;
    var assembler = Assembler.init(&storage);

    try testing.expect((try assembler.start(3, "ab", false)) == null);
    try testing.expect(assembler.isAssembling());
    try testing.expect((try assembler.continuation(3, "cd", false)) == null);
    const block = (try assembler.continuation(3, "ef", true)).?;
    try testing.expectEqualStrings("abcdef", block);
    try testing.expect(!assembler.isAssembling());

    // The assembler is ready for the next block.
    try testing.expectEqualStrings("x", (try assembler.start(5, "x", true)).?);
}

test "a wrong stream, a stray CONTINUATION, and interleaving are errors" {
    var storage: [16]u8 = undefined;
    var assembler = Assembler.init(&storage);

    try testing.expectError(
        error.UnexpectedContinuation,
        assembler.continuation(1, "a", true),
    );
    _ = try assembler.start(1, "a", false);
    try testing.expectError(
        error.UnexpectedContinuation,
        assembler.continuation(3, "b", true),
    );
    try testing.expectError(error.Interleaved, assembler.start(1, "c", true));
}

test "a block larger than the buffer is TooLarge and leaves no state" {
    var storage: [2]u8 = undefined;
    var assembler = Assembler.init(&storage);

    try testing.expectError(error.TooLarge, assembler.start(1, "abc", false));
    try testing.expect(!assembler.isAssembling());
    _ = try assembler.start(1, "a", false);
    try testing.expectError(error.TooLarge, assembler.continuation(1, "bc", true));
}

test "an empty block is a block" {
    var storage: [2]u8 = undefined;
    var assembler = Assembler.init(&storage);
    try testing.expectEqualStrings("", (try assembler.start(1, "", true)).?);

    _ = try assembler.start(1, "", false);
    try testing.expectEqualStrings("", (try assembler.continuation(1, "", true)).?);
}
