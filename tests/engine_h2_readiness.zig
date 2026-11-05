//! Integration test for the readiness HTTP/2 engine over a real loopback
//! socket. poll(2) on Linux, kqueue(2) on macOS.
//!
//! The client is the sans-I/O session, so the test covers the transport loop
//! and the exchange engine without speaking raw frames by hand.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const Io = std.Io;

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
