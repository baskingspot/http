//! The sans-I/O HTTP/2 exchange engine shared by the transports.
//!
//! The connection owns the session, the fixed slot table, the per-stream
//! arenas, and the handler. A transport feeds bytes with `receive`, calls
//! `drive` to deliver events and queue responses, and drains `send`. It never
//! touches a socket. `blocking` and the readiness engines are thin drivers
//! around this type.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const session_mod = @import("../session.zig");
const Session = session_mod.Session;
const SessionOptions = session_mod.Options;
const Event = session_mod.Event;
const head = @import("../head.zig");
const Header = @import("../../header.zig").Header;
const Headers = @import("../../header.zig").Headers;
const response_mod = @import("../../response.zig");

const common = @import("common.zig");
pub const Exchange = common.Exchange;
pub const Handler = common.Handler;
pub const Request = common.Request;
pub const ResponseOptions = common.ResponseOptions;

// ast-grep-ignore: public-struct-field-default -- options bag; defaults are the policy
pub const Options = struct {
    allocator: Allocator,
    handler: Handler,
    max_streams: u16 = 128,
    body_bytes: usize = 64 * 1024,
    arena_retain_bytes: usize = 4 * 1024,
    session: SessionOptions = .{ .role = .server },
};

const Slot = struct {
    used: bool = false,
    stream_id: u31 = 0,
    arena: ArenaAllocator,
    body: std.ArrayList(u8) = .empty,
    request_head: ?head.RequestHead = null,
    trailers: Headers = .{ .items = &.{} },
    content_length: ?u64 = null,
    received: u64 = 0,
    request_complete: bool = false,
    handler_called: bool = false,
    headers_sent: bool = false,
    body_offset: usize = 0,
    exchange: Exchange = undefined,
};

pub const Connection = struct {
    allocator: Allocator,
    handler: Handler,
    session: Session,
    slots: []Slot,
    body_bytes: usize,
    arena_retain_bytes: usize,

    pub fn init(options: Options) !Connection {
        var session_options = options.session;
        session_options.role = .server;
        session_options.max_streams = options.max_streams;

        var session = try Session.init(options.allocator, session_options);
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
        };
    }

    pub fn deinit(self: *Connection) void {
        self.completeAll();
        for (self.slots) |*slot| slot.arena.deinit();
        self.allocator.free(self.slots);
        self.session.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn receive(self: *Connection, bytes: []const u8) usize {
        return self.session.receive(bytes);
    }

    pub fn send(self: *Connection, out: []u8) usize {
        return self.session.send(out);
    }

    pub fn isClosed(self: *const Connection) bool {
        return self.session.isClosed();
    }

    /// Deliver every complete event currently buffered, start the handlers
    /// whose requests are complete, and queue as much response output as flow
    /// control accepts. Returns whether anything happened.
    pub fn drive(self: *Connection) !bool {
        if (self.session.isClosed()) return false;

        var progressed = false;
        while (try self.session.nextEvent(self.allocator)) |event| {
            try self.processEvent(event);
            progressed = true;
            if (self.session.isClosed()) break;
        }

        if (!self.session.isClosed()) {
            try self.startReady();
        }
        if (try self.pumpAll()) progressed = true;
        return progressed;
    }

    fn processEvent(self: *Connection, event: Event) !void {
        switch (event) {
            .request => |request| {
                const slot = allocSlot(self.slots) orelse {
                    try self.session.submitReset(
                        self.allocator,
                        request.stream_id,
                        .refused_stream,
                    );
                    return;
                };
                slot.used = true;
                slot.stream_id = request.stream_id;
                slot.body = .empty;
                slot.trailers = .{ .items = &.{} };
                slot.received = 0;
                slot.request_complete = request.end_stream;
                slot.handler_called = false;
                slot.headers_sent = false;
                slot.body_offset = 0;

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
                if (slot.content_length) |length| {
                    if (length > self.body_bytes) {
                        try self.session.submitReset(
                            self.allocator,
                            request.stream_id,
                            .enhance_your_calm,
                        );
                        self.finishSlot(slot, false);
                    }
                }
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
                if (slot.received + data.bytes.len > self.body_bytes) {
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
                    self.finishSlot(slot, false);
                    return;
                }

                slot.body.appendSlice(slot.arena.allocator(), data.bytes) catch |err| {
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
                    self.finishSlot(slot, false);
                    return err;
                };
                slot.received += data.bytes.len;
                if (data.bytes.len > 0) {
                    try self.session.release(
                        self.allocator,
                        data.stream_id,
                        @intCast(data.bytes.len),
                    );
                }
                if (data.end_stream) slot.request_complete = true;
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
                    self.finishSlot(slot, false);
                    return err;
                };
                slot.request_complete = trailers.end_stream;
            },

            .reset => |reset| {
                if (findSlot(self.slots, reset.stream_id)) |slot| {
                    self.finishSlot(slot, true);
                }
            },

            .window_update, .settings, .goaway, .connection_error, .response => {},
        }
    }

    fn startReady(self: *Connection) !void {
        for (self.slots, 0..) |*slot, index| {
            if (!slot.used or !slot.request_complete or slot.handler_called) continue;

            if (slot.content_length) |expected| {
                if (expected != slot.received) {
                    try self.session.submitReset(
                        self.allocator,
                        slot.stream_id,
                        .protocol_error,
                    );
                    self.finishSlot(slot, false);
                    continue;
                }
            }

            slot.exchange = .{
                .id = index,
                .stream_id = slot.stream_id,
                .request = .{
                    .head = slot.request_head.?,
                    .body = slot.body.items,
                    .trailers = slot.trailers,
                },
                .arena = slot.arena.allocator(),
            };
            slot.handler_called = true;

            var failed = false;
            self.handler.vtable.handle(self.handler.ptr, &slot.exchange) catch |err| {
                self.handler.vtable.report_error(self.handler.ptr, err);
                failed = true;
            };
            if (slot.exchange.response == null) {
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
    }

    fn pumpAll(self: *Connection) !bool {
        var progressed = false;
        for (self.slots) |*slot| {
            if (!slot.used or !slot.handler_called) continue;
            const reply = slot.exchange.response orelse continue;
            const response: response_mod.Response = .{
                .status = reply.options.status,
                .content_type = reply.options.content_type,
                .content_length = reply.body.len,
                .headers = reply.options.headers,
            };

            if (!slot.headers_sent) {
                const end = reply.body.len == 0;
                self.session.submitResponse(
                    self.allocator,
                    slot.stream_id,
                    response,
                    end,
                ) catch |err| switch (err) {
                    error.WouldBlock => continue,
                    error.UnknownStream, error.StreamClosed => {
                        self.finishSlot(slot, true);
                        progressed = true;
                        continue;
                    },
                    else => return err,
                };
                slot.headers_sent = true;
                progressed = true;
                if (end) {
                    self.finishSlot(slot, true);
                    continue;
                }
            }

            while (slot.body_offset < reply.body.len) {
                const accepted = self.session.submitData(
                    self.allocator,
                    slot.stream_id,
                    reply.body[slot.body_offset..],
                    true,
                ) catch |err| switch (err) {
                    error.UnknownStream, error.StreamClosed => {
                        self.finishSlot(slot, true);
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
                self.finishSlot(slot, true);
                progressed = true;
            }
        }
        return progressed;
    }

    fn finishSlot(self: *Connection, slot: *Slot, call_complete: bool) void {
        if (call_complete and slot.handler_called) {
            self.handler.vtable.complete(self.handler.ptr, &slot.exchange);
        }
        _ = slot.arena.reset(.{ .retain_with_limit = self.arena_retain_bytes });
        slot.used = false;
        slot.stream_id = 0;
        slot.body = .empty;
        slot.request_head = null;
        slot.trailers = .{ .items = &.{} };
        slot.content_length = null;
        slot.received = 0;
        slot.request_complete = false;
        slot.handler_called = false;
        slot.headers_sent = false;
        slot.body_offset = 0;
        slot.exchange = undefined;
    }

    fn completeAll(self: *Connection) void {
        for (self.slots) |*slot| {
            if (slot.used) self.finishSlot(slot, true);
        }
    }
};

fn findSlot(slots: []Slot, stream_id: u31) ?*Slot {
    for (slots) |*slot| {
        if (slot.used and slot.stream_id == stream_id) return slot;
    }
    return null;
}

fn allocSlot(slots: []Slot) ?*Slot {
    for (slots) |*slot| {
        if (!slot.used) return slot;
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
