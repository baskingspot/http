//! A step-shaped, multiplexed HTTP/2 client.
//!
//! One `Connection` owns one `h2.Session` and all stream state. The caller
//! feeds transport bytes, drains complete frames, and polls events. No method
//! reads or writes a socket, and no method blocks.
//!
//! Requests are opened as `Stream` handles. Request DATA is written as a
//! prefix under flow control; a short write is backpressure, not an error.
//! Response DATA is returned as a `DataLease`: the bytes are borrowed until
//! the next poll, and the lease returns exactly the application-byte charge to
//! both windows. Padding is credited by the session before the event reaches
//! the caller. Headers and trailers are snapshots in the stream arena.

const std = @import("std");
const compat = @import("../../compat.zig");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const frame = @import("../frame.zig");
const session_mod = @import("../session.zig");
const Session = session_mod.Session;
const SessionEvent = session_mod.Event;
const shared = @import("../../client/root.zig");
const Header = @import("../../header.zig").Header;
const Headers = @import("../../header.zig").Headers;

// ast-grep-ignore: public-struct-field-default -- request shape; headers are optional
pub const Request = struct {
    method_token: []const u8,
    scheme: shared.Scheme,
    authority: []const u8,
    target: []const u8,
    headers: []const Header = &.{},
};

pub const Close = union(enum) {
    end_stream,
    reset: u32,
    goaway,
    local: shared.Local,
};

pub const DataLease = struct {
    conn: *Connection,
    stream: u31,
    generation: u32,

    /// Return `n` consumed application bytes to the connection and stream
    /// windows. A lease can be consumed in pieces.
    pub fn consume(self: DataLease, n: u32) !void {
        try self.conn.releaseLease(self.stream, self.generation, n);
    }

    /// Return every remaining byte in this lease.
    pub fn release(self: DataLease) !void {
        try self.conn.releaseLease(self.stream, self.generation, null);
    }
};

pub const Event = union(enum) {
    head: struct {
        stream: u31,
        head: shared.ResponseHead,
        end_stream: bool,
    },
    data: struct {
        stream: u31,
        bytes: []const u8,
        lease: DataLease,
    },
    trailers: struct {
        stream: u31,
        headers: Headers,
    },
    closed: struct {
        stream: u31,
        reason: Close,
    },
    writable: struct {
        stream: u31,
    },
    goaway: shared.GoAway,
};

// ast-grep-ignore: public-struct-field-default -- options bag; defaults are the policy
pub const Options = struct {
    allocator: Allocator,
    max_streams: u16 = 64,
    max_header_bytes: usize = 16 * 1024,
    max_headers: usize = 128,
    session: session_mod.Options = .{ .role = .client },
};

pub const Stream = struct {
    conn: *Connection,
    id: u31,
    generation: u32,

    /// Queue request DATA. Returns the accepted prefix and never waits. A
    /// short result is backpressure: drain frames and poll for `.writable`.
    pub fn write(self: Stream, bytes: []const u8, end_stream: bool) !usize {
        return self.conn.write(self.id, self.generation, bytes, end_stream);
    }

    /// Send an empty DATA frame with END_STREAM.
    pub fn finish(self: Stream) !void {
        const n = try self.write("", true);
        assert(n == 0);
    }

    pub fn cancel(self: Stream, code: frame.ErrorCode) !void {
        return self.conn.cancel(self.id, self.generation, code);
    }

    /// Response trailers, available after the trailers event and before the
    /// next poll after `.closed`.
    pub fn trailers(self: Stream) Headers {
        return self.conn.trailers(self.id, self.generation);
    }
};

const Slot = struct {
    used: bool = false,
    retired: bool = false,
    id: u31 = 0,
    generation: u32 = 0,
    arena: std.heap.ArenaAllocator,
    lease_remaining: u32 = 0,
    lease_generation: u32 = 0,
    remote_end: bool = false,
    local_end: bool = false,
    trailers_ready: bool = false,
    trailers: Headers = .{ .items = &.{} },
    close_reason: ?Close = null,
    want_write: bool = false,
};

// ast-grep-ignore: public-struct-field-default -- client state; init sets every field
pub const Connection = struct {
    allocator: Allocator,
    session: Session,
    slots: []Slot,
    max_header_bytes: usize,
    max_headers: usize,
    preface_remaining: usize,
    goaway: ?shared.GoAway = null,
    poisoned: bool = false,

    pub fn init(self: *Connection, options: Options) !void {
        if (options.max_streams == 0) return error.NoStreams;
        var session_options = options.session;
        session_options.role = .client;
        session_options.max_streams = options.max_streams;

        var session = try Session.init(options.allocator, session_options);
        errdefer session.deinit(options.allocator);
        const slots = try options.allocator.alloc(Slot, options.max_streams);
        errdefer options.allocator.free(slots);

        self.* = .{
            .allocator = options.allocator,
            .session = session,
            .slots = slots,
            .max_header_bytes = options.max_header_bytes,
            .max_headers = options.max_headers,
            .preface_remaining = frame.preface.len,
        };
        for (self.slots) |*slot| slot.* = .{ .arena = .init(options.allocator) };
    }

    pub fn deinit(self: *Connection) void {
        for (self.slots) |*slot| slot.arena.deinit();
        self.allocator.free(self.slots);
        self.session.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn receive(self: *Connection, bytes: []const u8) usize {
        return self.session.receive(bytes);
    }

    /// Drain one transport unit: the client preface first, then one complete
    /// frame. Returns 0 when nothing is queued.
    pub fn nextFrame(self: *Connection, out: []u8) !usize {
        if (self.preface_remaining != 0) {
            const n = @min(out.len, self.preface_remaining);
            const sent = self.session.send(out[0..n]);
            self.preface_remaining -= sent;
            return sent;
        }
        return self.session.sendFrame(out);
    }

    pub fn hasPendingOutput(self: *const Connection) bool {
        return self.session.hasPendingOutput();
    }

    /// True when the connection still needs peer bytes to make progress.
    ///
    /// A driver reads its socket only while this holds. `poll` returning null
    /// means "no event queued", which is not the same thing and never was: once
    /// the last stream closes, the queue stays empty forever and a read blocks
    /// until the peer hangs up. During the handshake it holds because the
    /// server SETTINGS has not arrived yet.
    pub fn wantsInput(self: *const Connection) bool {
        if (self.poisoned or self.goaway != null) return false;
        if (!self.session.settings_received) return true;
        for (self.slots) |*slot| {
            if (slot.used and slot.close_reason == null) return true;
        }
        return false;
    }

    pub fn canOpen(self: *const Connection) bool {
        return !self.poisoned and self.goaway == null and self.freeSlot() != null;
    }

    pub fn goAway(self: *const Connection) ?shared.GoAway {
        return self.goaway;
    }

    pub fn isPoisoned(self: *const Connection) bool {
        return self.poisoned;
    }

    pub fn open(self: *Connection, request: Request, end_stream: bool) !Stream {
        if (self.poisoned) return error.ConnectionPoisoned;
        if (self.goaway != null) return error.GoAway;
        if (request.authority.len == 0) return error.InvalidAuthority;

        const slot = self.freeSlot() orelse return error.TooManyStreams;
        const field_count = 4 + request.headers.len;
        const fields = try self.allocator.alloc(Header, field_count);
        defer self.allocator.free(fields);

        fields[0] = .{ .name = ":method", .value = request.method_token };
        fields[1] = .{ .name = ":scheme", .value = request.scheme.token() };
        fields[2] = .{ .name = ":authority", .value = request.authority };
        fields[3] = .{ .name = ":path", .value = request.target };
        for (request.headers, 0..) |header, index| {
            if (header.name.len == 0 or header.name[0] == ':') return error.InvalidHeader;
            if (std.ascii.eqlIgnoreCase(header.name, "host")) return error.DuplicateAuthority;
            fields[4 + index] = header;
        }

        const id = self.session.submitRequest(self.allocator, fields, end_stream) catch |err| {
            return err;
        };
        slot.generation +%= 1;
        slot.used = true;
        slot.retired = false;
        slot.id = id;
        slot.local_end = end_stream;
        slot.remote_end = false;
        slot.trailers_ready = false;
        slot.trailers = .{ .items = &.{} };
        slot.close_reason = null;
        slot.want_write = false;
        slot.lease_remaining = 0;
        slot.lease_generation = slot.generation;
        _ = slot.arena.reset(.free_all);
        return .{ .conn = self, .id = id, .generation = slot.generation };
    }

    /// Queue request DATA. A short count is backpressure; a zero count means
    /// the stream or connection window or the output budget is full.
    pub fn write(
        self: *Connection,
        id: u31,
        generation: u32,
        bytes: []const u8,
        end_stream: bool,
    ) !usize {
        const slot = self.findSlot(id, generation) orelse return error.StreamClosed;
        if (slot.local_end) return error.StreamClosed;
        const n = try self.session.submitData(self.allocator, id, bytes, end_stream);
        if (end_stream and n == bytes.len) {
            slot.local_end = true;
            slot.want_write = false;
        } else if (n != bytes.len) {
            slot.want_write = true;
        }
        return n;
    }

    pub fn cancel(self: *Connection, id: u31, generation: u32, code: frame.ErrorCode) !void {
        const slot = self.findSlot(id, generation) orelse return error.StreamClosed;
        try self.session.submitReset(self.allocator, id, code);
        slot.local_end = true;
        // Our own reset is a local cause, never `.reset`. The wire code we
        // chose is not the peer's story, and a caller that reads it back as a
        // peer reset cannot tell its own CANCEL from a server fault.
        slot.close_reason = .{ .local = .canceled };
    }

    pub fn trailers(self: *Connection, id: u31, generation: u32) Headers {
        const slot = self.findSlot(id, generation) orelse return .{ .items = &.{} };
        return slot.trailers;
    }

    /// Poll one event. Returns null when more transport bytes are needed.
    /// Call `nextFrame` after every event that may have queued output.
    pub fn poll(self: *Connection) !?Event {
        for (self.slots) |*slot| {
            if (slot.used and slot.lease_remaining != 0) return error.LeaseOutstanding;
        }
        self.reclaim();

        if (self.closedEvent()) |event| return event;
        if (self.poisoned) return error.ConnectionClosed;

        while (true) {
            const event = try self.session.nextEvent(self.allocator) orelse return null;
            switch (event) {
                .settings => {},
                .window_update => |update| {
                    if (self.writableEvent(update.stream_id)) |writable| {
                        return writable;
                    }
                },
                .response => |response| {
                    const slot = self.slotById(response.stream_id) orelse
                        return error.UnexpectedStream;
                    if (response.head.status.class() == .informational) {
                        if (response.end_stream) return error.ProtocolError;
                        continue;
                    }
                    const headers = try self.snapshot(slot, response.head.headers);
                    if (response.end_stream) {
                        slot.remote_end = true;
                        slot.close_reason = .end_stream;
                    }
                    return .{ .head = .{
                        .stream = response.stream_id,
                        .head = .{
                            .protocol = .h2,
                            .status = response.head.status,
                            .headers = headers,
                        },
                        .end_stream = response.end_stream,
                    } };
                },
                .data => |data| {
                    const slot = self.slotById(data.stream_id) orelse
                        return error.UnexpectedStream;
                    if (data.end_stream) slot.remote_end = true;
                    if (data.bytes.len == 0) {
                        if (slot.remote_end) slot.close_reason = .end_stream;
                        continue;
                    }
                    slot.lease_remaining = @intCast(data.bytes.len);
                    slot.lease_generation = slot.generation;
                    return .{ .data = .{
                        .stream = data.stream_id,
                        .bytes = data.bytes,
                        .lease = .{
                            .conn = self,
                            .stream = data.stream_id,
                            .generation = slot.generation,
                        },
                    } };
                },
                .trailers => |trailer_event| {
                    const slot = self.slotById(trailer_event.stream_id) orelse
                        return error.UnexpectedStream;
                    slot.trailers = try self.snapshot(slot, trailer_event.headers);
                    slot.trailers_ready = true;
                    slot.remote_end = true;
                    slot.close_reason = .end_stream;
                    return .{ .trailers = .{
                        .stream = trailer_event.stream_id,
                        .headers = slot.trailers,
                    } };
                },
                .reset => |reset| {
                    const slot = self.slotById(reset.stream_id) orelse
                        return error.UnexpectedStream;
                    slot.close_reason = .{ .reset = compat.enumToInt(reset.code) };
                    return self.takeClosed(slot, slot.close_reason.?);
                },
                .goaway => |goaway| {
                    self.goaway = .{
                        .last_stream_id = goaway.last_stream_id,
                        .code = compat.enumToInt(goaway.code),
                    };
                    for (self.slots) |*slot| {
                        if (!slot.used or slot.id <= goaway.last_stream_id) continue;
                        if (slot.close_reason == null) slot.close_reason = .goaway;
                    }
                    return .{ .goaway = self.goaway.? };
                },
                .connection_error => {
                    self.poisoned = true;
                    for (self.slots) |*slot| {
                        if (slot.used and slot.close_reason == null) {
                            slot.close_reason = .{ .local = .unusable };
                        }
                    }
                    if (self.closedEvent()) |closed| return closed;
                    return error.ConnectionClosed;
                },
                .request => return error.UnexpectedRequest,
            }
        }
    }

    fn releaseLease(self: *Connection, id: u31, generation: u32, count: ?u32) !void {
        const slot = self.findSlot(id, generation) orelse return error.StreamClosed;
        const n = count orelse slot.lease_remaining;
        if (n > slot.lease_remaining) return error.InvalidLease;
        if (n != 0) try self.session.release(self.allocator, id, n);
        slot.lease_remaining -= n;
        if (slot.lease_remaining == 0 and slot.remote_end) {
            slot.close_reason = .end_stream;
        }
    }

    fn snapshot(self: *Connection, slot: *Slot, headers: Headers) !Headers {
        if (headers.items.len > self.max_headers) return error.HeadersTooLarge;
        var total: usize = 0;
        for (headers.items) |header| {
            total = std.math.add(usize, total, header.name.len) catch
                return error.HeadersTooLarge;
            total = std.math.add(usize, total, header.value.len) catch
                return error.HeadersTooLarge;
        }
        if (total > self.max_header_bytes) return error.HeadersTooLarge;
        const arena = slot.arena.allocator();
        const items = try arena.alloc(Header, headers.items.len);
        const bytes = try arena.alloc(u8, total);
        var used: usize = 0;
        for (headers.items, 0..) |header, index| {
            @memcpy(bytes[used..][0..header.name.len], header.name);
            const name = bytes[used..][0..header.name.len];
            used += header.name.len;
            @memcpy(bytes[used..][0..header.value.len], header.value);
            const value = bytes[used..][0..header.value.len];
            used += header.value.len;
            items[index] = .{ .name = name, .value = value };
        }
        return .{ .items = items };
    }

    fn closedEvent(self: *Connection) ?Event {
        for (self.slots) |*slot| {
            if (!slot.used or slot.retired or slot.lease_remaining != 0) continue;
            const reason = slot.close_reason orelse continue;
            return self.takeClosed(slot, reason);
        }
        return null;
    }

    fn takeClosed(self: *Connection, slot: *Slot, reason: Close) Event {
        _ = self;
        slot.retired = true;
        return .{ .closed = .{ .stream = slot.id, .reason = reason } };
    }

    fn writableEvent(self: *Connection, id: u31) ?Event {
        if (id == 0) {
            for (self.slots) |*slot| {
                if (slot.used and slot.want_write) {
                    slot.want_write = false;
                    return .{ .writable = .{ .stream = slot.id } };
                }
            }
            return null;
        }
        const slot = self.slotById(id) orelse return null;
        if (!slot.want_write) return null;
        slot.want_write = false;
        return .{ .writable = .{ .stream = id } };
    }

    fn reclaim(self: *Connection) void {
        for (self.slots) |*slot| {
            if (slot.used and slot.retired) {
                slot.used = false;
                slot.retired = false;
                slot.id = 0;
                slot.trailers_ready = false;
                slot.trailers = .{ .items = &.{} };
                slot.close_reason = null;
                _ = slot.arena.reset(.free_all);
            }
        }
    }

    fn findSlot(self: *Connection, id: u31, generation: u32) ?*Slot {
        for (self.slots) |*slot| {
            if (slot.used and slot.id == id and slot.generation == generation) return slot;
        }
        return null;
    }

    fn slotById(self: *Connection, id: u31) ?*Slot {
        for (self.slots) |*slot| {
            if (slot.used and slot.id == id) return slot;
        }
        return null;
    }

    fn freeSlot(self: *Connection) ?*Slot {
        for (self.slots) |*slot| {
            if (!slot.used) return slot;
        }
        return null;
    }
};

test {
    _ = Connection;
}

const testing = std.testing;

fn transferConnection(conn: *Connection, server: *Session) !void {
    var buffer: [16 * 1024]u8 = undefined;
    while (true) {
        const n = try conn.nextFrame(&buffer);
        if (n == 0) break;
        var offset: usize = 0;
        while (offset < n) {
            const taken = server.receive(buffer[offset..n]);
            if (taken == 0) return error.InputFull;
            offset += taken;
        }
    }
}

fn transferServer(server: *Session, conn: *Connection) !void {
    var buffer: [16 * 1024]u8 = undefined;
    while (true) {
        const n = server.send(&buffer);
        if (n == 0) break;
        var offset: usize = 0;
        while (offset < n) {
            const taken = conn.receive(buffer[offset..n]);
            if (taken == 0) return error.InputFull;
            offset += taken;
        }
    }
}

fn nextServerEvent(server: *Session) !SessionEvent {
    return (try server.nextEvent(testing.allocator)) orelse return error.NoEvent;
}

/// The next request the server sees, skipping anything queued before it.
fn nextRequestId(server: *Session) !u31 {
    while (true) {
        switch (try nextServerEvent(server)) {
            .request => |value| return value.stream_id,
            else => {},
        }
    }
}

test "a bidi stream carries request and response DATA and trailers" {
    var client: Connection = undefined;
    try client.init(.{
        .allocator = testing.allocator,
        .max_streams = 4,
    });
    defer client.deinit();

    var server = try Session.init(testing.allocator, .{
        .role = .server,
        .max_streams = 4,
    });
    defer server.deinit(testing.allocator);

    // Server SETTINGS first, then the client preface and SETTINGS.
    try transferServer(&server, &client);
    try transferConnection(&client, &server);
    var saw_settings = false;
    while (true) {
        const event = try nextServerEvent(&server);
        if (event == .request) return error.UnexpectedRequest;
        if (event == .settings) {
            saw_settings = true;
            try transferServer(&server, &client);
            break;
        }
    }
    try testing.expect(saw_settings);

    _ = try client.poll();
    const stream = try client.open(.{
        .method_token = "POST",
        .scheme = .http,
        .authority = "example.com",
        .target = "/service/Method",
        .headers = &.{
            .{ .name = "content-type", .value = "application/grpc" },
            .{ .name = "te", .value = "trailers" },
        },
    }, false);

    try transferConnection(&client, &server);
    const request = try nextServerEvent(&server);
    const id = switch (request) {
        .request => |value| value.stream_id,
        else => return error.ExpectedRequest,
    };

    // The server responds before the client body is finished.
    try server.submitResponse(testing.allocator, id, .{
        .status = .ok,
        .content_type = "application/grpc",
    }, false);
    _ = try server.submitData(testing.allocator, id, "response", false);
    try transferServer(&server, &client);

    var head_seen = false;
    var data_seen = false;
    while (!data_seen) {
        const event = try client.poll() orelse return error.NoEvent;
        switch (event) {
            .head => |value| {
                try testing.expectEqual(id, value.stream);
                try testing.expectEqual(@as(u16, 200), value.head.status.code());
                head_seen = true;
            },
            .data => |value| {
                try testing.expectEqualStrings("response", value.bytes);
                try testing.expectError(error.LeaseOutstanding, client.poll());
                try value.lease.release();
                data_seen = true;
            },
            else => {},
        }
    }
    try testing.expect(head_seen);

    // The client sends its request body after the response has started.
    const written = try stream.write("request", false);
    try testing.expectEqual(@as(usize, 7), written);
    try stream.finish();
    try transferConnection(&client, &server);

    var request_body: [16]u8 = undefined;
    var request_used: usize = 0;
    var request_end_seen = false;
    while (!request_end_seen) {
        const event = try nextServerEvent(&server);
        switch (event) {
            .data => |value| {
                if (value.stream_id != id) continue;
                @memcpy(request_body[request_used..][0..value.bytes.len], value.bytes);
                request_used += value.bytes.len;
                try server.release(testing.allocator, id, value.flow_len);
                if (value.end_stream) request_end_seen = true;
            },
            .settings => try transferServer(&server, &client),
            else => {},
        }
    }
    try testing.expectEqualStrings("request", request_body[0..request_used]);

    const trailers = [_]Header{.{ .name = "grpc-status", .value = "0" }};
    try server.submitTrailers(testing.allocator, id, &trailers);
    try transferServer(&server, &client);

    var trailers_seen = false;
    var closed_seen = false;
    while (!closed_seen) {
        const event = try client.poll() orelse return error.NoEvent;
        switch (event) {
            .trailers => |value| {
                try testing.expectEqualStrings("0", value.headers.get("grpc-status").?);
                trailers_seen = true;
            },
            .closed => |value| {
                try testing.expectEqual(id, value.stream);
                try testing.expect(value.reason == .end_stream);
                closed_seen = true;
            },
            else => {},
        }
    }
    try testing.expect(trailers_seen);
    try testing.expectEqualStrings("0", stream.trailers().get("grpc-status").?);
}

test "a gRPC trailers-only response arrives as a head with END_STREAM" {
    var client: Connection = undefined;
    try client.init(.{
        .allocator = testing.allocator,
        .max_streams = 4,
    });
    defer client.deinit();

    var server = try Session.init(testing.allocator, .{
        .role = .server,
        .max_streams = 4,
    });
    defer server.deinit(testing.allocator);

    try transferServer(&server, &client);
    try transferConnection(&client, &server);
    while (true) {
        const event = try nextServerEvent(&server);
        if (event == .request) return error.UnexpectedRequest;
        if (event == .settings) {
            try transferServer(&server, &client);
            break;
        }
    }
    _ = try client.poll();

    // A unary gRPC call: one message, then END_STREAM on the request.
    const stream = try client.open(.{
        .method_token = "POST",
        .scheme = .http,
        .authority = "example.com",
        .target = "/service/Method",
        .headers = &.{
            .{ .name = "content-type", .value = "application/grpc+proto" },
            .{ .name = "te", .value = "trailers" },
        },
    }, true);

    try transferConnection(&client, &server);
    const request = try nextServerEvent(&server);
    const id = switch (request) {
        .request => |value| value.stream_id,
        else => return error.ExpectedRequest,
    };
    try testing.expectEqual(stream.id, id);

    // Trailers-only: one HEADERS with :status, content-type, and grpc-status,
    // then END_STREAM. No DATA and no separate trailers block.
    try server.submitResponse(testing.allocator, id, .{
        .status = .ok,
        .content_type = "application/grpc+proto",
        .headers = &.{.{ .name = "grpc-status", .value = "0" }},
    }, true);
    try transferServer(&server, &client);

    var head_seen = false;
    var closed_seen = false;
    while (!closed_seen) {
        const event = try client.poll() orelse return error.NoEvent;
        switch (event) {
            .head => |value| {
                try testing.expectEqual(id, value.stream);
                try testing.expectEqual(@as(u16, 200), value.head.status.code());
                // The status rides in the head, and unrecognised regular
                // fields survive verbatim.
                try testing.expectEqualStrings("0", value.head.headers.get("grpc-status").?);
                try testing.expectEqualStrings(
                    "application/grpc+proto",
                    value.head.headers.get("content-type").?,
                );
                try testing.expect(value.end_stream);
                head_seen = true;
            },
            .trailers => return error.UnexpectedTrailers,
            .closed => |value| {
                try testing.expectEqual(id, value.stream);
                try testing.expect(value.reason == .end_stream);
                closed_seen = true;
            },
            else => {},
        }
    }
    try testing.expect(head_seen);
    try testing.expectEqual(@as(usize, 0), stream.trailers().items.len);
}

test "a local cancel and a peer reset are distinguishable" {
    var client: Connection = undefined;
    try client.init(.{
        .allocator = testing.allocator,
        .max_streams = 4,
    });
    defer client.deinit();

    var server = try Session.init(testing.allocator, .{
        .role = .server,
        .max_streams = 4,
    });
    defer server.deinit(testing.allocator);

    // Before the server SETTINGS arrives the driver must keep reading.
    try testing.expect(client.wantsInput());

    try transferServer(&server, &client);
    try transferConnection(&client, &server);
    while (true) {
        const event = try nextServerEvent(&server);
        if (event == .request) return error.UnexpectedRequest;
        if (event == .settings) {
            try transferServer(&server, &client);
            break;
        }
    }
    _ = try client.poll();

    const request: Request = .{
        .method_token = "POST",
        .scheme = .http,
        .authority = "example.com",
        .target = "/service/Method",
        .headers = &.{
            .{ .name = "content-type", .value = "application/grpc+proto" },
            .{ .name = "te", .value = "trailers" },
        },
    };

    // Our own cancel reads back as a local cause, never as a peer reset.
    const first = try client.open(request, false);
    try transferConnection(&client, &server);
    const first_id = try nextRequestId(&server);
    try testing.expectEqual(first.id, first_id);
    try first.cancel(.cancel);

    const local = try client.poll() orelse return error.NoEvent;
    switch (local) {
        .closed => |value| {
            try testing.expectEqual(first.id, value.stream);
            try testing.expect(value.reason == .local);
            try testing.expectEqual(shared.Local.canceled, value.reason.local);
        },
        else => return error.ExpectedClosed,
    }

    // A peer reset carries the wire code, so REFUSED_STREAM stays retriable.
    _ = try client.poll();
    const second = try client.open(request, false);
    try transferConnection(&client, &server);
    // The server also sees our RST_STREAM, so skip to its next request.
    const second_id = try nextRequestId(&server);
    try testing.expectEqual(second.id, second_id);

    try server.submitReset(testing.allocator, second_id, .refused_stream);
    try transferServer(&server, &client);

    const peer = try client.poll() orelse return error.NoEvent;
    switch (peer) {
        .closed => |value| {
            try testing.expectEqual(second_id, value.stream);
            try testing.expect(value.reason == .reset);
            try testing.expectEqual(@as(u32, 0x7), value.reason.reset);
        },
        else => return error.ExpectedClosed,
    }

    // The last stream is done, so the driver must not read again. A read here
    // blocks until the peer hangs up, which for a live server is never.
    try testing.expect(!client.wantsInput());
}
