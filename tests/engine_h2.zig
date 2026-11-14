//! Integration test for the direct HTTP/2 engine over a real loopback socket.
//!
//! The client is the sans-I/O session, so the test covers the transport loop
//! and the exchange engine without speaking raw frames by hand.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;

const http = @import("http");
const engine = http.h2.engine.direct;
const Handler = http.h2.engine.Handler;
const Exchange = http.h2.engine.Exchange;

const TestApp = struct {
    body: []const u8 = "hello",
    /// A trailing header section, which is how a gRPC server returns status.
    trailers: []const http.Header = &.{},
    /// Build the trailer section on the handler's own stack and scribble over
    /// it after `respond`, to prove the engine copied it.
    stack_trailers: bool = false,
    seen: usize = 0,

    fn handler(self: *TestApp) Handler {
        return .{ .ptr = self, .vtable = &.{
            .handle = handle,
            .complete = Handler.noopComplete,
            .report_error = reportError,
            .policy_response = Handler.defaultPolicyResponse,
        } };
    }

    fn handle(ptr: *anyopaque, exchange: *Exchange) anyerror!void {
        const self: *TestApp = @ptrCast(@alignCast(ptr));
        self.seen += 1;
        if (self.stack_trailers) {
            var name_storage: [32]u8 = undefined;
            var value_storage: [32]u8 = undefined;
            @memcpy(name_storage[0..11], "grpc-status");
            @memcpy(value_storage[0..1], "0");
            var fields = [_]http.Header{.{
                .name = name_storage[0..11],
                .value = value_storage[0..1],
            }};
            try exchange.respond(.{
                .status = .ok,
                .content_type = "text/plain",
                .trailers = &fields,
            }, self.body);
            // The engine sends the trailers after this frame is gone. It must
            // have copied them, or the peer sees this garbage.
            @memset(&name_storage, 'X');
            @memset(&value_storage, 'Y');
            @memset(std.mem.asBytes(&fields), 'Z');
            return;
        }
        try exchange.respond(.{
            .status = .ok,
            .content_type = "text/plain",
            .trailers = self.trailers,
        }, self.body);
    }

    fn reportError(_: *anyopaque, _: anyerror) void {}
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
    app: TestApp = .{},
    server: Server,
    thread: std.Thread,

    fn init(self: *Harness) !void {
        try self.initWith(.{});
    }

    fn initWith(self: *Harness, app: TestApp) !void {
        self.io = testing.io;
        self.app = app;
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
            std.debug.panic("server failed: {s}", .{@errorName(err)});
        }
        self.* = undefined;
    }

    fn connect(self: *Harness) !Io.net.Stream {
        return self.address.connect(self.io, .{ .mode = .stream });
    }
};

const request_fields = [_]http.Header{
    .{ .name = ":method", .value = "GET" },
    .{ .name = ":scheme", .value = "http" },
    .{ .name = ":authority", .value = "example.com" },
    .{ .name = ":path", .value = "/" },
};

fn flush(session: *http.h2.Session, w: *Io.Writer) !void {
    var out: [4096]u8 = undefined;
    while (true) {
        const n = session.send(&out);
        if (n == 0) break;
        try w.writeAll(out[0..n]);
    }
    try w.flush();
}

fn nextEvent(session: *http.h2.Session, r: *Io.Reader) !?http.h2.session.Event {
    while (true) {
        if (try session.nextEvent(testing.allocator)) |event| return event;
        var read_buffer: [4096]u8 = undefined;
        var vecs: [1][]u8 = .{&read_buffer};
        const n = r.readVec(&vecs) catch |err| switch (err) {
            error.EndOfStream => return null,
            error.ReadFailed => return err,
        };
        if (n == 0) return null;
        _ = session.receive(read_buffer[0..n]);
    }
}

fn handshake(session: *http.h2.Session, r: *Io.Reader, w: *Io.Writer) !void {
    while (!session.settings_received) {
        const event = try nextEvent(session, r) orelse return error.EndOfStream;
        switch (event) {
            .settings => try flush(session, w),
            .connection_error => return error.ConnectionError,
            else => {},
        }
    }
}

test "the direct engine serves a request over a socket" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();

    const stream = try harness.connect();
    defer stream.close(harness.io);

    var reader = stream.reader(harness.io, &.{});
    var write_buffer: [4096]u8 = undefined;
    var writer = stream.writer(harness.io, &write_buffer);
    const r = &reader.interface;
    const w = &writer.interface;

    var session = try http.h2.Session.init(testing.allocator, .{
        .role = .client,
        .max_streams = 4,
    });
    defer session.deinit(testing.allocator);

    try flush(&session, w);
    try handshake(&session, r, w);

    _ = try session.submitRequest(testing.allocator, &request_fields, true);
    try flush(&session, w);

    var response_seen = false;
    var data_seen = false;
    while (!data_seen) {
        const event = try nextEvent(&session, r) orelse return error.EndOfStream;
        switch (event) {
            .response => |response| {
                try testing.expectEqual(@as(u16, 200), response.head.status.code());
                response_seen = true;
            },
            .data => |data| {
                try testing.expectEqualStrings("hello", data.bytes);
                try testing.expect(data.end_stream);
                data_seen = true;
            },
            .settings => try flush(&session, w),
            .connection_error => return error.ConnectionError,
            else => {},
        }
    }

    try testing.expect(response_seen);
    try testing.expectEqual(@as(usize, 1), harness.app.seen);
}

test "the direct engine sends a trailer section after the body" {
    var harness: Harness = undefined;
    try harness.initWith(.{
        .trailers = &.{.{ .name = "grpc-status", .value = "0" }},
    });
    defer harness.deinit();

    const stream = try harness.connect();
    defer stream.close(harness.io);

    var reader = stream.reader(harness.io, &.{});
    var write_buffer: [4096]u8 = undefined;
    var writer = stream.writer(harness.io, &write_buffer);
    const r = &reader.interface;
    const w = &writer.interface;

    var session = try http.h2.Session.init(testing.allocator, .{
        .role = .client,
        .max_streams = 4,
    });
    defer session.deinit(testing.allocator);

    try flush(&session, w);
    try handshake(&session, r, w);

    _ = try session.submitRequest(testing.allocator, &request_fields, true);
    try flush(&session, w);

    // The body must not carry END_STREAM: the trailer section follows it.
    var response_seen = false;
    var data_seen = false;
    var trailers_seen = false;
    while (!trailers_seen) {
        const event = try nextEvent(&session, r) orelse return error.EndOfStream;
        switch (event) {
            .response => |response| {
                try testing.expectEqual(@as(u16, 200), response.head.status.code());
                try testing.expect(!response.end_stream);
                response_seen = true;
            },
            .data => |data| {
                try testing.expectEqualStrings("hello", data.bytes);
                try testing.expect(!data.end_stream);
                data_seen = true;
            },
            .trailers => |trailers| {
                try testing.expectEqualStrings("0", trailers.headers.get("grpc-status").?);
                trailers_seen = true;
            },
            .settings => try flush(&session, w),
            .connection_error => return error.ConnectionError,
            else => {},
        }
    }

    try testing.expect(response_seen);
    try testing.expect(data_seen);
}

test "the engine copies a stack-built trailer section" {
    var harness: Harness = undefined;
    try harness.initWith(.{ .stack_trailers = true });
    defer harness.deinit();

    const stream = try harness.connect();
    defer stream.close(harness.io);

    var reader = stream.reader(harness.io, &.{});
    var write_buffer: [4096]u8 = undefined;
    var writer = stream.writer(harness.io, &write_buffer);
    const r = &reader.interface;
    const w = &writer.interface;

    var session = try http.h2.Session.init(testing.allocator, .{
        .role = .client,
        .max_streams = 4,
    });
    defer session.deinit(testing.allocator);

    try flush(&session, w);
    try handshake(&session, r, w);

    _ = try session.submitRequest(testing.allocator, &request_fields, true);
    try flush(&session, w);

    var trailers_seen = false;
    while (!trailers_seen) {
        const event = try nextEvent(&session, r) orelse return error.EndOfStream;
        switch (event) {
            .trailers => |trailers| {
                try testing.expectEqualStrings("0", trailers.headers.get("grpc-status").?);
                trailers_seen = true;
            },
            .settings => try flush(&session, w),
            .connection_error => return error.ConnectionError,
            else => {},
        }
    }
}
