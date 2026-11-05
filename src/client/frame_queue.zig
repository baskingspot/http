//! Resumable outbound frame queue for a step-shaped HTTP client.
//!
//! A step client cannot block on a partial write: the transport may accept a
//! prefix of one frame and return. This queue keeps the frame being written and
//! a byte offset into it, refuses to append behind a partially written frame,
//! and holds the CONTIGUATION contiguity rule for header blocks (RFC 9113
//! §4.3).
//!
//! The queue owns no transport, no session, and no allocator. The caller lends
//! storage for the bytes and metadata for the frames. Bytes are copied in once;
//! after that the caller asks for `unsent()`, hands it to the transport, and
//! reports what was accepted with `accepted`.
//!
//! The queue describes one serialized request. A multiplexing client needs one
//! queue per stream plus an arbiter above them that never starts a second
//! stream's frame while any frame is partially written.

const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;

/// What a frame does to the connection's framing rules.
pub const Class = enum {
    /// HEADERS. Opens a header block unless `end_headers` is set.
    headers,
    /// CONTINUATION. Only legal while a header block is open.
    continuation,
    /// DATA or any other frame that takes no part in a header block.
    data,
    /// A connection-level frame: WINDOW_UPDATE, PING, SETTINGS, GOAWAY.
    control,
};

pub const Frame = struct {
    /// One complete encoded frame. Copied into the queue's storage.
    bytes: []const u8,
    stream_id: u31,
    class: Class,
    /// The frame carries the END_HEADERS flag.
    end_headers: bool,
};

/// Retry state for the request being written.
pub const State = enum {
    /// No byte of this request has left the queue.
    staged,
    /// Some byte has been accepted; END_HEADERS has not completed.
    in_flight,
    /// The frame carrying END_HEADERS was fully accepted.
    committed,
};

pub const PushError = error{
    /// A frame is partially written. Nothing may be appended until it completes.
    AppendWhilePartial,
    /// No room for the frame's bytes or metadata.
    QueueFull,
    /// A header block is open and this frame is not a CONTINUATION on that
    /// stream, or a CONTINUATION arrived with no block open.
    InterleavedFrame,
    /// A frame with no bytes.
    EmptyFrame,
};

pub const Queue = struct {
    storage: []u8,
    meta: []Meta,
    /// Bytes used in `storage`. Reset when the queue empties.
    used: usize,
    head: usize,
    tail: usize,
    /// Bytes of the head frame the transport already accepted.
    offset: usize,
    state: State,
    /// Stream whose header block is open, if any.
    run_stream: ?u31,

    pub const Meta = struct {
        start: usize,
        end: usize,
        stream_id: u31,
        class: Class,
        end_headers: bool,
    };

    pub fn init(storage: []u8, meta: []Meta) Queue {
        return .{
            .storage = storage,
            .meta = meta,
            .used = 0,
            .head = 0,
            .tail = 0,
            .offset = 0,
            .state = .staged,
            .run_stream = null,
        };
    }

    pub fn count(self: *const Queue) usize {
        return self.tail - self.head;
    }

    pub fn isEmpty(self: *const Queue) bool {
        return self.count() == 0;
    }

    /// True when a frame is partially written. Nothing may be appended.
    pub fn isPartial(self: *const Queue) bool {
        return self.offset != 0;
    }

    pub fn currentState(self: *const Queue) State {
        return self.state;
    }

    /// Bytes of the head frame still to be written, or null when empty.
    pub fn unsent(self: *const Queue) ?[]const u8 {
        if (self.isEmpty()) return null;
        const m = self.meta[self.head];
        return self.storage[m.start + self.offset .. m.end];
    }

    pub fn push(self: *Queue, frame: Frame) PushError!void {
        if (self.offset != 0) return error.AppendWhilePartial;
        if (frame.bytes.len == 0) return error.EmptyFrame;
        if (self.count() == self.meta.len) return error.QueueFull;
        if (self.used + frame.bytes.len > self.storage.len) return error.QueueFull;

        const continuing = frame.class == .continuation;
        if (self.run_stream) |stream| {
            // RFC 9113 §4.3 — once a header block opens, only CONTINUATION on
            // the same stream may follow until END_HEADERS.
            if (!continuing or frame.stream_id != stream) return error.InterleavedFrame;
        } else if (continuing) {
            return error.InterleavedFrame;
        }

        const start = self.used;
        @memcpy(self.storage[start..][0..frame.bytes.len], frame.bytes);
        self.used += frame.bytes.len;
        self.meta[self.tail] = .{
            .start = start,
            .end = self.used,
            .stream_id = frame.stream_id,
            .class = frame.class,
            .end_headers = frame.end_headers,
        };
        self.tail += 1;

        if (frame.class == .headers and !frame.end_headers) {
            self.run_stream = frame.stream_id;
        } else if (continuing and frame.end_headers) {
            self.run_stream = null;
        }
    }

    /// Report bytes the transport accepted. Never more than `unsent().?.len`.
    pub fn accepted(self: *Queue, n: usize) void {
        const frame = self.unsent() orelse {
            assert(n == 0);
            return;
        };
        assert(n <= frame.len);
        if (n == 0) return;

        if (self.state == .staged) self.state = .in_flight;
        self.offset += n;
        if (self.offset != frame.len) return;

        const m = self.meta[self.head];
        self.offset = 0;
        self.head += 1;
        if (m.end_headers and self.state != .committed) self.state = .committed;
        if (self.head == self.tail) {
            self.head = 0;
            self.tail = 0;
            self.used = 0;
        }
    }

    /// Start a new request. Requires an empty queue.
    pub fn reset(self: *Queue) void {
        assert(self.isEmpty());
        self.used = 0;
        self.offset = 0;
        self.state = .staged;
        self.run_stream = null;
    }
};

fn encode(out: []u8, tag: u8) []const u8 {
    out[0] = tag;
    return out[0..1];
}

test "a partially written frame blocks appends until it completes" {
    var storage: [64]u8 = undefined;
    var meta: [8]Queue.Meta = undefined;
    var q: Queue = .init(&storage, &meta);

    var buf: [4]u8 = undefined;
    try q.push(.{ .bytes = encode(&buf, 'a'), .stream_id = 1, .class = .headers, .end_headers = true });
    try testing.expectEqual(@as(usize, 1), q.count());

    q.accepted(0);
    try testing.expectEqual(State.staged, q.currentState());

    q.accepted(1);
    try testing.expectEqual(State.committed, q.currentState());
    try testing.expect(q.isEmpty());
}

test "append behind a partial frame is refused" {
    var storage: [64]u8 = undefined;
    var meta: [8]Queue.Meta = undefined;
    var q: Queue = .init(&storage, &meta);

    var buf: [8]u8 = undefined;
    try q.push(.{ .bytes = "ab"[0..], .stream_id = 1, .class = .data, .end_headers = false });

    q.accepted(1);
    try testing.expect(q.isPartial());
    try testing.expectError(error.AppendWhilePartial, q.push(.{
        .bytes = encode(&buf, 'c'),
        .stream_id = 1,
        .class = .data,
        .end_headers = false,
    }));
}

test "a header block admits only its own CONTINUATION frames" {
    var storage: [64]u8 = undefined;
    var meta: [8]Queue.Meta = undefined;
    var q: Queue = .init(&storage, &meta);

    var buf: [8]u8 = undefined;
    try q.push(.{ .bytes = encode(&buf, 'H'), .stream_id = 3, .class = .headers, .end_headers = false });

    // RFC 9113 §4.3 — DATA on the same stream is an interleave.
    try testing.expectError(error.InterleavedFrame, q.push(.{
        .bytes = encode(&buf, 'D'),
        .stream_id = 3,
        .class = .data,
        .end_headers = false,
    }));
    // A CONTINUATION on another stream is an interleave too.
    try testing.expectError(error.InterleavedFrame, q.push(.{
        .bytes = encode(&buf, 'C'),
        .stream_id = 5,
        .class = .continuation,
        .end_headers = false,
    }));
    // CONTROL frames are not exempt: nothing may interleave a block.
    try testing.expectError(error.InterleavedFrame, q.push(.{
        .bytes = encode(&buf, 'W'),
        .stream_id = 0,
        .class = .control,
        .end_headers = false,
    }));

    try q.push(.{ .bytes = encode(&buf, 'C'), .stream_id = 3, .class = .continuation, .end_headers = true });
    try q.push(.{ .bytes = encode(&buf, 'D'), .stream_id = 3, .class = .data, .end_headers = false });
    try testing.expectEqual(@as(usize, 3), q.count());
}

test "only the frame carrying END_HEADERS commits" {
    var storage: [64]u8 = undefined;
    var meta: [8]Queue.Meta = undefined;
    var q: Queue = .init(&storage, &meta);

    var buf: [8]u8 = undefined;
    try q.push(.{ .bytes = encode(&buf, 'H'), .stream_id = 1, .class = .headers, .end_headers = false });
    try q.push(.{ .bytes = encode(&buf, 'C'), .stream_id = 1, .class = .continuation, .end_headers = true });

    q.accepted(q.unsent().?.len);
    try testing.expectEqual(State.in_flight, q.currentState());

    q.accepted(q.unsent().?.len);
    try testing.expectEqual(State.committed, q.currentState());
}

test "a DATA frame alone never commits" {
    var storage: [64]u8 = undefined;
    var meta: [8]Queue.Meta = undefined;
    var q: Queue = .init(&storage, &meta);

    var buf: [8]u8 = undefined;
    try q.push(.{ .bytes = encode(&buf, 'D'), .stream_id = 1, .class = .data, .end_headers = false });

    q.accepted(1);
    try testing.expectEqual(State.in_flight, q.currentState());
    try testing.expect(q.isEmpty());
}

test "storage and metadata exhaustion are reported before any state change" {
    var storage: [2]u8 = undefined;
    var meta: [1]Queue.Meta = undefined;
    var q: Queue = .init(&storage, &meta);

    try q.push(.{ .bytes = "ab"[0..], .stream_id = 1, .class = .data, .end_headers = false });
    try testing.expectError(error.QueueFull, q.push(.{ .bytes = "c"[0..], .stream_id = 1, .class = .data, .end_headers = false }));
    try testing.expectEqual(@as(usize, 1), q.count());

    q.accepted(2);
    try testing.expect(q.isEmpty());
    try testing.expectEqual(@as(usize, 0), q.used);

    try q.push(.{ .bytes = "cd"[0..], .stream_id = 1, .class = .data, .end_headers = false });
    try testing.expectError(error.QueueFull, q.push(.{ .bytes = "e"[0..], .stream_id = 1, .class = .data, .end_headers = false }));
}

test "reset clears state and reclaims storage" {
    var storage: [8]u8 = undefined;
    var meta: [4]Queue.Meta = undefined;
    var q: Queue = .init(&storage, &meta);

    try q.push(.{ .bytes = "ab"[0..], .stream_id = 1, .class = .headers, .end_headers = true });
    q.accepted(2);
    try testing.expectEqual(State.committed, q.currentState());

    q.reset();
    try testing.expectEqual(State.staged, q.currentState());
    try testing.expectEqual(@as(usize, 0), q.used);
    try q.push(.{ .bytes = "z"[0..], .stream_id = 1, .class = .data, .end_headers = false });
}

test "an empty frame is refused" {
    var storage: [8]u8 = undefined;
    var meta: [4]Queue.Meta = undefined;
    var q: Queue = .init(&storage, &meta);
    try testing.expectError(error.EmptyFrame, q.push(.{ .bytes = "", .stream_id = 1, .class = .data, .end_headers = false }));
}

test "a CONTINUATION without an open block is refused" {
    var storage: [8]u8 = undefined;
    var meta: [4]Queue.Meta = undefined;
    var q: Queue = .init(&storage, &meta);
    try testing.expectError(error.InterleavedFrame, q.push(.{
        .bytes = "c"[0..],
        .stream_id = 1,
        .class = .continuation,
        .end_headers = true,
    }));
}
