//! An HTTP/2 connection state machine, sans I/O (RFC 9113).
//!
//! The session owns the protocol state: SETTINGS, the stream table, flow
//! control, HPACK, CONTINUATION assembly, and the outbound queue. It never
//! touches a socket, a TLS context, or an event loop. The caller feeds bytes
//! with `receive`, consumes events with `nextEvent`, submits frames with the
//! `submit*` methods, and drains `send` into its transport.
//!
//! Every method that can allocate takes the caller's allocator. The session
//! stores no allocator. Stream records and output chunks come from
//! fixed-record pools, so a caller with a fixed ceiling can pass a
//! `std.heap.FixedBufferAllocator`; the pools reuse records and chunks.

const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;
const mem = std.mem;
const Allocator = mem.Allocator;

const frame = @import("frame.zig");
const settings = @import("settings.zig");
const flow = @import("flow.zig");
const stream = @import("stream.zig");
const header_block = @import("header_block.zig");
const hpack = @import("../hpack/root.zig");
const Headers = @import("../header.zig").Headers;
const Header = @import("../header.zig").Header;
const head = @import("head.zig");

/// The largest frame payload this session writes. The peer must accept at
/// least this much, and it keeps the queue's frame buffer small.
const out_frame_payload: usize = 16_384;
/// One output chunk. Frames span chunks; `send` copies across them.
const out_chunk_size: usize = 4096;

pub const Origin = enum { local, remote };

pub const RequestEvent = struct {
    stream_id: u31,
    head: head.RequestHead,
    end_stream: bool,
};

pub const ResponseEvent = struct {
    stream_id: u31,
    head: head.ResponseHead,
    end_stream: bool,
};

pub const DataEvent = struct {
    stream_id: u31,
    /// The DATA payload with padding removed. Borrowed until the next event.
    bytes: []const u8,
    /// The whole DATA payload, padding included, as flow control counts it.
    flow_len: u32,
    end_stream: bool,
};

pub const TrailersEvent = struct {
    stream_id: u31,
    headers: Headers,
    end_stream: bool,
};

pub const ResetEvent = struct {
    stream_id: u31,
    code: frame.ErrorCode,
    origin: Origin,
};

pub const WindowUpdateEvent = struct {
    /// Zero is the connection window.
    stream_id: u31,
    available: i64,
};

pub const GoAwayEvent = struct {
    last_stream_id: u31,
    code: frame.ErrorCode,
    debug: []const u8,
};

pub const ConnectionErrorEvent = struct {
    code: frame.ErrorCode,
};

pub const Event = union(enum) {
    request: RequestEvent,
    response: ResponseEvent,
    data: DataEvent,
    trailers: TrailersEvent,
    reset: ResetEvent,
    window_update: WindowUpdateEvent,
    goaway: GoAwayEvent,
    settings: settings.Values,
    connection_error: ConnectionErrorEvent,
};

// ast-grep-ignore: public-struct-field-default -- these are protocol defaults
pub const Options = struct {
    role: settings.Role,
    /// Our SETTINGS_MAX_CONCURRENT_STREAMS and the stream table capacity.
    max_streams: u16 = 128,
    /// The largest frame we accept, advertised in SETTINGS.
    max_frame_size: u32 = frame.default_max_frame_size,
    /// Our decoder table, advertised in SETTINGS.
    header_table_size: u32 = 4096,
    /// Our stream receive window, advertised in SETTINGS.
    initial_window_size: u32 = 65_535,
    /// Our decoded field-section limit, advertised in SETTINGS.
    max_header_list_size: u32 = 16 * 1024,
    /// The assembled wire block we accept.
    max_in_header_block: u32 = 32 * 1024,
    /// The outbound header block we can encode.
    max_send_header_block: u32 = 16 * 1024,
    /// A cap on queued output. Control frames may exceed it.
    max_out_bytes: u32 = 256 * 1024,
};

pub const Error = error{
    ConnectionClosed,
    WrongRole,
    UnknownStream,
    StreamClosed,
    TooManyStreams,
    StreamIdsExhausted,
    HeaderBlockTooLarge,
    InvalidHead,
    WouldBlock,
    FlowControlError,
    InvalidMaxFrameSize,
    InvalidInitialWindowSize,
    InvalidHeaderTableSize,
    InvalidHeaderListSize,
    InvalidHeaderBlockSize,
    InvalidOutputSize,
    InvalidSetting,
    SettingsTooLarge,
    BufferTooSmall,
    TooLarge,
} || Allocator.Error;

const State = enum { open, closed };

const Initiator = enum { local, remote };

const EventKind = enum { request, response, trailers };

const Stream = struct {
    state: stream.State,
    initiator: Initiator,
    send: flow.Window,
    recv: flow.Window,
    recv_head: bool,
    sent_head: bool,
};

const Pending = struct {
    stream_id: u31,
    kind: EventKind,
    end_stream: bool,
};

const Closed = struct {
    id: u31,
    reset: bool,
};

const closed_capacity = 64;

const Chunk = struct {
    next: ?*Chunk = null,
    start: usize = 0,
    len: usize = 0,
    bytes: [out_chunk_size]u8 = undefined,
};

const OutQueue = struct {
    pool: std.heap.MemoryPool(Chunk) = .empty,
    head: ?*Chunk = null,
    tail: ?*Chunk = null,
    /// The next write location, which can lag `tail` after a reservation.
    write_chunk: ?*Chunk = null,
    write_offset: usize = 0,
    total: usize = 0,

    fn deinit(self: *OutQueue, allocator: Allocator) void {
        var node = self.head;
        while (node) |chunk| {
            const next = chunk.next;
            self.pool.destroy(chunk);
            node = next;
        }
        self.pool.deinit(allocator);
        self.* = undefined;
    }

    /// Make room for `n` bytes. Allocations are linked but no bytes are
    /// written, so a failure leaves only harmless empty chunks.
    fn ensure(self: *OutQueue, allocator: Allocator, n: usize) !void {
        if (n == 0) return;
        if (self.tail) |tail| {
            const free = out_chunk_size - tail.len;
            if (free >= n) return;
            var need = n - free;
            var last = tail;
            while (need > 0) {
                const chunk = try self.pool.create(allocator);
                chunk.* = .{};
                last.next = chunk;
                self.tail = chunk;
                last = chunk;
                need -|= out_chunk_size;
            }
            return;
        }

        var need = n;
        while (need > 0) {
            const chunk = try self.pool.create(allocator);
            chunk.* = .{};
            if (self.tail) |tail| {
                tail.next = chunk;
            } else {
                self.head = chunk;
            }
            self.tail = chunk;
            need -|= out_chunk_size;
        }
    }

    /// Append bytes. `ensure` guarantees the capacity; the copy itself cannot
    /// fail. The write starts at the old tail, not at a newly linked chunk.
    fn append(self: *OutQueue, allocator: Allocator, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        try self.ensure(allocator, bytes.len);

        var node = self.write_chunk orelse self.head.?;
        var offset: usize = if (self.write_chunk == null) 0 else self.write_offset;
        var rest = bytes;
        while (rest.len > 0) {
            const room = out_chunk_size - offset;
            const take = @min(room, rest.len);
            @memcpy(node.bytes[offset..][0..take], rest[0..take]);
            node.len = offset + take;
            rest = rest[take..];
            offset = 0;
            if (rest.len > 0) node = node.next.?;
        }
        self.write_chunk = node;
        self.write_offset = node.len;
        self.total += bytes.len;
    }

    fn send(self: *OutQueue, out: []u8) usize {
        var written: usize = 0;
        while (written < out.len) {
            const node = self.head orelse break;
            if (node.start == node.len) {
                self.dropHead();
                continue;
            }
            const take = @min(node.len - node.start, out.len - written);
            @memcpy(out[written..][0..take], node.bytes[node.start..][0..take]);
            node.start += take;
            written += take;
            self.total -= take;
            if (node.start == node.len) self.dropHead();
        }
        return written;
    }

    fn dropHead(self: *OutQueue) void {
        const node = self.head.?;
        self.head = node.next;
        if (self.head == null) self.tail = null;
        if (self.write_chunk == node) {
            self.write_chunk = null;
            self.write_offset = 0;
        }
        self.pool.destroy(node);
    }
};

pub const Session = struct {
    options: Options,
    state: State,
    ids: stream.Ids,
    streams: std.AutoHashMapUnmanaged(u31, Stream),
    active_local: u32,
    active_remote: u32,
    closed: [closed_capacity]Closed,
    closed_len: usize,
    closed_pos: usize,

    local: settings.Values,
    remote: settings.Values,
    conn_send: flow.Window,
    conn_recv: flow.Window,

    encoder: hpack.Encoder,
    decoder: hpack.Decoder,
    encoder_storage: hpack.TableStorage,
    decoder_storage: hpack.TableStorage,

    in_buf: []u8,
    in_len: usize,
    in_start: usize,
    preface_received: bool,
    settings_received: bool,
    settings_acked: bool,
    goaway_received: bool,
    goaway_sent: bool,

    block: header_block.Assembler,
    pending: ?Pending,
    field_headers: []Header,
    field_bytes: []u8,
    send_block: []u8,
    frame_buf: []u8,

    out: OutQueue,
    event: ?Event,

    pub fn init(allocator: Allocator, options: Options) Error!Session {
        try validateOptions(options);

        var decoder_storage = try hpack.TableStorage.init(allocator, options.header_table_size);
        errdefer decoder_storage.deinit(allocator);
        var encoder_storage = try hpack.TableStorage.init(allocator, options.header_table_size);
        errdefer encoder_storage.deinit(allocator);

        const in_buf = try allocator.alloc(u8, 9 + options.max_frame_size);
        errdefer allocator.free(in_buf);
        const block_buf = try allocator.alloc(u8, options.max_in_header_block);
        errdefer allocator.free(block_buf);
        const send_block = try allocator.alloc(u8, options.max_send_header_block);
        errdefer allocator.free(send_block);
        const frame_buf = try allocator.alloc(u8, 9 + out_frame_payload);
        errdefer allocator.free(frame_buf);
        const field_bytes = try allocator.alloc(u8, options.max_header_list_size);
        errdefer allocator.free(field_bytes);
        const max_fields = fieldCount(options.max_header_list_size);
        const field_headers = try allocator.alloc(Header, max_fields);
        errdefer allocator.free(field_headers);

        var streams: std.AutoHashMapUnmanaged(u31, Stream) = .empty;
        errdefer streams.deinit(allocator);
        try streams.ensureTotalCapacity(allocator, options.max_streams);

        var self: Session = .{
            .options = options,
            .state = .open,
            .ids = stream.Ids.init(options.role),
            .streams = streams,
            .active_local = 0,
            .active_remote = 0,
            .closed = undefined,
            .closed_len = 0,
            .closed_pos = 0,
            .local = .{
                .header_table_size = options.header_table_size,
                .enable_push = false,
                .max_concurrent_streams = if (options.role == .server) options.max_streams else 0,
                .initial_window_size = options.initial_window_size,
                .max_frame_size = options.max_frame_size,
                .max_header_list_size = options.max_header_list_size,
            },
            .remote = .{},
            .conn_send = flow.Window.init(65_535),
            .conn_recv = flow.Window.init(65_535),
            .encoder = hpack.Encoder.init(encoder_storage),
            .decoder = hpack.Decoder.init(decoder_storage),
            .encoder_storage = encoder_storage,
            .decoder_storage = decoder_storage,
            .in_buf = in_buf,
            .in_len = 0,
            .in_start = 0,
            .preface_received = options.role == .client,
            .settings_received = false,
            .settings_acked = false,
            .goaway_received = false,
            .goaway_sent = false,
            .block = header_block.Assembler.init(block_buf),
            .pending = null,
            .field_headers = field_headers,
            .field_bytes = field_bytes,
            .send_block = send_block,
            .frame_buf = frame_buf,
            .out = .{},
            .event = null,
        };

        // Until the peer says otherwise, its decoder starts at 4,096 bytes.
        self.encoder.setMaxSize(
            @min(self.remote.header_table_size, options.header_table_size),
        ) catch unreachable;
        self.queueInitial(allocator) catch |err| {
            self.out.deinit(allocator);
            return err;
        };
        return self;
    }

    pub fn deinit(self: *Session, allocator: Allocator) void {
        self.streams.deinit(allocator);
        self.out.deinit(allocator);
        self.encoder_storage.deinit(allocator);
        self.decoder_storage.deinit(allocator);
        allocator.free(self.in_buf);
        allocator.free(self.block.buffer);
        allocator.free(self.send_block);
        allocator.free(self.frame_buf);
        allocator.free(self.field_bytes);
        allocator.free(self.field_headers);
        self.* = undefined;
    }

    pub fn isClosed(self: *const Session) bool {
        return self.state == .closed;
    }

    pub fn hasPendingOutput(self: *const Session) bool {
        return self.out.total > 0;
    }

    /// Append transport bytes. Returns how many were consumed; zero means the
    /// input buffer is full and the caller must drain events first.
    pub fn receive(self: *Session, bytes: []const u8) usize {
        if (self.state == .closed) return 0;
        const room = self.in_buf.len - self.in_len;
        const n = @min(room, bytes.len);
        @memcpy(self.in_buf[self.in_len..][0..n], bytes[0..n]);
        self.in_len += n;
        return n;
    }

    /// Copy queued output into `out`. Never allocates.
    pub fn send(self: *Session, out: []u8) usize {
        return self.out.send(out);
    }

    pub fn nextEvent(self: *Session, allocator: Allocator) Error!?Event {
        if (self.state == .closed) return null;
        if (self.event) |_| {
            self.event = null;
            self.compact();
        }

        if (self.options.role == .server and !self.preface_received) {
            if (self.in_len - self.in_start < frame.preface.len) return null;
            const got = self.in_buf[self.in_start..][0..frame.preface.len];
            if (!mem.eql(u8, got, frame.preface)) {
                return self.connectionError(allocator, .protocol_error);
            }
            self.in_start += frame.preface.len;
            self.preface_received = true;
            self.compact();
        }

        while (true) {
            if (self.in_len - self.in_start < 9) return null;
            const header = frame.parseHeader(
                self.in_buf[self.in_start..self.in_len],
            ) catch unreachable;
            if (header.length > self.local.max_frame_size) {
                return self.connectionError(allocator, .frame_size_error);
            }
            const total = 9 + @as(usize, header.length);
            if (self.in_len - self.in_start < total) return null;

            if (self.block.isAssembling() and header.type != .continuation) {
                return self.connectionError(allocator, .protocol_error);
            }

            const payload = self.in_buf[self.in_start + 9 .. self.in_start + total];
            const body = frame.body(header, payload) catch |err| {
                const code: frame.ErrorCode = switch (err) {
                    error.InvalidLength => .frame_size_error,
                    else => .protocol_error,
                };
                return self.connectionError(allocator, code);
            };
            self.in_start += total;

            if (!self.settings_received) {
                switch (body) {
                    .settings => |s| {
                        if (s.ack) return self.connectionError(allocator, .protocol_error);
                    },
                    else => return self.connectionError(allocator, .protocol_error),
                }
            }

            if (try self.handleFrame(allocator, header, body)) |event| {
                self.event = event;
                return event;
            }
            self.compact();
        }
    }

    fn handleFrame(
        self: *Session,
        allocator: Allocator,
        header: frame.Header,
        body: frame.Body,
    ) Error!?Event {
        return switch (body) {
            .data => |data_frame| self.onData(allocator, header, data_frame),
            .headers => |headers_frame| self.onHeaders(allocator, header, headers_frame),
            .priority => |priority| self.onPriority(allocator, header, priority),
            .rst_stream => |rst| self.onRstStream(allocator, header, rst),
            .settings => |s| self.onSettings(allocator, header, s),
            .push_promise => self.connectionError(allocator, .protocol_error),
            .ping => |ping| self.onPing(allocator, header, ping),
            .goaway => |goaway| self.onGoAway(allocator, header, goaway),
            .window_update => |update| self.onWindowUpdate(allocator, header, update),
            .continuation => |cont| self.onContinuation(allocator, header, cont),
            .unknown => null,
        };
    }

    fn onSettings(
        self: *Session,
        allocator: Allocator,
        header: frame.Header,
        s: frame.Settings,
    ) Error!?Event {
        if (header.stream_id != 0) return self.connectionError(allocator, .protocol_error);
        if (s.ack) {
            self.settings_acked = true;
            return null;
        }

        const old_initial = self.remote.initial_window_size;
        settings.apply(&self.remote, self.options.role, s) catch {
            return self.connectionError(allocator, .protocol_error);
        };

        if (self.remote.initial_window_size != old_initial) {
            var it = self.streams.valueIterator();
            while (it.next()) |state| {
                state.send.applyInitialChange(old_initial, self.remote.initial_window_size) catch {
                    return self.connectionError(allocator, .flow_control_error);
                };
            }
        }

        const table = @min(self.remote.header_table_size, self.options.header_table_size);
        self.encoder.setMaxSize(table) catch {
            return self.connectionError(allocator, .protocol_error);
        };
        self.settings_received = true;
        try self.appendFrame(allocator, .settings, frame.flags.ack, 0, &.{});
        return .{ .settings = self.remote };
    }

    fn onPing(
        self: *Session,
        allocator: Allocator,
        header: frame.Header,
        ping: frame.Ping,
    ) Error!?Event {
        if (header.stream_id != 0) return self.connectionError(allocator, .protocol_error);
        if (!ping.ack) {
            try self.appendFrame(allocator, .ping, frame.flags.ack, 0, ping.payload);
        }
        return null;
    }

    fn onGoAway(
        self: *Session,
        allocator: Allocator,
        header: frame.Header,
        goaway: frame.GoAway,
    ) Error!?Event {
        if (header.stream_id != 0) return self.connectionError(allocator, .protocol_error);
        self.goaway_received = true;
        return .{ .goaway = .{
            .last_stream_id = goaway.last_stream_id,
            .code = goaway.error_code,
            .debug = goaway.debug,
        } };
    }

    fn onWindowUpdate(
        self: *Session,
        allocator: Allocator,
        header: frame.Header,
        update: frame.WindowUpdate,
    ) Error!?Event {
        if (update.increment == 0) {
            if (header.stream_id == 0) return self.connectionError(allocator, .protocol_error);
            return self.failStream(allocator, header.stream_id, .protocol_error);
        }

        if (header.stream_id == 0) {
            self.conn_send.increase(update.increment) catch {
                return self.connectionError(allocator, .flow_control_error);
            };
            return .{ .window_update = .{
                .stream_id = 0,
                .available = self.conn_send.available,
            } };
        }

        const state = self.streams.getPtr(header.stream_id) orelse {
            if (self.closedReason(header.stream_id) != null or
                self.isClosedStream(header.stream_id)) return null;
            return self.connectionError(allocator, .protocol_error);
        };
        state.send.increase(update.increment) catch {
            return self.failStream(allocator, header.stream_id, .flow_control_error);
        };
        return .{ .window_update = .{
            .stream_id = header.stream_id,
            .available = state.send.available,
        } };
    }

    fn onRstStream(
        self: *Session,
        allocator: Allocator,
        header: frame.Header,
        rst: frame.RstStream,
    ) Error!?Event {
        if (header.stream_id == 0) return self.connectionError(allocator, .protocol_error);
        if (self.closedReason(header.stream_id) != null) return null;
        if (self.streams.contains(header.stream_id)) {
            _ = self.removeStream(header.stream_id, true);
        } else if (!self.isClosedStream(header.stream_id)) {
            return self.connectionError(allocator, .protocol_error);
        }
        return .{ .reset = .{
            .stream_id = header.stream_id,
            .code = rst.error_code,
            .origin = .remote,
        } };
    }

    fn onPriority(
        self: *Session,
        allocator: Allocator,
        header: frame.Header,
        priority: frame.Priority,
    ) Error!?Event {
        if (header.stream_id == 0) return self.connectionError(allocator, .protocol_error);
        if (priority.dependency == header.stream_id) {
            return self.failStream(allocator, header.stream_id, .protocol_error);
        }
        return null;
    }

    fn onData(
        self: *Session,
        allocator: Allocator,
        header: frame.Header,
        data_frame: frame.Data,
    ) Error!?Event {
        const id = header.stream_id;
        if (id == 0) return self.connectionError(allocator, .protocol_error);

        const state = self.streams.getPtr(id) orelse {
            if (self.closedReason(id) != null) {
                self.conn_recv.consume(header.length) catch {
                    return self.connectionError(allocator, .flow_control_error);
                };
                const event = try self.failStream(allocator, id, .stream_closed);
                try self.grantConnection(allocator, header.length);
                return event;
            }
            return self.connectionError(allocator, .protocol_error);
        };

        self.conn_recv.consume(header.length) catch {
            return self.connectionError(allocator, .flow_control_error);
        };
        state.recv.consume(header.length) catch {
            const event = try self.failStream(allocator, id, .flow_control_error);
            try self.grantConnection(allocator, header.length);
            return event;
        };

        const end_stream = header.flags & frame.flags.end_stream != 0;
        state.state = stream.transition(state.state, .remote, .data) catch |err| {
            const event = switch (err) {
                error.IdleStream => return self.connectionError(allocator, .protocol_error),
                error.InvalidTransition => try self.failStream(allocator, id, .stream_closed),
                else => return self.connectionError(allocator, .protocol_error),
            };
            try self.grantConnection(allocator, header.length);
            return event;
        };
        if (end_stream) {
            state.state = stream.transition(state.state, .remote, .end_stream) catch {
                const event = try self.failStream(allocator, id, .protocol_error);
                try self.grantConnection(allocator, header.length);
                return event;
            };
        }

        const event: Event = .{ .data = .{
            .stream_id = id,
            .bytes = data_frame.data,
            .flow_len = header.length,
            .end_stream = end_stream,
        } };

        // Padding counts for flow control but never reaches the application.
        // Return it now; the application returns the data bytes it consumed.
        const padding = @as(u32, header.length) - @as(u32, @intCast(data_frame.data.len));
        if (padding > 0) try self.grant(allocator, id, padding);
        self.maybeRemoveClosed(id);
        return event;
    }

    fn onHeaders(
        self: *Session,
        allocator: Allocator,
        header: frame.Header,
        headers_frame: frame.Headers,
    ) Error!?Event {
        const id = header.stream_id;
        if (id == 0) return self.connectionError(allocator, .protocol_error);

        if (headers_frame.priority) |priority| {
            if (priority.dependency == id) {
                return self.failStream(allocator, id, .protocol_error);
            }
        }

        var state = self.streams.getPtr(id);
        if (state == null) {
            if (self.closedReason(id)) |reset| {
                if (reset) return self.failStream(allocator, id, .stream_closed);
                return self.connectionError(allocator, .stream_closed);
            }
            const local_parity: u31 = if (self.options.role == .client) 1 else 0;
            if (id & 1 == local_parity) {
                if (id < self.ids.local_next) {
                    return self.failStream(allocator, id, .stream_closed);
                }
                return self.connectionError(allocator, .protocol_error);
            }
            if (id < self.ids.last_remote) {
                // A lower remote identifier that was never opened is an
                // idle stream, not a closed one (RFC 9113 §5.1.1).
                return self.connectionError(allocator, .protocol_error);
            }
            if (id == self.ids.last_remote and id != 0) {
                return self.connectionError(allocator, .stream_closed);
            }
            self.ids.acceptRemote(id) catch {
                return self.connectionError(allocator, .protocol_error);
            };
            const stream_limit = self.local.max_concurrent_streams orelse self.options.max_streams;
            if (self.active_remote >= stream_limit or
                self.streams.count() >= self.options.max_streams)
            {
                try self.appendFrame(allocator, .rst_stream, 0, id, &.{
                    0, 0, 0, @intFromEnum(frame.ErrorCode.refused_stream),
                });
                self.rememberClosed(id, true);
                return null;
            }
            self.streams.putAssumeCapacityNoClobber(id, .{
                .state = .idle,
                .initiator = .remote,
                .send = flow.Window.init(self.remote.initial_window_size),
                .recv = flow.Window.init(self.local.initial_window_size),
                .recv_head = false,
                .sent_head = false,
            });
            self.active_remote += 1;
            state = self.streams.getPtr(id);
        }

        const tracked = state.?;
        const end_stream = header.flags & frame.flags.end_stream != 0;
        const kind: EventKind = if (tracked.recv_head)
            .trailers
        else if (tracked.initiator == .remote)
            .request
        else
            .response;
        if (kind == .trailers and !end_stream) {
            return self.failStream(allocator, id, .protocol_error);
        }
        if (kind != .trailers) tracked.recv_head = true;

        tracked.state = stream.transition(tracked.state, .remote, .headers) catch |err| {
            return switch (err) {
                error.IdleStream => self.connectionError(allocator, .protocol_error),
                error.InvalidTransition => self.failStream(
                    allocator,
                    id,
                    if (tracked.state == .half_closed_remote)
                        .stream_closed
                    else
                        .protocol_error,
                ),
                else => self.connectionError(allocator, .protocol_error),
            };
        };

        if (end_stream) {
            tracked.state = stream.transition(tracked.state, .remote, .end_stream) catch {
                return self.failStream(allocator, id, .protocol_error);
            };
        }

        const block = self.block.start(
            id,
            headers_frame.block,
            header.flags & frame.flags.end_headers != 0,
        ) catch |err| switch (err) {
            error.Interleaved => return self.connectionError(allocator, .protocol_error),
            error.TooLarge => return self.connectionError(allocator, .enhance_your_calm),
            error.UnexpectedContinuation => unreachable,
        };

        if (block) |complete| {
            return self.processBlock(allocator, id, complete, kind, end_stream);
        }
        self.pending = .{ .stream_id = id, .kind = kind, .end_stream = end_stream };
        return null;
    }

    fn onContinuation(
        self: *Session,
        allocator: Allocator,
        header: frame.Header,
        continuation: frame.Continuation,
    ) Error!?Event {
        const pending = self.pending orelse {
            return self.connectionError(allocator, .protocol_error);
        };
        if (header.stream_id != pending.stream_id) {
            return self.connectionError(allocator, .protocol_error);
        }

        const block = self.block.continuation(
            header.stream_id,
            continuation.block,
            header.flags & frame.flags.end_headers != 0,
        ) catch |err| switch (err) {
            error.UnexpectedContinuation => return self.connectionError(allocator, .protocol_error),
            error.TooLarge => return self.connectionError(allocator, .enhance_your_calm),
            error.Interleaved => unreachable,
        };

        if (block) |complete| {
            self.pending = null;
            return self.processBlock(
                allocator,
                pending.stream_id,
                complete,
                pending.kind,
                pending.end_stream,
            );
        }
        return null;
    }

    fn processBlock(
        self: *Session,
        allocator: Allocator,
        id: u31,
        block: []const u8,
        kind: EventKind,
        end_stream: bool,
    ) Error!?Event {
        const fields = self.decoder.decode(
            block,
            self.field_headers,
            self.field_bytes,
        ) catch |err| {
            return switch (err) {
                error.TooManyHeaders, error.OutputTooSmall => self.failStream(
                    allocator,
                    id,
                    .enhance_your_calm,
                ),
                else => self.connectionError(allocator, .compression_error),
            };
        };

        if (self.local.max_header_list_size) |limit| {
            var list_size: usize = 0;
            for (fields.items) |field| {
                list_size += field.name.len + field.value.len + 32;
            }
            if (list_size > limit) {
                return self.failStream(allocator, id, .enhance_your_calm);
            }
        }

        const event: Event = switch (kind) {
            .request => .{ .request = .{
                .stream_id = id,
                .head = head.request(fields) catch {
                    return self.failStream(allocator, id, .protocol_error);
                },
                .end_stream = end_stream,
            } },
            .response => .{ .response = .{
                .stream_id = id,
                .head = head.response(fields) catch {
                    return self.failStream(allocator, id, .protocol_error);
                },
                .end_stream = end_stream,
            } },
            .trailers => .{ .trailers = .{
                .stream_id = id,
                .headers = head.trailers(fields) catch {
                    return self.failStream(allocator, id, .protocol_error);
                },
                .end_stream = end_stream,
            } },
        };
        self.maybeRemoveClosed(id);
        return event;
    }

    fn maybeRemoveClosed(self: *Session, id: u31) void {
        const state = self.streams.getPtr(id) orelse return;
        if (state.state == .closed) _ = self.removeStream(id, false);
    }

    pub fn submitRequest(
        self: *Session,
        allocator: Allocator,
        fields: []const Header,
        end_stream: bool,
    ) Error!u31 {
        if (self.options.role != .client) return error.WrongRole;
        if (self.state == .closed) return error.ConnectionClosed;
        if (self.goaway_received or self.goaway_sent) return error.ConnectionClosed;
        if (self.remote.max_concurrent_streams) |max| {
            if (self.active_local >= max) return error.TooManyStreams;
        }
        if (self.streams.count() >= self.options.max_streams) return error.TooManyStreams;
        if (self.ids.local_next > 0x7fff_ffff) return error.StreamIdsExhausted;

        _ = head.request(.{ .items = fields }) catch return error.InvalidHead;
        const upper = self.encoder.encodedLen(fields);
        if (upper > self.send_block.len) return error.HeaderBlockTooLarge;
        const reserve = upper + 9 * headerFrameCount(upper);
        try self.checkBudget(reserve);
        try self.out.ensure(allocator, reserve);

        const block = self.encoder.encode(fields, self.send_block) catch {
            return error.HeaderBlockTooLarge;
        };
        const id = self.ids.nextLocal().?;
        self.streams.putAssumeCapacityNoClobber(id, .{
            .state = .idle,
            .initiator = .local,
            .send = flow.Window.init(self.remote.initial_window_size),
            .recv = flow.Window.init(self.local.initial_window_size),
            .recv_head = false,
            .sent_head = true,
        });
        self.active_local += 1;

        const state = self.streams.getPtr(id).?;
        state.state = stream.transition(state.state, .local, .headers) catch unreachable;
        if (end_stream) {
            state.state = stream.transition(state.state, .local, .end_stream) catch unreachable;
        }
        try self.writeHeaderBlock(allocator, id, block, end_stream);
        return id;
    }

    pub fn submitResponse(
        self: *Session,
        allocator: Allocator,
        id: u31,
        fields: []const Header,
        end_stream: bool,
    ) Error!void {
        if (self.options.role != .server) return error.WrongRole;
        if (self.state == .closed) return error.ConnectionClosed;

        const state = self.streams.getPtr(id) orelse return error.UnknownStream;
        if (state.sent_head) return error.InvalidHead;
        _ = head.response(.{ .items = fields }) catch return error.InvalidHead;

        var next = stream.transition(state.state, .local, .headers) catch {
            return error.StreamClosed;
        };
        if (end_stream) {
            next = stream.transition(next, .local, .end_stream) catch {
                return error.StreamClosed;
            };
        }

        const upper = self.encoder.encodedLen(fields);
        if (upper > self.send_block.len) return error.HeaderBlockTooLarge;
        const reserve = upper + 9 * headerFrameCount(upper);
        try self.checkBudget(reserve);
        try self.out.ensure(allocator, reserve);
        const block = self.encoder.encode(fields, self.send_block) catch {
            return error.HeaderBlockTooLarge;
        };

        state.state = next;
        state.sent_head = true;
        try self.writeHeaderBlock(allocator, id, block, end_stream);
        self.maybeRemoveClosed(id);
    }

    pub fn submitTrailers(
        self: *Session,
        allocator: Allocator,
        id: u31,
        fields: []const Header,
    ) Error!void {
        if (self.state == .closed) return error.ConnectionClosed;

        const state = self.streams.getPtr(id) orelse return error.UnknownStream;
        if (!state.sent_head) return error.InvalidHead;
        _ = head.trailers(.{ .items = fields }) catch return error.InvalidHead;

        var next = stream.transition(state.state, .local, .headers) catch {
            return error.StreamClosed;
        };
        next = stream.transition(next, .local, .end_stream) catch {
            return error.StreamClosed;
        };

        const upper = self.encoder.encodedLen(fields);
        if (upper > self.send_block.len) return error.HeaderBlockTooLarge;
        const reserve = upper + 9 * headerFrameCount(upper);
        try self.checkBudget(reserve);
        try self.out.ensure(allocator, reserve);
        const block = self.encoder.encode(fields, self.send_block) catch {
            return error.HeaderBlockTooLarge;
        };

        state.state = next;
        try self.writeHeaderBlock(allocator, id, block, true);
        self.maybeRemoveClosed(id);
    }

    /// Queue as much of `bytes` as flow control and the output budget allow.
    /// Returns the number of bytes accepted; the caller keeps the rest.
    pub fn submitData(
        self: *Session,
        allocator: Allocator,
        id: u31,
        bytes: []const u8,
        end_stream: bool,
    ) Error!usize {
        if (self.state == .closed) return error.ConnectionClosed;

        const state = self.streams.getPtr(id) orelse return error.UnknownStream;
        _ = stream.transition(state.state, .local, .data) catch return error.StreamClosed;

        if (bytes.len == 0) {
            if (!end_stream) return 0;
            try self.out.ensure(allocator, 9);
            state.state = stream.transition(state.state, .local, .data) catch unreachable;
            state.state = stream.transition(state.state, .local, .end_stream) catch unreachable;
            try self.appendFrame(allocator, .data, frame.flags.end_stream, id, &.{});
            self.maybeRemoveClosed(id);
            return 0;
        }

        const max_out = self.options.max_out_bytes;
        if (self.out.total >= max_out) return 0;
        const head_room = max_out - self.out.total;
        if (head_room <= 9) return 0;

        const stream_space: u64 = if (state.send.available > 0)
            @intCast(state.send.available)
        else
            0;
        const conn_space: u64 = if (self.conn_send.available > 0)
            @intCast(self.conn_send.available)
        else
            0;

        var accepted: usize = @min(bytes.len, out_frame_payload);
        accepted = @min(accepted, @as(usize, @intCast(stream_space)));
        accepted = @min(accepted, @as(usize, @intCast(conn_space)));
        accepted = @min(accepted, head_room - 9);
        if (accepted == 0) return 0;

        try self.out.ensure(allocator, 9 + accepted);
        state.send.consume(@intCast(accepted)) catch unreachable;
        self.conn_send.consume(@intCast(accepted)) catch unreachable;
        state.state = stream.transition(state.state, .local, .data) catch unreachable;

        const end = end_stream and accepted == bytes.len;
        if (end) {
            state.state = stream.transition(state.state, .local, .end_stream) catch unreachable;
        }
        try self.appendFrame(
            allocator,
            .data,
            if (end) frame.flags.end_stream else 0,
            id,
            bytes[0..accepted],
        );
        self.maybeRemoveClosed(id);
        return accepted;
    }

    pub fn submitReset(
        self: *Session,
        allocator: Allocator,
        id: u31,
        code: frame.ErrorCode,
    ) Error!void {
        if (self.state == .closed) return error.ConnectionClosed;
        const state = self.streams.getPtr(id) orelse return error.UnknownStream;
        _ = stream.transition(state.state, .local, .reset) catch return error.StreamClosed;
        var payload: [4]u8 = undefined;
        mem.writeInt(u32, &payload, @intFromEnum(code), .big);
        try self.appendFrame(allocator, .rst_stream, 0, id, &payload);
        _ = self.removeStream(id, true);
    }

    /// Send a local SETTINGS change. Only the entries supplied are sent; the
    /// session validates each one, applies the receive-side effects, and
    /// queues the frame. Local table and buffer growth is capped by what
    /// `init` allocated.
    pub fn submitSettings(
        self: *Session,
        allocator: Allocator,
        entries: []const frame.Setting,
    ) Error!void {
        if (self.state == .closed) return error.ConnectionClosed;
        if (self.goaway_sent) return error.ConnectionClosed;

        var next = self.local;
        for (entries) |entry| {
            switch (entry.id) {
                .header_table_size,
                .enable_push,
                .max_concurrent_streams,
                .initial_window_size,
                .max_frame_size,
                .max_header_list_size,
                => {},
                else => return error.InvalidSetting,
            }
            if (entry.id == .enable_push) {
                if (entry.value > 1) return error.InvalidSetting;
                if (self.options.role == .server or entry.value == 1) {
                    return error.InvalidSetting;
                }
            }
            settings.applyEntry(&next, self.options.role, entry) catch {
                return error.InvalidSetting;
            };
        }

        if (next.header_table_size > self.decoder_storage.max_size) {
            return error.SettingsTooLarge;
        }
        if (next.max_frame_size > self.in_buf.len - 9) {
            return error.SettingsTooLarge;
        }
        if (next.max_header_list_size) |limit| {
            if (limit > self.field_bytes.len) return error.SettingsTooLarge;
        }
        if (next.max_concurrent_streams) |limit| {
            if (limit > self.options.max_streams) return error.SettingsTooLarge;
        }

        const old_initial = self.local.initial_window_size;
        if (next.initial_window_size != old_initial) {
            var it = self.streams.valueIterator();
            while (it.next()) |state| {
                var probe = state.recv;
                probe.applyInitialChange(old_initial, next.initial_window_size) catch {
                    return error.FlowControlError;
                };
            }
        }

        const payload = try allocator.alloc(u8, entries.len * 6);
        defer allocator.free(payload);
        for (entries, 0..) |entry, index| {
            const at = index * 6;
            mem.writeInt(u16, payload[at..][0..2], @intFromEnum(entry.id), .big);
            mem.writeInt(u32, payload[at + 2 ..][0..4], entry.value, .big);
        }
        if (9 + payload.len > self.frame_buf.len) return error.SettingsTooLarge;
        try self.out.ensure(allocator, 9 + payload.len);

        if (next.initial_window_size != old_initial) {
            var it = self.streams.valueIterator();
            while (it.next()) |state| {
                state.recv.applyInitialChange(
                    old_initial,
                    next.initial_window_size,
                ) catch unreachable;
            }
        }
        if (next.header_table_size != self.local.header_table_size) {
            self.decoder.table.setMaxSize(next.header_table_size) catch unreachable;
        }
        self.local = next;
        try self.appendFrame(allocator, .settings, 0, 0, payload);
    }

    pub fn submitGoaway(self: *Session, allocator: Allocator, code: frame.ErrorCode) Error!void {
        if (self.state == .closed) return error.ConnectionClosed;
        if (self.goaway_sent) return;
        var payload: [8]u8 = undefined;
        mem.writeInt(u32, payload[0..4], self.ids.last_remote, .big);
        mem.writeInt(u32, payload[4..8], @intFromEnum(code), .big);
        try self.appendFrame(allocator, .goaway, 0, 0, &payload);
        self.goaway_sent = true;
    }

    pub fn submitPing(self: *Session, allocator: Allocator, payload: *const [8]u8) Error!void {
        if (self.state == .closed) return error.ConnectionClosed;
        try self.appendFrame(allocator, .ping, 0, 0, payload);
    }

    /// Return consumed DATA bytes to the flow-control windows and send the two
    /// WINDOW_UPDATE frames. A closed stream only gets the connection update.
    pub fn release(
        self: *Session,
        allocator: Allocator,
        id: u31,
        count: u32,
    ) Error!void {
        if (count == 0) return;
        if (count > 0x7fff_ffff) return error.FlowControlError;
        const inc: u31 = @intCast(count);

        try self.out.ensure(allocator, 26);
        self.conn_recv.increase(inc) catch return error.FlowControlError;
        var payload: [4]u8 = undefined;
        mem.writeInt(u32, &payload, @as(u32, inc), .big);
        try self.appendFrame(allocator, .window_update, 0, 0, &payload);

        if (self.streams.getPtr(id)) |state| {
            if (state.state != .closed) {
                state.recv.increase(inc) catch return error.FlowControlError;
                try self.appendFrame(allocator, .window_update, 0, id, &payload);
            }
        }
    }

    fn checkBudget(self: *Session, n: usize) Error!void {
        const max = self.options.max_out_bytes;
        if (n > max or self.out.total > max - n) return error.WouldBlock;
    }

    fn writeHeaderBlock(
        self: *Session,
        allocator: Allocator,
        id: u31,
        block: []const u8,
        end_stream: bool,
    ) Error!void {
        var offset: usize = 0;
        var first = true;
        while (true) {
            const len = @min(block.len - offset, out_frame_payload);
            const fragment = block[offset..][0..len];
            offset += len;
            const last = offset == block.len;

            var frame_flags: u8 = 0;
            if (first and end_stream) frame_flags |= frame.flags.end_stream;
            if (last) frame_flags |= frame.flags.end_headers;

            try self.appendFrame(
                allocator,
                if (first) .headers else .continuation,
                frame_flags,
                id,
                fragment,
            );
            if (last) break;
            first = false;
        }
    }

    fn grant(self: *Session, allocator: Allocator, id: u31, count: u32) Error!void {
        try self.release(allocator, id, count);
    }

    /// Return a discarded DATA frame's bytes to the connection window, with a
    /// WINDOW_UPDATE the peer can see. A stream being reset keeps no stream
    /// window; the connection window is the one that must not stall.
    fn grantConnection(self: *Session, allocator: Allocator, count: u32) Error!void {
        if (count == 0) return;
        const inc: u31 = @intCast(count);
        self.conn_recv.increase(inc) catch return error.FlowControlError;
        var payload: [4]u8 = undefined;
        mem.writeInt(u32, &payload, @as(u32, inc), .big);
        try self.appendFrame(allocator, .window_update, 0, 0, &payload);
    }

    fn rememberClosed(self: *Session, id: u31, reset: bool) void {
        self.closed[self.closed_pos] = .{ .id = id, .reset = reset };
        self.closed_pos = (self.closed_pos + 1) % closed_capacity;
        if (self.closed_len < closed_capacity) self.closed_len += 1;
    }

    fn closedReason(self: *const Session, id: u31) ?bool {
        var index: usize = 0;
        while (index < self.closed_len) : (index += 1) {
            const closed = self.closed[index];
            if (closed.id == id) return closed.reset;
        }
        return null;
    }

    fn isClosedStream(self: *const Session, id: u31) bool {
        const local_parity: u31 = if (self.options.role == .client) 1 else 0;
        if (id & 1 == local_parity) {
            return id < self.ids.local_next;
        }
        return id <= self.ids.last_remote;
    }

    fn removeStream(self: *Session, id: u31, reset: bool) ?Stream {
        const kv = self.streams.fetchRemove(id) orelse return null;
        self.rememberClosed(id, reset);
        switch (kv.value.initiator) {
            .local => self.active_local -= 1,
            .remote => self.active_remote -= 1,
        }
        return kv.value;
    }

    fn failStream(
        self: *Session,
        allocator: Allocator,
        id: u31,
        code: frame.ErrorCode,
    ) Error!?Event {
        const existed = self.streams.contains(id);
        var payload: [4]u8 = undefined;
        mem.writeInt(u32, &payload, @intFromEnum(code), .big);
        try self.appendFrame(allocator, .rst_stream, 0, id, &payload);
        if (!existed) return null;
        _ = self.removeStream(id, true);
        return .{ .reset = .{ .stream_id = id, .code = code, .origin = .local } };
    }

    fn connectionError(self: *Session, allocator: Allocator, code: frame.ErrorCode) Error!?Event {
        if (!self.goaway_sent) {
            var payload: [8]u8 = undefined;
            mem.writeInt(u32, payload[0..4], self.ids.last_remote, .big);
            mem.writeInt(u32, payload[4..8], @intFromEnum(code), .big);
            try self.appendFrame(allocator, .goaway, 0, 0, &payload);
            self.goaway_sent = true;
        }
        self.state = .closed;
        return .{ .connection_error = .{ .code = code } };
    }

    fn compact(self: *Session) void {
        if (self.in_start == 0) return;
        const remaining = self.in_len - self.in_start;
        if (remaining > 0) {
            @memmove(
                self.in_buf[0..remaining],
                self.in_buf[self.in_start..self.in_len],
            );
        }
        self.in_len = remaining;
        self.in_start = 0;
    }

    fn appendFrame(
        self: *Session,
        allocator: Allocator,
        frame_type: frame.FrameType,
        frame_flags: u8,
        stream_id: u31,
        payload: []const u8,
    ) Error!void {
        const total = 9 + payload.len;
        assert(total <= self.frame_buf.len);
        var header: [9]u8 = undefined;
        frame.encodeHeader(&header, .{
            .length = @intCast(payload.len),
            .type = frame_type,
            .flags = frame_flags,
            .stream_id = stream_id,
        });
        @memcpy(self.frame_buf[0..9], &header);
        if (payload.len > 0) @memcpy(self.frame_buf[9..][0..payload.len], payload);
        try self.out.append(allocator, self.frame_buf[0..total]);
    }

    fn queueInitial(self: *Session, allocator: Allocator) Error!void {
        if (self.options.role == .client) try self.out.append(allocator, frame.preface);
        var payload: [6 * 6]u8 = undefined;
        var n: usize = 0;
        putSetting(&payload, &n, .header_table_size, self.options.header_table_size);
        if (self.options.role == .client) putSetting(&payload, &n, .enable_push, 0);
        putSetting(&payload, &n, .max_concurrent_streams, self.local.max_concurrent_streams.?);
        putSetting(&payload, &n, .initial_window_size, self.options.initial_window_size);
        putSetting(&payload, &n, .max_frame_size, self.options.max_frame_size);
        putSetting(&payload, &n, .max_header_list_size, self.options.max_header_list_size);
        try self.appendFrame(allocator, .settings, 0, 0, payload[0..n]);
    }
};

fn putSetting(buf: []u8, n: *usize, id: frame.SettingId, value: u32) void {
    mem.writeInt(u16, buf[n.*..][0..2], @intFromEnum(id), .big);
    mem.writeInt(u32, buf[n.* + 2 ..][0..4], value, .big);
    n.* += 6;
}

fn headerFrameCount(n: usize) usize {
    if (n == 0) return 1;
    return (n + out_frame_payload - 1) / out_frame_payload;
}

fn fieldCount(max_header_list_size: u32) usize {
    const count = @as(usize, max_header_list_size) / 32 + 1;
    return @max(8, @min(count, 1024));
}

fn validateOptions(options: Options) Error!void {
    if (options.max_frame_size < frame.min_max_frame_size or
        options.max_frame_size > frame.max_frame_size_limit) return error.InvalidMaxFrameSize;
    if (options.initial_window_size > 0x7fff_ffff) return error.InvalidInitialWindowSize;
    if (options.header_table_size > 0x7fff_ffff) return error.InvalidHeaderTableSize;
    if (options.max_in_header_block == 0 or options.max_send_header_block == 0) {
        return error.InvalidHeaderBlockSize;
    }
    if (options.max_out_bytes < 1024) return error.InvalidOutputSize;
}

fn transfer(from: *Session, to: *Session) !void {
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = from.send(&buf);
        if (n == 0) break;
        var off: usize = 0;
        while (off < n) {
            const written = to.receive(buf[off..n]);
            if (written == 0) return error.InputStuck;
            off += written;
        }
    }
}

fn drain(session: *Session, allocator: Allocator) !void {
    while (try session.nextEvent(allocator)) |_| {}
}

fn handshake(client: *Session, server: *Session, allocator: Allocator) !void {
    try transfer(client, server);
    try drain(server, allocator);
    try transfer(server, client);
    try drain(client, allocator);
    try transfer(client, server);
    try drain(server, allocator);
    try transfer(server, client);
    try drain(client, allocator);
}

const request_fields = [_]Header{
    .{ .name = ":method", .value = "GET" },
    .{ .name = ":scheme", .value = "http" },
    .{ .name = ":authority", .value = "example.com" },
    .{ .name = ":path", .value = "/" },
};

const response_fields = [_]Header{
    .{ .name = ":status", .value = "200" },
};

test "a client and server complete the settings handshake" {
    var client = try Session.init(testing.allocator, .{ .role = .client });
    defer client.deinit(testing.allocator);
    var server = try Session.init(testing.allocator, .{ .role = .server });
    defer server.deinit(testing.allocator);

    try handshake(&client, &server, testing.allocator);
    try testing.expect(client.settings_received);
    try testing.expect(server.settings_received);
    try testing.expect(!client.hasPendingOutput());
    try testing.expect(!server.hasPendingOutput());
}

test "a bad preface is a connection error" {
    var server = try Session.init(testing.allocator, .{ .role = .server });
    defer server.deinit(testing.allocator);

    var bad = frame.preface.*;
    bad[0] = 'X';
    try testing.expectEqual(bad.len, server.receive(&bad));
    const event = (try server.nextEvent(testing.allocator)).?;
    switch (event) {
        .connection_error => |err| try testing.expectEqual(
            frame.ErrorCode.protocol_error,
            err.code,
        ),
        else => return error.TestUnexpectedResult,
    }
    try testing.expect(server.isClosed());
    var out: [128]u8 = undefined;
    try testing.expect(server.send(&out) > 0);
}

test "the first frame must be SETTINGS" {
    var server = try Session.init(testing.allocator, .{ .role = .server });
    defer server.deinit(testing.allocator);

    _ = server.receive(frame.preface);
    var ping: [8]u8 = @splat(0);
    var buf: [32]u8 = undefined;
    var writer = frame.Writer.init(&buf);
    try writer.begin(.ping, 0, 0);
    try writer.bytes(&ping);
    writer.end();
    _ = server.receive(writer.written());

    const event = (try server.nextEvent(testing.allocator)).?;
    switch (event) {
        .connection_error => |err| try testing.expectEqual(
            frame.ErrorCode.protocol_error,
            err.code,
        ),
        else => return error.TestUnexpectedResult,
    }
}

test "a request and response cross the session" {
    var client = try Session.init(testing.allocator, .{ .role = .client });
    defer client.deinit(testing.allocator);
    var server = try Session.init(testing.allocator, .{ .role = .server });
    defer server.deinit(testing.allocator);
    try handshake(&client, &server, testing.allocator);

    const id = try client.submitRequest(testing.allocator, &request_fields, true);
    try testing.expectEqual(@as(u31, 1), id);
    try transfer(&client, &server);

    const request_event = (try server.nextEvent(testing.allocator)).?;
    switch (request_event) {
        .request => |request| {
            try testing.expectEqual(@as(u31, 1), request.stream_id);
            try testing.expectEqualStrings("/", request.head.path.?);
            try testing.expect(request.end_stream);
        },
        else => return error.TestUnexpectedResult,
    }

    try server.submitResponse(testing.allocator, id, &response_fields, true);
    try transfer(&server, &client);

    const response_event = (try client.nextEvent(testing.allocator)).?;
    switch (response_event) {
        .response => |response| {
            try testing.expectEqual(@as(u31, 1), response.stream_id);
            try testing.expectEqual(@as(u16, 200), response.head.status.code());
            try testing.expect(response.end_stream);
        },
        else => return error.TestUnexpectedResult,
    }

    try testing.expectEqual(@as(usize, 0), client.streams.count());
    try testing.expectEqual(@as(usize, 0), server.streams.count());
}

test "DATA respects flow control and carries END_STREAM" {
    var client = try Session.init(testing.allocator, .{ .role = .client });
    defer client.deinit(testing.allocator);
    var server = try Session.init(testing.allocator, .{ .role = .server });
    defer server.deinit(testing.allocator);
    try handshake(&client, &server, testing.allocator);

    const id = try client.submitRequest(testing.allocator, &request_fields, true);
    try transfer(&client, &server);
    _ = (try server.nextEvent(testing.allocator)).?;

    try server.submitResponse(testing.allocator, id, &response_fields, false);
    try transfer(&server, &client);
    _ = (try client.nextEvent(testing.allocator)).?;

    const accepted = try server.submitData(testing.allocator, id, "hello", true);
    try testing.expectEqual(@as(usize, 5), accepted);
    try transfer(&server, &client);

    const event = (try client.nextEvent(testing.allocator)).?;
    switch (event) {
        .data => |data| {
            try testing.expectEqualStrings("hello", data.bytes);
            try testing.expect(data.end_stream);
        },
        else => return error.TestUnexpectedResult,
    }
    try testing.expectEqual(@as(usize, 0), server.streams.count());
    try testing.expectEqual(@as(usize, 0), client.streams.count());
}

test "trailers end the response" {
    var client = try Session.init(testing.allocator, .{ .role = .client });
    defer client.deinit(testing.allocator);
    var server = try Session.init(testing.allocator, .{ .role = .server });
    defer server.deinit(testing.allocator);
    try handshake(&client, &server, testing.allocator);

    const id = try client.submitRequest(testing.allocator, &request_fields, true);
    try transfer(&client, &server);
    _ = (try server.nextEvent(testing.allocator)).?;

    try server.submitResponse(testing.allocator, id, &response_fields, false);
    try transfer(&server, &client);
    _ = (try client.nextEvent(testing.allocator)).?;

    const trailers = [_]Header{.{ .name = "x-check", .value = "done" }};
    try server.submitTrailers(testing.allocator, id, &trailers);
    try transfer(&server, &client);

    const event = (try client.nextEvent(testing.allocator)).?;
    switch (event) {
        .trailers => |t| {
            try testing.expectEqualStrings("x-check", t.headers.items[0].name);
            try testing.expect(t.end_stream);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "RST_STREAM reaches the peer as a reset event" {
    var client = try Session.init(testing.allocator, .{ .role = .client });
    defer client.deinit(testing.allocator);
    var server = try Session.init(testing.allocator, .{ .role = .server });
    defer server.deinit(testing.allocator);
    try handshake(&client, &server, testing.allocator);

    const id = try client.submitRequest(testing.allocator, &request_fields, true);
    try transfer(&client, &server);
    _ = (try server.nextEvent(testing.allocator)).?;

    try client.submitReset(testing.allocator, id, .cancel);
    try transfer(&client, &server);
    const event = (try server.nextEvent(testing.allocator)).?;
    switch (event) {
        .reset => |reset| {
            try testing.expectEqual(frame.ErrorCode.cancel, reset.code);
            try testing.expectEqual(Origin.remote, reset.origin);
        },
        else => return error.TestUnexpectedResult,
    }
    try testing.expectEqual(@as(usize, 0), server.streams.count());
}

test "release returns DATA bytes to both windows" {
    var client = try Session.init(testing.allocator, .{ .role = .client });
    defer client.deinit(testing.allocator);
    var server = try Session.init(testing.allocator, .{ .role = .server });
    defer server.deinit(testing.allocator);
    try handshake(&client, &server, testing.allocator);

    const id = try client.submitRequest(testing.allocator, &request_fields, true);
    try transfer(&client, &server);
    _ = (try server.nextEvent(testing.allocator)).?;
    try server.submitResponse(testing.allocator, id, &response_fields, false);
    try transfer(&server, &client);
    _ = (try client.nextEvent(testing.allocator)).?;

    try testing.expectEqual(
        @as(usize, 4),
        try server.submitData(testing.allocator, id, "body", false),
    );
    try transfer(&server, &client);
    const data = (try client.nextEvent(testing.allocator)).?;
    switch (data) {
        .data => |d| try testing.expectEqualStrings("body", d.bytes),
        else => return error.TestUnexpectedResult,
    }

    try client.release(testing.allocator, id, 4);
    try transfer(&client, &server);
    const first = (try server.nextEvent(testing.allocator)).?;
    switch (first) {
        .window_update => |w| try testing.expectEqual(@as(u31, 0), w.stream_id),
        else => return error.TestUnexpectedResult,
    }
    const second = (try server.nextEvent(testing.allocator)).?;
    switch (second) {
        .window_update => |w| try testing.expectEqual(id, w.stream_id),
        else => return error.TestUnexpectedResult,
    }
}

test "the output queue reserves capacity without skipping the write cursor" {
    var queue: OutQueue = .{};
    defer queue.deinit(testing.allocator);

    try queue.append(testing.allocator, "a");
    try queue.ensure(testing.allocator, out_chunk_size * 3);
    try queue.append(testing.allocator, "b");

    var small: [2]u8 = undefined;
    try testing.expectEqual(@as(usize, 2), queue.send(&small));
    try testing.expectEqualStrings("ab", &small);

    var bytes: [out_chunk_size * 2 + 17]u8 = undefined;
    for (&bytes, 0..) |*byte, index| byte.* = @intCast(index % 251);
    try queue.append(testing.allocator, &bytes);

    var sent: [out_chunk_size * 2 + 17]u8 = undefined;
    var offset: usize = 0;
    while (offset < sent.len) {
        offset += queue.send(sent[offset..]);
    }
    try testing.expectEqualSlices(u8, &bytes, &sent);
    try testing.expectEqual(@as(usize, 0), queue.total);
}

test "PING is acknowledged and GOAWAY is delivered" {
    var client = try Session.init(testing.allocator, .{ .role = .client });
    defer client.deinit(testing.allocator);
    var server = try Session.init(testing.allocator, .{ .role = .server });
    defer server.deinit(testing.allocator);
    try handshake(&client, &server, testing.allocator);

    const ping: [8]u8 = .{ 1, 2, 3, 4, 5, 6, 7, 8 };
    try client.submitPing(testing.allocator, &ping);
    try transfer(&client, &server);
    try testing.expect((try server.nextEvent(testing.allocator)) == null);
    try testing.expect(server.hasPendingOutput());
    try transfer(&server, &client);
    try testing.expect((try client.nextEvent(testing.allocator)) == null);

    try client.submitGoaway(testing.allocator, .no_error);
    try transfer(&client, &server);
    const event = (try server.nextEvent(testing.allocator)).?;
    switch (event) {
        .goaway => |goaway| try testing.expectEqual(frame.ErrorCode.no_error, goaway.code),
        else => return error.TestUnexpectedResult,
    }
    try testing.expectError(error.ConnectionClosed, client.submitRequest(
        testing.allocator,
        &request_fields,
        true,
    ));
}

test "a small initial window makes submitData accept a prefix" {
    var client = try Session.init(testing.allocator, .{
        .role = .client,
        .initial_window_size = 10,
    });
    defer client.deinit(testing.allocator);
    var server = try Session.init(testing.allocator, .{
        .role = .server,
        .initial_window_size = 10,
    });
    defer server.deinit(testing.allocator);
    try handshake(&client, &server, testing.allocator);

    const id = try client.submitRequest(testing.allocator, &request_fields, true);
    try transfer(&client, &server);
    _ = (try server.nextEvent(testing.allocator)).?;
    try server.submitResponse(testing.allocator, id, &response_fields, false);
    try transfer(&server, &client);
    _ = (try client.nextEvent(testing.allocator)).?;

    const accepted = try server.submitData(testing.allocator, id, "0123456789abcde", false);
    try testing.expectEqual(@as(usize, 10), accepted);
    try transfer(&server, &client);
    const data = (try client.nextEvent(testing.allocator)).?;
    switch (data) {
        .data => |d| try testing.expectEqualStrings("0123456789", d.bytes),
        else => return error.TestUnexpectedResult,
    }

    try client.release(testing.allocator, id, 10);
    try transfer(&client, &server);
    _ = (try server.nextEvent(testing.allocator)).?;
    _ = (try server.nextEvent(testing.allocator)).?;

    try testing.expectEqual(
        @as(usize, 5),
        try server.submitData(testing.allocator, id, "abcde", true),
    );
    try transfer(&server, &client);
    const rest = (try client.nextEvent(testing.allocator)).?;
    switch (rest) {
        .data => |d| {
            try testing.expectEqualStrings("abcde", d.bytes);
            try testing.expect(d.end_stream);
        },
        else => return error.TestUnexpectedResult,
    }
}

fn takeFrame(session: *Session, buf: []u8) !frame.Parsed {
    const n = session.send(buf);
    try testing.expect(n > 0);
    return frame.parse(buf[0..n], frame.default_max_frame_size);
}

test "a closed stream rejects DATA with STREAM_CLOSED" {
    var client = try Session.init(testing.allocator, .{ .role = .client });
    defer client.deinit(testing.allocator);
    var server = try Session.init(testing.allocator, .{ .role = .server });
    defer server.deinit(testing.allocator);
    try handshake(&client, &server, testing.allocator);

    const id = try client.submitRequest(testing.allocator, &request_fields, true);
    try transfer(&client, &server);
    _ = (try server.nextEvent(testing.allocator)).?;
    try server.submitResponse(testing.allocator, id, &response_fields, true);
    try transfer(&server, &client);
    _ = (try client.nextEvent(testing.allocator)).?;

    var raw: [32]u8 = undefined;
    var writer = frame.Writer.init(&raw);
    try writer.begin(.data, 0, id);
    try writer.bytes("x");
    writer.end();
    _ = server.receive(writer.written());
    try testing.expect((try server.nextEvent(testing.allocator)) == null);

    var out: [13]u8 = undefined;
    const parsed = try takeFrame(&server, &out);
    const body = try frame.body(parsed.header, parsed.payload);
    try testing.expectEqual(frame.FrameType.rst_stream, parsed.header.type);
    try testing.expectEqual(frame.ErrorCode.stream_closed, body.rst_stream.error_code);

    const update = try takeFrame(&server, &out);
    const update_body = try frame.body(update.header, update.payload);
    try testing.expectEqual(frame.FrameType.window_update, update.header.type);
    try testing.expectEqual(@as(u31, 0), update.header.stream_id);
    try testing.expectEqual(@as(u31, 1), update_body.window_update.increment);
    try testing.expectEqual(@as(i64, 65_535), server.conn_recv.available);
}

test "a refused stream keeps its DATA out of the connection" {
    var client = try Session.init(testing.allocator, .{
        .role = .client,
        .max_streams = 1,
    });
    defer client.deinit(testing.allocator);
    var server = try Session.init(testing.allocator, .{
        .role = .server,
        .max_streams = 1,
    });
    defer server.deinit(testing.allocator);
    try handshake(&client, &server, testing.allocator);

    _ = try client.submitRequest(testing.allocator, &request_fields, false);
    try transfer(&client, &server);
    _ = (try server.nextEvent(testing.allocator)).?;

    var raw: [32]u8 = undefined;
    var writer = frame.Writer.init(&raw);
    try writer.begin(.headers, frame.flags.end_headers, 3);
    writer.end();
    _ = server.receive(writer.written());
    try testing.expect((try server.nextEvent(testing.allocator)) == null);

    var out: [13]u8 = undefined;
    const refused = try takeFrame(&server, &out);
    const refused_body = try frame.body(refused.header, refused.payload);
    try testing.expectEqual(
        frame.ErrorCode.refused_stream,
        refused_body.rst_stream.error_code,
    );

    writer = frame.Writer.init(&raw);
    try writer.begin(.data, 0, 3);
    try writer.bytes("x");
    writer.end();
    _ = server.receive(writer.written());
    try testing.expect((try server.nextEvent(testing.allocator)) == null);
    try testing.expect(!server.isClosed());

    const reset = try takeFrame(&server, &out);
    const reset_body = try frame.body(reset.header, reset.payload);
    try testing.expectEqual(frame.ErrorCode.stream_closed, reset_body.rst_stream.error_code);
    const update = try takeFrame(&server, &out);
    const update_body = try frame.body(update.header, update.payload);
    try testing.expectEqual(frame.FrameType.window_update, update.header.type);
    try testing.expectEqual(@as(u31, 1), update_body.window_update.increment);
}

test "a normal closed stream rejects HEADERS as a connection error" {
    var client = try Session.init(testing.allocator, .{ .role = .client });
    defer client.deinit(testing.allocator);
    var server = try Session.init(testing.allocator, .{ .role = .server });
    defer server.deinit(testing.allocator);
    try handshake(&client, &server, testing.allocator);

    const id = try client.submitRequest(testing.allocator, &request_fields, true);
    try transfer(&client, &server);
    _ = (try server.nextEvent(testing.allocator)).?;
    try server.submitResponse(testing.allocator, id, &response_fields, true);
    try transfer(&server, &client);
    _ = (try client.nextEvent(testing.allocator)).?;

    var raw: [32]u8 = undefined;
    var writer = frame.Writer.init(&raw);
    try writer.begin(.headers, frame.flags.end_headers, id);
    writer.end();
    _ = server.receive(writer.written());

    const event = (try server.nextEvent(testing.allocator)).?;
    switch (event) {
        .connection_error => |err| try testing.expectEqual(frame.ErrorCode.stream_closed, err.code),
        else => return error.TestUnexpectedResult,
    }
}

test "a reset stream rejects HEADERS with STREAM_CLOSED" {
    var client = try Session.init(testing.allocator, .{ .role = .client });
    defer client.deinit(testing.allocator);
    var server = try Session.init(testing.allocator, .{ .role = .server });
    defer server.deinit(testing.allocator);
    try handshake(&client, &server, testing.allocator);

    const id = try client.submitRequest(testing.allocator, &request_fields, true);
    try transfer(&client, &server);
    _ = (try server.nextEvent(testing.allocator)).?;
    try client.submitReset(testing.allocator, id, .cancel);
    try transfer(&client, &server);
    _ = (try server.nextEvent(testing.allocator)).?;

    var raw: [32]u8 = undefined;
    var writer = frame.Writer.init(&raw);
    try writer.begin(.headers, frame.flags.end_headers, id);
    writer.end();
    _ = server.receive(writer.written());
    try testing.expect((try server.nextEvent(testing.allocator)) == null);

    var out: [64]u8 = undefined;
    const parsed = try takeFrame(&server, &out);
    const body = try frame.body(parsed.header, parsed.payload);
    try testing.expectEqual(frame.FrameType.rst_stream, parsed.header.type);
    try testing.expectEqual(frame.ErrorCode.stream_closed, body.rst_stream.error_code);
}

test "a PRIORITY self-dependency is a stream error" {
    var client = try Session.init(testing.allocator, .{ .role = .client });
    defer client.deinit(testing.allocator);
    var server = try Session.init(testing.allocator, .{ .role = .server });
    defer server.deinit(testing.allocator);
    try handshake(&client, &server, testing.allocator);

    const id = try client.submitRequest(testing.allocator, &request_fields, false);
    try transfer(&client, &server);
    _ = (try server.nextEvent(testing.allocator)).?;

    var raw: [16]u8 = undefined;
    var writer = frame.Writer.init(&raw);
    try writer.begin(.priority, 0, id);
    try writer.int(u32, id);
    try writer.byte(0);
    writer.end();
    _ = server.receive(writer.written());

    const event = (try server.nextEvent(testing.allocator)).?;
    switch (event) {
        .reset => |reset| try testing.expectEqual(frame.ErrorCode.protocol_error, reset.code),
        else => return error.TestUnexpectedResult,
    }
}

test "trailers without END_STREAM are a stream error" {
    var client = try Session.init(testing.allocator, .{ .role = .client });
    defer client.deinit(testing.allocator);
    var server = try Session.init(testing.allocator, .{ .role = .server });
    defer server.deinit(testing.allocator);
    try handshake(&client, &server, testing.allocator);

    const id = try client.submitRequest(testing.allocator, &request_fields, false);
    try transfer(&client, &server);
    _ = (try server.nextEvent(testing.allocator)).?;

    var raw: [16]u8 = undefined;
    var writer = frame.Writer.init(&raw);
    try writer.begin(.headers, frame.flags.end_headers, id);
    writer.end();
    _ = server.receive(writer.written());

    const event = (try server.nextEvent(testing.allocator)).?;
    switch (event) {
        .reset => |reset| try testing.expectEqual(frame.ErrorCode.protocol_error, reset.code),
        else => return error.TestUnexpectedResult,
    }
}

test "a SETTINGS update is visible to the application" {
    var client = try Session.init(testing.allocator, .{ .role = .client });
    defer client.deinit(testing.allocator);
    var server = try Session.init(testing.allocator, .{ .role = .server });
    defer server.deinit(testing.allocator);
    try handshake(&client, &server, testing.allocator);

    var raw: [16]u8 = undefined;
    var writer = frame.Writer.init(&raw);
    try writer.begin(.settings, 0, 0);
    try writer.int(u16, @intFromEnum(frame.SettingId.initial_window_size));
    try writer.int(u32, 100);
    writer.end();
    _ = server.receive(writer.written());

    const event = (try server.nextEvent(testing.allocator)).?;
    switch (event) {
        .settings => |values| try testing.expectEqual(@as(u32, 100), values.initial_window_size),
        else => return error.TestUnexpectedResult,
    }
}

test "a local SETTINGS change adjusts receive windows and sends a frame" {
    var client = try Session.init(testing.allocator, .{ .role = .client });
    defer client.deinit(testing.allocator);

    const id = try client.submitRequest(testing.allocator, &request_fields, true);
    var discard: [1024]u8 = undefined;
    while (client.send(&discard) > 0) {}

    try client.submitSettings(testing.allocator, &.{
        .{ .id = .initial_window_size, .value = 100 },
    });
    try testing.expectEqual(@as(u32, 100), client.local.initial_window_size);
    try testing.expectEqual(@as(i64, 100), client.streams.get(id).?.recv.available);

    var out: [64]u8 = undefined;
    const parsed = try takeFrame(&client, &out);
    try testing.expectEqual(frame.FrameType.settings, parsed.header.type);
    const body = try frame.body(parsed.header, parsed.payload);
    var entries = body.settings.iterator();
    const entry = entries.next().?;
    try testing.expectEqual(frame.SettingId.initial_window_size, entry.id);
    try testing.expectEqual(@as(u32, 100), entry.value);
    try testing.expect(entries.next() == null);
}

test "local SETTINGS cannot exceed the allocated resources" {
    var server = try Session.init(testing.allocator, .{ .role = .server });
    defer server.deinit(testing.allocator);

    try testing.expectError(error.InvalidSetting, server.submitSettings(
        testing.allocator,
        &.{.{ .id = .enable_push, .value = 0 }},
    ));
    try testing.expectError(error.SettingsTooLarge, server.submitSettings(
        testing.allocator,
        &.{.{ .id = .max_frame_size, .value = 32_768 }},
    ));
    try testing.expectError(error.SettingsTooLarge, server.submitSettings(
        testing.allocator,
        &.{.{ .id = .header_table_size, .value = 4097 }},
    ));

    var client = try Session.init(testing.allocator, .{ .role = .client });
    defer client.deinit(testing.allocator);
    const id = try client.submitRequest(testing.allocator, &request_fields, true);
    client.streams.getPtr(id).?.recv.increase(0x7fff_ffff - 65_535) catch unreachable;
    try testing.expectError(error.FlowControlError, client.submitSettings(
        testing.allocator,
        &.{.{ .id = .initial_window_size, .value = 0x7fff_ffff }},
    ));
    try testing.expectEqual(@as(u32, 65_535), client.local.initial_window_size);
}

test "a malformed HPACK block is a connection error" {
    var server = try Session.init(testing.allocator, .{ .role = .server });
    defer server.deinit(testing.allocator);
    var client = try Session.init(testing.allocator, .{ .role = .client });
    defer client.deinit(testing.allocator);
    try handshake(&client, &server, testing.allocator);

    var raw: [16]u8 = undefined;
    var writer = frame.Writer.init(&raw);
    try writer.begin(.headers, frame.flags.end_headers, 1);
    try writer.byte(0);
    writer.end();
    _ = server.receive(writer.written());

    const event = (try server.nextEvent(testing.allocator)).?;
    switch (event) {
        .connection_error => |err| try testing.expectEqual(
            frame.ErrorCode.compression_error,
            err.code,
        ),
        else => return error.TestUnexpectedResult,
    }
}

const fuzz_settings_frame = "\x00\x00\x00\x04\x00\x00\x00\x00\x00";

test "fuzz session input never panics" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) anyerror!void {
            var session = try Session.init(testing.allocator, .{ .role = .server });
            defer session.deinit(testing.allocator);

            var input: [512]u8 = undefined;
            const len = smith.slice(&input);
            var offset: usize = 0;
            while (offset < len) {
                const chunk = @min(
                    len - offset,
                    @as(usize, smith.valueRangeAtMost(u16, 1, 64)),
                );
                const consumed = session.receive(input[offset..][0..chunk]);
                if (consumed == 0) break;
                offset += consumed;
                while (try session.nextEvent(testing.allocator)) |_| {}
                var out: [256]u8 = undefined;
                while (session.send(&out) > 0) {}
                if (session.isClosed()) return;
            }
            while (try session.nextEvent(testing.allocator)) |_| {}
            var out: [256]u8 = undefined;
            while (session.send(&out) > 0) {}
        }
    }.run, .{ .corpus = &.{
        "",
        frame.preface,
        frame.preface ++ fuzz_settings_frame,
        frame.preface ++ fuzz_settings_frame ++ "\x00\x00\x00\x01\x00\x00\x00\x00\x00",
    } });
}

test "fuzz session submissions never panic" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) anyerror!void {
            var client = try Session.init(testing.allocator, .{ .role = .client });
            defer client.deinit(testing.allocator);
            var server = try Session.init(testing.allocator, .{ .role = .server });
            defer server.deinit(testing.allocator);
            try handshake(&client, &server, testing.allocator);

            var stream_id: ?u31 = null;
            const steps = smith.valueRangeAtMost(u8, 1, 16);
            for (0..steps) |_| {
                switch (smith.valueRangeAtMost(u8, 0, 4)) {
                    0 => {
                        if (stream_id == null) {
                            stream_id = client.submitRequest(
                                testing.allocator,
                                &request_fields,
                                smith.valueRangeAtMost(u8, 0, 1) == 1,
                            ) catch null;
                        }
                    },
                    1 => {
                        if (stream_id) |id| {
                            var data_buf: [32]u8 = undefined;
                            const n = smith.slice(&data_buf);
                            _ = client.submitData(
                                testing.allocator,
                                id,
                                data_buf[0..n],
                                smith.valueRangeAtMost(u8, 0, 1) == 1,
                            ) catch |err| {
                                if (err == error.OutOfMemory) return err;
                                _ = @errorName(err);
                            };
                        }
                    },
                    2 => {
                        if (stream_id) |id| {
                            client.submitReset(testing.allocator, id, .cancel) catch |err| {
                                _ = @errorName(err);
                                // The stream may already be closed.
                            };
                        }
                    },
                    3 => {
                        const ping: [8]u8 = @splat(0);
                        client.submitPing(testing.allocator, &ping) catch |err| {
                            _ = @errorName(err);
                        };
                    },
                    4 => {
                        client.submitSettings(testing.allocator, &.{
                            .{
                                .id = .initial_window_size,
                                .value = smith.valueRangeAtMost(u32, 0, 65_535),
                            },
                        }) catch |err| {
                            _ = @errorName(err);
                            // The peer may have stopped reading.
                        };
                    },
                    else => unreachable,
                }
                try transfer(&client, &server);
                while (try server.nextEvent(testing.allocator)) |_| {}
                try transfer(&server, &client);
                while (try client.nextEvent(testing.allocator)) |_| {}
            }
        }
    }.run, .{ .corpus = &.{} });
}

test "HEADERS on a half-closed remote stream is STREAM_CLOSED" {
    var client = try Session.init(testing.allocator, .{ .role = .client });
    defer client.deinit(testing.allocator);
    var server = try Session.init(testing.allocator, .{ .role = .server });
    defer server.deinit(testing.allocator);
    try handshake(&client, &server, testing.allocator);

    const id = try client.submitRequest(testing.allocator, &request_fields, true);
    try transfer(&client, &server);
    _ = (try server.nextEvent(testing.allocator)).?;

    var raw: [16]u8 = undefined;
    var writer = frame.Writer.init(&raw);
    try writer.begin(
        .headers,
        frame.flags.end_headers | frame.flags.end_stream,
        id,
    );
    writer.end();
    _ = server.receive(writer.written());

    const event = (try server.nextEvent(testing.allocator)).?;
    switch (event) {
        .reset => |reset| try testing.expectEqual(frame.ErrorCode.stream_closed, reset.code),
        else => return error.TestUnexpectedResult,
    }
}
