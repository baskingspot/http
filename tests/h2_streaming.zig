//! Full-duplex HTTP/2 streaming, end to end over a loopback socket.
//!
//! The server is the blocking engine in `.stream` body mode; the client is the
//! blocking adapter using `begin`, `BodyWriter`, and `response`. The test that
//! decides whether request-body streaming works is the first one here: two
//! request/response messages cross on one stream while the request body is
//! still open.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;

const http = @import("http");
const engine = http.h2.engine.blocking;
const Handler = http.h2.engine.Handler;
const Exchange = http.h2.engine.Exchange;
const client_mod = http.h2.client.blocking;
const Client = client_mod.Client;

/// Echo every request chunk as a response chunk, before END_STREAM. The
/// response head goes out with the first chunk and the trailers with the last.
const EchoApp = struct {
    response_started: bool = false,
    turns: usize = 0,
    chunks: usize = 0,
    bytes: usize = 0,
    saw_end: bool = false,
    ended: bool = false,
    answered_before_end: bool = false,
    /// Reset the stream on the first body chunk instead of answering.
    reset_first: bool = false,
    /// The tail of a chunk the peer had no window for. The borrowed chunk is
    /// valid until the next `next`, so it must be finished first.
    pending: []const u8 = &.{},
    /// Never read the body, so the unread balance is what grows.
    deaf: bool = false,
    failure: ?anyerror = null,

    fn handler(self: *EchoApp) Handler {
        return .{ .ptr = self, .vtable = &.{
            .handle = handle,
            .complete = Handler.noopComplete,
            .report_error = reportError,
            .policy_response = Handler.defaultPolicyResponse,
        } };
    }

    /// Queue `bytes`, keeping the unsent tail in `pending` when the peer has
    /// no credit. False means the turn must park.
    fn writeAll(self: *EchoApp, exchange: *Exchange, bytes: []const u8) anyerror!bool {
        self.pending = bytes;
        while (self.pending.len != 0) {
            const written = try exchange.write(self.pending);
            if (written == 0) return false;
            self.pending = self.pending[written..];
            self.bytes += written;
        }
        return true;
    }

    fn handle(ptr: *anyopaque, exchange: *Exchange) anyerror!void {
        const self: *EchoApp = @ptrCast(@alignCast(ptr));
        self.turns += 1;
        if (self.deaf) return exchange.waitForProgress();
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
                // RFC 9113 §6.1: END_STREAM on DATA ends the request side and
                // leaves the response side open for the answer.
                error.EndOfStream => {
                    self.saw_end = true;
                    if (!self.response_started) {
                        try exchange.beginResponse(.{ .status = .ok });
                        self.response_started = true;
                    }
                    const trailers = [_]http.Header{
                        .{ .name = "grpc-status", .value = "0" },
                    };
                    try exchange.endResponse(&trailers);
                    self.ended = true;
                    return;
                },
                else => return err,
            };
            if (self.reset_first) {
                try exchange.resetStream(.cancel);
                return;
            }
            if (!self.response_started) {
                try exchange.beginResponse(.{
                    .status = .ok,
                    .content_type = "application/grpc",
                });
                self.response_started = true;
            }
            if (!self.saw_end) self.answered_before_end = true;

            if (!try self.writeAll(exchange, chunk.data)) {
                return exchange.waitForProgress();
            }
            self.chunks += 1;
        }
    }

    fn reportError(ptr: *anyopaque, err: anyerror) void {
        const self: *EchoApp = @ptrCast(@alignCast(ptr));
        self.failure = err;
    }
};

const Server = struct {
    io: Io,
    listener: *Io.net.Server,
    handler: Handler,
    result: ?anyerror = null,

    fn run(self: *Server) void {
        const stream = self.listener.accept(self.io) catch |err| {
            self.result = err;
            return;
        };
        defer stream.close(self.io);

        var read_buffer: [4096]u8 = undefined;
        var write_buffer: [4096]u8 = undefined;
        engine.serve(self.io, stream, self.handler, .{
            .allocator = testing.allocator,
            .read_buffer = &read_buffer,
            .write_buffer = &write_buffer,
            .max_streams = 4,
            .body_mode = .stream,
            .common = .{ .body_bytes = 1024 },
        }) catch |err| {
            self.result = err;
        };
    }
};

const Harness = struct {
    io: Io,
    listener: Io.net.Server,
    address: Io.net.IpAddress,
    app: EchoApp = .{},
    server: Server,
    thread: std.Thread,
    /// The test closes the socket as its last act, and a blocking reader can
    /// see that as `ReadFailed` rather than a clean EOF. Neither is a server
    /// bug; a failure that matters reaches the handler first.
    allow_read_failed: bool = true,

    fn init(self: *Harness) !void {
        return self.initApp(.{});
    }

    fn initApp(self: *Harness, app: EchoApp) !void {
        self.io = testing.io;
        self.app = app;
        self.allow_read_failed = true;
        const address: Io.net.IpAddress = try .parseLiteral("127.0.0.1:0");
        self.listener = try address.listen(self.io, .{
            .mode = .stream,
            .reuse_address = true,
        });
        self.address = address;
        self.address.setPort(self.listener.socket.address.getPort());
        self.server = .{
            .io = self.io,
            .listener = &self.listener,
            .handler = self.app.handler(),
        };
        self.thread = try .spawn(.{}, Server.run, .{&self.server});
    }

    fn deinit(self: *Harness) void {
        self.thread.join();
        self.listener.deinit(self.io);
        if (self.server.result) |err| {
            if (!(self.allow_read_failed and err == error.ReadFailed)) {
                std.debug.panic("server failed: {s}", .{@errorName(err)});
            }
        }
        self.* = undefined;
    }

    fn connect(self: *Harness) !Io.net.Stream {
        return self.address.connect(self.io, .{ .mode = .stream });
    }
};

/// Regular fields only; pseudo-headers come from the `Request`.
const fields = [_]http.Header{
    .{ .name = "content-type", .value = "application/grpc" },
    .{ .name = "te", .value = "trailers" },
};

test "two request and response messages cross before END_STREAM (RFC 9113 §5.1)" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();

    const stream = try harness.connect();
    defer stream.close(harness.io);

    var reader = stream.reader(harness.io, &.{});
    var write_buffer: [4096]u8 = undefined;
    var writer = stream.writer(harness.io, &write_buffer);

    var client: Client = undefined;
    try client.init(
        &reader.interface,
        &writer.interface,
        .{ .allocator = testing.allocator },
    );
    defer client.deinit();

    const body_writer = try client.begin(.{
        .method_token = "POST",
        .scheme = .http,
        .authority = "example.com",
        .target = "/chat",
        .headers = &fields,
    });

    // Pair one: send a message, then read the answer. The request body is
    // open the whole time: no END_STREAM has been queued.
    try body_writer.write("one");
    const response = try client.response();
    defer response.body.close();
    try testing.expectEqual(http.client.Protocol.h2, response.head.protocol);
    try testing.expectEqual(@as(u16, 200), response.head.status.code());
    try testing.expectEqualStrings(
        "application/grpc",
        response.head.headers.get("content-type").?,
    );
    try testing.expectEqualStrings("one", (try response.body.read()).data);
    try testing.expect(!harness.app.saw_end);

    // Pair two: the response body is still open, and so is the request.
    try body_writer.write("two");
    try testing.expectEqualStrings("two", (try response.body.read()).data);

    // Now end the request. The server ends its response with trailers.
    body_writer.close();
    try testing.expectError(error.EndOfStream, response.body.read());

    try testing.expectEqual(@as(usize, 2), harness.app.chunks);
    try testing.expectEqual(@as(usize, 6), harness.app.bytes);
    try testing.expect(harness.app.answered_before_end);
    try testing.expect(harness.app.saw_end);
    try testing.expect(harness.app.ended);
    try testing.expectEqual(@as(?anyerror, null), harness.app.failure);
}

test "a peer that outruns the handler past body_bytes is reset (RFC 9113 §5.4.2)" {
    var harness: Harness = undefined;
    try harness.initApp(.{ .deaf = true });
    defer harness.deinit();

    const stream = try harness.connect();
    defer stream.close(harness.io);

    var reader = stream.reader(harness.io, &.{});
    var write_buffer: [4096]u8 = undefined;
    var writer = stream.writer(harness.io, &write_buffer);

    var client: Client = undefined;
    try client.init(
        &reader.interface,
        &writer.interface,
        .{ .allocator = testing.allocator },
    );
    defer client.deinit();

    const body_writer = try client.begin(.{
        .method_token = "POST",
        .scheme = .http,
        .authority = "example.com",
        .target = "/chat",
        .headers = &fields,
    });

    var chunk: [300]u8 = undefined;
    @memset(&chunk, 'x');
    // The handler never reads, so the unread balance is what the 1024-byte cap
    // bounds. Four 300-byte chunks must trip it rather than grow storage.
    var refused = false;
    for (0..4) |_| {
        body_writer.write(&chunk) catch {
            refused = true;
            break;
        };
    }
    body_writer.close();
    // The reset arrives at the writer, at the response head, or mid-response
    // body; all three are the documented outcome.
    var refused_outcome = refused;
    if (client.response()) |response| {
        defer response.body.close();
        while (true) {
            _ = response.body.read() catch {
                refused_outcome = true;
                break;
            };
        }
    } else |err| {
        try testing.expectEqual(error.StreamReset, err);
        refused_outcome = true;
    }
    try testing.expect(refused_outcome);
    // Nothing was consumed, so nothing was echoed.
    try testing.expectEqual(@as(usize, 0), harness.app.chunks);
    try testing.expectEqual(@as(usize, 0), harness.app.bytes);
}

test "a reset mid-body reaches the writer as Reset (RFC 9113 6.8)" {
    var harness: Harness = undefined;
    try harness.initApp(.{ .reset_first = true });
    defer harness.deinit();

    const stream = try harness.connect();
    defer stream.close(harness.io);

    var reader = stream.reader(harness.io, &.{});
    var write_buffer: [4096]u8 = undefined;
    var writer = stream.writer(harness.io, &write_buffer);

    var client: Client = undefined;
    try client.init(
        &reader.interface,
        &writer.interface,
        .{ .allocator = testing.allocator },
    );
    defer client.deinit();

    const body_writer = try client.begin(.{
        .method_token = "POST",
        .scheme = .http,
        .authority = "example.com",
        .target = "/chat",
        .headers = &fields,
    });

    var saw_reset = false;
    for (0..4) |_| {
        body_writer.write("chunk") catch |err| switch (err) {
            error.Reset => {
                saw_reset = true;
                break;
            },
            else => return err,
        };
    }
    body_writer.close();
    if (!saw_reset) try testing.expectError(error.StreamReset, client.response());
    try testing.expect(harness.app.chunks <= 1);
}

/// The two gRPC messages from the acceptance sequence, byte for byte.
const grpc_one = "\x00\x00\x00\x00\x05\x0a\x03one";
const grpc_two = "\x00\x00\x00\x00\x05\x0a\x03two";

/// The next event that carries application data; flow control and SETTINGS
/// are bookkeeping, not part of the sequence under test.
fn nextSessionEvent(session: *http.h2.Session) !?http.h2.session.Event {
    while (try session.nextEvent(testing.allocator)) |event| {
        switch (event) {
            .window_update, .settings => continue,
            else => return event,
        }
    }
    return null;
}

/// Move one side's queued output into the other and drain its events.
fn pumpToConnection(from: *http.h2.Session, to: *http.h2.engine.Connection) !void {
    var buffer: [4096]u8 = undefined;
    while (true) {
        const n = from.send(&buffer);
        if (n == 0) break;
        var offset: usize = 0;
        while (offset < n) {
            const written = to.receive(buffer[offset..n]);
            if (written == 0) {
                _ = try to.drive(Io.Timestamp.zero);
                continue;
            }
            offset += written;
            _ = try to.drive(Io.Timestamp.zero);
        }
    }
    _ = try to.drive(Io.Timestamp.zero);
}

fn pumpToSession(from: *http.h2.engine.Connection, to: *http.h2.Session) !void {
    var buffer: [4096]u8 = undefined;
    while (true) {
        const n = from.send(&buffer);
        if (n == 0) break;
        var offset: usize = 0;
        while (offset < n) {
            const written = to.receive(buffer[offset..n]);
            if (written == 0) return error.InputStuck;
            offset += written;
        }
    }
}

// The wire sequence grpc-lead named, frame for frame. One stream:
//
//     C HEADERS (END_HEADERS, no END_STREAM)
//     C DATA 00000000050a036f6e65
//     S HEADERS (END_HEADERS, no END_STREAM)  :status 200
//     S DATA 00000000050a036f6e65
//     C DATA 00000000050a0374776f
//     S DATA 00000000050a0374776f
//     C DATA (empty, END_STREAM)
//     S HEADERS (END_HEADERS|END_STREAM) grpc-status: 0
//
// The assertion that matters is the order: each response frame exists before
// the client sends the next request frame, and END_STREAM on the request
// comes last. RFC 9113 §5.1 keeps the stream open in both directions until
// either side ends its half.
test "grpc full duplex: two echoes before END_STREAM (RFC 9113 5.1)" {
    const grpc_fields = [_]http.Header{
        .{ .name = ":method", .value = "POST" },
        .{ .name = ":scheme", .value = "http" },
        .{ .name = ":authority", .value = "example.com" },
        .{ .name = ":path", .value = "/svc.Method" },
        .{ .name = "content-type", .value = "application/grpc+proto" },
        .{ .name = "te", .value = "trailers" },
    };

    var app: EchoApp = .{};
    var server = try http.h2.engine.Connection.init(.{
        .allocator = testing.allocator,
        .handler = app.handler(),
        .body_mode = .stream,
    });
    defer server.deinit();

    var client = try http.h2.Session.init(testing.allocator, .{ .role = .client });
    defer client.deinit(testing.allocator);

    try pumpToConnection(&client, &server);
    try pumpToSession(&server, &client);
    while (try nextSessionEvent(&client)) |_| {}

    const id = try client.submitRequest(testing.allocator, &grpc_fields, false);
    try pumpToConnection(&client, &server);
    // The handler ran on the head with the body still open.
    try testing.expectEqual(@as(usize, 1), app.turns);
    try testing.expect(!app.response_started);

    _ = try client.submitData(testing.allocator, id, grpc_one, false);
    try pumpToConnection(&client, &server);
    try pumpToSession(&server, &client);

    const response_head = (try nextSessionEvent(&client)).?;
    switch (response_head) {
        .response => |response| {
            try testing.expectEqual(@as(u16, 200), response.head.status.code());
            try testing.expect(!response.end_stream);
        },
        else => return error.TestUnexpectedResult,
    }
    const echo_one = (try nextSessionEvent(&client)).?;
    switch (echo_one) {
        .data => |data| {
            try testing.expectEqualSlices(u8, grpc_one, data.bytes);
            try testing.expect(!data.end_stream);
        },
        else => return error.TestUnexpectedResult,
    }
    try client.release(testing.allocator, id, grpc_one.len);
    // Both response frames exist while the request half is still open.
    try testing.expect(!app.saw_end);

    _ = try client.submitData(testing.allocator, id, grpc_two, false);
    try pumpToConnection(&client, &server);
    try pumpToSession(&server, &client);
    const echo_two = (try nextSessionEvent(&client)).?;
    switch (echo_two) {
        .data => |data| {
            try testing.expectEqualSlices(u8, grpc_two, data.bytes);
            try testing.expect(!data.end_stream);
        },
        else => return error.TestUnexpectedResult,
    }
    try client.release(testing.allocator, id, grpc_two.len);
    try testing.expect(!app.saw_end);

    _ = try client.submitData(testing.allocator, id, "", true);
    try pumpToConnection(&client, &server);
    try pumpToSession(&server, &client);
    const trailing = (try nextSessionEvent(&client)).?;
    switch (trailing) {
        .trailers => |trailers| {
            try testing.expect(trailers.end_stream);
            try testing.expectEqualStrings("0", trailers.headers.get("grpc-status").?);
        },
        else => return error.TestUnexpectedResult,
    }
    try testing.expect(app.saw_end);
    try testing.expect(app.ended);
    try testing.expectEqual(@as(?anyerror, null), app.failure);
}

/// Sends the response head, then arms a deadline that has already passed and
/// parks. On expiry it finishes the response it started, which is what a gRPC
/// server does with DEADLINE_EXCEEDED: no second response.
const DeadlineApp = struct {
    turns: usize = 0,
    expired_turns: usize = 0,
    started: bool = false,
    ended: bool = false,
    failure: ?anyerror = null,

    fn handler(self: *DeadlineApp) Handler {
        return .{ .ptr = self, .vtable = &.{
            .handle = handle,
            .complete = Handler.noopComplete,
            .report_error = reportError,
            .policy_response = Handler.defaultPolicyResponse,
        } };
    }

    fn handle(ptr: *anyopaque, exchange: *Exchange) anyerror!void {
        const self: *DeadlineApp = @ptrCast(@alignCast(ptr));
        self.turns += 1;
        switch (exchange.wake) {
            .expired => {
                self.expired_turns += 1;
                const trailers = [_]http.Header{
                    .{ .name = "grpc-status", .value = "4" },
                };
                try exchange.endResponse(&trailers);
                self.ended = true;
            },
            .progress => {
                if (self.started) return exchange.waitForProgress();
                try exchange.beginResponse(.{
                    .status = .ok,
                    .content_type = "application/grpc",
                });
                self.started = true;
                // Already in the past: the engine sees it on its next turn.
                exchange.setDeadline(try .init(.fromNanoseconds(0)));
                return exchange.waitForProgress();
            },
        }
    }

    fn reportError(ptr: *anyopaque, err: anyerror) void {
        const self: *DeadlineApp = @ptrCast(@alignCast(ptr));
        self.failure = err;
    }
};

test "an expiry finishes the response it started, not a second one" {
    const io = testing.io;

    const address: Io.net.IpAddress = try .parseLiteral("127.0.0.1:0");
    var listener = try address.listen(io, .{ .mode = .stream, .reuse_address = true });
    defer listener.deinit(io);
    var bound = address;
    bound.setPort(listener.socket.address.getPort());

    var app: DeadlineApp = .{};
    var server: Server = .{ .io = io, .listener = &listener, .handler = app.handler() };
    const thread = try std.Thread.spawn(.{}, Server.run, .{&server});
    defer thread.join();
    defer if (server.result) |err| {
        if (err != error.ReadFailed) std.debug.panic("server failed: {s}", .{@errorName(err)});
    };

    const stream = try bound.connect(io, .{ .mode = .stream });
    defer stream.close(io);

    var reader = stream.reader(io, &.{});
    var write_buffer: [4096]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);

    var client: Client = undefined;
    try client.init(&reader.interface, &writer.interface, .{ .allocator = testing.allocator });
    defer client.deinit();

    const body_writer = try client.begin(.{
        .method_token = "POST",
        .scheme = .http,
        .authority = "example.com",
        .target = "/deadline",
        .headers = &fields,
    });
    // The request body stays open: the deadline fires with no END_STREAM.
    try body_writer.write("never finished");

    const response = try client.response();
    defer response.body.close();
    try testing.expectEqual(@as(u16, 200), response.head.status.code());

    // The response ends with no data, because the expiry finished it.
    const result = response.body.read() catch |err| switch (err) {
        error.EndOfStream => null,
        else => return err,
    };
    try testing.expect(result == null);

    try testing.expectEqual(@as(usize, 1), app.expired_turns);
    try testing.expect(app.started);
    try testing.expect(app.ended);
}
