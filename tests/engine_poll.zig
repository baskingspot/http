//! Integration tests for the poll engine.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;

const http = @import("http");
const h1 = http.h1;
const engine = h1.engine.poll;

const TestApp = struct {
    pub fn handle(_: *TestApp, exchange: *engine.Exchange) anyerror!void {
        const target = exchange.request.head.target;
        if (std.mem.eql(u8, target, "/no-response")) return;
        if (std.mem.eql(u8, target, "/big")) {
            @memset(exchange.response_body, 'x');
            try exchange.respond(.{ .status = .ok }, exchange.response_body);
            return;
        }
        const body = try std.fmt.bufPrint(
            exchange.response_body,
            "{s} {d}\n",
            .{ target, exchange.request.body.len },
        );
        try exchange.respond(.{ .status = .ok, .content_type = "text/plain" }, body);
    }
};

const PollServer = engine.Server(TestApp);

const Harness = struct {
    io: Io,
    server: PollServer,
    thread: std.Thread,
    result: ?anyerror = null,
    address: Io.net.IpAddress,
    app: TestApp = .{},
    joined: bool = false,

    fn init(self: *Harness, limits: h1.ServerConn.Limits, max_connections: usize) !void {
        try self.initConfig(limits, max_connections, 8 * 1024);
    }

    fn initConfig(
        self: *Harness,
        limits: h1.ServerConn.Limits,
        max_connections: usize,
        response_body_bytes: usize,
    ) !void {
        self.io = testing.io;
        self.app = .{};
        self.result = null;
        self.joined = false;
        const address: Io.net.IpAddress = try .parseLiteral("127.0.0.1:0");
        self.server = try .init(self.io, address, &self.app, .{
            .allocator = testing.allocator,
            .max_connections = max_connections,
            .response_body_bytes = response_body_bytes,
            .limits = limits,
        });
        self.address = address;
        self.address.setPort(self.server.port());
        self.thread = try .spawn(.{}, runServer, .{self});
    }

    fn stop(self: *Harness) void {
        if (self.joined) return;
        self.server.stop();
        self.thread.join();
        self.joined = true;
    }

    fn deinit(self: *Harness) void {
        self.stop();
        self.server.deinit();
        if (self.result) |err| {
            std.debug.panic("poll server failed: {s}", .{@errorName(err)});
        }
    }

    fn runServer(self: *Harness) void {
        self.server.run() catch |err| {
            self.result = err;
        };
    }

    fn connect(self: *Harness) !Io.net.Stream {
        return self.address.connect(self.io, .{ .mode = .stream });
    }
};

fn send(stream: Io.net.Stream, io: Io, bytes: []const u8) !void {
    var buffer: [256]u8 = undefined;
    var w = stream.writer(io, &buffer);
    try w.interface.writeAll(bytes);
    try w.interface.flush();
}

fn readHead(stream: Io.net.Stream, io: Io, out: []u8) ![]u8 {
    var buffer: [256]u8 = undefined;
    var r = stream.reader(io, &buffer);
    var used: usize = 0;
    while (used < out.len) {
        var iovecs: [1][]u8 = .{out[used..]};
        used += r.interface.readVec(&iovecs) catch |err| switch (err) {
            error.EndOfStream => return error.EndOfStream,
            else => return err,
        };
        if (std.mem.find(u8, out[0..used], "\r\n\r\n")) |end| {
            return out[0 .. end + 4];
        }
    }
    return error.HeadTooLong;
}

fn readAll(stream: Io.net.Stream, io: Io, out: []u8) ![]u8 {
    var buffer: [256]u8 = undefined;
    var r = stream.reader(io, &buffer);
    var used: usize = 0;
    while (used < out.len) {
        var iovecs: [1][]u8 = .{out[used..]};
        used += r.interface.readVec(&iovecs) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
    }
    return out[0..used];
}

test "poll serves pipelined requests" {
    var h: Harness = undefined;
    try h.init(.{}, 8);
    defer h.deinit();

    const stream = try h.connect();
    defer stream.close(h.io);

    try send(
        stream,
        h.io,
        "GET /one HTTP/1.1\r\nHost: x\r\n\r\n" ++
            "GET /two HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
    );

    var response: [2048]u8 = undefined;
    const got = try readAll(stream, h.io, &response);
    try testing.expectEqual(2, std.mem.count(u8, got, "HTTP/1.1 200 OK"));
    try testing.expect(std.mem.find(u8, got, "/one 0\n") != null);
    try testing.expect(std.mem.find(u8, got, "/two 0\n") != null);
}

test "poll sends 100 Continue before reading the body" {
    var h: Harness = undefined;
    try h.init(.{}, 8);
    defer h.deinit();

    const stream = try h.connect();
    defer stream.close(h.io);

    try send(
        stream,
        h.io,
        "POST / HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\n" ++
            "Content-Length: 5\r\nConnection: close\r\n\r\n",
    );

    var interim: [256]u8 = undefined;
    const head = try readHead(stream, h.io, &interim);
    try testing.expectEqualStrings("HTTP/1.1 100 Continue\r\n\r\n", head);

    try send(stream, h.io, "hello");
    var response: [2048]u8 = undefined;
    const got = try readAll(stream, h.io, &response);
    try testing.expect(std.mem.find(u8, got, "HTTP/1.1 200 OK") != null);
    try testing.expect(std.mem.find(u8, got, "/ 5\n") != null);
}

test "poll closes an idle connection" {
    var h: Harness = undefined;
    try h.init(.{
        .idle_timeout = .fromSeconds(1),
        .head_timeout = .fromSeconds(1),
        .total_timeout = .fromSeconds(5),
    }, 8);
    defer h.deinit();

    const stream = try h.connect();
    defer stream.close(h.io);

    var response: [512]u8 = undefined;
    const got = try readAll(stream, h.io, &response);
    try testing.expect(std.mem.startsWith(u8, got, "HTTP/1.1 408 Request Timeout\r\n"));
}

test "poll stalled mid-head does not block another connection" {
    var h: Harness = undefined;
    try h.init(.{}, 8);
    defer h.deinit();

    const stalled = try h.connect();
    defer stalled.close(h.io);
    try send(stalled, h.io, "GET /");

    const other = try h.connect();
    defer other.close(h.io);
    try send(other, h.io, "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");

    var response: [1024]u8 = undefined;
    const got = try readAll(other, h.io, &response);
    try testing.expect(std.mem.find(u8, got, "HTTP/1.1 200 OK") != null);
    try testing.expect(std.mem.find(u8, got, "/ 0\n") != null);
}

test "poll closes a stalled mid-head at the head deadline" {
    var h: Harness = undefined;
    try h.init(.{
        .head_timeout = .fromMilliseconds(200),
        .idle_timeout = .fromSeconds(5),
        .total_timeout = .fromSeconds(5),
    }, 8);
    defer h.deinit();

    const stream = try h.connect();
    defer stream.close(h.io);
    try send(stream, h.io, "GET /");

    var response: [512]u8 = undefined;
    const got = try readAll(stream, h.io, &response);
    try testing.expect(std.mem.startsWith(u8, got, "HTTP/1.1 408 Request Timeout\r\n"));
}

test "poll reads a POST body split across writes" {
    var h: Harness = undefined;
    try h.init(.{}, 8);
    defer h.deinit();

    const stream = try h.connect();
    defer stream.close(h.io);

    try send(
        stream,
        h.io,
        "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhe",
    );
    try send(stream, h.io, "llo");

    var response: [1024]u8 = undefined;
    const got = try readAll(stream, h.io, &response);
    try testing.expect(std.mem.find(u8, got, "HTTP/1.1 200 OK") != null);
    try testing.expect(std.mem.find(u8, got, "/ 5\n") != null);
}

test "poll stop ends the loop with a client mid-request" {
    var h: Harness = undefined;
    try h.init(.{}, 8);
    defer h.deinit();

    const stream = try h.connect();
    defer stream.close(h.io);
    try send(stream, h.io, "GET /");

    h.stop();
    try testing.expect(h.result == null);
}

test "poll full slots leave a new connection in the backlog" {
    var h: Harness = undefined;
    try h.init(.{}, 1);
    defer h.deinit();

    const busy = try h.connect();
    var busy_open = true;
    defer if (busy_open) busy.close(h.io);
    try send(busy, h.io, "GET /");

    const waiting = try h.connect();
    defer waiting.close(h.io);
    try send(waiting, h.io, "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");

    var pfd = [_]std.posix.pollfd{.{
        .fd = waiting.socket.handle,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    try testing.expectEqual(0, try std.posix.poll(&pfd, 50));

    busy.close(h.io);
    busy_open = false;

    var response: [1024]u8 = undefined;
    const got = try readAll(waiting, h.io, &response);
    try testing.expect(std.mem.find(u8, got, "HTTP/1.1 200 OK") != null);
    try testing.expect(std.mem.find(u8, got, "/ 0\n") != null);
}

test "poll answers a handler that forgets to respond" {
    var h: Harness = undefined;
    try h.init(.{}, 8);
    defer h.deinit();

    const stream = try h.connect();
    defer stream.close(h.io);

    try send(
        stream,
        h.io,
        "GET /no-response HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
    );

    var response: [1024]u8 = undefined;
    const got = try readAll(stream, h.io, &response);
    try testing.expect(std.mem.startsWith(u8, got, "HTTP/1.1 500 Internal Server Error\r\n"));
}

test "poll listener does not set SO_REUSEPORT" {
    var h: Harness = undefined;
    try h.init(.{}, 8);
    defer h.deinit();

    var address = h.address;
    address.setPort(h.server.port());
    var second_app: TestApp = .{};
    try testing.expectError(error.BindFailed, PollServer.init(h.io, address, &second_app, .{
        .allocator = testing.allocator,
        .max_connections = 8,
    }));
}

test "poll a slow reader hits the write deadline" {
    var h: Harness = undefined;
    try h.initConfig(.{
        .write_timeout = .fromMilliseconds(50),
        .total_timeout = .fromSeconds(5),
    }, 8, 4 * 1024 * 1024);
    defer h.deinit();

    const stream = try h.connect();
    defer stream.close(h.io);

    var receive_buffer: c_int = 1024;
    try std.posix.setsockopt(
        stream.socket.handle,
        std.posix.SOL.SOCKET,
        std.posix.SO.RCVBUF,
        std.mem.asBytes(&receive_buffer),
    );

    try send(
        stream,
        h.io,
        "GET /big HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
    );

    try testing.io.sleep(.fromMilliseconds(200), .awake);

    var response: [4096]u8 = undefined;
    const got = try readAll(stream, h.io, &response);
    try testing.expect(std.mem.startsWith(u8, got, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(got.len < 4 * 1024 * 1024);
}
