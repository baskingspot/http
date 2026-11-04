//! HTTP/2 frame codec (RFC 9113 §4, §6, §7).
//!
//! Sans-I/O: `parse` takes bytes read so far and reports a frame, `Incomplete`,
//! or an error; `Writer` fills a caller buffer. Neither owns memory, and both
//! borrow the payload from the input.
//!
//! `parse` enforces frame syntax only: the 9-byte header, the per-type payload
//! length, and padding. Stream and connection rules (which frame may appear on
//! which stream, SETTINGS state, flow control, CONTINUATION ordering) belong to
//! the layer above. Unknown frame types parse as `Body.unknown`; the caller
//! ignores them, as RFC 9113 §4.1 requires.
//!
//! h2c and h2 over TLS use this same codec. The connection preface is
//! `preface`; nothing here touches TLS.

const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;
const mem = std.mem;

/// The client connection preface (RFC 9113 §3.4).
pub const preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";

/// The default and largest SETTINGS_MAX_FRAME_SIZE values (RFC 9113 §6.5.2).
pub const default_max_frame_size: u32 = 16_384;
pub const max_frame_size_limit: u32 = 0xff_ffff;

/// Frame types defined by RFC 9113 §6, plus the open registry.
pub const FrameType = enum(u8) {
    data = 0x0,
    headers = 0x1,
    priority = 0x2,
    rst_stream = 0x3,
    settings = 0x4,
    push_promise = 0x5,
    ping = 0x6,
    goaway = 0x7,
    window_update = 0x8,
    continuation = 0x9,
    _,
};

/// Error codes from RFC 9113 §7, plus the open registry.
pub const ErrorCode = enum(u32) {
    no_error = 0x0,
    protocol_error = 0x1,
    internal_error = 0x2,
    flow_control_error = 0x3,
    settings_timeout = 0x4,
    stream_closed = 0x5,
    frame_size_error = 0x6,
    refused_stream = 0x7,
    cancel = 0x8,
    compression_error = 0x9,
    connect_error = 0xa,
    enhance_your_calm = 0xb,
    inadequate_security = 0xc,
    http_1_1_required = 0xd,
    _,
};

/// SETTINGS identifiers from RFC 9113 §6.5.2, plus the open registry.
pub const SettingId = enum(u16) {
    header_table_size = 0x1,
    enable_push = 0x2,
    max_concurrent_streams = 0x3,
    initial_window_size = 0x4,
    max_frame_size = 0x5,
    max_header_list_size = 0x6,
    _,
};

/// Frame flags. The same bit means different things per frame type; unused
/// flags are ignored on receipt (RFC 9113 §4.1).
pub const flags = struct {
    /// DATA, HEADERS.
    pub const end_stream: u8 = 0x1;
    /// SETTINGS, PING.
    pub const ack: u8 = 0x1;
    /// HEADERS, PUSH_PROMISE, CONTINUATION.
    pub const end_headers: u8 = 0x4;
    /// DATA, HEADERS, PUSH_PROMISE.
    pub const padded: u8 = 0x8;
    /// HEADERS.
    pub const priority: u8 = 0x20;
};

pub const Error = error{
    /// Fewer than 9 header bytes, or fewer payload bytes than the header says.
    Incomplete,
    /// The payload length exceeds the caller's SETTINGS_MAX_FRAME_SIZE.
    FrameTooLarge,
    /// The payload length is wrong for the frame type.
    InvalidLength,
    /// The padding length is larger than the payload.
    InvalidPadding,
    /// The frame cannot be represented.
    Invalid,
};

pub const Header = struct {
    /// Payload length, excluding the 9-byte header.
    length: u24,
    type: FrameType,
    flags: u8,
    /// 31 bits. The reserved high bit is ignored on receipt (§4.1).
    stream_id: u31,
};

pub const Parsed = struct {
    header: Header,
    /// The payload, borrowed from the input.
    payload: []const u8,
    /// 9 plus `header.length`.
    consumed: u32,
};

pub fn parseHeader(buf: []const u8) Error!Header {
    if (buf.len < 9) return error.Incomplete;
    return .{
        .length = mem.readInt(u24, buf[0..3], .big),
        .type = @enumFromInt(buf[3]),
        .flags = buf[4],
        .stream_id = @intCast(mem.readInt(u32, buf[5..9], .big) & 0x7fff_ffff),
    };
}

pub fn encodeHeader(out: *[9]u8, header: Header) void {
    mem.writeInt(u24, out[0..3], header.length, .big);
    out[3] = @intFromEnum(header.type);
    out[4] = header.flags;
    mem.writeInt(u32, out[5..9], header.stream_id, .big);
}

/// Parse one frame from the front of `buf`, rejecting a payload larger than
/// `max_frame_size` before waiting for it.
pub fn parse(buf: []const u8, max_frame_size: u32) Error!Parsed {
    const header = try parseHeader(buf);
    if (header.length > max_frame_size) return error.FrameTooLarge;

    const end: u32 = 9 + @as(u32, header.length);
    if (buf.len < end) return error.Incomplete;
    return .{
        .header = header,
        .payload = buf[9..end],
        .consumed = end,
    };
}

pub const Data = struct {
    /// Payload with the pad length and padding removed.
    data: []const u8,
};

pub const Priority = struct {
    exclusive: bool,
    dependency: u31,
    /// The wire value; the effective weight is this plus one.
    weight: u8,
};

pub const Headers = struct {
    /// Present when the PRIORITY flag is set. Priority signals are deprecated
    /// (RFC 9113 §5.3.2), but the fields are still parsed.
    priority: ?Priority,
    /// The field block fragment, padding removed.
    block: []const u8,
};

pub const RstStream = struct {
    error_code: ErrorCode,
};

pub const Setting = struct {
    id: SettingId,
    value: u32,
};

pub const Settings = struct {
    ack: bool,
    /// The 6-byte entries, in wire order. Use `iterator`.
    payload: []const u8,

    pub fn iterator(self: Settings) SettingsIterator {
        return .{ .payload = self.payload, .pos = 0 };
    }
};

pub const SettingsIterator = struct {
    payload: []const u8,
    pos: usize,

    pub fn next(self: *SettingsIterator) ?Setting {
        if (self.pos == self.payload.len) return null;
        const entry = self.payload[self.pos..][0..6];
        self.pos += 6;
        return .{
            .id = @enumFromInt(mem.readInt(u16, entry[0..2], .big)),
            .value = mem.readInt(u32, entry[2..6], .big),
        };
    }
};

pub const PushPromise = struct {
    promised_stream_id: u31,
    /// The field block fragment, padding removed.
    block: []const u8,
};

pub const Ping = struct {
    ack: bool,
    /// Exactly 8 octets.
    payload: []const u8,
};

pub const GoAway = struct {
    last_stream_id: u31,
    error_code: ErrorCode,
    debug: []const u8,
};

pub const WindowUpdate = struct {
    /// The 31-bit increment. Zero is a protocol error at the stream layer
    /// (RFC 9113 §6.9); this codec keeps the wire value.
    increment: u31,
};

pub const Continuation = struct {
    block: []const u8,
};

pub const Unknown = struct {
    type: FrameType,
    payload: []const u8,
};

pub const Body = union(enum) {
    data: Data,
    headers: Headers,
    priority: Priority,
    rst_stream: RstStream,
    settings: Settings,
    push_promise: PushPromise,
    ping: Ping,
    goaway: GoAway,
    window_update: WindowUpdate,
    continuation: Continuation,
    unknown: Unknown,
};

/// Parse the payload of a frame whose header is already known.
pub fn body(header: Header, payload: []const u8) Error!Body {
    switch (header.type) {
        .data => return .{ .data = .{ .data = try unpadded(payload, header.flags) } },

        .headers => {
            var rest = try unpadded(payload, header.flags);
            var priority: ?Priority = null;
            if (header.flags & flags.priority != 0) {
                if (rest.len < 5) return error.InvalidLength;
                priority = parsePriority(rest[0..5]);
                rest = rest[5..];
            }
            return .{ .headers = .{ .priority = priority, .block = rest } };
        },

        .priority => {
            if (payload.len != 5) return error.InvalidLength;
            return .{ .priority = parsePriority(payload) };
        },

        .rst_stream => {
            if (payload.len != 4) return error.InvalidLength;
            return .{ .rst_stream = .{
                .error_code = @enumFromInt(mem.readInt(u32, payload[0..4], .big)),
            } };
        },

        .settings => {
            const ack = header.flags & flags.ack != 0;
            if (payload.len % 6 != 0) return error.InvalidLength;
            if (ack and payload.len != 0) return error.InvalidLength;
            return .{ .settings = .{ .ack = ack, .payload = payload } };
        },

        .push_promise => {
            const rest = try unpadded(payload, header.flags);
            if (rest.len < 4) return error.InvalidLength;
            return .{ .push_promise = .{
                .promised_stream_id = readStreamId(rest[0..4]),
                .block = rest[4..],
            } };
        },

        .ping => {
            if (payload.len != 8) return error.InvalidLength;
            return .{ .ping = .{
                .ack = header.flags & flags.ack != 0,
                .payload = payload,
            } };
        },

        .goaway => {
            if (payload.len < 8) return error.InvalidLength;
            return .{ .goaway = .{
                .last_stream_id = readStreamId(payload[0..4]),
                .error_code = @enumFromInt(mem.readInt(u32, payload[4..8], .big)),
                .debug = payload[8..],
            } };
        },

        .window_update => {
            if (payload.len != 4) return error.InvalidLength;
            return .{ .window_update = .{ .increment = readStreamId(payload[0..4]) } };
        },

        .continuation => return .{ .continuation = .{ .block = payload } },

        else => return .{ .unknown = .{ .type = header.type, .payload = payload } },
    }
}

fn unpadded(payload: []const u8, frame_flags: u8) Error![]const u8 {
    if (frame_flags & flags.padded == 0) return payload;
    if (payload.len == 0) return error.InvalidPadding;
    const pad: usize = payload[0];
    if (pad + 1 > payload.len) return error.InvalidPadding;
    return payload[1 .. payload.len - pad];
}

fn parsePriority(bytes: []const u8) Priority {
    assert(bytes.len == 5);
    const word = mem.readInt(u32, bytes[0..4], .big);
    return .{
        .exclusive = word & 0x8000_0000 != 0,
        .dependency = @intCast(word & 0x7fff_ffff),
        .weight = bytes[4],
    };
}

fn readStreamId(bytes: []const u8) u31 {
    assert(bytes.len == 4);
    return @intCast(mem.readInt(u32, bytes[0..4], .big) & 0x7fff_ffff);
}

/// Build frames into a caller buffer. `begin` reserves the header, the caller
/// appends the payload, and `end` patches the length.
pub const Writer = struct {
    buf: []u8,
    pos: usize,
    start: usize,

    pub const WriterError = error{NoSpace};

    pub fn init(buf: []u8) Writer {
        return .{ .buf = buf, .pos = 0, .start = 0 };
    }

    pub fn begin(
        self: *Writer,
        frame_type: FrameType,
        frame_flags: u8,
        stream_id: u31,
    ) WriterError!void {
        if (self.buf.len - self.pos < 9) return error.NoSpace;
        self.start = self.pos;
        @memset(self.buf[self.start..][0..9], 0);
        self.pos += 9;

        self.buf[self.start + 3] = @intFromEnum(frame_type);
        self.buf[self.start + 4] = frame_flags;
        mem.writeInt(u32, self.buf[self.start + 5 ..][0..4], stream_id, .big);
    }

    pub fn bytes(self: *Writer, data: []const u8) WriterError!void {
        if (self.buf.len - self.pos < data.len) return error.NoSpace;
        @memcpy(self.buf[self.pos..][0..data.len], data);
        self.pos += data.len;
    }

    pub fn byte(self: *Writer, value: u8) WriterError!void {
        if (self.buf.len - self.pos < 1) return error.NoSpace;
        self.buf[self.pos] = value;
        self.pos += 1;
    }

    pub fn int(self: *Writer, comptime T: type, value: T) WriterError!void {
        const n = @sizeOf(T);
        if (self.buf.len - self.pos < n) return error.NoSpace;
        mem.writeInt(T, self.buf[self.pos..][0..n], value, .big);
        self.pos += n;
    }

    pub fn end(self: *Writer) void {
        const length = self.pos - self.start - 9;
        assert(length <= max_frame_size_limit);
        mem.writeInt(u24, self.buf[self.start..][0..3], @intCast(length), .big);
    }

    pub fn written(self: *const Writer) []const u8 {
        return self.buf[0..self.pos];
    }
};

test "frame header round-trips and ignores the reserved bit" {
    const bytes = [_]u8{ 0, 0, 5, 0, flags.end_stream, 0x80, 0, 0, 1 };
    const header = try parseHeader(&bytes);

    try testing.expectEqual(@as(u24, 5), header.length);
    try testing.expectEqual(FrameType.data, header.type);
    try testing.expectEqual(flags.end_stream, header.flags);
    try testing.expectEqual(@as(u31, 1), header.stream_id);

    var out: [9]u8 = undefined;
    encodeHeader(&out, header);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 5, 0, 1, 0, 0, 0, 1 }, &out);
}

test "parse: incomplete until the whole payload arrives" {
    const head = [_]u8{ 0, 0, 3, 0, 0, 0, 0, 0, 1 };
    try testing.expectError(error.Incomplete, parse(&head, default_max_frame_size));

    const full = head ++ [_]u8{ 'a', 'b', 'c' };
    const parsed = try parse(&full, default_max_frame_size);
    try testing.expectEqual(@as(u32, 12), parsed.consumed);
    try testing.expectEqualStrings("abc", parsed.payload);
}

test "parse: a payload above max_frame_size is rejected before waiting" {
    const head = [_]u8{ 0, 0x40, 0x01, 0, 0, 0, 0, 0, 1 };
    try testing.expectError(error.FrameTooLarge, parse(&head, default_max_frame_size));
}

test "DATA: padding is stripped, and an oversized pad is invalid" {
    const header: Header = .{
        .length = 5,
        .type = .data,
        .flags = flags.padded,
        .stream_id = 1,
    };
    const data = try body(header, &.{ 2, 'a', 'b', 0, 0 });
    try testing.expectEqualStrings("ab", data.data.data);

    // Padding may fill everything after the pad length.
    try testing.expectEqualStrings("", (try body(header, &.{ 4, 0, 0, 0, 0 })).data.data);
    try testing.expectError(error.InvalidPadding, body(header, &.{ 5, 0, 0, 0, 0 }));
    try testing.expectError(error.InvalidPadding, body(header, &.{}));
}

test "HEADERS: optional priority then the block fragment" {
    const header: Header = .{
        .length = 8,
        .type = .headers,
        .flags = flags.priority,
        .stream_id = 3,
    };
    // exclusive, dependency 1, weight 15, then "abc".
    const parsed = try body(header, &.{ 0x80, 0, 0, 1, 15, 'a', 'b', 'c' });
    const priority = parsed.headers.priority.?;

    try testing.expect(priority.exclusive);
    try testing.expectEqual(@as(u31, 1), priority.dependency);
    try testing.expectEqual(@as(u8, 15), priority.weight);
    try testing.expectEqualStrings("abc", parsed.headers.block);

    try testing.expectError(error.InvalidLength, body(header, &.{ 0, 0, 0, 0 }));
}

test "PRIORITY, RST_STREAM, and WINDOW_UPDATE fixed lengths" {
    const priority: Header = .{ .length = 5, .flags = 0, .type = .priority, .stream_id = 1 };
    const p = try body(priority, &.{ 0, 0, 0, 3, 1 });
    try testing.expect(!p.priority.exclusive);
    try testing.expectEqual(@as(u31, 3), p.priority.dependency);

    const rst: Header = .{ .length = 4, .flags = 0, .type = .rst_stream, .stream_id = 1 };
    const r = try body(rst, &.{ 0, 0, 0, 8 });
    try testing.expectEqual(ErrorCode.cancel, r.rst_stream.error_code);

    const window: Header = .{ .length = 4, .flags = 0, .type = .window_update, .stream_id = 0 };
    const w = try body(window, &.{ 0x80, 0, 0, 5 });
    try testing.expectEqual(@as(u31, 5), w.window_update.increment);

    try testing.expectError(error.InvalidLength, body(priority, &.{ 0, 0, 0 }));
    try testing.expectError(error.InvalidLength, body(rst, &.{ 0, 0 }));
    try testing.expectError(error.InvalidLength, body(window, &.{ 0, 0 }));
}

test "SETTINGS: pairs, ACK, and a length that is not a multiple of six" {
    const header: Header = .{ .length = 6, .flags = 0, .type = .settings, .stream_id = 0 };
    const settings = (try body(header, &.{ 0, 5, 0, 0, 0x40, 0 })).settings;
    try testing.expect(!settings.ack);

    var it = settings.iterator();
    const first = it.next().?;
    try testing.expectEqual(SettingId.max_frame_size, first.id);
    try testing.expectEqual(@as(u32, 0x4000), first.value);
    try testing.expect(it.next() == null);

    const ack: Header = .{ .length = 0, .type = .settings, .flags = flags.ack, .stream_id = 0 };
    try testing.expect((try body(ack, &.{})).settings.ack);
    try testing.expectError(
        error.InvalidLength,
        body(ack, &.{ 0, 5, 0, 0, 0x40, 0 }),
    );
    try testing.expectError(
        error.InvalidLength,
        body(
            .{ .length = 5, .flags = 0, .type = .settings, .stream_id = 0 },
            &.{ 0, 5, 0, 0, 0x40 },
        ),
    );
}

test "PING, GOAWAY, and PUSH_PROMISE" {
    const ping: Header = .{ .length = 8, .flags = 0, .type = .ping, .stream_id = 0 };
    const p = try body(ping, "12345678");
    try testing.expect(!p.ping.ack);
    try testing.expectEqualStrings("12345678", p.ping.payload);
    try testing.expectError(error.InvalidLength, body(ping, "1234567"));

    const goaway: Header = .{ .length = 13, .flags = 0, .type = .goaway, .stream_id = 0 };
    const g = (try body(goaway, &.{ 0, 0, 0, 7, 0, 0, 0, 1, 'b', 'y', 'e' })).goaway;
    try testing.expectEqual(@as(u31, 7), g.last_stream_id);
    try testing.expectEqual(ErrorCode.protocol_error, g.error_code);
    try testing.expectEqualStrings("bye", g.debug);

    const push: Header = .{ .length = 6, .flags = 0, .type = .push_promise, .stream_id = 1 };
    const pp = (try body(push, &.{ 0, 0, 0, 2, 'a', 'b' })).push_promise;
    try testing.expectEqual(@as(u31, 2), pp.promised_stream_id);
    try testing.expectEqualStrings("ab", pp.block);
}

test "unknown frame types keep their payload" {
    const header: Header = .{ .length = 3, .flags = 0, .type = @enumFromInt(0x42), .stream_id = 0 };
    const parsed = try body(header, "xyz");
    try testing.expectEqual(@as(u8, 0x42), @intFromEnum(parsed.unknown.type));
    try testing.expectEqualStrings("xyz", parsed.unknown.payload);
}

test "Writer: build frames and parse them back" {
    var buf: [128]u8 = undefined;
    var writer = Writer.init(&buf);

    try writer.begin(.data, flags.end_stream, 1);
    try writer.bytes("hello");
    writer.end();

    try writer.begin(.settings, 0, 0);
    try writer.int(u16, @intFromEnum(SettingId.header_table_size));
    try writer.int(u32, 4096);
    writer.end();

    try writer.begin(.headers, flags.priority | flags.end_headers, 3);
    try writer.int(u32, 0x8000_0001);
    try writer.byte(15);
    try writer.bytes("block");
    writer.end();

    var rest = writer.written();
    const data = try parse(rest, default_max_frame_size);
    try testing.expectEqual(FrameType.data, data.header.type);
    try testing.expectEqualStrings("hello", data.payload);
    rest = rest[data.consumed..];

    const settings = try parse(rest, default_max_frame_size);
    const entries = (try body(settings.header, settings.payload)).settings;
    var it = entries.iterator();
    const setting = it.next().?;
    try testing.expectEqual(SettingId.header_table_size, setting.id);
    try testing.expectEqual(@as(u32, 4096), setting.value);
    try testing.expect(it.next() == null);
    rest = rest[settings.consumed..];

    const headers = try parse(rest, default_max_frame_size);
    const h = try body(headers.header, headers.payload);
    try testing.expect(h.headers.priority.?.exclusive);
    try testing.expectEqualStrings("block", h.headers.block);
}

test "Writer: a short buffer is NoSpace, not a partial frame" {
    var buf: [12]u8 = undefined;
    var writer = Writer.init(&buf);

    try writer.begin(.data, 0, 1);
    try testing.expectError(error.NoSpace, writer.bytes("abcd"));
    try testing.expectEqual(@as(usize, 9), writer.pos);
}

test "fuzz frames: parse and body never overrun" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) anyerror!void {
            var buf: [256]u8 = undefined;
            const input = buf[0..smith.slice(&buf)];
            const parsed = parse(input, default_max_frame_size) catch return;

            try testing.expect(parsed.consumed <= input.len);
            try testing.expectEqual(parsed.header.length, parsed.payload.len);
            _ = body(parsed.header, parsed.payload) catch return;
        }
    }.run, .{
        .corpus = &.{
            "",
            "\x00\x00\x00\x00\x00\x00\x00\x00\x00",
            "\x00\x00\x05\x00\x01\x00\x00\x00\x01hello",
        },
    });
}
