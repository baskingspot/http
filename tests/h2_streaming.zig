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
    chunks: usize = 0,
    bytes: usize = 0,
    saw_end: bool = false,
    ended: bool = false,
    answered_before_end: bool = false,
    failure: ?anyerror = null,

    fn handler(self: *EchoApp) Handler {
        return .{ .ptr = self, .vtable = &.{
            .handle = handle,
            .complete = Handler.noopComplete,
            .report_error = reportError,
            .policy_response = Handler.defaultPolicyResponse,
        } };
    }

    fn handle(ptr: *anyopaque, exchange: *Exchange) anyerror!void {
        const self: *EchoApp = @ptrCast(@alignCast(ptr));
        const body = exchange.request_body.?;
        while (true) {
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
            if (!self.response_started) {
                try exchange.beginResponse(.{
                    .status = .ok,
                    .content_type = "application/grpc",
                });
                self.response_started = true;
            }
            if (!self.saw_end) self.answered_before_end = true;

            var rest = chunk.data;
            while (rest.len != 0) {
                const written = try exchange.write(rest);
                if (written == 0) return exchange.waitForProgress();
                rest = rest[written..];
                self.bytes += written;
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
        self.io = testing.io;
        self.app = .{};
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

test "a request body over body_bytes gets a reset, not a bigger buffer (RFC 9113 §5.4.2)" {
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

    var chunk: [300]u8 = undefined;
    @memset(&chunk, 'x');
    // The engine caps the request body at 1024 bytes. The fourth chunk is the
    // one that must fail rather than grow; the reset is the documented outcome
    // whether the writer or the response head sees it first.
    var refused = false;
    for (0..4) |_| {
        body_writer.write(&chunk) catch {
            refused = true;
            break;
        };
    }
    body_writer.close();
    if (!refused) {
        try testing.expectError(error.StreamReset, client.response());
    }
    try testing.expect(harness.app.chunks <= 4);
    try testing.expect(harness.app.bytes <= 1024);
}
