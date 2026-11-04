//! A blocking HTTP/2 server engine over std.Io.
//!
//! The engine buffers one complete request per stream, hands it to the
//! application as an `Exchange`, and pumps the response back under flow
//! control. It matches `h1.engine.blocking`: one connection per `serve`, one
//! accept at a time in `run`, and no timeouts. The h2c example puts a thread
//! per connection above `serve`.
//!
//! The handler provides `handle`, `complete`, and `report_error` through a
//! vtable. `Exchange.arena` owns the copied request, so a handler can allocate
//! per-stream state and forget it at `complete`. The response body is borrowed
//! and must stay valid until `complete`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const mem = std.mem;
const ArenaAllocator = std.heap.ArenaAllocator;

const session_mod = @import("../session.zig");
const Session = session_mod.Session;
const Options = session_mod.Options;
const Event = session_mod.Event;
const head = @import("../head.zig");
const Header = @import("../../header.zig").Header;
const Headers = @import("../../header.zig").Headers;

const common = @import("common.zig");
pub const Exchange = common.Exchange;
pub const Handler = common.Handler;
pub const Request = common.Request;
pub const ResponseOptions = common.ResponseOptions;

// ast-grep-ignore: public-struct-field-default -- options bag; defaults are the policy
pub const Config = struct {
    allocator: Allocator,
    /// Transport read scratch fed to `Session.receive`.
    read_buffer: []u8,
    /// The `std.Io` writer's buffer.
    write_buffer: []u8,
    /// Engine slot count and the session's MAX_CONCURRENT_STREAMS.
    max_streams: u16 = 128,
    /// Per-request body cap. Worst-case live memory is max_streams × this.
    body_bytes: usize = 64 * 1024,
    /// Retained per-stream arena capacity after complete.
    arena_retain_bytes: usize = 4 * 1024,
    session: Options = .{ .role = .server },
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

/// Accept connections until an unrecoverable accept error.
pub fn run(
    io: Io,
    listener: *Io.net.Server,
    handler: Handler,
    config: Config,
) !void {
    while (true) {
        const stream = listener.accept(io) catch |err| switch (err) {
            error.ConnectionAborted, error.WouldBlock => continue,
            error.ProcessFdQuotaExceeded,
            error.SystemFdQuotaExceeded,
            error.SystemResources,
            => {
                io.sleep(.fromSeconds(1), .awake) catch |sleep_err| switch (sleep_err) {
                    error.Canceled => return,
                };
                continue;
            },
            error.Canceled => return,
            else => return err,
        };
        defer stream.close(io);

        serve(io, stream, handler, config) catch |err| {
            handler.vtable.report_error(handler.ptr, err);
            continue;
        };
    }
}

/// Serve one connection until the peer closes or the session fails.
pub fn serve(
    io: Io,
    stream: Io.net.Stream,
    handler: Handler,
    config: Config,
) !void {
    if (config.read_buffer.len == 0 or config.write_buffer.len == 0) {
        return error.NoBuffer;
    }

    var options = config.session;
    options.role = .server;
    options.max_streams = config.max_streams;

    var session = try Session.init(config.allocator, options);
    defer session.deinit(config.allocator);

    const slots = try config.allocator.alloc(Slot, config.max_streams);
    defer {
        for (slots) |*slot| slot.arena.deinit();
        config.allocator.free(slots);
    }
    for (slots) |*slot| slot.* = .{ .arena = .init(config.allocator) };

    var reader = stream.reader(io, &.{});
    var writer = stream.writer(io, config.write_buffer);
    const r = &reader.interface;
    const w = &writer.interface;
    var out_buffer: [4096]u8 = undefined;

    while (true) {
        _ = try pumpAll(&session, slots, handler, config);
        try flush(&session, w, &out_buffer);
        if (try pumpAll(&session, slots, handler, config)) continue;

        var vecs: [1][]u8 = .{config.read_buffer};
        const n = r.readVec(&vecs) catch |err| switch (err) {
            error.EndOfStream => {
                completeAll(slots, handler, config);
                return;
            },
            error.ReadFailed => {
                completeAll(slots, handler, config);
                return err;
            },
        };
        if (n == 0) {
            completeAll(slots, handler, config);
            return;
        }

        var offset: usize = 0;
        while (offset < n) {
            const consumed = session.receive(config.read_buffer[offset..n]);
            if (consumed == 0) {
                completeAll(slots, handler, config);
                if (session.isClosed()) try flush(&session, w, &out_buffer);
                return error.InputFull;
            }
            offset += consumed;

            while (try session.nextEvent(config.allocator)) |event| {
                processEvent(&session, slots, handler, config, event) catch |err| {
                    completeAll(slots, handler, config);
                    flush(&session, w, &out_buffer) catch |flush_err| {
                        _ = @errorName(flush_err);
                    };
                    return err;
                };
                if (session.isClosed()) break;
            }
            if (session.isClosed()) {
                completeAll(slots, handler, config);
                try flush(&session, w, &out_buffer);
                return;
            }
        }

        startReady(&session, slots, handler, config) catch |err| {
            completeAll(slots, handler, config);
            flush(&session, w, &out_buffer) catch |flush_err| {
                _ = @errorName(flush_err);
            };
            return err;
        };
    }
}

fn processEvent(
    session: *Session,
    slots: []Slot,
    handler: Handler,
    config: Config,
    event: Event,
) !void {
    switch (event) {
        .request => |request| {
            const slot = allocSlot(slots) orelse {
                try session.submitReset(config.allocator, request.stream_id, .refused_stream);
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

            slot.request_head = copyHead(slot.arena.allocator(), request.head) catch |err| {
                try session.submitReset(config.allocator, request.stream_id, .internal_error);
                finishSlot(slot, handler, config, false);
                return err;
            };
            slot.content_length = parseContentLength(request.head.headers) catch {
                try session.submitReset(config.allocator, request.stream_id, .protocol_error);
                finishSlot(slot, handler, config, false);
                return;
            };
            if (slot.content_length) |length| {
                if (length > config.body_bytes) {
                    try session.submitReset(
                        config.allocator,
                        request.stream_id,
                        .enhance_your_calm,
                    );
                    finishSlot(slot, handler, config, false);
                }
            }
        },

        .data => |data| {
            const slot = findSlot(slots, data.stream_id) orelse {
                if (data.bytes.len > 0) {
                    try session.release(config.allocator, data.stream_id, @intCast(data.bytes.len));
                }
                return;
            };
            if (slot.received + data.bytes.len > config.body_bytes) {
                try session.submitReset(
                    config.allocator,
                    data.stream_id,
                    .enhance_your_calm,
                );
                if (data.bytes.len > 0) {
                    try session.release(config.allocator, data.stream_id, @intCast(data.bytes.len));
                }
                finishSlot(slot, handler, config, false);
                return;
            }

            slot.body.appendSlice(slot.arena.allocator(), data.bytes) catch |err| {
                try session.submitReset(config.allocator, data.stream_id, .internal_error);
                if (data.bytes.len > 0) {
                    try session.release(config.allocator, data.stream_id, @intCast(data.bytes.len));
                }
                finishSlot(slot, handler, config, false);
                return err;
            };
            slot.received += data.bytes.len;
            if (data.bytes.len > 0) {
                try session.release(config.allocator, data.stream_id, @intCast(data.bytes.len));
            }
            if (data.end_stream) slot.request_complete = true;
        },

        .trailers => |trailers| {
            const slot = findSlot(slots, trailers.stream_id) orelse return;
            slot.trailers = copyHeaders(slot.arena.allocator(), trailers.headers) catch |err| {
                try session.submitReset(config.allocator, trailers.stream_id, .internal_error);
                finishSlot(slot, handler, config, false);
                return err;
            };
            slot.request_complete = trailers.end_stream;
        },

        .reset => |reset| {
            if (findSlot(slots, reset.stream_id)) |slot| {
                finishSlot(slot, handler, config, true);
            }
        },

        .window_update, .settings, .goaway, .connection_error, .response => {},
    }
}

fn startReady(
    session: *Session,
    slots: []Slot,
    handler: Handler,
    config: Config,
) !void {
    for (slots, 0..) |*slot, index| {
        if (!slot.used or !slot.request_complete or slot.handler_called) continue;

        if (slot.content_length) |expected| {
            if (expected != slot.received) {
                try session.submitReset(config.allocator, slot.stream_id, .protocol_error);
                finishSlot(slot, handler, config, false);
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
        handler.vtable.handle(handler.ptr, &slot.exchange) catch |err| {
            handler.vtable.report_error(handler.ptr, err);
            failed = true;
        };
        if (slot.exchange.response == null) {
            if (!failed) handler.vtable.report_error(handler.ptr, error.NoResponse);
            slot.exchange.respond(.{ .status = .internal_server_error }, "") catch {
                try session.submitReset(config.allocator, slot.stream_id, .internal_error);
                finishSlot(slot, handler, config, true);
            };
        }
    }
}

/// Queue as much response output as the session accepts. Returns whether any
/// slot made progress; the caller flushes and calls again.
fn pumpAll(
    session: *Session,
    slots: []Slot,
    handler: Handler,
    config: Config,
) !bool {
    var progressed = false;
    for (slots) |*slot| {
        if (!slot.used or !slot.handler_called) continue;
        const response = slot.exchange.response orelse continue;

        if (!slot.headers_sent) {
            const end = response.body.len == 0;
            session.submitResponse(
                config.allocator,
                slot.stream_id,
                response.fields,
                end,
            ) catch |err| switch (err) {
                error.WouldBlock => continue,
                error.UnknownStream, error.StreamClosed => {
                    finishSlot(slot, handler, config, true);
                    progressed = true;
                    continue;
                },
                else => return err,
            };
            slot.headers_sent = true;
            progressed = true;
            if (end) {
                finishSlot(slot, handler, config, true);
                continue;
            }
        }

        while (slot.body_offset < response.body.len) {
            const accepted = session.submitData(
                config.allocator,
                slot.stream_id,
                response.body[slot.body_offset..],
                true,
            ) catch |err| switch (err) {
                error.UnknownStream, error.StreamClosed => {
                    finishSlot(slot, handler, config, true);
                    progressed = true;
                    break;
                },
                else => return err,
            };
            if (accepted == 0) break;
            slot.body_offset += accepted;
            progressed = true;
        }

        if (slot.body_offset == response.body.len) {
            finishSlot(slot, handler, config, true);
            progressed = true;
        }
    }
    return progressed;
}

fn finishSlot(slot: *Slot, handler: Handler, config: Config, call_complete: bool) void {
    if (call_complete and slot.handler_called) {
        handler.vtable.complete(handler.ptr, &slot.exchange);
    }
    _ = slot.arena.reset(.{ .retain_with_limit = config.arena_retain_bytes });
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

fn completeAll(slots: []Slot, handler: Handler, config: Config) void {
    for (slots) |*slot| {
        if (slot.used) finishSlot(slot, handler, config, true);
    }
}

fn flush(session: *Session, w: *Io.Writer, out: []u8) !void {
    while (true) {
        const n = session.send(out);
        if (n == 0) break;
        try w.writeAll(out[0..n]);
    }
    try w.flush();
}

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
