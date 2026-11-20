//! An HTTP/3 connection over a numbered-stream transport (RFC 9114).
//!
//! Sans-I/O. The caller opens the QUIC streams and feeds their bytes; the
//! session owns the HTTP state: the control stream, the QPACK decoder table,
//! field-section decoding, request and response sequencing, and the outbound
//! queue. It never opens a socket or a stream, and it never touches QUIC.
//!
//! The local unidirectional streams are opened by the caller and named in
//! `Options`; the session writes their type byte and SETTINGS. The peer's
//! unidirectional streams are classified by the type varint the peer sends.
//!
//! Inbound events borrow either the bytes passed to `receive` (DATA) or the
//! session's decode buffer (heads and trailers). The caller consumes an event
//! before the next `receive` or `nextEvent`. Outbound writes are tagged with
//! the stream id and drained with `nextAction` and `release`.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Cursor = @import("../Cursor.zig");
const Header = @import("../header.zig").Header;
const Headers = @import("../header.zig").Headers;
const varint = @import("../varint.zig");
const qpack = @import("../qpack/root.zig");
const frame = @import("frame.zig");
const head = @import("head.zig");
const settings = @import("settings.zig");
const control = @import("control.zig");
const error_code = @import("error_code.zig");
const encoder_stream = @import("../qpack/encoder_stream.zig");
const decoder_stream = @import("../qpack/decoder_stream.zig");

pub const Role = control.Role;
pub const Origin = enum { local, remote };

// ast-grep-ignore: public-struct-field-default -- an options bag with protocol defaults.
pub const Options = struct {
    role: Role,
    /// The caller opened this unidirectional stream and gives it to the session.
    control_stream: u62,
    /// The static-only encoder needs no encoder stream.
    encoder_stream: ?u62 = null,
    /// Required when `qpack_max_table_capacity` is not zero.
    decoder_stream: ?u62 = null,
    qpack_max_table_capacity: u32 = 4096,
    qpack_blocked_streams: u32 = 16,
    max_field_section_size: ?u32 = 16 * 1024,
    max_streams: u16 = 128,
    max_fields: u16 = 128,
    max_in_header_block: u32 = 32 * 1024,
    max_control_frame: u32 = 16 * 1024,
    max_blocked_bytes: u32 = 64 * 1024,
};

pub const Error = error{
    InvalidOptions,
    MissingDecoderStream,
    ConnectionClosed,
    WrongRole,
    UnknownStream,
    WrongStream,
    StreamClosed,
    HeadAlreadySent,
    InvalidHead,
    BlockedStreamLimit,
    HeaderBlockTooLarge,
    TooManyStreams,
    MessageTooLarge,
} || Allocator.Error;

pub const RequestEvent = struct {
    stream_id: u62,
    head: head.RequestHead,
    end_stream: bool,
};

pub const ResponseEvent = struct {
    stream_id: u62,
    head: head.ResponseHead,
    end_stream: bool,
};

pub const DataEvent = struct {
    stream_id: u62,
    /// Borrowed from the bytes passed to `receive`.
    bytes: []const u8,
    end_stream: bool,
};

pub const TrailersEvent = struct {
    stream_id: u62,
    headers: Headers,
    end_stream: bool,
};

pub const ResetEvent = struct {
    stream_id: u62,
    code: u64,
    origin: Origin,
};

pub const GoAwayEvent = struct {
    id: u62,
};

pub const ConnectionErrorEvent = struct {
    code: error_code.Code,
};

pub const StreamErrorEvent = struct {
    stream_id: u62,
    code: error_code.Code,
};

pub const Event = union(enum) {
    request: RequestEvent,
    response: ResponseEvent,
    data: DataEvent,
    trailers: TrailersEvent,
    reset: ResetEvent,
    goaway: GoAwayEvent,
    settings: settings.Values,
    connection_error: ConnectionErrorEvent,
    stream_error: StreamErrorEvent,
    discard_stream: u62,
};

pub const Write = struct {
    stream_id: u62,
    /// Borrowed until `release`.
    bytes: []const u8,
    fin: bool,
};

pub const Action = union(enum) {
    write: Write,
    reset: struct { stream_id: u62, code: u64 },
    stop_sending: struct { stream_id: u62, code: u64 },
    close: u64,
};

const Queued = union(enum) {
    write: struct {
        stream_id: u62,
        start: usize,
        len: usize,
        fin: bool,
    },
    reset: struct { stream_id: u62, code: u64 },
    stop_sending: struct { stream_id: u62, code: u64 },
    close: u64,
};

const Kind = enum {
    request,
    control,
    encoder,
    decoder,
    push,
    unknown,
};

const Stream = struct {
    id: u62,
    kind: Kind,
    local: bool,
    /// The peer's unidirectional stream type has been parsed.
    typed: bool,
    reader: frame.Reader,
    assembly: []u8,
    assembly_len: usize,
    head_seen: bool,
    trailers_seen: bool,
    local_head: bool,
    remote_closed: bool,
    local_closed: bool,
    /// A field section held until its Required Insert Count arrives.
    held: ?[]u8,
    held_ric: u64,
    held_trailers: bool,
    dynamic: bool,
};

const State = enum { open, closed };

pub const Session = struct {
    options: Options,
    state: State,
    streams: std.AutoHashMapUnmanaged(u62, Stream),
    local_settings: settings.Values,
    peer_settings: settings.Values,
    qpack_storage: qpack.TableStorage,
    decoder: qpack.Decoder,
    encoder: qpack.Encoder,
    control_state: control.Control,
    peer_control: ?u62,
    peer_encoder: ?u62,
    peer_decoder: ?u62,
    goaway_received: ?u62,
    goaway_sent: bool,

    field_headers: []Header,
    field_bytes: []u8,
    send_block: []u8,
    send_frame: []u8,
    qpack_scratch: []u8,

    event: ?Event,
    out_bytes: std.ArrayList(u8),
    out_queued: std.ArrayList(Queued),
    out_pos: usize,
    blocked_streams: u32,

    pub fn init(allocator: Allocator, options: Options) Error!Session {
        try validate(options);

        const field_bytes = try allocator.alloc(
            u8,
            options.max_field_section_size orelse options.max_in_header_block,
        );
        errdefer allocator.free(field_bytes);
        const field_headers = try allocator.alloc(Header, options.max_fields);
        errdefer allocator.free(field_headers);
        const send_block = try allocator.alloc(u8, options.max_in_header_block);
        errdefer allocator.free(send_block);
        const send_frame = try allocator.alloc(u8, options.max_in_header_block + 16);
        errdefer allocator.free(send_frame);
        const qpack_scratch = try allocator.alloc(u8, options.max_in_header_block);
        errdefer allocator.free(qpack_scratch);

        const storage = qpack.TableStorage.init(
            allocator,
            options.qpack_max_table_capacity,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidOptions,
        };

        var self: Session = .{
            .options = options,
            .state = .open,
            .streams = .empty,
            .local_settings = .{
                .qpack_max_table_capacity = options.qpack_max_table_capacity,
                .max_field_section_size = if (options.max_field_section_size) |max|
                    @as(u62, max)
                else
                    null,
                .qpack_blocked_streams = options.qpack_blocked_streams,
            },
            .peer_settings = settings.Values.zero(),
            .qpack_storage = storage,
            .decoder = qpack.Decoder.init(storage),
            .encoder = qpack.Encoder.init(),
            .control_state = control.Control.init(options.role),
            .peer_control = null,
            .peer_encoder = null,
            .peer_decoder = null,
            .goaway_received = null,
            .goaway_sent = false,
            .field_headers = field_headers,
            .field_bytes = field_bytes,
            .send_block = send_block,
            .send_frame = send_frame,
            .qpack_scratch = qpack_scratch,
            .event = null,
            .out_bytes = .empty,
            .out_queued = .empty,
            .out_pos = 0,
            .blocked_streams = 0,
        };
        // The array errdefers above own their allocations until `self`
        // returns. This block owns the map, the queue, and the QPACK blob
        // only if a later step fails.
        errdefer {
            var streams = self.streams.valueIterator();
            while (streams.next()) |stream| {
                if (stream.assembly.len != 0) allocator.free(stream.assembly);
                if (stream.held) |held| allocator.free(held);
            }
            self.streams.deinit(allocator);
            self.qpack_storage.deinit(allocator);
            self.out_bytes.deinit(allocator);
            self.out_queued.deinit(allocator);
        }

        try self.addLocal(allocator, options.control_stream, .control);
        try self.queueType(allocator, options.control_stream, 0x00);
        try self.queueSettings(allocator);
        if (options.encoder_stream) |id| {
            try self.addLocal(allocator, id, .encoder);
            try self.queueType(allocator, id, 0x02);
        }
        if (options.decoder_stream) |id| {
            try self.addLocal(allocator, id, .decoder);
            try self.queueType(allocator, id, 0x03);
        }
        return self;
    }

    pub fn deinit(self: *Session, allocator: Allocator) void {
        var it = self.streams.valueIterator();
        while (it.next()) |stream| {
            if (stream.assembly.len != 0) allocator.free(stream.assembly);
            if (stream.held) |held| allocator.free(held);
        }
        self.streams.deinit(allocator);
        self.qpack_storage.deinit(allocator);
        self.out_bytes.deinit(allocator);
        self.out_queued.deinit(allocator);
        allocator.free(self.field_headers);
        allocator.free(self.field_bytes);
        allocator.free(self.send_block);
        allocator.free(self.send_frame);
        allocator.free(self.qpack_scratch);
        self.* = undefined;
    }

    pub fn isClosed(self: *const Session) bool {
        return self.state == .closed;
    }

    pub fn hasPendingOutput(self: *const Session) bool {
        return self.out_pos < self.out_queued.items.len;
    }

    /// The next outbound action. The bytes of a write are valid until
    /// `release`. The caller must process actions in order.
    pub fn nextAction(self: *Session) ?Action {
        if (self.out_pos == self.out_queued.items.len) return null;
        return switch (self.out_queued.items[self.out_pos]) {
            .write => |w| .{ .write = .{
                .stream_id = w.stream_id,
                .bytes = self.out_bytes.items[w.start..][0..w.len],
                .fin = w.fin,
            } },
            .reset => |r| .{ .reset = .{ .stream_id = r.stream_id, .code = r.code } },
            .stop_sending => |s| .{ .stop_sending = .{
                .stream_id = s.stream_id,
                .code = s.code,
            } },
            .close => |code| .{ .close = code },
        };
    }

    pub fn release(self: *Session, allocator: Allocator) void {
        _ = allocator;
        if (self.out_pos == self.out_queued.items.len) return;
        self.out_pos += 1;
        if (self.out_pos == self.out_queued.items.len) {
            self.out_queued.clearRetainingCapacity();
            self.out_bytes.clearRetainingCapacity();
            self.out_pos = 0;
        }
    }

    /// Feed bytes from one QUIC stream. Returns the prefix consumed. Zero
    /// means the session needs the caller to consume the pending event first,
    /// or that a stream type varint is still partial.
    pub fn receive(
        self: *Session,
        allocator: Allocator,
        stream_id: u62,
        bytes: []const u8,
        fin: bool,
    ) usize {
        if (self.state == .closed or self.event != null) return 0;
        return self.process(allocator, stream_id, bytes, fin) catch |err| {
            switch (err) {
                error.ConnectionClosed => return 0,
                error.OutOfMemory => @panic("h3 session allocation failed"),
                else => {
                    _ = self.connectionError(allocator, .internal_error);
                    return 0;
                },
            }
        };
    }

    pub fn nextEvent(self: *Session, allocator: Allocator) Error!?Event {
        if (self.event) |event| {
            self.event = null;
            return event;
        }
        if (self.state == .closed) return null;

        // A held field section may have become decodable.
        var it = self.streams.valueIterator();
        while (it.next()) |stream| {
            const held = stream.held orelse continue;
            if (self.decoder.table.insert_count < stream.held_ric) continue;

            const held_trailers = stream.held_trailers;
            const block = held;
            stream.held = null;
            self.blocked_streams -= 1;
            defer allocator.free(block);

            if (try self.decodeSection(allocator, stream, block, held_trailers)) |event| {
                self.event = event;
                return event;
            }
        }
        return null;
    }

    fn process(
        self: *Session,
        allocator: Allocator,
        stream_id: u62,
        bytes: []const u8,
        fin: bool,
    ) Error!usize {
        const entry = try self.streams.getOrPut(allocator, stream_id);
        if (!entry.found_existing) {
            entry.value_ptr.* = .{
                .id = stream_id,
                .kind = if (stream_id & 0x2 == 0) .request else .unknown,
                .local = false,
                .typed = stream_id & 0x2 == 0,
                .reader = frame.Reader.init(),
                .assembly = &.{},
                .assembly_len = 0,
                .head_seen = false,
                .trailers_seen = false,
                .local_head = false,
                .remote_closed = false,
                .local_closed = false,
                .held = null,
                .held_ric = 0,
                .held_trailers = false,
                .dynamic = false,
            };
        }
        const stream = entry.value_ptr;

        if (stream.local and stream.kind != .request) return error.WrongStream;
        if (stream.remote_closed and bytes.len != 0) return error.StreamClosed;

        // A server-initiated bidirectional stream is not an HTTP/3 stream.
        if (stream_id & 0x2 == 0 and stream_id & 0x1 == 1) {
            return self.fail(allocator, .stream_creation_error);
        }

        var cursor = Cursor.init(bytes);

        if (stream_id & 0x2 != 0 and !stream.typed) {
            const value = varint.decode(&cursor) catch return 0;
            stream.typed = true;
            try self.classify(allocator, stream, value);
            if (stream.kind == .unknown) {
                self.event = .{ .discard_stream = stream_id };
                return cursor.pos;
            }
        }

        switch (stream.kind) {
            .request => try self.processFrames(allocator, stream, &cursor, fin),
            .control => try self.processFrames(allocator, stream, &cursor, fin),
            .encoder => try self.processEncoder(allocator, stream, &cursor),
            .decoder => {
                // The encoder is static-only: decoder instructions have no
                // state to change. Consume them.
                try self.processDecoder(&cursor);
            },
            .push, .unknown => return cursor.pos,
        }

        if (fin) try self.onFin(allocator, stream, &cursor);
        return cursor.pos;
    }

    fn classify(self: *Session, allocator: Allocator, stream: *Stream, value: u62) Error!void {
        const known = control.streamType(value) orelse {
            stream.kind = .unknown;
            return;
        };
        switch (known) {
            .control => {
                if (self.peer_control != null) return self.fail(allocator, .stream_creation_error);
                self.peer_control = stream.id;
                stream.kind = .control;
            },
            .encoder => {
                if (self.peer_encoder != null) return self.fail(allocator, .stream_creation_error);
                self.peer_encoder = stream.id;
                stream.kind = .encoder;
            },
            .decoder => {
                if (self.peer_decoder != null) return self.fail(allocator, .stream_creation_error);
                self.peer_decoder = stream.id;
                stream.kind = .decoder;
            },
            .push => {
                if (self.options.role == .client) return self.fail(allocator, .id_error);
                return self.fail(allocator, .stream_creation_error);
            },
        }
    }

    fn processFrames(
        self: *Session,
        allocator: Allocator,
        stream: *Stream,
        cursor: *Cursor,
        fin: bool,
    ) Error!void {
        while (true) {
            const chunk = stream.reader.next(cursor) catch |err| switch (err) {
                error.Incomplete => return,
                error.Reserved => return self.fail(allocator, .frame_unexpected),
                else => return self.fail(allocator, .frame_error),
            };
            try self.onChunk(allocator, stream, chunk, cursor, fin);
            if (self.event != null or stream.held != null) return;
        }
    }

    fn onChunk(
        self: *Session,
        allocator: Allocator,
        stream: *Stream,
        chunk: frame.Chunk,
        cursor: *Cursor,
        fin: bool,
    ) Error!void {
        switch (chunk.header.frame_type) {
            .data => {
                if (stream.kind != .request) return self.fail(allocator, .frame_unexpected);
                if (!stream.head_seen or stream.trailers_seen) {
                    return self.fail(allocator, .frame_unexpected);
                }
                const end_stream = chunk.end and cursor.atEnd() and fin;
                self.event = .{ .data = .{
                    .stream_id = stream.id,
                    .bytes = chunk.payload,
                    .end_stream = end_stream,
                } };
                if (end_stream) stream.remote_closed = true;
            },

            .headers => {
                if (stream.kind != .request) return self.fail(allocator, .frame_unexpected);
                try self.appendAssembly(allocator, stream, chunk.payload);
                if (!chunk.end) return;

                const block = stream.assembly[0..stream.assembly_len];
                const trailers = stream.head_seen;
                stream.assembly_len = 0;
                const at_end = cursor.atEnd() and fin;
                try self.handleHeaders(allocator, stream, block, trailers, at_end);
            },

            .settings, .goaway, .cancel_push, .max_push_id, .push_promise => {
                if (stream.kind != .control) {
                    if (chunk.header.frame_type == .push_promise and
                        self.options.role == .client)
                    {
                        return self.fail(allocator, .id_error);
                    }
                    return self.fail(allocator, .frame_unexpected);
                }
                try self.appendAssembly(allocator, stream, chunk.payload);
                if (!chunk.end) return;

                const payload = stream.assembly[0..stream.assembly_len];
                stream.assembly_len = 0;
                const value = frame.body(chunk.header, payload) catch {
                    return self.fail(allocator, .frame_error);
                };
                try self.onControl(allocator, value);
            },

            else => {
                // An unknown extension frame. The control stream ignores it
                // after SETTINGS; a request stream ignores it outright.
                if (stream.kind != .control) return;
                try self.appendAssembly(allocator, stream, chunk.payload);
                if (!chunk.end) return;

                const payload = stream.assembly[0..stream.assembly_len];
                stream.assembly_len = 0;
                const value = frame.body(chunk.header, payload) catch {
                    return self.fail(allocator, .frame_error);
                };
                try self.onControl(allocator, value);
            },
        }
    }

    fn onControl(self: *Session, allocator: Allocator, value: frame.Body) Error!void {
        const event = self.control_state.receive(value) catch |err| switch (err) {
            error.MissingSettings => return self.fail(allocator, .missing_settings),
            error.UnexpectedFrame => return self.fail(allocator, .frame_unexpected),
            error.IdError => return self.fail(allocator, .id_error),
            error.SettingsError => return self.fail(allocator, .settings_error),
        };
        if (event) |e| switch (e) {
            .settings => |values| {
                self.peer_settings = values;
                self.event = .{ .settings = values };
            },
            .goaway => |id| {
                self.goaway_received = id;
                self.event = .{ .goaway = .{ .id = id } };
            },
            .max_push_id => {},
        };
    }

    fn handleHeaders(
        self: *Session,
        allocator: Allocator,
        stream: *Stream,
        block: []const u8,
        trailers: bool,
        at_end: bool,
    ) Error!void {
        const maybe_event = try self.decodeSection(allocator, stream, block, trailers);
        var event = maybe_event orelse return;
        if (at_end) {
            stream.remote_closed = true;
            self.setEndStream(&event);
        }
        self.event = event;
    }

    fn decodeSection(
        self: *Session,
        allocator: Allocator,
        stream: *Stream,
        block: []const u8,
        trailers: bool,
    ) Error!?Event {
        const result = self.decoder.decode(block, self.field_headers, self.field_bytes) catch {
            return self.fail(allocator, .qpack_decompression_failed);
        };

        switch (result) {
            .blocked => |blocked| {
                if (stream.held != null) return error.InvalidHead;
                if (self.blocked_streams >= self.options.qpack_blocked_streams) {
                    return self.fail(allocator, .qpack_decompression_failed);
                }
                if (block.len > self.options.max_blocked_bytes) {
                    return self.fail(allocator, .qpack_decompression_failed);
                }
                const copy = try allocator.dupe(u8, block);
                stream.held = copy;
                stream.held_ric = blocked.required_insert_count;
                stream.held_trailers = trailers;
                self.blocked_streams += 1;
                return null;
            },
            .fields => |fields| {
                if (fields.required_insert_count != 0) {
                    stream.dynamic = true;
                    try self.queueAck(allocator, stream.id);
                }

                if (trailers) {
                    const validated = head.trailers(fields.headers) catch {
                        _ = self.streamError(allocator, stream.id, .message_error);
                        return null;
                    };
                    stream.trailers_seen = true;
                    return .{ .trailers = .{
                        .stream_id = stream.id,
                        .headers = validated,
                        .end_stream = false,
                    } };
                }

                if (stream.head_seen) {
                    _ = self.streamError(allocator, stream.id, .message_error);
                    return null;
                }

                stream.head_seen = true;
                if (self.options.role == .server) {
                    const request = head.request(fields.headers) catch {
                        _ = self.streamError(allocator, stream.id, .message_error);
                        return null;
                    };
                    return .{ .request = .{
                        .stream_id = stream.id,
                        .head = request,
                        .end_stream = false,
                    } };
                }
                const response = head.response(fields.headers) catch {
                    _ = self.streamError(allocator, stream.id, .message_error);
                    return null;
                };
                return .{ .response = .{
                    .stream_id = stream.id,
                    .head = response,
                    .end_stream = false,
                } };
            },
        }
    }

    fn setEndStream(self: *Session, event: *Event) void {
        _ = self;
        switch (event.*) {
            .request => |*e| e.end_stream = true,
            .response => |*e| e.end_stream = true,
            .data => |*e| e.end_stream = true,
            .trailers => |*e| e.end_stream = true,
            else => {},
        }
    }

    fn onFin(self: *Session, allocator: Allocator, stream: *Stream, cursor: *Cursor) Error!void {
        if (!cursor.atEnd()) return;
        if (stream.remote_closed) return;
        if (stream.held != null) return;
        if (stream.kind == .control) return self.fail(allocator, .closed_critical_stream);
        if (stream.kind == .encoder) return self.fail(allocator, .closed_critical_stream);
        if (stream.kind == .decoder) return self.fail(allocator, .closed_critical_stream);
        stream.remote_closed = true;
        if (stream.kind == .request and self.event == null) {
            self.event = .{ .data = .{
                .stream_id = stream.id,
                .bytes = "",
                .end_stream = true,
            } };
        }
    }

    fn appendAssembly(
        self: *Session,
        allocator: Allocator,
        stream: *Stream,
        bytes: []const u8,
    ) Error!void {
        const total = stream.assembly_len + bytes.len;
        const limit = if (stream.kind == .control)
            self.options.max_control_frame
        else
            self.options.max_in_header_block;
        if (total > limit) return self.fail(allocator, .excessive_load);

        if (stream.assembly.len < total) {
            if (stream.assembly.len != 0) allocator.free(stream.assembly);
            stream.assembly = try allocator.alloc(u8, total);
        }
        @memcpy(stream.assembly[stream.assembly_len..][0..bytes.len], bytes);
        stream.assembly_len = total;
    }

    fn processEncoder(
        self: *Session,
        allocator: Allocator,
        stream: *Stream,
        cursor: *Cursor,
    ) Error!void {
        // Buffer the bytes so an instruction split across reads parses once.
        if (cursor.remaining() != 0) {
            try self.appendAssembly(allocator, stream, cursor.rest());
            _ = cursor.skip(cursor.remaining());
        }

        var at = Cursor.init(stream.assembly[0..stream.assembly_len]);
        while (!at.atEnd()) {
            const before = at;
            const instruction = encoder_stream.parse(
                &at,
                self.field_bytes,
            ) catch |err| switch (err) {
                error.Truncated => {
                    at = before;
                    break;
                },
                else => return self.fail(allocator, .qpack_encoder_stream_error),
            };
            encoder_stream.apply(
                instruction,
                &self.decoder.table,
                self.qpack_scratch,
            ) catch {
                return self.fail(allocator, .qpack_encoder_stream_error);
            };
        }
        const rest = at.rest();
        if (rest.len != 0) {
            @memmove(stream.assembly[0..rest.len], rest);
        }
        stream.assembly_len = rest.len;
    }

    fn processDecoder(self: *Session, cursor: *Cursor) Error!void {
        _ = self;
        _ = cursor;
    }

    /// Tell the session the peer reset a stream (QUIC RESET_STREAM).
    pub fn reset(self: *Session, allocator: Allocator, stream_id: u62, code: u64) void {
        const stream = self.streams.getPtr(stream_id) orelse return;
        if (stream.held) |held| {
            allocator.free(held);
            stream.held = null;
            self.blocked_streams -= 1;
        }
        if (stream.dynamic) {
            if (self.options.decoder_stream) |id| {
                var buf: [8]u8 = undefined;
                const instruction = decoder_stream.write(
                    &buf,
                    .{ .stream_cancel = stream_id },
                ) catch null;
                if (instruction) |bytes| {
                    self.queueWrite(allocator, id, bytes, false) catch
                        @panic("h3 session allocation failed");
                }
            }
        }
        stream.remote_closed = true;
        self.event = .{ .reset = .{
            .stream_id = stream_id,
            .code = code,
            .origin = .remote,
        } };
    }

    pub fn submitRequest(
        self: *Session,
        allocator: Allocator,
        stream_id: u62,
        fields: []const Header,
        end_stream: bool,
    ) Error!void {
        if (self.options.role != .client) return error.WrongRole;
        if (self.state == .closed) return error.ConnectionClosed;
        if (stream_id & 0x3 != 0) return error.WrongStream;
        if (self.goaway_received) |id| if (stream_id >= id) return error.ConnectionClosed;

        _ = head.request(.{ .items = fields }) catch return error.InvalidHead;
        try self.queueHeaders(allocator, stream_id, fields, end_stream, false);
    }

    pub fn submitResponse(
        self: *Session,
        allocator: Allocator,
        stream_id: u62,
        fields: []const Header,
        end_stream: bool,
    ) Error!void {
        if (self.options.role != .server) return error.WrongRole;
        if (self.state == .closed) return error.ConnectionClosed;

        const stream = self.streams.getPtr(stream_id) orelse return error.UnknownStream;
        if (!stream.head_seen) return error.InvalidHead;
        if (stream.local_head) return error.HeadAlreadySent;

        _ = head.response(.{ .items = fields }) catch return error.InvalidHead;
        try self.queueHeaders(allocator, stream_id, fields, end_stream, false);
    }

    pub fn submitTrailers(
        self: *Session,
        allocator: Allocator,
        stream_id: u62,
        fields: []const Header,
    ) Error!void {
        if (self.state == .closed) return error.ConnectionClosed;
        const stream = self.streams.getPtr(stream_id) orelse return error.UnknownStream;
        if (!stream.local_head or stream.local_closed) return error.InvalidHead;

        _ = head.trailers(.{ .items = fields }) catch return error.InvalidHead;
        try self.queueHeaders(allocator, stream_id, fields, true, true);
    }

    pub fn submitData(
        self: *Session,
        allocator: Allocator,
        stream_id: u62,
        bytes: []const u8,
        end_stream: bool,
    ) Error!void {
        if (self.state == .closed) return error.ConnectionClosed;
        const stream = self.streams.getPtr(stream_id) orelse return error.UnknownStream;
        if (!stream.local_head or stream.local_closed) return error.InvalidHead;

        const framed = frame.write(self.send_frame, .data, bytes) catch
            return error.MessageTooLarge;
        try self.queueWrite(allocator, stream_id, framed, end_stream);
        if (end_stream) stream.local_closed = true;
    }

    pub fn submitReset(
        self: *Session,
        allocator: Allocator,
        stream_id: u62,
        code: u64,
    ) Error!void {
        if (self.state == .closed) return error.ConnectionClosed;
        const stream = self.streams.getPtr(stream_id) orelse return error.UnknownStream;
        try self.queueAction(allocator, .{
            .reset = .{ .stream_id = stream_id, .code = code },
        });
        try self.queueAction(allocator, .{
            .stop_sending = .{ .stream_id = stream_id, .code = code },
        });
        stream.local_closed = true;
        stream.remote_closed = true;
    }

    pub fn submitGoaway(self: *Session, allocator: Allocator, id: u62) Error!void {
        if (self.state == .closed) return error.ConnectionClosed;
        var payload: [8]u8 = undefined;
        const encoded = try varint.encode(&payload, id);
        const framed = frame.write(self.send_frame, .goaway, encoded) catch
            return error.MessageTooLarge;
        try self.queueWrite(allocator, self.options.control_stream, framed, false);
        self.goaway_sent = true;
    }

    fn queueHeaders(
        self: *Session,
        allocator: Allocator,
        stream_id: u62,
        fields: []const Header,
        end_stream: bool,
        trailers: bool,
    ) Error!void {
        const block = self.encoder.encode(self.send_block, .{ .items = fields }) catch
            return error.HeaderBlockTooLarge;
        const framed = frame.write(self.send_frame, .headers, block) catch
            return error.HeaderBlockTooLarge;
        try self.queueWrite(allocator, stream_id, framed, end_stream);

        const entry = try self.streams.getOrPut(allocator, stream_id);
        if (!entry.found_existing) {
            entry.value_ptr.* = .{
                .id = stream_id,
                .kind = .request,
                .local = false,
                .typed = true,
                .reader = frame.Reader.init(),
                .assembly = &.{},
                .assembly_len = 0,
                .head_seen = false,
                .trailers_seen = false,
                .local_head = false,
                .remote_closed = false,
                .local_closed = false,
                .held = null,
                .held_ric = 0,
                .held_trailers = false,
                .dynamic = false,
            };
        }
        const stream = entry.value_ptr;
        if (stream.local_head and !trailers) return error.HeadAlreadySent;
        stream.local_head = true;
        if (end_stream) stream.local_closed = true;
    }

    fn queueType(self: *Session, allocator: Allocator, stream_id: u62, value: u8) Error!void {
        try self.queueWrite(allocator, stream_id, &.{value}, false);
    }

    fn queueSettings(self: *Session, allocator: Allocator) Error!void {
        var payload: [32]u8 = undefined;
        const settings_payload = settings.write(&payload, self.local_settings) catch
            return error.InvalidOptions;
        const framed = frame.write(self.send_frame, .settings, settings_payload) catch
            return error.InvalidOptions;
        try self.queueWrite(allocator, self.options.control_stream, framed, false);
    }

    fn queueAck(self: *Session, allocator: Allocator, stream_id: u62) Error!void {
        const id = self.options.decoder_stream orelse return error.MissingDecoderStream;
        var buf: [8]u8 = undefined;
        const instruction = decoder_stream.write(
            &buf,
            .{ .section_ack = stream_id },
        ) catch return error.MessageTooLarge;
        try self.queueWrite(allocator, id, instruction, false);
    }

    fn queueWrite(
        self: *Session,
        allocator: Allocator,
        stream_id: u62,
        bytes: []const u8,
        fin: bool,
    ) Error!void {
        const start = self.out_bytes.items.len;
        try self.out_bytes.appendSlice(allocator, bytes);
        errdefer self.out_bytes.shrinkRetainingCapacity(start);
        try self.out_queued.append(allocator, .{ .write = .{
            .stream_id = stream_id,
            .start = start,
            .len = bytes.len,
            .fin = fin,
        } });
    }

    fn queueAction(self: *Session, allocator: Allocator, action: Queued) Error!void {
        try self.out_queued.append(allocator, action);
    }

    fn addLocal(self: *Session, allocator: Allocator, id: u62, kind: Kind) Error!void {
        if (self.streams.count() >= self.options.max_streams) return error.TooManyStreams;
        try self.streams.put(allocator, id, .{
            .id = id,
            .kind = kind,
            .local = true,
            .typed = true,
            .reader = frame.Reader.init(),
            .assembly = &.{},
            .assembly_len = 0,
            .head_seen = false,
            .trailers_seen = false,
            .local_head = false,
            .remote_closed = false,
            .local_closed = false,
            .held = null,
            .held_ric = 0,
            .held_trailers = false,
            .dynamic = false,
        });
    }

    fn fail(self: *Session, allocator: Allocator, code: error_code.Code) Error {
        _ = self.connectionError(allocator, code);
        return error.ConnectionClosed;
    }

    fn connectionError(self: *Session, allocator: Allocator, code: error_code.Code) usize {
        if (self.state == .closed) return 0;
        self.state = .closed;
        self.queueAction(allocator, .{ .close = @backingInt(code) }) catch
            @panic("h3 session allocation failed");
        self.event = .{ .connection_error = .{ .code = code } };
        return 0;
    }

    fn streamError(
        self: *Session,
        allocator: Allocator,
        stream_id: u62,
        code: error_code.Code,
    ) usize {
        const value = @backingInt(code);
        self.queueAction(allocator, .{
            .reset = .{ .stream_id = stream_id, .code = value },
        }) catch @panic("h3 session allocation failed");
        self.queueAction(allocator, .{
            .stop_sending = .{ .stream_id = stream_id, .code = value },
        }) catch @panic("h3 session allocation failed");
        self.event = .{ .stream_error = .{ .stream_id = stream_id, .code = code } };
        return 0;
    }
};

fn validate(options: Options) Error!void {
    if (options.qpack_max_table_capacity != 0 and options.decoder_stream == null) {
        return error.MissingDecoderStream;
    }
    if (options.max_field_section_size) |max| {
        if (max == 0) return error.InvalidOptions;
    }
    if (options.max_in_header_block == 0 or options.max_fields == 0) {
        return error.InvalidOptions;
    }
}

test "a client and server exchange a request and a response" {
    var client = try Session.init(testing.allocator, .{
        .role = .client,
        .control_stream = 2,
        .decoder_stream = 6,
    });
    defer client.deinit(testing.allocator);
    var server = try Session.init(testing.allocator, .{
        .role = .server,
        .control_stream = 3,
        .decoder_stream = 7,
    });
    defer server.deinit(testing.allocator);

    try initSettings(testing.allocator, &client, &server);
    try initSettings(testing.allocator, &server, &client);

    try client.submitRequest(testing.allocator, 0, &.{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":authority", .value = "example.com" },
        .{ .name = ":path", .value = "/" },
        .{ .name = "accept", .value = "*/*" },
    }, true);
    try pumpOne(testing.allocator, &client, &server);

    const request = (try server.nextEvent(testing.allocator)).?.request;
    try testing.expectEqual(@as(u62, 0), request.stream_id);
    try testing.expectEqualStrings("/", request.head.path.?);
    try testing.expect(request.end_stream);

    try server.submitResponse(testing.allocator, 0, &.{
        .{ .name = ":status", .value = "200" },
        .{ .name = "content-type", .value = "text/plain" },
    }, true);
    try pumpOne(testing.allocator, &server, &client);

    const response = (try client.nextEvent(testing.allocator)).?.response;
    try testing.expectEqual(@as(u16, 200), response.head.status.code());
    try testing.expect(response.end_stream);
}

/// Drain one write from `from` into `to`, requiring full consumption.
fn pumpOne(allocator: Allocator, from: *Session, to: *Session) !void {
    const action = from.nextAction().?;
    const write = action.write;
    const consumed = to.receive(allocator, write.stream_id, write.bytes, write.fin);
    try testing.expectEqual(write.bytes.len, consumed);
    from.release(allocator);
}

/// Send the type byte, SETTINGS, and the decoder stream type byte, draining
/// the settings event before the last write.
fn initSettings(allocator: Allocator, from: *Session, to: *Session) !void {
    try pumpOne(allocator, from, to); // control stream type
    try pumpOne(allocator, from, to); // SETTINGS

    const event = (try to.nextEvent(allocator)).?;
    try testing.expectEqual(@as(u62, 4096), event.settings.qpack_max_table_capacity);

    try pumpOne(allocator, from, to); // decoder stream type
}
