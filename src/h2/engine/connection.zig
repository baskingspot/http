//! The sans-I/O HTTP/2 exchange engine shared by the transports.
//!
//! The connection owns the session, the fixed slot table, the per-stream
//! arenas, and the handler. A transport feeds bytes with `receive`, calls
//! `drive` to deliver events and queue responses, and drains `send`. It never
//! touches a socket. `blocking` and the readiness engines are thin drivers
//! around this type.
//!
//! `Options.body_mode` chooses when the handler runs. `.buffered` (the
//! default) waits for END_STREAM and hands over the whole body, which is what
//! a request/response server wants. `.stream` runs the handler on the request
//! head and gives it `Exchange.request_body` plus the push response API, so it
//! can answer before the body ends. The handler is re-entered on each turn
//! rather than parked on a stack frame; see `h2.engine.common`.

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const testing = std.testing;

const time = @import("stdx").time;

const compat = @import("../../compat.zig");
const shared = @import("../../engine/common.zig");
const Header = @import("../../header.zig").Header;
const Headers = @import("../../header.zig").Headers;
const frame = @import("../frame.zig");
const head = @import("../head.zig");
const session_mod = @import("../session.zig");
const Session = session_mod.Session;
const SessionOptions = session_mod.Options;
const Event = session_mod.Event;
const common = @import("common.zig");
pub const Exchange = common.Exchange;
pub const Handler = common.Handler;
pub const Request = common.Request;
pub const ResponseOptions = common.ResponseOptions;

pub const BodyMode = enum {
    /// Run the handler once, with the whole request body.
    buffered,
    /// Run the handler on the request head; it reads the body with
    /// `Exchange.request_body` and may respond before END_STREAM.
    stream,
};

// ast-grep-ignore: public-struct-field-default -- options bag; defaults are the policy
pub const Options = struct {
    allocator: Allocator,
    handler: Handler,
    max_streams: u16 = 128,
    body_bytes: usize = 64 * 1024,
    arena_retain_bytes: usize = 4 * 1024,
    session: SessionOptions = .{ .role = .server },
    /// Time from accept until the first request head; zero disables.
    head_timeout: Io.Duration = .zero,
    /// Time from a request head to its END_STREAM; zero disables.
    body_timeout: Io.Duration = .zero,
    /// When the handler runs, and therefore whether the body is buffered.
    body_mode: BodyMode = .buffered,
};

const Slot = struct {
    used: bool = false,
    stream_id: u31 = 0,
    arena: ArenaAllocator,
    /// `.buffered`: the whole request body.
    body: std.ArrayList(u8) = .empty,
    /// `.stream`: body bytes received and not yet handed to the handler.
    unread: std.ArrayList(u8) = .empty,
    /// `.stream`: the chunk the handler holds, valid until the next `next`.
    /// The two buffers swap per chunk, so consumed bytes are reusable and the
    /// memory is bounded by two chunks, not by the whole upload.
    chunk: std.ArrayList(u8) = .empty,
    /// `.stream`: flow-control charge for `chunk`.
    chunk_flow: u32 = 0,
    request_head: ?head.RequestHead = null,
    trailers: Headers = .{ .items = &.{} },
    content_length: ?u64 = null,
    received: u64 = 0,
    request_complete: bool = false,
    handler_called: bool = false,
    /// `.stream`: the handler asked for another turn when something changes.
    parked: bool = false,
    /// The handler's absolute awake-clock deadline, or `.none`.
    deadline: time.OptionalTimestamp = .none,
    /// A response head is queued.
    response_started: bool = false,
    /// The response head and body are queued by `pumpAll`, not by the sink.
    reply: ?Exchange.Response = null,
    headers_sent: bool = false,
    trailers_sent: bool = false,
    body_offset: usize = 0,
    /// `.stream`: the response ends after `end_trailers`, in `pumpAll`.
    response_ended: bool = false,
    end_sent: bool = false,
    end_trailers: Headers = .{ .items = &.{} },
    /// `.stream`: the handler queued RST_STREAM.
    reset_pending: bool = false,
    /// The peer's RST_STREAM code, if the stream was reset.
    reset_code: ?u32 = null,
    /// The handler's own per-exchange state. The engine never reads it.
    context: ?*anyopaque = null,
    sink: SlotSink = undefined,
    reader: SlotReader = undefined,
    body_deadline: time.OptionalTimestamp = .none,
    exchange: Exchange = undefined,
};

/// The engine behind `Exchange.beginResponse`, `write`, `endResponse`, and
/// `resetStream`. One per slot; the slots slice never moves.
const SlotSink = struct {
    connection: *Connection,
    index: usize,

    fn sink(self: *SlotSink) common.Sink {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: common.Sink.VTable = .{
        .buffered = buffered,
        .begin = begin,
        .write = write,
        .end = end,
        .reset = reset,
    };

    fn target(self: *SlotSink) *Slot {
        return &self.connection.slots[self.index];
    }

    fn buffered(
        ptr: *anyopaque,
        options: ResponseOptions,
        body: []const u8,
    ) common.Sink.SinkError!void {
        const self: *SlotSink = @ptrCast(@alignCast(ptr));
        const slot = self.target();
        if (slot.response_started) return error.ResponseEnded;
        slot.response_started = true;
        // The response is under way. A handler that armed its own deadline
        // finishes it; the engine's body timeout must not reset it first.
        slot.body_deadline = .none;
        slot.reply = .{ .options = options, .body = body };
    }

    fn begin(ptr: *anyopaque, options: ResponseOptions) common.Sink.SinkError!void {
        const self: *SlotSink = @ptrCast(@alignCast(ptr));
        const slot = self.target();
        if (slot.response_started) return error.ResponseEnded;
        self.connection.session.submitResponse(
            self.connection.allocator,
            slot.stream_id,
            .{
                .status = options.status,
                .content_type = options.content_type,
                .content_length = null,
                .headers = options.headers,
            },
            false,
        ) catch |err| return mapSession(err);
        slot.response_started = true;
        slot.headers_sent = true;
        slot.body_deadline = .none;
    }

    fn write(ptr: *anyopaque, bytes: []const u8) common.Sink.SinkError!usize {
        const self: *SlotSink = @ptrCast(@alignCast(ptr));
        const slot = self.target();
        if (!slot.headers_sent) return error.ResponseNotStarted;
        return self.connection.session.submitData(
            self.connection.allocator,
            slot.stream_id,
            bytes,
            false,
        ) catch |err| return mapSession(err);
    }

    fn end(ptr: *anyopaque, trailers: []const Header) common.Sink.SinkError!void {
        const self: *SlotSink = @ptrCast(@alignCast(ptr));
        const slot = self.target();
        if (slot.response_ended) return error.ResponseEnded;
        // The end frame is queued by `pumpAll`, after this handler returns, so
        // a full output budget cannot make the last byte of the response a
        // retryable failure.
        slot.end_trailers = copyHeaders(slot.arena.allocator(), .{ .items = trailers }) catch
            return error.OutOfMemory;
        slot.response_ended = true;
    }

    fn reset(ptr: *anyopaque, code: frame.ErrorCode) common.Sink.SinkError!void {
        const self: *SlotSink = @ptrCast(@alignCast(ptr));
        const slot = self.target();
        self.connection.session.submitReset(
            self.connection.allocator,
            slot.stream_id,
            code,
        ) catch |err| return mapSession(err);
        slot.response_ended = true;
        slot.reset_pending = true;
        slot.end_sent = true;
    }
};

/// The request body for a streaming engine: pulls one buffered chunk per
/// `next`. The slot keeps two reusable buffers and swaps them, so the returned
/// slice stays valid until the handler asks for the next one and consumed bytes
/// are not retained. It is not copied into the arena.
const SlotReader = struct {
    connection: *Connection,
    index: usize,
    stream: shared.stream.ReadStream = undefined,

    fn reader(self: *SlotReader) shared.stream.ReadStream {
        self.stream = .{ .ptr = self, .vtable = &vtable };
        return self.stream;
    }

    const vtable: shared.stream.ReadStream.VTable = .{ .next = next, .close = close };

    fn next(ptr: *anyopaque) shared.stream.ReadError!shared.stream.ReadResult {
        const self: *SlotReader = @ptrCast(@alignCast(ptr));
        return self.connection.nextBodyChunk(self.index);
    }

    fn close(_: *anyopaque) void {}
};

pub const Connection = struct {
    allocator: Allocator,
    handler: Handler,
    session: Session,
    slots: []Slot,
    body_bytes: usize,
    arena_retain_bytes: usize,
    body_mode: BodyMode,
    head_timeout: Io.Duration,
    body_timeout: Io.Duration,
    head_deadline: ?Io.Timestamp,

    pub fn init(options: Options) !Connection {
        var session_options = options.session;
        session_options.role = .server;
        session_options.max_streams = options.max_streams;

        var session: Session = try .init(options.allocator, session_options);
        errdefer session.deinit(options.allocator);

        const slots = try options.allocator.alloc(Slot, options.max_streams);
        errdefer options.allocator.free(slots);
        for (slots) |*slot| slot.* = .{ .arena = .init(options.allocator) };

        return .{
            .allocator = options.allocator,
            .handler = options.handler,
            .session = session,
            .slots = slots,
            .body_bytes = options.body_bytes,
            .arena_retain_bytes = options.arena_retain_bytes,
            .body_mode = options.body_mode,
            .head_timeout = options.head_timeout,
            .body_timeout = options.body_timeout,
            .head_deadline = null,
        };
    }

    pub fn deinit(self: *Connection) void {
        self.completeAll();
        for (self.slots) |*slot| {
            slot.unread.deinit(self.allocator);
            slot.chunk.deinit(self.allocator);
            slot.arena.deinit();
        }
        self.allocator.free(self.slots);
        self.session.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn receive(self: *Connection, bytes: []const u8) usize {
        return self.session.receive(bytes);
    }

    pub fn send(self: *Connection, out: []u8) usize {
        const n = self.session.send(out);
        // A handler that parked on a full output budget resumes once any
        // output leaves the queue.
        if (n != 0) {
            for (self.slots) |*slot| {
                if (slot.used) slot.parked = false;
            }
        }
        return n;
    }

    pub fn isClosed(self: *const Connection) bool {
        return self.session.isClosed();
    }

    pub fn hasPendingOutput(self: *const Connection) bool {
        return self.session.hasPendingOutput();
    }

    /// Queue a GOAWAY and leave the connection open for its active streams.
    pub fn beginDrain(self: *Connection) !void {
        if (self.session.isClosed()) return;
        try self.session.submitGoaway(self.allocator, .no_error);
    }

    /// Arm the connection-level head deadline. A zero timeout leaves it unset.
    pub fn start(self: *Connection, now: Io.Timestamp) void {
        if (self.head_timeout.nanoseconds > 0) {
            self.head_deadline = now.addDuration(self.head_timeout);
        }
    }

    /// The earliest deadline this engine enforces itself: head and request
    /// body. A driver closes the connection when this passes. It deliberately
    /// excludes `Exchange.setDeadline`, which belongs to the application.
    pub fn deadline(self: *const Connection) ?Io.Timestamp {
        var at = self.head_deadline;
        for (self.slots) |*slot| {
            if (!slot.used) continue;
            if (slot.body_deadline.get()) |body_deadline| {
                at = earliest(at, body_deadline.toStd());
            }
        }
        return at;
    }

    /// The earliest deadline a handler armed through `Exchange.setDeadline`.
    /// A driver uses it only to pick a wakeup time and then calls `drive`,
    /// which delivers `wake = .expired`. It is never a reason to close.
    pub fn wakeDeadline(self: *const Connection) ?Io.Timestamp {
        var at: ?Io.Timestamp = null;
        for (self.slots) |*slot| {
            if (!slot.used) continue;
            const wake_at = slot.deadline.get() orelse continue;
            const value = wake_at.toStd();
            at = if (at) |current| earliest(current, value) else value;
        }
        return at;
    }

    /// Deliver every complete event currently buffered, run the handlers whose
    /// turn it is, and queue as much response output as flow control accepts.
    /// Returns whether anything happened.
    pub fn drive(self: *Connection, now: Io.Timestamp) !bool {
        if (self.session.isClosed()) return false;

        var progressed = false;
        while (try self.session.nextEvent(self.allocator)) |event| {
            try self.processEvent(event, now);
            progressed = true;
            if (self.session.isClosed()) break;
        }

        if (!self.session.isClosed()) {
            try self.startReady(now);
        }
        if (try self.pumpAll()) progressed = true;
        return progressed;
    }

    fn processEvent(self: *Connection, event: Event, now: Io.Timestamp) !void {
        switch (event) {
            .request => |request| {
                const slot_index = allocSlotIndex(self.slots) orelse {
                    try self.session.submitReset(
                        self.allocator,
                        request.stream_id,
                        .refused_stream,
                    );
                    return;
                };
                const slot = &self.slots[slot_index];
                slot.used = true;
                slot.stream_id = request.stream_id;
                slot.body = .empty;
                slot.unread.clearRetainingCapacity();
                slot.chunk.clearRetainingCapacity();
                slot.chunk_flow = 0;
                slot.trailers = .{ .items = &.{} };
                slot.received = 0;
                slot.request_complete = request.end_stream;
                slot.handler_called = false;
                slot.parked = false;
                slot.deadline = .none;
                slot.response_started = false;
                slot.reply = null;
                slot.headers_sent = false;
                slot.trailers_sent = false;
                slot.body_offset = 0;
                slot.response_ended = false;
                slot.end_sent = false;
                slot.end_trailers = .{ .items = &.{} };
                slot.reset_pending = false;
                slot.reset_code = null;
                slot.context = null;
                slot.body_deadline = .none;
                self.head_deadline = null;
                if (!request.end_stream and self.body_timeout.nanoseconds > 0) {
                    slot.body_deadline = try .init(
                        try .fromStd(now.addDuration(self.body_timeout)),
                    );
                }

                slot.request_head = copyHead(
                    slot.arena.allocator(),
                    request.head,
                ) catch |err| {
                    try self.session.submitReset(
                        self.allocator,
                        request.stream_id,
                        .internal_error,
                    );
                    self.finishSlot(slot, false);
                    return err;
                };
                slot.content_length = parseContentLength(request.head.headers) catch {
                    try self.session.submitReset(
                        self.allocator,
                        request.stream_id,
                        .protocol_error,
                    );
                    self.finishSlot(slot, false);
                    return;
                };
                // A declared length above the cap is a buffered-mode refusal:
                // there the engine must hold the whole body. A streamed body
                // is bounded by what is unconsumed, not by its total.
                if (self.body_mode == .buffered) {
                    if (slot.content_length) |length| {
                        if (length > self.body_bytes) {
                            try self.session.submitReset(
                                self.allocator,
                                request.stream_id,
                                .enhance_your_calm,
                            );
                            self.finishSlot(slot, false);
                            return;
                        }
                    }
                }
                slot.sink = .{ .connection = self, .index = slot_index };
                slot.reader = .{ .connection = self, .index = slot_index };
            },

            .data => |data| {
                const slot = findSlot(self.slots, data.stream_id) orelse {
                    if (data.bytes.len > 0) {
                        try self.session.release(
                            self.allocator,
                            data.stream_id,
                            @intCast(data.bytes.len),
                        );
                    }
                    return;
                };
                const unconsumed = if (self.body_mode == .buffered)
                    slot.received + data.bytes.len
                else
                    slot.unread.items.len + data.bytes.len;
                if (unconsumed > self.body_bytes) {
                    try self.session.submitReset(
                        self.allocator,
                        data.stream_id,
                        .enhance_your_calm,
                    );
                    if (data.bytes.len > 0) {
                        try self.session.release(
                            self.allocator,
                            data.stream_id,
                            @intCast(data.bytes.len),
                        );
                    }
                    self.finishSlot(slot, slot.handler_called);
                    return;
                }

                const storage = if (self.body_mode == .buffered)
                    slot.arena.allocator()
                else
                    self.allocator;
                if (self.body_mode == .buffered) {
                    slot.body.appendSlice(storage, data.bytes) catch |err| {
                        try self.session.submitReset(
                            self.allocator,
                            data.stream_id,
                            .internal_error,
                        );
                        if (data.bytes.len > 0) {
                            try self.session.release(
                                self.allocator,
                                data.stream_id,
                                @intCast(data.bytes.len),
                            );
                        }
                        self.finishSlot(slot, slot.handler_called);
                        return err;
                    };
                    if (data.bytes.len > 0) {
                        try self.session.release(
                            self.allocator,
                            data.stream_id,
                            @intCast(data.bytes.len),
                        );
                    }
                } else {
                    // The bytes stay charged to both windows until the handler
                    // asks for the next chunk, so a handler that stops reading
                    // stops the peer.
                    slot.unread.appendSlice(storage, data.bytes) catch |err| {
                        try self.session.submitReset(
                            self.allocator,
                            data.stream_id,
                            .internal_error,
                        );
                        if (data.bytes.len > 0) {
                            try self.session.release(
                                self.allocator,
                                data.stream_id,
                                @intCast(data.bytes.len),
                            );
                        }
                        self.finishSlot(slot, slot.handler_called);
                        return err;
                    };
                    if (data.bytes.len != 0) slot.parked = false;
                }
                slot.received += data.bytes.len;
                if (data.end_stream) {
                    slot.request_complete = true;
                    slot.body_deadline = .none;
                    slot.parked = false;
                }
            },

            .trailers => |trailers| {
                const slot = findSlot(self.slots, trailers.stream_id) orelse return;
                slot.trailers = copyHeaders(
                    slot.arena.allocator(),
                    trailers.headers,
                ) catch |err| {
                    try self.session.submitReset(
                        self.allocator,
                        trailers.stream_id,
                        .internal_error,
                    );
                    self.finishSlot(slot, slot.handler_called);
                    return err;
                };
                slot.request_complete = trailers.end_stream;
                slot.parked = false;
                if (trailers.end_stream) slot.body_deadline = .none;
            },

            .reset => |reset| {
                if (findSlot(self.slots, reset.stream_id)) |slot| {
                    slot.reset_code = compatCode(reset.code);
                    self.finishSlot(slot, slot.handler_called);
                }
            },

            .window_update => |update| {
                // A handler parked on a zero write resumes when credit
                // arrives. A connection-level update can open any stream.
                if (update.stream_id == 0) {
                    for (self.slots) |*slot| slot.parked = false;
                } else if (findSlot(self.slots, update.stream_id)) |slot| {
                    slot.parked = false;
                }
            },
            .settings, .goaway, .connection_error, .response => {},
        }
    }

    fn startReady(self: *Connection, now: Io.Timestamp) !void {
        for (self.slots, 0..) |*slot, index| {
            if (!slot.used) continue;
            if (slot.response_ended or slot.reset_pending) continue;
            if (self.body_mode == .buffered) {
                if (!slot.request_complete or slot.handler_called) continue;
            } else if (slot.parked) {
                // A parked handler waits for data, output, or its own deadline.
                const due = if (slot.deadline.get()) |wake_at|
                    now.nanoseconds >= wake_at.nanoseconds
                else
                    false;
                if (!due) continue;
            }

            if (slot.request_complete) {
                if (slot.content_length) |expected| {
                    if (expected != slot.received) {
                        try self.session.submitReset(
                            self.allocator,
                            slot.stream_id,
                            .protocol_error,
                        );
                        self.finishSlot(slot, slot.handler_called);
                        continue;
                    }
                }
            }

            var body: []const u8 = &.{};
            if (self.body_mode == .buffered) body = slot.body.items;
            const request_body = if (self.body_mode == .stream)
                slot.reader.reader()
            else
                null;

            const expired = if (slot.deadline.get()) |wake_at|
                now.nanoseconds >= wake_at.nanoseconds
            else
                false;
            // Clearing before the call means a handler that parks without
            // re-arming cannot spin on a deadline that already passed.
            if (expired) slot.deadline = .none;

            slot.exchange = .{
                .id = index,
                .stream_id = slot.stream_id,
                .request = .{
                    .head = slot.request_head.?,
                    .body = body,
                    .trailers = slot.trailers,
                },
                .arena = slot.arena.allocator(),
                .request_body = request_body,
                .reset_code = slot.reset_code,
                .response_started = slot.response_started,
                .sink = slot.sink.sink(),
                .parked = false,
                .context = slot.context,
                .wake = if (expired) .expired else .progress,
                .deadline = slot.deadline,
            };
            slot.handler_called = true;
            slot.parked = false;
            slot.deadline = .none;

            var failed = false;
            self.handler.vtable.handle(self.handler.ptr, &slot.exchange) catch |err| {
                self.handler.vtable.report_error(self.handler.ptr, err);
                failed = true;
            };
            if (slot.exchange.parked) slot.parked = true;
            slot.context = slot.exchange.context;
            slot.deadline = slot.exchange.deadline;
            slot.response_started = slot.response_started or slot.exchange.response_started;

            if (slot.response_started or slot.response_ended or slot.reset_pending) continue;
            if (self.body_mode == .stream and slot.parked) continue;
            if (!failed) {
                self.handler.vtable.report_error(self.handler.ptr, error.NoResponse);
            }
            slot.exchange.respond(.{ .status = .internal_server_error }, "") catch {
                try self.session.submitReset(
                    self.allocator,
                    slot.stream_id,
                    .internal_error,
                );
                self.finishSlot(slot, true);
            };
        }
    }

    fn nextBodyChunk(
        self: *Connection,
        index: usize,
    ) shared.stream.ReadError!shared.stream.ReadResult {
        const slot = &self.slots[index];
        if (!slot.used) return error.Canceled;
        try self.releaseChunk(slot);
        slot.chunk.clearRetainingCapacity();
        if (slot.reset_pending) return error.Canceled;
        if (slot.unread.items.len != 0) {
            // The caller is done with the previous chunk, so its storage
            // becomes the buffer for the next one. Neither buffer outgrows
            // `body_bytes`, so a long-lived stream reuses them.
            std.mem.swap(std.ArrayList(u8), &slot.chunk, &slot.unread);
            slot.chunk_flow = @intCast(slot.chunk.items.len);
            return .{ .data = slot.chunk.items };
        }
        if (slot.request_complete) return error.EndOfStream;
        return error.Pending;
    }

    /// Return the flow-control credit for the chunk the handler finished with.
    /// A stream that the peer already reset has no stream window left, so only
    /// the connection window is credited.
    fn releaseChunk(self: *Connection, slot: *Slot) shared.stream.ReadError!void {
        if (slot.chunk_flow == 0) return;
        const count = slot.chunk_flow;
        slot.chunk_flow = 0;
        self.session.release(self.allocator, slot.stream_id, count) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.Canceled,
        };
    }

    fn pumpAll(self: *Connection) !bool {
        var progressed = false;
        for (self.slots) |*slot| {
            if (!slot.used) continue;

            if (slot.response_ended or slot.reset_pending) {
                if (!slot.end_sent) {
                    if (slot.reset_pending) {
                        slot.end_sent = true;
                    } else if (slot.end_trailers.items.len != 0) {
                        self.session.submitTrailers(
                            self.allocator,
                            slot.stream_id,
                            slot.end_trailers.items,
                        ) catch |err| switch (err) {
                            error.WouldBlock => continue,
                            error.UnknownStream,
                            error.StreamClosed,
                            error.ConnectionClosed,
                            => {
                                self.finishSlot(slot, slot.handler_called);
                                progressed = true;
                                continue;
                            },
                            else => return err,
                        };
                        slot.end_sent = true;
                    } else {
                        _ = self.session.submitData(
                            self.allocator,
                            slot.stream_id,
                            &.{},
                            true,
                        ) catch |err| switch (err) {
                            error.UnknownStream,
                            error.StreamClosed,
                            error.ConnectionClosed,
                            => {
                                self.finishSlot(slot, slot.handler_called);
                                progressed = true;
                                continue;
                            },
                            else => return err,
                        };
                        slot.end_sent = true;
                    }
                }
                self.finishSlot(slot, slot.handler_called);
                progressed = true;
                continue;
            }

            if (slot.reply == null) continue;
            const reply = slot.reply.?;
            if (!slot.headers_sent) {
                // END_STREAM on the head only when nothing follows it. A
                // trailer section needs the stream left open.
                const end = reply.body.len == 0 and reply.options.trailers.len == 0;
                self.session.submitResponse(
                    self.allocator,
                    slot.stream_id,
                    .{
                        .status = reply.options.status,
                        .content_type = reply.options.content_type,
                        .content_length = reply.body.len,
                        .headers = reply.options.headers,
                    },
                    end,
                ) catch |err| switch (err) {
                    error.WouldBlock => continue,
                    error.UnknownStream,
                    error.StreamClosed,
                    error.ConnectionClosed,
                    => {
                        self.finishSlot(slot, slot.handler_called);
                        progressed = true;
                        continue;
                    },
                    else => return err,
                };
                slot.headers_sent = true;
                progressed = true;
                if (end) {
                    self.finishSlot(slot, slot.handler_called);
                    continue;
                }
            }

            while (slot.body_offset < reply.body.len) {
                const accepted = self.session.submitData(
                    self.allocator,
                    slot.stream_id,
                    reply.body[slot.body_offset..],
                    reply.options.trailers.len == 0,
                ) catch |err| switch (err) {
                    error.UnknownStream,
                    error.StreamClosed,
                    error.ConnectionClosed,
                    => {
                        self.finishSlot(slot, slot.handler_called);
                        progressed = true;
                        break;
                    },
                    else => return err,
                };
                if (accepted == 0) break;
                slot.body_offset += accepted;
                progressed = true;
            }

            if (slot.body_offset == reply.body.len) {
                if (!slot.trailers_sent and reply.options.trailers.len != 0) {
                    self.session.submitTrailers(
                        self.allocator,
                        slot.stream_id,
                        reply.options.trailers,
                    ) catch |err| switch (err) {
                        error.WouldBlock => continue,
                        error.UnknownStream,
                        error.StreamClosed,
                        error.ConnectionClosed,
                        => {
                            self.finishSlot(slot, slot.handler_called);
                            progressed = true;
                            continue;
                        },
                        else => return err,
                    };
                    slot.trailers_sent = true;
                }
                self.finishSlot(slot, slot.handler_called);
                progressed = true;
            }
        }
        return progressed;
    }

    fn finishSlot(self: *Connection, slot: *Slot, call_complete: bool) void {
        if (slot.used and self.body_mode == .stream) {
            // Unread bytes and the outstanding chunk are still charged to the
            // receive windows. The stream is gone, so only the connection
            // window can take them back.
            const outstanding = @min(
                @as(u64, slot.chunk_flow) + slot.unread.items.len,
                0x7fff_ffff,
            );
            slot.chunk_flow = 0;
            slot.unread.clearRetainingCapacity();
            slot.chunk.clearRetainingCapacity();
            if (outstanding != 0 and !self.session.isClosed()) {
                self.session.releaseConnection(
                    self.allocator,
                    @intCast(outstanding),
                ) catch |err| {
                    _ = @errorName(err);
                };
            }
        }
        if (call_complete and slot.handler_called) {
            self.handler.vtable.complete(self.handler.ptr, &slot.exchange);
        }
        shared.resetArena(&slot.arena, self.arena_retain_bytes);
        slot.used = false;
        slot.stream_id = 0;
        slot.body = .empty;
        slot.request_head = null;
        slot.trailers = .{ .items = &.{} };
        slot.content_length = null;
        slot.received = 0;
        slot.request_complete = false;
        slot.handler_called = false;
        slot.parked = false;
        slot.deadline = .none;
        slot.response_started = false;
        slot.reply = null;
        slot.headers_sent = false;
        slot.trailers_sent = false;
        slot.body_offset = 0;
        slot.response_ended = false;
        slot.end_sent = false;
        slot.end_trailers = .{ .items = &.{} };
        slot.reset_pending = false;
        slot.reset_code = null;
        slot.context = null;
        slot.body_deadline = .none;
        slot.exchange = undefined;
    }

    fn completeAll(self: *Connection) void {
        for (self.slots) |*slot| {
            if (slot.used) self.finishSlot(slot, true);
        }
    }
};

fn mapSession(err: anyerror) common.Sink.SinkError {
    return switch (err) {
        error.UnknownStream, error.StreamClosed => error.StreamClosed,
        error.ConnectionClosed, error.WrongRole => error.ConnectionClosed,
        error.WouldBlock => error.WouldBlock,
        error.InvalidHead => error.InvalidResponse,
        error.OutOfMemory => error.OutOfMemory,
        else => error.ConnectionClosed,
    };
}

fn compatCode(code: frame.ErrorCode) u32 {
    return compat.enumToInt(code);
}

fn earliest(a: ?Io.Timestamp, b: Io.Timestamp) Io.Timestamp {
    const at = a orelse return b;
    return if (at.nanoseconds <= b.nanoseconds) at else b;
}

fn findSlot(slots: []Slot, stream_id: u31) ?*Slot {
    for (slots) |*slot| {
        if (slot.used and slot.stream_id == stream_id) return slot;
    }
    return null;
}

fn allocSlotIndex(slots: []Slot) ?usize {
    for (slots, 0..) |*slot, index| {
        if (!slot.used) return index;
    }
    return null;
}

fn copyHead(arena: Allocator, source: head.RequestHead) !head.RequestHead {
    const items = try arena.alloc(Header, source.headers.items.len);
    for (source.headers.items, 0..) |header, index| {
        items[index] = .{
            .name = try arena.dupe(u8, header.name),
            .value = try arena.dupe(u8, header.value),
        };
    }
    return .{
        .method = source.method,
        .method_token = try arena.dupe(u8, source.method_token),
        .scheme = if (source.scheme) |value| try arena.dupe(u8, value) else null,
        .authority = if (source.authority) |value| try arena.dupe(u8, value) else null,
        .path = if (source.path) |value| try arena.dupe(u8, value) else null,
        .protocol = if (source.protocol) |value| try arena.dupe(u8, value) else null,
        .headers = .{ .items = items },
    };
}

fn copyHeaders(arena: Allocator, source: Headers) !Headers {
    const items = try arena.alloc(Header, source.items.len);
    for (source.items, 0..) |header, index| {
        items[index] = .{
            .name = try arena.dupe(u8, header.name),
            .value = try arena.dupe(u8, header.value),
        };
    }
    return .{ .items = items };
}

fn parseContentLength(headers: Headers) error{Invalid}!?u64 {
    var value: ?u64 = null;
    for (headers.items) |field| {
        if (!std.ascii.eqlIgnoreCase(field.name, "content-length")) continue;
        const parsed = std.fmt.parseInt(u64, field.value, 10) catch return error.Invalid;
        if (value) |previous| {
            if (previous != parsed) return error.Invalid;
        }
        value = parsed;
    }
    return value;
}

const stream_fields = [_]Header{
    .{ .name = ":method", .value = "POST" },
    .{ .name = ":scheme", .value = "http" },
    .{ .name = ":authority", .value = "example.com" },
    .{ .name = ":path", .value = "/" },
    .{ .name = "content-type", .value = "application/grpc" },
};

/// Push one session's queued output into a connection and drain events.
fn feedConnection(from: *Session, to: *Connection, now: Io.Timestamp) !void {
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = from.send(&buf);
        if (n == 0) break;
        var offset: usize = 0;
        while (offset < n) {
            const written = to.receive(buf[offset..n]);
            if (written == 0) {
                _ = try to.drive(now);
                continue;
            }
            offset += written;
            _ = try to.drive(now);
        }
    }
    _ = try to.drive(now);
}

/// Push one connection's queued output into a session.
fn feedSession(from: *Connection, to: *Session) !void {
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = from.send(&buf);
        if (n == 0) break;
        var offset: usize = 0;
        while (offset < n) {
            const written = to.receive(buf[offset..n]);
            if (written == 0) return error.InputStuck;
            offset += written;
        }
    }
}

/// The next event that carries application data. Flow-control and SETTINGS
/// events are protocol bookkeeping, not test subjects.
fn nextClientEvent(client: *Session) !?Event {
    while (try client.nextEvent(testing.allocator)) |event| {
        switch (event) {
            .window_update, .settings => continue,
            else => return event,
        }
    }
    return null;
}

/// Echo every request-body chunk back as a response chunk, before END_STREAM.
const StreamingApp = struct {
    response_started: bool = false,
    turns: usize = 0,
    received: usize = 0,
    ended: bool = false,
    /// The tail of a chunk the peer had no window for. A borrowed body chunk
    /// is valid until the next advancing call, so the handler must finish
    /// with it before calling `next` again.
    pending: []const u8 = &.{},
    failed: ?anyerror = null,

    fn handler(self: *StreamingApp) Handler {
        return .{ .ptr = self, .vtable = &.{
            .handle = handle,
            .complete = Handler.noopComplete,
            .report_error = reportError,
            .policy_response = Handler.defaultPolicyResponse,
        } };
    }

    /// Queue `bytes`, keeping the unsent tail in `pending` when the peer has
    /// no credit. False means the turn must park.
    fn writeAll(self: *StreamingApp, exchange: *Exchange, bytes: []const u8) anyerror!bool {
        self.pending = bytes;
        while (self.pending.len != 0) {
            const written = try exchange.write(self.pending);
            if (written == 0) return false;
            self.pending = self.pending[written..];
            self.received += written;
        }
        return true;
    }

    fn handle(ptr: *anyopaque, exchange: *Exchange) anyerror!void {
        const self: *StreamingApp = @ptrCast(@alignCast(ptr));
        self.turns += 1;
        // The engine carries the opaque context, unread, across every turn.
        if (exchange.context) |saved| {
            try testing.expectEqual(self, @as(*StreamingApp, @ptrCast(@alignCast(saved))));
        } else {
            exchange.context = self;
        }
        const body = exchange.request_body.?;
        while (true) {
            if (self.pending.len != 0) {
                if (!try self.writeAll(exchange, self.pending)) {
                    return exchange.waitForProgress();
                }
                continue;
            }
            const chunk = body.next() catch |err| switch (err) {
                error.Pending => return exchange.waitForProgress(),
                error.Canceled => return,
                error.EndOfStream => {
                    if (!self.response_started) {
                        try exchange.beginResponse(.{ .status = .ok });
                        self.response_started = true;
                    }
                    self.ended = true;
                    const trailers = [_]Header{.{ .name = "grpc-status", .value = "0" }};
                    return exchange.endResponse(&trailers);
                },
                else => return err,
            };
            if (!self.response_started) {
                try exchange.beginResponse(.{ .status = .ok });
                self.response_started = true;
            }
            if (!try self.writeAll(exchange, chunk.data)) {
                return exchange.waitForProgress();
            }
        }
    }

    fn reportError(ptr: *anyopaque, err: anyerror) void {
        const self: *StreamingApp = @ptrCast(@alignCast(ptr));
        self.failed = err;
    }
};

test "the stream engine answers twice before the request ends" {
    // RFC 9113 §5.1: a stream is bidirectional while open, so the server may
    // send HEADERS and DATA while the client still sends DATA.
    const allocator = testing.allocator;
    var app: StreamingApp = .{};
    var conn: Connection = try .init(.{
        .allocator = allocator,
        .handler = app.handler(),
        .body_mode = .stream,
    });
    defer conn.deinit();

    var client: Session = try .init(allocator, .{ .role = .client });
    defer client.deinit(allocator);

    const now = Io.Timestamp.zero;
    // Client preface and SETTINGS.
    try feedConnection(&client, &conn, now);
    try feedSession(&conn, &client);
    while (try client.nextEvent(allocator)) |_| {}

    const id = try client.submitRequest(allocator, &stream_fields, false);
    try feedConnection(&client, &conn, now);
    try testing.expectEqual(@as(usize, 1), app.turns);
    // The handler ran on the head with no body yet, and paused.
    try testing.expect(!app.response_started);
    try testing.expectEqual(@as(usize, 0), app.received);

    _ = try client.submitData(allocator, id, "one", false);
    try feedConnection(&client, &conn, now);
    try feedSession(&conn, &client);

    const response_event = (try nextClientEvent(&client)).?;
    switch (response_event) {
        .response => |response| {
            try testing.expectEqual(@as(u16, 200), response.head.status.code());
            try testing.expect(!response.end_stream);
        },
        else => return error.TestUnexpectedResult,
    }
    const first = (try nextClientEvent(&client)).?;
    switch (first) {
        .data => |data| {
            try testing.expectEqualStrings("one", data.bytes);
            try testing.expect(!data.end_stream);
        },
        else => return error.TestUnexpectedResult,
    }
    try client.release(allocator, id, 3);
    // The request is still open when the first response arrives.
    try testing.expect(!app.ended);

    _ = try client.submitData(allocator, id, "two", false);
    try feedConnection(&client, &conn, now);
    try feedSession(&conn, &client);
    const second = (try nextClientEvent(&client)).?;
    switch (second) {
        .data => |data| {
            try testing.expectEqualStrings("two", data.bytes);
            try testing.expect(!data.end_stream);
        },
        else => return error.TestUnexpectedResult,
    }
    try client.release(allocator, id, 3);

    _ = try client.submitData(allocator, id, "", true);
    try feedConnection(&client, &conn, now);
    try feedSession(&conn, &client);
    const trailers = (try nextClientEvent(&client)).?;
    switch (trailers) {
        .trailers => |t| try testing.expectEqualStrings(
            "0",
            t.headers.get("grpc-status").?,
        ),
        else => return error.TestUnexpectedResult,
    }
    try testing.expectEqual(@as(usize, 6), app.received);
    try testing.expectEqual(@as(?anyerror, null), app.failed);
}

/// Arms a future deadline on its first turn and reports how it was woken.
const DeadlineApp = struct {
    deadline: time.Timestamp = .fromNanoseconds(1_000_000_000),
    expiries: usize = 0,
    turns: usize = 0,

    fn handler(self: *DeadlineApp) Handler {
        return .{ .ptr = self, .vtable = &.{
            .handle = handle,
            .complete = Handler.noopComplete,
            .report_error = Handler.noopReportError,
            .policy_response = Handler.defaultPolicyResponse,
        } };
    }

    fn handle(ptr: *anyopaque, exchange: *Exchange) anyerror!void {
        const self: *DeadlineApp = @ptrCast(@alignCast(ptr));
        self.turns += 1;
        if (exchange.wake == .expired) {
            self.expiries += 1;
            try exchange.beginResponse(.{ .status = .ok });
            return exchange.endResponse(&.{
                .{ .name = "x-deadline", .value = "expired" },
            });
        }
        if (!exchange.response_started and self.expiries == 0) {
            exchange.setDeadline(try .init(self.deadline));
        }
        exchange.waitForProgress();
    }
};

test "an application deadline survives progress and delivers expired once" {
    const allocator = testing.allocator;
    var app: DeadlineApp = .{};
    var conn: Connection = try .init(.{
        .allocator = allocator,
        .handler = app.handler(),
        .body_mode = .stream,
    });
    defer conn.deinit();

    var client: Session = try .init(allocator, .{ .role = .client });
    defer client.deinit(allocator);

    const now = Io.Timestamp.zero;
    try feedConnection(&client, &conn, now);
    try feedSession(&conn, &client);
    while (try client.nextEvent(allocator)) |_| {}

    const id = try client.submitRequest(allocator, &stream_fields, false);
    try feedConnection(&client, &conn, now);
    try testing.expectEqual(@as(usize, 1), app.turns);

    // The application deadline is not an engine close condition, but a driver
    // must wake for it.
    try testing.expect(conn.deadline() == null);
    try testing.expectEqual(
        @as(?Io.Timestamp, Io.Timestamp.fromNanoseconds(1_000_000_000)),
        conn.wakeDeadline(),
    );

    // DATA, a WINDOW_UPDATE, and the trailers that end the request are
    // progress; none of them may cancel the application timer.
    _ = try client.submitData(allocator, id, "x", false);
    try feedConnection(&client, &conn, now);
    try testing.expectEqual(
        @as(?Io.Timestamp, Io.Timestamp.fromNanoseconds(1_000_000_000)),
        conn.wakeDeadline(),
    );

    try client.release(allocator, id, 1);
    try feedConnection(&client, &conn, now);
    try testing.expect(conn.wakeDeadline() != null);

    const trailers = [_]Header{.{ .name = "x-last", .value = "1" }};
    try client.submitTrailers(allocator, id, &trailers);
    try feedConnection(&client, &conn, now);
    try testing.expect(conn.wakeDeadline() != null);
    try testing.expectEqual(@as(usize, 0), app.expiries);

    // Before the deadline the slot stays parked; after it, one expiry turn.
    _ = try conn.drive(.fromNanoseconds(999_000_000));
    try testing.expectEqual(@as(usize, 0), app.expiries);
    _ = try conn.drive(.fromNanoseconds(1_001_000_000));
    try testing.expectEqual(@as(usize, 1), app.expiries);
    try testing.expect(conn.wakeDeadline() == null);
    _ = try conn.drive(.fromNanoseconds(2_000_000_000));
    try testing.expectEqual(@as(usize, 1), app.expiries);

    try feedSession(&conn, &client);
    var saw_head = false;
    var saw_trailers = false;
    while (try nextClientEvent(&client)) |event| {
        switch (event) {
            .response => |response| {
                try testing.expectEqual(@as(u16, 200), response.head.status.code());
                saw_head = true;
            },
            .trailers => |t| {
                try testing.expectEqualStrings("expired", t.headers.get("x-deadline").?);
                saw_trailers = true;
            },
            .data => {},
            else => return error.TestUnexpectedResult,
        }
    }
    try testing.expect(saw_head);
    try testing.expect(saw_trailers);
}

/// Parks on the first turn without reading, so the test can inspect the
/// unread balance.
const ParkApp = struct {
    turns: usize = 0,

    fn handler(self: *ParkApp) Handler {
        return .{ .ptr = self, .vtable = &.{
            .handle = handle,
            .complete = Handler.noopComplete,
            .report_error = Handler.noopReportError,
            .policy_response = Handler.defaultPolicyResponse,
        } };
    }

    fn handle(ptr: *anyopaque, exchange: *Exchange) anyerror!void {
        const self: *ParkApp = @ptrCast(@alignCast(ptr));
        self.turns += 1;
        exchange.waitForProgress();
    }
};

/// Reads exactly one chunk per turn, then parks, so the test can observe the
/// credit balance between turns.
const OneChunkApp = struct {
    chunks: usize = 0,

    fn handler(self: *OneChunkApp) Handler {
        return .{ .ptr = self, .vtable = &.{
            .handle = handle,
            .complete = Handler.noopComplete,
            .report_error = Handler.noopReportError,
            .policy_response = Handler.defaultPolicyResponse,
        } };
    }

    fn handle(ptr: *anyopaque, exchange: *Exchange) anyerror!void {
        const self: *OneChunkApp = @ptrCast(@alignCast(ptr));
        const chunk = exchange.request_body.?.next() catch |err| switch (err) {
            error.Pending, error.Canceled => return exchange.waitForProgress(),
            error.EndOfStream => {
                try exchange.beginResponse(.{ .status = .ok });
                return exchange.endResponse(&.{});
            },
            else => return err,
        };
        try testing.expect(chunk.data.len != 0);
        self.chunks += 1;
        exchange.waitForProgress();
    }
};

test "a chunk's flow-control credit returns when the handler supersedes it" {
    // RFC 9113 §5.2.1: a receiver returns credit with WINDOW_UPDATE once it has
    // consumed DATA. The engine consumes one chunk at a time, so the previous
    // chunk is what the handler has finished with.
    const allocator = testing.allocator;
    var app: OneChunkApp = .{};
    var conn: Connection = try .init(.{
        .allocator = allocator,
        .handler = app.handler(),
        .body_mode = .stream,
    });
    defer conn.deinit();

    var client: Session = try .init(allocator, .{ .role = .client });
    defer client.deinit(allocator);

    const now = Io.Timestamp.zero;
    try feedConnection(&client, &conn, now);
    try feedSession(&conn, &client);
    while (try client.nextEvent(allocator)) |_| {}

    const id = try client.submitRequest(allocator, &stream_fields, false);
    try feedConnection(&client, &conn, now);

    _ = try client.submitData(allocator, id, "one", false);
    try feedConnection(&client, &conn, now);
    try testing.expectEqual(@as(usize, 1), app.chunks);
    // The handler holds "one"; both windows are charged for it.
    try testing.expectEqual(@as(i64, 65_535 - 3), conn.session.conn_recv.available);
    try testing.expectEqual(
        @as(i64, 65_535 - 3),
        conn.session.streams.get(id).?.recv.available,
    );

    _ = try client.submitData(allocator, id, "two", false);
    try feedConnection(&client, &conn, now);
    try testing.expectEqual(@as(usize, 2), app.chunks);
    // Superseding "one" returned three bytes, then "two" was consumed.
    try testing.expectEqual(@as(i64, 65_535 - 3), conn.session.conn_recv.available);

    _ = try client.submitData(allocator, id, "", true);
    try feedConnection(&client, &conn, now);
    try testing.expectEqual(@as(i64, 65_535), conn.session.conn_recv.available);
    try testing.expectEqual(@as(usize, 0), conn.session.streams.count());
}

test "a zero-credit write keeps its tail and resumes on WINDOW_UPDATE" {
    // RFC 9113 §5.2: a sender may not exceed the peer's window. A write that
    // stops at the window edge must keep the rest; the handler parks, and the
    // WINDOW_UPDATE that opens the window calls it again with its own state.
    const allocator = testing.allocator;
    var app: StreamingApp = .{};
    var conn: Connection = try .init(.{
        .allocator = allocator,
        .handler = app.handler(),
        .body_mode = .stream,
    });
    defer conn.deinit();

    // A 3-byte receive window: the echo of a 6-byte chunk cannot fit in one
    // frame, so the handler hits a zero write mid-message.
    var client: Session = try .init(allocator, .{
        .role = .client,
        .initial_window_size = 3,
    });
    defer client.deinit(allocator);

    const now = Io.Timestamp.zero;
    try feedConnection(&client, &conn, now);
    try feedSession(&conn, &client);
    while (try client.nextEvent(allocator)) |_| {}

    const id = try client.submitRequest(allocator, &stream_fields, false);
    try feedConnection(&client, &conn, now);
    _ = try client.submitData(allocator, id, "abcdef", false);
    try feedConnection(&client, &conn, now);
    try feedSession(&conn, &client);

    var received: [8]u8 = undefined;
    var used: usize = 0;
    const response_event = (try nextClientEvent(&client)).?;
    switch (response_event) {
        .response => |response| try testing.expect(!response.end_stream),
        else => return error.TestUnexpectedResult,
    }
    const first = (try nextClientEvent(&client)).?;
    switch (first) {
        .data => |data| {
            @memcpy(received[0..data.bytes.len], data.bytes);
            used = data.bytes.len;
        },
        else => return error.TestUnexpectedResult,
    }
    try testing.expectEqual(@as(usize, 3), used);
    // The tail is held by the handler, not dropped and not resent.
    try testing.expectEqual(@as(usize, 3), app.pending.len);

    try client.release(allocator, id, 3);
    try feedConnection(&client, &conn, now);
    try feedSession(&conn, &client);

    const second = (try nextClientEvent(&client)).?;
    switch (second) {
        .data => |data| {
            @memcpy(received[used..][0..data.bytes.len], data.bytes);
            used += data.bytes.len;
        },
        else => return error.TestUnexpectedResult,
    }
    try testing.expectEqualStrings("abcdef", received[0..used]);
    try testing.expectEqual(@as(usize, 0), app.pending.len);
    try testing.expectEqual(@as(usize, 6), app.received);

    try client.release(allocator, id, @intCast(used));
    _ = try client.submitData(allocator, id, "", true);
    try feedConnection(&client, &conn, now);
    try feedSession(&conn, &client);
    try testing.expect(app.ended);
    try testing.expectEqual(@as(usize, 0), conn.session.streams.count());
}

/// Holds the current chunk across a deadline wake and checks it is intact.
/// Every byte must be seen once; nothing may be retained between rounds.
const ResidentMemoryApp = struct {
    held: []const u8 = &.{},
    expected_byte: u8 = 0,
    deadline: time.Timestamp = .zero,
    received: usize = 0,
    expiries: usize = 0,
    ended: bool = false,

    fn handler(self: *ResidentMemoryApp) Handler {
        return .{ .ptr = self, .vtable = &.{
            .handle = handle,
            .complete = Handler.noopComplete,
            .report_error = Handler.noopReportError,
            .policy_response = Handler.defaultPolicyResponse,
        } };
    }

    fn handle(ptr: *anyopaque, exchange: *Exchange) anyerror!void {
        const self: *ResidentMemoryApp = @ptrCast(@alignCast(ptr));
        if (exchange.wake == .expired) {
            self.expiries += 1;
            try testing.expectEqual(@as(usize, 4096), self.held.len);
            for (self.held) |byte| try testing.expectEqual(self.expected_byte, byte);
            self.held = &.{};
        }
        const chunk = exchange.request_body.?.next() catch |err| switch (err) {
            error.Pending => return exchange.waitForProgress(),
            error.EndOfStream => {
                self.ended = true;
                try exchange.beginResponse(.{ .status = .ok });
                return exchange.endResponse(&.{});
            },
            else => return err,
        };
        self.held = chunk.data;
        self.received += chunk.data.len;
        exchange.setDeadline(try .init(self.deadline));
        exchange.waitForProgress();
    }
};

test "resident memory plateaus across consume, park, and deadline" {
    // RFC 9113 §5.1 and §5.2: one long-lived stream, each chunk's credit
    // returned after a deadline wake. `body_bytes` is large enough here that
    // the upload never trips it; what must not grow is the allocator total.
    // The baseline is taken at 16 chunks, so the loop runs to 32: a 16-chunk
    // test would compare the baseline with itself.
    var counter: std.heap.DebugAllocator(.{
        .enable_memory_limit = true,
        .stack_trace_frames = 0,
    }) = .init;
    defer assert(counter.deinit() == .ok);
    const allocator = counter.allocator();

    var app: ResidentMemoryApp = .{};
    var conn: Connection = try .init(.{
        .allocator = allocator,
        .handler = app.handler(),
        .body_mode = .stream,
        .body_bytes = 8 * 1024 * 1024,
        .max_streams = 1,
    });
    defer conn.deinit();

    var client: Session = try .init(testing.allocator, .{ .role = .client });
    defer client.deinit(testing.allocator);

    const now = Io.Timestamp.zero;
    try feedConnection(&client, &conn, now);
    try feedSession(&conn, &client);
    while (try client.nextEvent(testing.allocator)) |_| {}

    const id = try client.submitRequest(testing.allocator, &stream_fields, false);
    try feedConnection(&client, &conn, now);

    var warm_live: usize = 0;
    var warm_capacity: usize = 0;
    for (0..32) |round| {
        const now_ns: u64 = @intCast(round * 10);
        app.deadline = .fromNanoseconds(now_ns + 5);
        app.expected_byte = @truncate(round);
        const bytes: [4096]u8 = @splat(app.expected_byte);
        const accepted = try client.submitData(testing.allocator, id, &bytes, false);
        try testing.expectEqual(bytes.len, accepted);
        try feedConnection(&client, &conn, Io.Timestamp.fromNanoseconds(now_ns));
        try testing.expectEqual((round + 1) * bytes.len, app.received);
        try testing.expectEqual(bytes.len, app.held.len);

        _ = try conn.drive(app.deadline.toStd());
        try testing.expectEqual(round + 1, app.expiries);
        try feedSession(&conn, &client);
        while (try client.nextEvent(testing.allocator)) |_| {}

        // The allocator total is the test: at the old revision every chunk was
        // duplicated into the slot arena, and a capacity-only check misses it
        // because `unread` stays the same shape while the arena grows.
        const slot = &conn.slots[0];
        const capacity = slot.chunk.capacity + slot.unread.capacity;
        if (round == 15) {
            warm_live = counter.total_requested_bytes;
            warm_capacity = capacity;
        }
        if (round >= 15) {
            try testing.expectEqual(warm_live, counter.total_requested_bytes);
            try testing.expectEqual(warm_capacity, capacity);
        }
    }

    _ = try client.submitData(testing.allocator, id, "", true);
    try feedConnection(&client, &conn, Io.Timestamp.fromNanoseconds(20_000));
    try feedSession(&conn, &client);
    while (try client.nextEvent(testing.allocator)) |_| {}

    try testing.expect(app.ended);
    try testing.expectEqual(@as(usize, 32 * 4096), app.received);
    try testing.expectEqual(@as(usize, 0), conn.session.streams.count());
    try testing.expectEqual(@as(i64, 65_535), conn.session.conn_recv.available);
}

test "a peer reset returns unread body credit to the connection window" {
    // A reset stream has no stream window left (RFC 9113 §5.1), so the unread
    // bytes can only be credited at the connection level.
    const allocator = testing.allocator;
    var app: ParkApp = .{};
    var conn: Connection = try .init(.{
        .allocator = allocator,
        .handler = app.handler(),
        .body_mode = .stream,
    });
    defer conn.deinit();

    var client: Session = try .init(allocator, .{ .role = .client });
    defer client.deinit(allocator);

    const now = Io.Timestamp.zero;
    try feedConnection(&client, &conn, now);
    try feedSession(&conn, &client);
    while (try client.nextEvent(allocator)) |_| {}

    const id = try client.submitRequest(allocator, &stream_fields, false);
    try feedConnection(&client, &conn, now);
    _ = try client.submitData(allocator, id, "abc", false);
    try feedConnection(&client, &conn, now);
    try testing.expectEqual(@as(i64, 65_535 - 3), conn.session.conn_recv.available);

    try client.submitReset(allocator, id, .cancel);
    try feedConnection(&client, &conn, now);
    try testing.expectEqual(@as(usize, 0), conn.session.streams.count());
    try testing.expectEqual(@as(i64, 65_535), conn.session.conn_recv.available);
    // The head turn and one turn woken by the DATA.
    try testing.expectEqual(@as(usize, 2), app.turns);
}

test "a request body over body_bytes is a reset, not growth" {
    const allocator = testing.allocator;
    var app: ParkApp = .{};
    var conn: Connection = try .init(.{
        .allocator = allocator,
        .handler = app.handler(),
        .body_mode = .stream,
        .body_bytes = 4,
    });
    defer conn.deinit();

    var client: Session = try .init(allocator, .{ .role = .client });
    defer client.deinit(allocator);

    const now = Io.Timestamp.zero;
    try feedConnection(&client, &conn, now);
    try feedSession(&conn, &client);
    while (try client.nextEvent(allocator)) |_| {}

    const id = try client.submitRequest(allocator, &stream_fields, false);
    try feedConnection(&client, &conn, now);
    _ = try client.submitData(allocator, id, "abcde", false);
    try feedConnection(&client, &conn, now);
    try feedSession(&conn, &client);

    const event = (try nextClientEvent(&client)).?;
    switch (event) {
        .reset => |reset| try testing.expectEqual(frame.ErrorCode.enhance_your_calm, reset.code),
        else => return error.TestUnexpectedResult,
    }
    try testing.expectEqual(@as(usize, 0), conn.session.streams.count());
    try testing.expectEqual(@as(i64, 65_535), conn.session.conn_recv.available);
}

/// The next DATA event, skipping the one response head and control events.
fn readEcho(client: *Session, sink: []u8) ![]const u8 {
    while (try nextClientEvent(client)) |event| {
        switch (event) {
            .response => |response| try testing.expect(!response.end_stream),
            .data => |data| {
                @memcpy(sink[0..data.bytes.len], data.bytes);
                return sink[0..data.bytes.len];
            },
            else => return error.TestUnexpectedResult,
        }
    }
    return error.EndOfStream;
}

test "a streamed body is bounded by unconsumed bytes, not by its total" {
    // `Config.body_bytes` is a memory cap. A handler that consumes a chunk
    // before the next arrives reopens the window, so the upload itself may be
    // arbitrarily longer than the cap. What may not grow is the unread
    // balance: the two slot buffers are reused, never accumulated.
    const allocator = testing.allocator;
    var app: StreamingApp = .{};
    var conn: Connection = try .init(.{
        .allocator = allocator,
        .handler = app.handler(),
        .body_mode = .stream,
        .body_bytes = 8,
    });
    defer conn.deinit();

    var client: Session = try .init(allocator, .{ .role = .client });
    defer client.deinit(allocator);

    const now = Io.Timestamp.zero;
    try feedConnection(&client, &conn, now);
    try feedSession(&conn, &client);
    while (try client.nextEvent(allocator)) |_| {}

    const id = try client.submitRequest(allocator, &stream_fields, false);
    try feedConnection(&client, &conn, now);

    var total: usize = 0;
    var sink: [16]u8 = undefined;
    var capacity_after_second: usize = 0;
    for (0..6) |round| {
        _ = try client.submitData(allocator, id, "abcd", false);
        try feedConnection(&client, &conn, now);
        try feedSession(&conn, &client);

        const echo = try readEcho(&client, &sink);
        try testing.expectEqualStrings("abcd", echo);
        total += echo.len;
        try client.release(allocator, id, 4);
        try testing.expectEqual((round + 1) * 4, app.received);

        // From the second chunk on, the two buffers are reused: 24 bytes of
        // upload leave the same storage behind as 8.
        const slot = &conn.slots[0];
        const capacity = slot.chunk.capacity + slot.unread.capacity;
        if (round == 1) capacity_after_second = capacity;
        if (round >= 1) try testing.expectEqual(capacity_after_second, capacity);
    }
    // Six 4-byte chunks against an 8-byte cap: the total is three times the
    // cap and nothing was reset.
    try testing.expectEqual(@as(usize, 24), total);
    try testing.expect(conn.slots[0].chunk.items.len <= 8);

    _ = try client.submitData(allocator, id, "", true);
    try feedConnection(&client, &conn, now);
    try feedSession(&conn, &client);
    try testing.expect(app.ended);
    try testing.expectEqual(@as(usize, 0), conn.session.streams.count());
    try testing.expectEqual(@as(i64, 65_535), conn.session.conn_recv.available);
}
