//! Integration tests for the poll engine.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;

const http = @import("http");
const engine = http.engine.poll;
const h1 = http.h1;

const TestApp = struct {
    pub fn handle(_: *TestApp, exchange: *engine.Exchange) anyerror!void {
        const target = exchange.request.head.target;
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

    fn init(self: *Harness, limits: h1.ServerConn.Limits) !void {
        self.io = testing.io;
        self.app = .{};
        self.result = null;
        const address = try Io.net.IpAddress.parseLiteral("127.0.0.1:0");
        self.server = try PollServer.init(self.io, address, &self.app, .{
            .allocator = testing.allocator,
            .max_connections = 8,
            .limits = limits,
        });
        self.address = address;
        self.address.setPort(self.server.port());
        self.thread = try std.Thread.spawn(.{}, runServer, .{self});
    }

    fn deinit(self: *Harness) void {
        self.server.stop();
        self.thread.join();
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
    try h.init(.{});
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
    try h.init(.{});
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
    });
    defer h.deinit();

    const stream = try h.connect();
    defer stream.close(h.io);

    var response: [512]u8 = undefined;
    const got = try readAll(stream, h.io, &response);
    try testing.expect(std.mem.startsWith(u8, got, "HTTP/1.1 408 Request Timeout\r\n"));
}
