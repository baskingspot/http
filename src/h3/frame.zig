//! HTTP/3 frame codec (RFC 9114 §7).
//!
//! Sans-I/O: `parse` takes one whole frame, `Reader` walks a stream in pieces,
//! and `write` fills a caller buffer. Nothing here owns memory, and every
//! payload borrows the input.
//!
//! The codec checks frame syntax only. Which frame may appear on which stream,
//! SETTINGS state, and the rest belong to the session. An unknown extension
//! type is `Body.unknown`; the caller ignores it, as §9 requires. The four
//! reserved HTTP/2 types are a connection error on receipt, so they are
//! `error.Reserved` here.
//!
//! Neither the type nor the length has a minimal-encoding rule. RFC 9114 §7.1
//! defines both as variable-length integers without one; RFC 9000 §16's
//! exception is the QUIC Frame Type field, not an HTTP/3 field. The length must
//! match the payload bytes exactly (§10.8), and nothing may follow the fields a
//! typed payload defines.

const std = @import("std");
const testing = std.testing;
const mem = std.mem;

const Cursor = @import("../Cursor.zig");
const varint = @import("../varint.zig");

/// Frame types defined by RFC 9114 §7.2, plus the open registry. The four
/// reserved HTTP/2 values are deliberately absent; `isReserved` names them.
pub const FrameType = enum(u62) {
    data = 0x00,
    headers = 0x01,
    cancel_push = 0x03,
    settings = 0x04,
    push_promise = 0x05,
    goaway = 0x07,
    max_push_id = 0x0d,
    _,
};

pub const Error = error{
    /// The buffer ended inside the header, or before the payload length.
    Incomplete,
    /// A frame type reserved by RFC 9114 §11.2.1 for HTTP/2 (0x02, 0x06,
    /// 0x08, 0x09). Receipt is H3_FRAME_UNEXPECTED on every stream.
    Reserved,
    /// The payload does not match the fields its type defines.
    InvalidLength,
    /// The destination buffer cannot hold the frame.
    NoSpace,
    /// The payload is larger than a varint can describe.
    TooLarge,
};

/// Whether `frame_type` is one of the HTTP/2 types RFC 9114 §11.2.1 reserved.
pub fn isReserved(frame_type: u62) bool {
    return switch (frame_type) {
        0x02, 0x06, 0x08, 0x09 => true,
        else => false,
    };
}

pub const Header = struct {
    frame_type: FrameType,
    /// Payload length, excluding the two varints that precede it.
    length: u62,
};

pub const ParsedHeader = struct {
    header: Header,
    /// The bytes the type and the length occupied.
    consumed: u32,
};

/// Parse the type and length without the payload. On `error.Incomplete` the
/// buffer did not hold both varints.
pub fn parseHeader(buf: []const u8) Error!ParsedHeader {
    var cursor = Cursor.init(buf);
    const frame_type = varint.decode(&cursor) catch return error.Incomplete;
    if (isReserved(frame_type)) return error.Reserved;
    const length = varint.decode(&cursor) catch return error.Incomplete;
    return .{
        .header = .{ .frame_type = @fromBackingInt(@intCast(frame_type)), .length = length },
        .consumed = cursor.pos,
    };
}

pub const Setting = struct {
    id: u62,
    value: u62,
};

/// A validated SETTINGS payload: a sequence of id/value varint pairs.
pub const Settings = struct {
    /// The bytes after the frame header. Construct with `parse`.
    payload: []const u8,

    /// Validate the whole sequence. A pair cut short is `InvalidLength`.
    pub fn parse(payload: []const u8) Error!Settings {
        var cursor = Cursor.init(payload);
        while (!cursor.atEnd()) {
            _ = varint.decode(&cursor) catch return error.InvalidLength;
            _ = varint.decode(&cursor) catch return error.InvalidLength;
        }
        return .{ .payload = payload };
    }

    pub fn iterator(self: Settings) Iterator {
        return .{ .cursor = Cursor.init(self.payload) };
    }

    pub const Iterator = struct {
        cursor: Cursor,

        /// Null at the end. The payload was validated by `Settings.parse`.
        pub fn next(self: *Iterator) ?Setting {
            if (self.cursor.atEnd()) return null;
            const id = varint.decode(&self.cursor) catch unreachable;
            const value = varint.decode(&self.cursor) catch unreachable;
            return .{ .id = id, .value = value };
        }
    };
};

pub const PushPromise = struct {
    push_id: u62,
    /// The encoded field section, borrowed from the payload.
    block: []const u8,
};

pub const Unknown = struct {
    frame_type: u62,
    payload: []const u8,
};

pub const Body = union(enum) {
    data: []const u8,
    headers: []const u8,
    cancel_push: u62,
    settings: Settings,
    push_promise: PushPromise,
    goaway: u62,
    max_push_id: u62,
    unknown: Unknown,
};

pub const Frame = struct {
    header: Header,
    body: Body,
};

/// Parse one whole frame. `error.Incomplete` means the buffer ended before the
/// payload did; the caller waits for more bytes.
pub fn parse(buf: []const u8) Error!Frame {
    const parsed = try parseHeader(buf);
    const end = @as(u64, parsed.consumed) + parsed.header.length;
    if (end > buf.len) return error.Incomplete;

    const payload = buf[parsed.consumed..@intCast(end)];
    return .{
        .header = parsed.header,
        .body = try parseBody(parsed.header.frame_type, payload),
    };
}

fn parseBody(frame_type: FrameType, payload: []const u8) Error!Body {
    return switch (frame_type) {
        .data => .{ .data = payload },
        .headers => .{ .headers = payload },
        .cancel_push => .{ .cancel_push = try exactVarint(payload) },
        .settings => .{ .settings = try Settings.parse(payload) },
        .push_promise => blk: {
            var cursor = Cursor.init(payload);
            const push_id = varint.decode(&cursor) catch return error.InvalidLength;
            break :blk .{ .push_promise = .{
                .push_id = push_id,
                .block = payload[cursor.pos..],
            } };
        },
        .goaway => .{ .goaway = try exactVarint(payload) },
        .max_push_id => .{ .max_push_id = try exactVarint(payload) },
        else => .{ .unknown = .{
            .frame_type = @backingInt(frame_type),
            .payload = payload,
        } },
    };
}

/// One varint that must consume the whole payload.
fn exactVarint(payload: []const u8) Error!u62 {
    var cursor = Cursor.init(payload);
    const value = varint.decode(&cursor) catch return error.InvalidLength;
    if (!cursor.atEnd()) return error.InvalidLength;
    return value;
}

/// A per-stream frame reader. Feed it the bytes a QUIC stream delivered and it
/// returns a header once, then the payload in the chunks those bytes allow.
///
/// The reader never consumes a partial header and never consumes a payload
/// byte it cannot return. On `error.Incomplete`, the caller's cursor is where
/// it was.
pub const Reader = struct {
    header: ?Header,
    /// Header bytes not yet consumed from the caller's cursor.
    header_len: u32,
    remaining: u62,

    pub fn init() Reader {
        return .{ .header = null, .header_len = 0, .remaining = 0 };
    }

    pub fn next(self: *Reader, cursor: *Cursor) Error!Chunk {
        if (self.header == null) {
            const parsed = try parseHeader(cursor.rest());
            self.header = parsed.header;
            self.header_len = parsed.consumed;
            self.remaining = parsed.header.length;

            if (self.remaining == 0) {
                _ = cursor.skip(self.header_len);
                const header = self.header.?;
                self.header = null;
                self.header_len = 0;
                return .{ .header = header, .payload = "", .end = true };
            }
        }

        const header = self.header.?;
        if (cursor.remaining() <= self.header_len) return error.Incomplete;

        _ = cursor.skip(self.header_len);
        self.header_len = 0;

        const take: u32 = @intCast(@min(self.remaining, @as(u62, cursor.remaining())));
        const payload = cursor.take(take).?;
        self.remaining -= @as(u62, take);

        const end = self.remaining == 0;
        if (end) self.header = null;
        return .{ .header = header, .payload = payload, .end = end };
    }
};

pub const Chunk = struct {
    header: Header,
    /// A run of payload bytes. Borrowed from the caller's buffer. Empty only
    /// for a zero-length frame, which is returned as one `end` chunk.
    payload: []const u8,
    /// The frame ends with this chunk.
    end: bool,
};

/// The bytes `writeHeader` needs for `payload_len`.
pub fn headerLen(frame_type: u62, payload_len: u62) usize {
    return varint.encodedLen(frame_type) + varint.encodedLen(payload_len);
}

/// Write the type and length only. The caller appends the payload.
pub fn writeHeader(buf: []u8, frame_type: FrameType, payload_len: u62) Error![]u8 {
    const value = @backingInt(frame_type);
    if (isReserved(value)) return error.Reserved;

    if (buf.len < headerLen(value, payload_len)) return error.NoSpace;
    var pos: usize = 0;
    pos += (try varint.encode(buf[pos..], value)).len;
    pos += (try varint.encode(buf[pos..], payload_len)).len;
    return buf[0..pos];
}

/// Write one whole frame.
pub fn write(buf: []u8, frame_type: FrameType, payload: []const u8) Error![]u8 {
    if (payload.len > varint.max) return error.TooLarge;
    const payload_len: u62 = @intCast(payload.len);
    const need = headerLen(@backingInt(frame_type), payload_len) + payload.len;
    if (buf.len < need) return error.NoSpace;

    const header = try writeHeader(buf, frame_type, payload_len);
    @memcpy(buf[header.len..][0..payload.len], payload);
    return buf[0 .. header.len + payload.len];
}

fn expectFrame(bytes: []const u8, frame_type: FrameType, payload: []const u8) !void {
    const frame = try parse(bytes);
    try testing.expectEqual(frame_type, frame.header.frame_type);
    try testing.expectEqual(@as(u62, @intCast(payload.len)), frame.header.length);
    switch (frame.body) {
        .data => |value| try testing.expectEqualStrings(payload, value),
        .headers => |value| try testing.expectEqualStrings(payload, value),
        else => unreachable,
    }
}

test "RFC 9114 §7.1, a frame round-trips through the writer" {
    var buf: [16]u8 = undefined;
    const bytes = try write(&buf, .data, "hello");
    try testing.expectEqualSlices(u8, &.{ 0x00, 0x05, 'h', 'e', 'l', 'l', 'o' }, bytes);
    try expectFrame(bytes, .data, "hello");

    const headers = try write(&buf, .headers, "block");
    try expectFrame(headers, .headers, "block");
}

test "RFC 9114 §7.1, neither varint must use the shortest encoding" {
    // Type 0 encoded in two bytes, length 0 in one.
    const wide_type = [_]u8{ 0x40, 0x00, 0x00 };
    try expectFrame(&wide_type, .data, "");

    // Type 0 in one byte, length 3 in two.
    const wide_length = [_]u8{ 0x00, 0x40, 0x03, 'a', 'b', 'c' };
    try expectFrame(&wide_length, .data, "abc");
}

test "RFC 9114 §7.2.8, the reserved HTTP/2 types reject on receipt and on send" {
    const reserved = [_]u8{ 0x02, 0x06, 0x08, 0x09 };
    for (reserved) |value| {
        const bytes = [_]u8{ value, 0x00 };
        try testing.expectError(error.Reserved, parse(&bytes));

        var buf: [8]u8 = undefined;
        const frame_type: FrameType = @fromBackingInt(@intCast(@as(u62, value)));
        try testing.expectError(error.Reserved, write(&buf, frame_type, ""));
    }
}

test "a payload that does not match its type is InvalidLength" {
    const goaway_extra = [_]u8{ 0x07, 0x02, 0x01, 0x02 };
    try testing.expectError(error.InvalidLength, parse(&goaway_extra));

    const goaway_short = [_]u8{ 0x07, 0x01, 0x40 };
    try testing.expectError(error.InvalidLength, parse(&goaway_short));

    const cancel_push_empty = [_]u8{ 0x03, 0x00 };
    try testing.expectError(error.InvalidLength, parse(&cancel_push_empty));

    const max_push_id_extra = [_]u8{ 0x0d, 0x02, 0x01, 0x02 };
    try testing.expectError(error.InvalidLength, parse(&max_push_id_extra));

    const settings_odd = [_]u8{ 0x04, 0x03, 0x01, 0x02, 0x03 };
    try testing.expectError(error.InvalidLength, parse(&settings_odd));
}

test "RFC 9114 §6.2.3, an unknown frame type is borrowed, not rejected" {
    // 0x1f * 0 + 0x21 is the exercise-and-ignore type.
    const bytes = [_]u8{ 0x21, 0x03, 0xaa, 0xbb, 0xcc };
    const frame = try parse(&bytes);
    try testing.expectEqual(@as(u62, 0x21), @backingInt(frame.header.frame_type));
    try testing.expectEqual(@as(u62, 0x03), frame.header.length);
    try testing.expectEqualStrings(&.{ 0xaa, 0xbb, 0xcc }, frame.body.unknown.payload);
    try testing.expectEqual(@as(u62, 0x21), frame.body.unknown.frame_type);
}

test "SETTINGS entries iterate in wire order" {
    const bytes = [_]u8{
        0x04, 0x06,
        0x01, 0x10, // id 1, value 16
        0x06, 0x20, // id 6, value 32
        0x07, 0x00, // id 7, value 0
    };
    const frame = try parse(&bytes);
    var entries = frame.body.settings.iterator();
    try testing.expectEqual(Setting{ .id = 1, .value = 16 }, entries.next().?);
    try testing.expectEqual(Setting{ .id = 6, .value = 32 }, entries.next().?);
    try testing.expectEqual(Setting{ .id = 7, .value = 0 }, entries.next().?);
    try testing.expect(entries.next() == null);
}

test "PUSH_PROMISE splits the push id from the field section" {
    const bytes = [_]u8{ 0x05, 0x04, 0x09, 0xaa, 0xbb, 0xcc };
    const frame = try parse(&bytes);
    try testing.expectEqual(@as(u62, 9), frame.body.push_promise.push_id);
    try testing.expectEqualStrings(&.{ 0xaa, 0xbb, 0xcc }, frame.body.push_promise.block);
}

test "the reader returns a split frame in chunks and moves only on a chunk" {
    var reader = Reader.init();
    const bytes = [_]u8{ 0x00, 0x08, 1, 2, 3, 4, 5, 6, 7, 8, 0x01, 0x01, 0xee };

    // The header alone is not enough for a payload byte.
    var cursor = Cursor.init(bytes[0..2]);
    try testing.expectError(error.Incomplete, reader.next(&cursor));
    try testing.expectEqual(@as(u32, 0), cursor.pos);

    // Header plus four payload bytes.
    cursor = Cursor.init(bytes[0..6]);
    const first = try reader.next(&cursor);
    try testing.expectEqual(FrameType.data, first.header.frame_type);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, first.payload);
    try testing.expect(!first.end);
    try testing.expectEqual(@as(u32, 6), cursor.pos);

    // The rest of the first frame and the whole second frame, one call each.
    cursor = Cursor.init(bytes[6..]);
    const second = try reader.next(&cursor);
    try testing.expectEqualSlices(u8, &.{ 5, 6, 7, 8 }, second.payload);
    try testing.expect(second.end);

    const third = try reader.next(&cursor);
    try testing.expectEqual(FrameType.headers, third.header.frame_type);
    try testing.expectEqualSlices(u8, &.{0xee}, third.payload);
    try testing.expect(third.end);
    try testing.expect(cursor.atEnd());

    try testing.expectError(error.Incomplete, reader.next(&cursor));
}

test "a zero-length frame is one chunk" {
    var reader = Reader.init();
    var cursor = Cursor.init(&.{ 0x00, 0x00 });
    const chunk = try reader.next(&cursor);
    try testing.expectEqual(FrameType.data, chunk.header.frame_type);
    try testing.expectEqualStrings("", chunk.payload);
    try testing.expect(chunk.end);
    try testing.expect(cursor.atEnd());
}

test "a short destination is NoSpace and writes nothing" {
    var buf: [3]u8 = undefined;
    buf = .{ 0xaa, 0xbb, 0xcc };
    try testing.expectError(error.NoSpace, write(&buf, .data, "hello"));
    try testing.expectEqualSlices(u8, &.{ 0xaa, 0xbb, 0xcc }, &buf);

    var tiny: [1]u8 = undefined;
    const wide_type: FrameType = @fromBackingInt(@intCast(0x3fff));
    try testing.expectError(error.NoSpace, writeHeader(&tiny, wide_type, 0));
}

test "fuzz parse against a bounded model" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) anyerror!void {
            var buf: [64]u8 = undefined;
            const input = buf[0..smith.slice(&buf)];

            const frame = parse(input) catch |err| {
                try testing.expect(err == error.Incomplete or
                    err == error.Reserved or
                    err == error.InvalidLength);
                return;
            };

            const end = @as(u64, (try parseHeader(input)).consumed) + frame.header.length;
            try testing.expectEqual(@as(u64, input.len), end);

            switch (frame.body) {
                .data => |payload| try testing.expectEqual(
                    frame.header.length,
                    @as(u62, @intCast(payload.len)),
                ),
                .headers => |payload| try testing.expectEqual(
                    frame.header.length,
                    @as(u62, @intCast(payload.len)),
                ),
                .settings => |settings| try testing.expectEqual(
                    frame.header.length,
                    @as(u62, @intCast(settings.payload.len)),
                ),
                .push_promise => |promise| try testing.expect(
                    promise.block.len + 1 <= @as(usize, @intCast(frame.header.length)),
                ),
                else => {},
            }
        }
    }.run, .{
        .corpus = &.{
            "",
            "\x00\x00",
            "\x00\x05hello",
            "\x04\x06\x01\x10\x06\x20\x07\x00",
            "\x02\x00",
            "\x21\x03\xaa\xbb\xcc",
        },
    });
}
