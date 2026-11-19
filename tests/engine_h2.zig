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
const SplitReader = @import("split_reader.zig").SplitReader;
const StalledReader = @import("split_reader.zig").StalledReader;
const TrickleReader = @import("split_reader.zig").TrickleReader;
const IdleReader = @import("split_reader.zig").IdleReader;

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

/// Parks first, then spends longer than the stall bound on a streaming
/// response. Neither the handler nor its output belongs in an empty-read run.
const WakeWorkApp = struct {
    io: Io,
    expiries: usize = 0,
    finished: bool = false,

    fn handler(self: *WakeWorkApp) Handler {
        return .{ .ptr = self, .vtable = &.{
            .handle = handle,
            .complete = Handler.noopComplete,
            .report_error = Handler.noopReportError,
            .policy_response = Handler.defaultPolicyResponse,
        } };
    }

    fn handle(ptr: *anyopaque, exchange: *Exchange) anyerror!void {
        const self: *WakeWorkApp = @ptrCast(@alignCast(ptr));
        if (self.finished) return;
        if (exchange.wake != .expired) {
            const wake = Io.Clock.now(.awake, self.io).addDuration(.fromMilliseconds(10));
            exchange.setDeadline(try .init(try .fromStd(wake)));
            return exchange.waitForProgress();
        }
        self.expiries += 1;
        try self.io.sleep(.fromMilliseconds(150), .awake);
        try exchange.beginResponse(.{ .status = .ok, .content_type = "text/plain" });
        if (try exchange.write("hello") != 5) return error.ShortResponseWrite;
        try exchange.endResponse(&.{});
        self.finished = true;
    }
};

/// Produces no bytes until the wake handler finishes, then returns empty reads
/// for 40 ms before EOF. The 50 ms engine bound must survive both intervals.
const WakeWorkReader = struct {
    reader: Io.Reader,
    io: Io,
    app: *const WakeWorkApp,
    request: []const u8,
    request_sent: bool = false,
    finished_zero_started: ?Io.Timestamp = null,

    fn init(self: *WakeWorkReader, io: Io, app: *const WakeWorkApp, request: []const u8) void {
        self.reader = .{
            .vtable = &.{ .stream = stream, .readVec = readVec },
            .buffer = &.{},
            .seek = 0,
            .end = 0,
        };
        self.io = io;
        self.app = app;
        self.request = request;
        self.request_sent = false;
        self.finished_zero_started = null;
    }

    fn stream(_: *Io.Reader, _: *Io.Writer, _: Io.Limit) Io.Reader.StreamError!usize {
        return 0;
    }

    fn readVec(reader: *Io.Reader, data: [][]u8) Io.Reader.Error!usize {
        const self: *WakeWorkReader = @alignCast(@fieldParentPtr("reader", reader));
        if (!self.request_sent) {
            self.request_sent = true;
            std.debug.assert(self.request.len <= data[0].len);
            @memcpy(data[0][0..self.request.len], self.request);
            return self.request.len;
        }
        if (!self.app.finished) return 0;
        const current: Io.Timestamp = .now(self.io, .awake);
        const began = self.finished_zero_started orelse {
            self.finished_zero_started = current;
            return 0;
        };
        if (began.durationTo(current).nanoseconds < 40 * std.time.ns_per_ms) return 0;
        return error.EndOfStream;
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

fn expectBufferedHellos(client: *http.h2.Session, response: []const u8, expected: usize) !void {
    try testing.expectEqual(response.len, client.receive(response));
    var response_count: usize = 0;
    var data_count: usize = 0;
    while (data_count < expected) {
        const event = try client.nextEvent(testing.allocator) orelse return error.EndOfStream;
        switch (event) {
            .response => |head| {
                try testing.expectEqual(@as(u16, 200), head.head.status.code());
                response_count += 1;
            },
            .data => |data| {
                try testing.expectEqualStrings("hello", data.bytes);
                data_count += 1;
            },
            .connection_error => return error.ConnectionError,
            else => {},
        }
    }
    try testing.expectEqual(expected, response_count);
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

test "a zero read in a split request head is not EOF" {
    var client: http.h2.Session = try .init(testing.allocator, .{
        .role = .client,
        .max_streams = 4,
    });
    defer client.deinit(testing.allocator);

    var request_storage: [4096]u8 = undefined;
    var request_writer: Io.Writer = .fixed(&request_storage);
    try flush(&client, &request_writer);
    _ = try client.submitRequest(testing.allocator, &request_fields, true);
    try flush(&client, &request_writer);
    const request = request_writer.buffered();
    try testing.expect(request.len > 1);

    const records = [_][]const u8{
        request[0 .. request.len - 1],
        request[request.len - 1 ..],
    };
    var source: SplitReader = undefined;
    source.init(&records);
    var response_storage: [4096]u8 = undefined;
    var response_writer: Io.Writer = .fixed(&response_storage);
    var read_buffer: [16 * 1024]u8 = undefined;
    var app: TestApp = .{};
    try engine.serveIo(testing.io, &source.reader, &response_writer, app.handler(), .{
        .allocator = testing.allocator,
        .read_buffer = &read_buffer,
        .write_buffer = &.{},
        .max_streams = 4,
        .common = .{ .body_bytes = 1024 },
    });

    try testing.expectEqual(1, source.zero_reads);
    try testing.expectEqual(1, app.seen);

    try expectBufferedHellos(&client, response_writer.buffered(), 1);
}

test "empty zero reads do not end a split head" {
    var client: http.h2.Session = try .init(testing.allocator, .{
        .role = .client,
        .max_streams = 4,
    });
    defer client.deinit(testing.allocator);

    var request_storage: [4096]u8 = undefined;
    var request_writer: Io.Writer = .fixed(&request_storage);
    try flush(&client, &request_writer);
    _ = try client.submitRequest(testing.allocator, &request_fields, true);
    try flush(&client, &request_writer);
    const request = request_writer.buffered();
    try testing.expect(request.len > 1);

    const records = [_][]const u8{
        request[0 .. request.len - 1],
        "",
        "",
        "",
        request[request.len - 1 ..],
    };
    var source: SplitReader = undefined;
    source.init(&records);
    var response_storage: [4096]u8 = undefined;
    var response_writer: Io.Writer = .fixed(&response_storage);
    var read_buffer: [16 * 1024]u8 = undefined;
    var app: TestApp = .{};
    try engine.serveIo(testing.io, &source.reader, &response_writer, app.handler(), .{
        .allocator = testing.allocator,
        .read_buffer = &read_buffer,
        .write_buffer = &.{},
        .max_streams = 4,
        .common = .{ .body_bytes = 1024 },
    });

    try testing.expectEqual(records.len, source.record_index);
    try testing.expectEqual(4, source.zero_reads);
    try testing.expectEqual(1, app.seen);
    try expectBufferedHellos(&client, response_writer.buffered(), 1);
}

test "a reader that returns zero forever stalls" {
    var source: StalledReader = undefined;
    source.init();
    var response_storage: [4096]u8 = undefined;
    var response_writer: Io.Writer = .fixed(&response_storage);
    var read_buffer: [16 * 1024]u8 = undefined;
    var app: TestApp = .{};

    try testing.expectError(error.ReaderStalled, engine.serveIo(
        testing.io,
        &source.reader,
        &response_writer,
        app.handler(),
        .{
            .allocator = testing.allocator,
            .read_buffer = &read_buffer,
            .write_buffer = &.{},
            .max_streams = 4,
            .common = .{ .body_bytes = 1024 },
            .stall_timeout = .fromMilliseconds(1),
        },
    ));
    try testing.expect(source.reads > 0);
    try testing.expectEqual(0, app.seen);
}

test "wait_fd polls for the remaining stall budget" {
    const address: Io.net.IpAddress = try .parseLiteral("127.0.0.1:0");
    var listener = try address.listen(testing.io, .{ .mode = .stream, .reuse_address = true });
    defer listener.deinit(testing.io);
    var client_address = address;
    client_address.setPort(listener.socket.address.getPort());
    const client_stream = try client_address.connect(testing.io, .{ .mode = .stream });
    defer client_stream.close(testing.io);
    const server_stream = try listener.accept(testing.io);
    defer server_stream.close(testing.io);

    var source: StalledReader = undefined;
    source.init();
    var response_storage: [4096]u8 = undefined;
    var response_writer: Io.Writer = .fixed(&response_storage);
    var read_buffer: [16 * 1024]u8 = undefined;
    var app: TestApp = .{};
    try testing.expectError(error.ReaderStalled, engine.serveIo(
        testing.io,
        &source.reader,
        &response_writer,
        app.handler(),
        .{
            .allocator = testing.allocator,
            .read_buffer = &read_buffer,
            .write_buffer = &.{},
            .max_streams = 4,
            .common = .{ .body_bytes = 1024 },
            .wait_fd = .init(server_stream.socket.handle),
            .stall_timeout = .fromMilliseconds(5),
        },
    ));
    try testing.expectEqual(1, source.reads);
}

test "bytes between empty reads reset the stall timeout" {
    var client: http.h2.Session = try .init(testing.allocator, .{
        .role = .client,
        .max_streams = 4,
    });
    defer client.deinit(testing.allocator);

    var request_storage: [4096]u8 = undefined;
    var request_writer: Io.Writer = .fixed(&request_storage);
    try flush(&client, &request_writer);
    _ = try client.submitRequest(testing.allocator, &request_fields, true);
    try flush(&client, &request_writer);
    const request = request_writer.buffered();

    const delay_ms = 5;
    var source: TrickleReader = undefined;
    source.init(testing.io, request, .fromMilliseconds(delay_ms));
    var response_storage: [4096]u8 = undefined;
    var response_writer: Io.Writer = .fixed(&response_storage);
    var read_buffer: [16 * 1024]u8 = undefined;
    var app: TestApp = .{};
    try engine.serveIo(testing.io, &source.reader, &response_writer, app.handler(), .{
        .allocator = testing.allocator,
        .read_buffer = &read_buffer,
        .write_buffer = &.{},
        .max_streams = 4,
        .common = .{ .body_bytes = 1024 },
        .stall_timeout = .fromMilliseconds(100),
    });

    try testing.expect(source.zero_reads * delay_ms > 100);
    try testing.expectEqual(1, app.seen);
    try expectBufferedHellos(&client, response_writer.buffered(), 1);
}

test "idle time before an empty read does not start the stall clock" {
    var client: http.h2.Session = try .init(testing.allocator, .{
        .role = .client,
        .max_streams = 4,
    });
    defer client.deinit(testing.allocator);

    var request_storage: [4096]u8 = undefined;
    var request_writer: Io.Writer = .fixed(&request_storage);
    try flush(&client, &request_writer);
    _ = try client.submitRequest(testing.allocator, &request_fields, true);
    try flush(&client, &request_writer);
    const first_len = request_writer.buffered().len;
    _ = try client.submitRequest(testing.allocator, &request_fields, true);
    try flush(&client, &request_writer);
    const request = request_writer.buffered();

    var source: IdleReader = undefined;
    source.init(
        testing.io,
        request[0..first_len],
        request[first_len..],
        .fromMilliseconds(60),
    );
    var response_storage: [4096]u8 = undefined;
    var response_writer: Io.Writer = .fixed(&response_storage);
    var read_buffer: [16 * 1024]u8 = undefined;
    var app: TestApp = .{};
    try engine.serveIo(testing.io, &source.reader, &response_writer, app.handler(), .{
        .allocator = testing.allocator,
        .read_buffer = &read_buffer,
        .write_buffer = &.{},
        .max_streams = 4,
        .common = .{ .body_bytes = 1024 },
        .stall_timeout = .fromMilliseconds(50),
    });

    try testing.expectEqual(2, app.seen);
    try expectBufferedHellos(&client, response_writer.buffered(), 2);
}

test "wake work and output do not extend an empty-read stall" {
    var client: http.h2.Session = try .init(testing.allocator, .{
        .role = .client,
        .max_streams = 4,
    });
    defer client.deinit(testing.allocator);

    var request_storage: [4096]u8 = undefined;
    var request_writer: Io.Writer = .fixed(&request_storage);
    try flush(&client, &request_writer);
    _ = try client.submitRequest(testing.allocator, &request_fields, true);
    try flush(&client, &request_writer);

    var app: WakeWorkApp = .{ .io = testing.io };
    var source: WakeWorkReader = undefined;
    source.init(testing.io, &app, request_writer.buffered());
    var response_storage: [4096]u8 = undefined;
    var response_writer: Io.Writer = .fixed(&response_storage);
    var read_buffer: [16 * 1024]u8 = undefined;
    try engine.serveIo(testing.io, &source.reader, &response_writer, app.handler(), .{
        .allocator = testing.allocator,
        .read_buffer = &read_buffer,
        .write_buffer = &.{},
        .max_streams = 4,
        .body_mode = .stream,
        .common = .{ .body_bytes = 1024 },
        .stall_timeout = .fromMilliseconds(50),
    });

    try testing.expectEqual(1, app.expiries);
    try testing.expect(app.finished);
    try expectBufferedHellos(&client, response_writer.buffered(), 1);
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

/// Read with a deadline. The test drives raw frames, so a missing response
/// must fail the test rather than run into the CI job timeout.
fn readSome(r: *Io.Reader, stream: Io.net.Stream, buf: []u8) !usize {
    if (r.bufferedLen() == 0) {
        var fds = [_]std.posix.pollfd{.{
            .fd = stream.socket.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const ready = try std.posix.poll(&fds, 5_000);
        if (ready == 0) return error.ReadTimedOut;
    }
    var vecs: [1][]u8 = .{buf};
    return r.readVec(&vecs);
}

/// Find one frame by type in an accumulated byte stream. The test reads raw
/// bytes because it sends frames that no conforming client session will emit.
fn findFrame(bytes: []const u8, kind: http.h2.frame.FrameType) ?[]const u8 {
    var off: usize = 0;
    while (off + 9 <= bytes.len) {
        const length = (@as(usize, bytes[off]) << 16) |
            (@as(usize, bytes[off + 1]) << 8) |
            bytes[off + 2];
        if (off + 9 + length > bytes.len) return null;
        if (bytes[off + 3] == @backingInt(kind)) return bytes[off + 9 ..][0..length];
        off += 9 + length;
    }
    return null;
}

test "the nginx2root window sequence ends in a flow-control GOAWAY" {
    var harness: Harness = undefined;
    // Ten bytes of body, but only five bytes of stream credit. The engine
    // sends a prefix and keeps the stream open, which is nginx's state when
    // the reset returns the queued DATA's credit a second time.
    try harness.initWith(.{ .body = "0123456789" });
    defer harness.deinit();

    const stream = try harness.connect();
    defer stream.close(harness.io);

    var reader = stream.reader(harness.io, &.{});
    var write_buffer: [4096]u8 = undefined;
    var writer = stream.writer(harness.io, &write_buffer);
    const r = &reader.interface;
    const w = &writer.interface;

    // A client session only to produce a valid HPACK HEADERS frame. Its own
    // preface and SETTINGS are discarded; the raw client below writes those.
    var encoder = try http.h2.Session.init(testing.allocator, .{ .role = .client });
    defer encoder.deinit(testing.allocator);
    var enc_out: [512]u8 = undefined;
    while (encoder.send(&enc_out) != 0) {}
    _ = try encoder.submitRequest(testing.allocator, &request_fields, true);
    const headers_len = encoder.send(&enc_out);
    try testing.expect(headers_len > 0);
    try testing.expectEqual(
        @as(u8, @backingInt(http.h2.frame.FrameType.headers)),
        enc_out[3],
    );

    var frame_buf: [32]u8 = undefined;

    try w.writeAll(http.h2.frame.preface);

    // SETTINGS_INITIAL_WINDOW_SIZE = 0: the server can send response headers
    // but no response DATA until the client grants stream credit.
    var settings = http.h2.frame.Writer.init(&frame_buf);
    try settings.begin(.settings, 0, 0);
    try settings.int(u16, @backingInt(http.h2.frame.SettingId.initial_window_size));
    try settings.int(u32, 0);
    settings.end();
    try w.writeAll(settings.written());

    // Raise the connection send window to its maximum, as the exploit does.
    const raise: u31 = @intCast(http.h2.flow.max_window - 65_535);
    var update = http.h2.frame.Writer.init(&frame_buf);
    try update.begin(.window_update, 0, 0);
    try update.int(u32, raise);
    update.end();
    try w.writeAll(update.written());

    try w.writeAll(enc_out[0..headers_len]);

    // The server has queued the response head and wants to send five bytes of
    // body but has no stream window. Grant exactly those five bytes: the DATA
    // consumes five from the connection window.
    var stream_update = http.h2.frame.Writer.init(&frame_buf);
    try stream_update.begin(.window_update, 0, 1);
    try stream_update.int(u32, 5);
    stream_update.end();
    try w.writeAll(stream_update.written());
    try w.flush();

    var collected: std.ArrayList(u8) = .empty;
    defer collected.deinit(testing.allocator);
    var read_buffer: [4096]u8 = undefined;

    // Wait for the body before resetting. The engine must have run the
    // handler and consumed the five bytes of connection credit; only then is
    // the reset the same state nginx was in.
    var data_seen = false;
    while (!data_seen) {
        const n = readSome(r, stream, &read_buffer) catch |err| switch (err) {
            error.EndOfStream => break,
            error.ReadTimedOut => {
                std.debug.print("timed out with {d} response bytes\n", .{collected.items.len});
                return err;
            },
            else => return err,
        };
        if (n == 0) break;
        try collected.appendSlice(testing.allocator, read_buffer[0..n]);
        if (findFrame(collected.items, .data)) |payload| {
            try testing.expectEqualStrings("01234", payload);
            data_seen = true;
        }
    }
    try testing.expect(data_seen);
    try testing.expectEqual(@as(usize, 1), harness.app.seen);

    // Put the connection window back at its maximum. In nginx the reset below
    // then adds the queued DATA's credit a second time.
    var conn_update = http.h2.frame.Writer.init(&frame_buf);
    try conn_update.begin(.window_update, 0, 0);
    try conn_update.int(u32, 5);
    conn_update.end();
    try w.writeAll(conn_update.written());

    var reset = http.h2.frame.Writer.init(&frame_buf);
    try reset.begin(.rst_stream, 0, 1);
    try reset.int(u32, @backingInt(http.h2.frame.ErrorCode.cancel));
    reset.end();
    try w.writeAll(reset.written());
    try w.flush();

    // One past the maximum. nginx accepted this after its unsigned check
    // underflowed; this server must answer with GOAWAY(FLOW_CONTROL_ERROR).
    var over = http.h2.frame.Writer.init(&frame_buf);
    try over.begin(.window_update, 0, 0);
    try over.int(u32, 1);
    over.end();
    try w.writeAll(over.written());
    try w.flush();

    var goaway: ?[]const u8 = null;
    while (goaway == null) {
        const n = readSome(r, stream, &read_buffer) catch |err| switch (err) {
            error.EndOfStream => break,
            error.ReadTimedOut => {
                std.debug.print("timed out with {d} response bytes\n", .{collected.items.len});
                return err;
            },
            else => return err,
        };
        if (n == 0) break;
        try collected.appendSlice(testing.allocator, read_buffer[0..n]);
        goaway = findFrame(collected.items, .goaway);
    }

    const payload = goaway orelse return error.MissingGoAway;
    try testing.expectEqual(
        @as(u32, @backingInt(http.h2.frame.ErrorCode.flow_control_error)),
        std.mem.readInt(u32, payload[4..][0..4], .big),
    );
}
