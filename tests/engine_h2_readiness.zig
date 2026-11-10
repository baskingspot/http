//! Integration test for the readiness HTTP/2 engine over a real loopback
//! socket. poll(2) on Linux, kqueue(2) on macOS.
//!
//! The client is the sans-I/O session, so the test covers the transport loop
//! and the exchange engine without speaking raw frames by hand.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const Io = std.Io;
const time = @import("stdx").time;

const http = @import("http");
const engine_options = @import("engine_options");
const Engine = switch (builtin.os.tag) {
    .linux => if (engine_options.epoll) http.h2.engine.epoll else http.h2.engine.poll,
    .macos => http.h2.engine.kqueue,
    else => @compileError("the readiness engine test is Linux and macOS only"),
};
const Handler = http.h2.engine.Handler;
const Exchange = http.h2.engine.Exchange;

const TestApp = struct {
    body: []const u8 = "hello",
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
        try exchange.respond(.{
            .status = .ok,
            .content_type = "text/plain",
        }, self.body);
    }

    fn reportError(_: *anyopaque, _: anyerror) void {}
};

const Server = struct {
    engine: Engine.Server,
    result: ?anyerror = null,

    fn run(self: *Server) void {
        self.engine.run() catch |err| {
            self.result = err;
        };
    }
};

const Harness = struct {
    io: Io,
    app: TestApp = .{},
    server: Server,
    thread: std.Thread,

    fn init(self: *Harness) !void {
        try self.initWithConfig(.{
            .allocator = testing.allocator,
            .max_connections = 4,
            .max_streams = 4,
            .common = .{ .body_bytes = 1024 },
        });
    }

    fn initWithConfig(self: *Harness, config: Engine.Config) !void {
        self.io = testing.io;
        self.app = .{};
        const address: Io.net.IpAddress = try .parseLiteral("127.0.0.1:0");
        self.server = .{
            .engine = try Engine.Server.init(self.io, address, self.app.handler(), config),
        };
        self.thread = try .spawn(.{}, Server.run, .{&self.server});
    }

    fn deinit(self: *Harness) void {
        self.server.engine.requestStop();
        self.thread.join();
        self.server.engine.deinit();
        if (self.server.result) |err| {
            std.debug.panic("server failed: {s}", .{@errorName(err)});
        }
        self.* = undefined;
    }

    fn connect(self: *Harness) !Io.net.Stream {
        return self.server.engine.address().connect(self.io, .{ .mode = .stream });
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

test "the readiness engine serves a request over a socket" {
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

test "an idle deadline closes the connection" {
    var harness: Harness = undefined;
    try harness.initWithConfig(.{
        .allocator = testing.allocator,
        .max_connections = 4,
        .max_streams = 4,
        .common = .{ .body_bytes = 1024 },
        .idle_timeout = .fromMilliseconds(50),
    });
    defer harness.deinit();

    const stream = try harness.connect();
    defer stream.close(harness.io);

    var reader = stream.reader(harness.io, &.{});
    var buf: [16]u8 = undefined;
    var vecs: [1][]u8 = .{&buf};
    const n = reader.interface.readVec(&vecs) catch |err| switch (err) {
        error.EndOfStream => return,
        error.ReadFailed => return err,
    };
    try testing.expectEqual(@as(usize, 0), n);
}

test "a head deadline closes a silent connection" {
    var harness: Harness = undefined;
    try harness.initWithConfig(.{
        .allocator = testing.allocator,
        .max_connections = 4,
        .max_streams = 4,
        .common = .{ .body_bytes = 1024 },
        .head_timeout = .fromMilliseconds(50),
    });
    defer harness.deinit();

    const stream = try harness.connect();
    defer stream.close(harness.io);

    var reader = stream.reader(harness.io, &.{});
    var buf: [16]u8 = undefined;
    var vecs: [1][]u8 = .{&buf};
    const n = reader.interface.readVec(&vecs) catch |err| switch (err) {
        error.EndOfStream => return,
        error.ReadFailed => return err,
    };
    try testing.expectEqual(@as(usize, 0), n);
}

test "a body deadline closes a request that never ends" {
    var harness: Harness = undefined;
    try harness.initWithConfig(.{
        .allocator = testing.allocator,
        .max_connections = 4,
        .max_streams = 4,
        .common = .{ .body_bytes = 1024 },
        .body_timeout = .fromMilliseconds(50),
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
    _ = try session.submitRequest(testing.allocator, &request_fields, false);
    try flush(&session, w);

    try testing.expect((try nextEvent(&session, r)) == null);
}

test "stop sends GOAWAY and drains the connection" {
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

    var saw_data = false;
    while (!saw_data) {
        const event = try nextEvent(&session, r) orelse return error.EndOfStream;
        switch (event) {
            .data => |data| {
                try testing.expect(data.end_stream);
                saw_data = true;
            },
            .settings => try flush(&session, w),
            .connection_error => return error.ConnectionError,
            else => {},
        }
    }

    harness.server.engine.requestStop();
    while (true) {
        const event = try nextEvent(&session, r) orelse return error.EndOfStream;
        switch (event) {
            .goaway => |goaway| {
                try testing.expectEqual(http.h2.frame.ErrorCode.no_error, goaway.code);
                return;
            },
            .settings => try flush(&session, w),
            else => {},
        }
    }
}

/// Arms a future application deadline at the request head and finishes the
/// response when it expires. Nothing else happens on the connection: the wake
/// can only come from the poll timeout.
const DeadlineApp = struct {
    io: Io,
    wake_at: time.OptionalTimestamp = .none,
    turns: usize = 0,
    expiries: usize = 0,

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
        if (exchange.wake == .expired) {
            self.expiries += 1;
            if (!exchange.response_started) {
                try exchange.beginResponse(.{ .status = .ok });
            }
            return exchange.endResponse(&.{
                .{ .name = "x-deadline", .value = "expired" },
            });
        }
        if (self.wake_at.get() == null) {
            self.wake_at = try .init(try .fromStd(
                Io.Clock.awake.now(self.io).addDuration(.fromMilliseconds(100)),
            ));
            exchange.setDeadline(self.wake_at);
        }
        exchange.waitForProgress();
    }

    fn reportError(_: *anyopaque, _: anyerror) void {}
};

const DeadlineServer = struct {
    engine: Engine.Server,
    result: ?anyerror = null,

    fn run(self: *DeadlineServer) void {
        self.engine.run() catch |err| {
            self.result = err;
        };
    }
};

const DeadlineHarness = struct {
    io: Io,
    app: DeadlineApp,
    server: DeadlineServer,
    thread: std.Thread,

    fn init(self: *DeadlineHarness) !void {
        self.io = testing.io;
        self.app = .{ .io = self.io };
        const address: Io.net.IpAddress = try .parseLiteral("127.0.0.1:0");
        self.server = .{
            .engine = try Engine.Server.init(self.io, address, self.app.handler(), .{
                .allocator = testing.allocator,
                .max_connections = 4,
                .max_streams = 4,
                .common = .{ .body_bytes = 1024 },
                .body_mode = .stream,
                // A wrong implementation loses the wakeup and waits forever.
                // This turns that hang into a closed connection and a test
                // failure instead.
                .total_timeout = .fromSeconds(5),
            }),
        };
        self.thread = try .spawn(.{}, DeadlineServer.run, .{&self.server});
    }

    fn deinit(self: *DeadlineHarness) void {
        self.server.engine.requestStop();
        self.thread.join();
        self.server.engine.deinit();
        if (self.server.result) |err| {
            std.debug.panic("server failed: {s}", .{@errorName(err)});
        }
        self.* = undefined;
    }

    fn connect(self: *DeadlineHarness) !Io.net.Stream {
        return self.server.engine.address().connect(self.io, .{ .mode = .stream });
    }
};

fn deadlineCase(request_end_stream: bool) !void {
    var harness: DeadlineHarness = undefined;
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

    _ = try session.submitRequest(
        testing.allocator,
        &request_fields,
        request_end_stream,
    );
    try flush(&session, w);

    // No further input. The only way the response can arrive is the poll
    // waking on the handler's own deadline.
    var saw_head = false;
    var saw_trailers = false;
    while (!saw_trailers) {
        const event = try nextEvent(&session, r) orelse return error.EndOfStream;
        switch (event) {
            .response => |response| {
                try testing.expectEqual(@as(u16, 200), response.head.status.code());
                saw_head = true;
            },
            .trailers => |trailers| {
                try testing.expect(trailers.end_stream);
                try testing.expectEqualStrings(
                    "expired",
                    trailers.headers.get("x-deadline").?,
                );
                saw_trailers = true;
            },
            .settings => try flush(&session, w),
            .connection_error => return error.ConnectionError,
            else => {},
        }
    }

    try testing.expect(saw_head);
    try testing.expectEqual(@as(usize, 1), harness.app.expiries);
}

test "a future handler deadline wakes the poll with the request still open" {
    try deadlineCase(false);
}

test "a future handler deadline wakes the poll after request END_STREAM" {
    try deadlineCase(true);
}

/// Echo every request chunk as a response chunk before END_STREAM. The tail a
/// zero write could not take lives in `pending`, never in a local.
const EchoApp = struct {
    turns: usize = 0,
    pending: []const u8 = &.{},
    saw_end: bool = false,

    fn handler(self: *EchoApp) Handler {
        return .{ .ptr = self, .vtable = &.{
            .handle = handle,
            .complete = Handler.noopComplete,
            .report_error = Handler.noopReportError,
            .policy_response = Handler.defaultPolicyResponse,
        } };
    }

    fn handle(ptr: *anyopaque, exchange: *Exchange) anyerror!void {
        const self: *EchoApp = @ptrCast(@alignCast(ptr));
        self.turns += 1;
        if (exchange.wake != .progress) return;
        const body = exchange.request_body orelse return;
        while (true) {
            if (self.pending.len == 0) {
                const chunk = body.next() catch |err| switch (err) {
                    error.Pending, error.Canceled => return exchange.waitForProgress(),
                    error.EndOfStream => {
                        self.saw_end = true;
                        if (!exchange.response_started) {
                            try exchange.beginResponse(.{ .status = .ok });
                        }
                        const trailers = [_]http.Header{
                            .{ .name = "grpc-status", .value = "0" },
                        };
                        return exchange.endResponse(&trailers);
                    },
                    else => return err,
                };
                if (!exchange.response_started) {
                    try exchange.beginResponse(.{ .status = .ok });
                }
                self.pending = chunk.data;
            }
            const written = try exchange.write(self.pending);
            if (written == 0) return exchange.waitForProgress();
            self.pending = self.pending[written..];
        }
    }
};

const EchoServer = struct {
    engine: Engine.Server,
    result: ?anyerror = null,

    fn run(self: *EchoServer) void {
        self.engine.run() catch |err| {
            self.result = err;
        };
    }
};

const EchoHarness = struct {
    io: Io,
    app: EchoApp,
    server: EchoServer,
    thread: std.Thread,

    fn init(self: *EchoHarness) !void {
        self.io = testing.io;
        self.app = .{};
        const address: Io.net.IpAddress = try .parseLiteral("127.0.0.1:0");
        self.server = .{
            .engine = try Engine.Server.init(self.io, address, self.app.handler(), .{
                .allocator = testing.allocator,
                .max_connections = 4,
                .max_streams = 4,
                .common = .{ .body_bytes = 1024 },
                .body_mode = .stream,
                .total_timeout = .fromSeconds(5),
            }),
        };
        self.thread = try .spawn(.{}, EchoServer.run, .{&self.server});
    }

    fn deinit(self: *EchoHarness) void {
        self.server.engine.requestStop();
        self.thread.join();
        self.server.engine.deinit();
        if (self.server.result) |err| {
            std.debug.panic("server failed: {s}", .{@errorName(err)});
        }
        self.* = undefined;
    }

    fn connect(self: *EchoHarness) !Io.net.Stream {
        return self.server.engine.address().connect(self.io, .{ .mode = .stream });
    }
};

/// Read until one DATA event arrives; returns its bytes through `sink`.
fn readData(
    session: *http.h2.Session,
    r: *Io.Reader,
    w: *Io.Writer,
    sink: []u8,
) ![]const u8 {
    while (true) {
        const event = try nextEvent(session, r) orelse return error.EndOfStream;
        switch (event) {
            .data => |data| {
                try testing.expect(!data.end_stream);
                @memcpy(sink[0..data.bytes.len], data.bytes);
                return sink[0..data.bytes.len];
            },
            .settings => try flush(session, w),
            .connection_error => return error.ConnectionError,
            else => {},
        }
    }
}

test "the readiness engine streams two pairs before END_STREAM" {
    var harness: EchoHarness = undefined;
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

    const id = try session.submitRequest(testing.allocator, &request_fields, false);
    try flush(&session, w);

    var sink: [64]u8 = undefined;

    _ = try session.submitData(testing.allocator, id, "one", false);
    try flush(&session, w);
    try testing.expectEqualStrings("one", try readData(&session, r, w, &sink));
    // The request half is still open when the first echo arrives.
    try testing.expect(!harness.app.saw_end);

    _ = try session.submitData(testing.allocator, id, "two", false);
    try flush(&session, w);
    try testing.expectEqualStrings("two", try readData(&session, r, w, &sink));
    try testing.expect(!harness.app.saw_end);

    _ = try session.submitData(testing.allocator, id, "", true);
    try flush(&session, w);

    var saw_trailers = false;
    while (!saw_trailers) {
        const event = try nextEvent(&session, r) orelse return error.EndOfStream;
        switch (event) {
            .trailers => |trailers| {
                try testing.expect(trailers.end_stream);
                try testing.expectEqualStrings(
                    "0",
                    trailers.headers.get("grpc-status").?,
                );
                saw_trailers = true;
            },
            .settings => try flush(&session, w),
            .connection_error => return error.ConnectionError,
            else => {},
        }
    }
    try testing.expect(harness.app.saw_end);
}
