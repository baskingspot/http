//! Integration tests for the blocking HTTP/1 engine.
//!
//! Each test starts one listener, serves one connection, and speaks raw HTTP
//! over a real loopback socket. The tests exercise the transport edge, not just
//! the connection machine.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const mem = std.mem;
const panic = std.debug.panic;

const http = @import("http");
const engine = http.h1.engine.blocking;

const TestConfig = struct {
    request_buffer: [1024]u8 = undefined,
    headers: [16]http.Header = undefined,
    response_head: [512]u8 = undefined,

    fn config(self: *TestConfig, body_bytes: usize) engine.Config {
        return .{
            .allocator = testing.allocator,
            .request_buffer = &self.request_buffer,
            .headers = &self.headers,
            .response_head_buffer = &self.response_head,
            .common = .{ .body_bytes = body_bytes },
        };
    }
};

const Server = struct {
    io: Io,
    listener: *Io.net.Server,
    handler: *TestApp,
    config: engine.Config,
    result: ?anyerror = null,

    fn run(self: *Server) void {
        const stream = self.listener.accept(self.io) catch |err| {
            self.result = err;
            return;
        };
        defer stream.close(self.io);
        engine.serve(self.io, stream, self.handler.handler(), self.config) catch |err| {
            self.result = err;
        };
    }
};

const Harness = struct {
    io: Io,
    listener: Io.net.Server,
    address: Io.net.IpAddress,
    handler: TestApp = .{},
    server: Server,
    thread: std.Thread,

    fn init(self: *Harness, config: engine.Config) !void {
        self.io = testing.io;
        self.handler = .{};
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
            .handler = &self.handler,
            .config = config,
        };
        self.thread = try .spawn(.{}, Server.run, .{&self.server});
    }

    fn deinit(self: *Harness) void {
        self.thread.join();
        self.listener.deinit(self.io);
        if (self.server.result) |err| {
            panic("server failed: {s}", .{@errorName(err)});
        }
        self.* = undefined;
    }

    fn connect(self: *Harness) !Io.net.Stream {
        return self.address.connect(self.io, .{ .mode = .stream });
    }
};

const Client = struct {
    io: Io,
    stream: Io.net.Stream,
    reader: Io.net.Stream.Reader = undefined,
    writer: Io.net.Stream.Writer = undefined,
    read_buffer: [512]u8 = undefined,
    write_buffer: [512]u8 = undefined,

    fn init(self: *Client, io: Io, stream: Io.net.Stream) void {
        self.* = .{ .io = io, .stream = stream };
        self.reader = stream.reader(io, &self.read_buffer);
        self.writer = stream.writer(io, &self.write_buffer);
    }

    fn close(self: *Client) void {
        self.stream.close(self.io);
    }

    fn send(self: *Client, bytes: []const u8) !void {
        try self.writer.interface.writeAll(bytes);
        try self.writer.interface.flush();
    }

    fn readUntilHead(self: *Client, out: []u8) ![]u8 {
        var used: usize = 0;
        while (used < out.len) {
            var iovecs: [1][]u8 = .{out[used..]};
            used += self.reader.interface.readVec(&iovecs) catch |err| switch (err) {
                error.EndOfStream => return error.EndOfStream,
                else => return err,
            };
            if (mem.find(u8, out[0..used], "\r\n\r\n")) |end| {
                return out[0 .. end + 4];
            }
        }
        return error.HeadTooLong;
    }

    fn readAll(self: *Client, out: []u8) ![]u8 {
        var used: usize = 0;
        while (used < out.len) {
            var iovecs: [1][]u8 = .{out[used..]};
            used += self.reader.interface.readVec(&iovecs) catch |err| switch (err) {
                error.EndOfStream => break,
                else => return err,
            };
        }
        return out[0..used];
    }
};

const TestApp = struct {
    fn handler(_: *TestApp) engine.Handler {
        return .{ .ptr = undefined, .vtable = &.{
            .handle = handle,
            .complete = engine.Handler.noopComplete,
            .report_error = engine.Handler.noopReportError,
            .policy_response = engine.Handler.defaultPolicyResponse,
        } };
    }

    fn handle(_: *anyopaque, exchange: *engine.Exchange) anyerror!void {
        const target = exchange.request.head.target;
        if (mem.eql(u8, target, "/204")) {
            try exchange.respond(.{ .status = .no_content }, "");
            return;
        }
        if (mem.eql(u8, target, "/304")) {
            try exchange.respond(.{ .status = .not_modified }, "");
            return;
        }
        if (mem.eql(u8, target, "/big")) {
            const body = try exchange.arena.alloc(u8, 1024 * 1024);
            @memset(body, 'x');
            try exchange.respond(.{ .status = .ok }, body);
            return;
        }

        const body = try std.fmt.allocPrint(
            exchange.arena,
            "{s} {d}\n",
            .{ target, exchange.request.body.len },
        );
        try exchange.respond(.{ .status = .ok, .content_type = "text/plain" }, body);
    }
};

fn startTest(storage: *TestConfig, harness: *Harness, body_bytes: usize) !void {
    try harness.init(storage.config(body_bytes));
}

test "keep-alive and pipelined requests" {
    var storage: TestConfig = .{};
    var h: Harness = undefined;
    try startTest(&storage, &h, 64);
    defer h.deinit();

    const stream = try h.connect();
    var client: Client = undefined;
    client.init(testing.io, stream);
    defer client.close();

    try client.send(
        "GET /one HTTP/1.1\r\nHost: x\r\n\r\n" ++
            "GET /two HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
    );

    var response: [2048]u8 = undefined;
    const got = try client.readAll(&response);
    try testing.expectEqual(2, mem.count(u8, got, "HTTP/1.1 200 OK"));
    try testing.expect(mem.find(u8, got, "/one 0\n") != null);
    try testing.expect(mem.find(u8, got, "/two 0\n") != null);
}

test "a body larger than the arena retain limit" {
    var storage: TestConfig = .{};
    var h: Harness = undefined;
    try startTest(&storage, &h, 64);
    defer h.deinit();

    const stream = try h.connect();
    var client: Client = undefined;
    client.init(testing.io, stream);
    defer client.close();

    try client.send("GET /big HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");

    var response: [1024 * 1024 + 1024]u8 = undefined;
    const got = try client.readAll(&response);
    try testing.expect(mem.startsWith(u8, got, "HTTP/1.1 200 OK\r\n"));
    try testing.expectEqual(1024 * 1024, mem.count(u8, got, "x"));
}

test "HEAD keeps Content-Length and drops the body" {
    var storage: TestConfig = .{};
    var h: Harness = undefined;
    try startTest(&storage, &h, 64);
    defer h.deinit();

    const stream = try h.connect();
    var client: Client = undefined;
    client.init(testing.io, stream);
    defer client.close();

    try client.send("HEAD / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");

    var response: [2048]u8 = undefined;
    const got = try client.readAll(&response);
    try testing.expect(mem.startsWith(u8, got, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(mem.find(u8, got, "Content-Length: 4") != null);
    try testing.expect(mem.find(u8, got, "/ 0\n") == null);
}

test "Expect: 100-continue" {
    var storage: TestConfig = .{};
    var h: Harness = undefined;
    try startTest(&storage, &h, 64);
    defer h.deinit();

    const stream = try h.connect();
    var client: Client = undefined;
    client.init(testing.io, stream);
    defer client.close();

    try client.send(
        "POST / HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\n" ++
            "Content-Length: 5\r\nConnection: close\r\n\r\n",
    );

    var interim: [256]u8 = undefined;
    const first = try client.readUntilHead(&interim);
    try testing.expectEqualStrings("HTTP/1.1 100 Continue\r\n\r\n", first);

    try client.send("hello");
    var response: [2048]u8 = undefined;
    const got = try client.readAll(&response);
    try testing.expect(mem.find(u8, got, "HTTP/1.1 200 OK") != null);
    try testing.expect(mem.find(u8, got, "/ 5\n") != null);
}

test "HTTP/1.0 has no Host and no 100 Continue" {
    var storage: TestConfig = .{};
    var h: Harness = undefined;
    try startTest(&storage, &h, 64);
    defer h.deinit();

    const stream = try h.connect();
    var client: Client = undefined;
    client.init(testing.io, stream);
    defer client.close();

    try client.send(
        "POST / HTTP/1.0\r\nExpect: 100-continue\r\n" ++
            "Content-Length: 5\r\nConnection: close\r\n\r\nhello",
    );

    var response: [2048]u8 = undefined;
    const got = try client.readAll(&response);
    try testing.expect(mem.startsWith(u8, got, "HTTP/1.0 200 OK\r\n"));
    try testing.expect(mem.find(u8, got, "100 Continue") == null);
    try testing.expect(mem.find(u8, got, "/ 5\n") != null);
}

test "missing Host is 400" {
    var storage: TestConfig = .{};
    var h: Harness = undefined;
    try startTest(&storage, &h, 64);
    defer h.deinit();

    const stream = try h.connect();
    var client: Client = undefined;
    client.init(testing.io, stream);
    defer client.close();

    try client.send("GET / HTTP/1.1\r\nConnection: close\r\n\r\n");

    var response: [2048]u8 = undefined;
    const got = try client.readAll(&response);
    try testing.expect(mem.startsWith(u8, got, "HTTP/1.1 400 Bad Request\r\n"));
}

test "body over the limit is 413" {
    var storage: TestConfig = .{};
    var h: Harness = undefined;
    try startTest(&storage, &h, 4);
    defer h.deinit();

    const stream = try h.connect();
    var client: Client = undefined;
    client.init(testing.io, stream);
    defer client.close();

    try client.send(
        "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nConnection: close\r\n\r\n",
    );

    var response: [2048]u8 = undefined;
    const got = try client.readAll(&response);
    try testing.expect(mem.startsWith(u8, got, "HTTP/1.1 413 Payload Too Large\r\n"));
}

test "chunked request is 501" {
    var storage: TestConfig = .{};
    var h: Harness = undefined;
    try startTest(&storage, &h, 64);
    defer h.deinit();

    const stream = try h.connect();
    var client: Client = undefined;
    client.init(testing.io, stream);
    defer client.close();

    try client.send(
        "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n",
    );

    var response: [2048]u8 = undefined;
    const got = try client.readAll(&response);
    try testing.expect(mem.startsWith(u8, got, "HTTP/1.1 501 Not Implemented\r\n"));
}

test "bad Expect is 417" {
    var storage: TestConfig = .{};
    var h: Harness = undefined;
    try startTest(&storage, &h, 64);
    defer h.deinit();

    const stream = try h.connect();
    var client: Client = undefined;
    client.init(testing.io, stream);
    defer client.close();

    try client.send(
        "POST / HTTP/1.1\r\nHost: x\r\nExpect: nope\r\n" ++
            "Content-Length: 1\r\nConnection: close\r\n\r\n",
    );

    var response: [2048]u8 = undefined;
    const got = try client.readAll(&response);
    try testing.expect(mem.startsWith(u8, got, "HTTP/1.1 417 Expectation Failed\r\n"));
}

test "duplicate Host is 400" {
    var storage: TestConfig = .{};
    var h: Harness = undefined;
    try startTest(&storage, &h, 64);
    defer h.deinit();

    const stream = try h.connect();
    var client: Client = undefined;
    client.init(testing.io, stream);
    defer client.close();

    try client.send(
        "GET / HTTP/1.1\r\nHost: x\r\nHost: y\r\nConnection: close\r\n\r\n",
    );

    var response: [2048]u8 = undefined;
    const got = try client.readAll(&response);
    try testing.expect(mem.startsWith(u8, got, "HTTP/1.1 400 Bad Request\r\n"));
}

test "Transfer-Encoding with Content-Length is 400" {
    var storage: TestConfig = .{};
    var h: Harness = undefined;
    try startTest(&storage, &h, 64);
    defer h.deinit();

    const stream = try h.connect();
    var client: Client = undefined;
    client.init(testing.io, stream);
    defer client.close();

    try client.send(
        "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 1\r\n" ++
            "Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n",
    );

    var response: [2048]u8 = undefined;
    const got = try client.readAll(&response);
    try testing.expect(mem.startsWith(u8, got, "HTTP/1.1 400 Bad Request\r\n"));
}

test "a full request buffer is 431" {
    var storage: TestConfig = .{};
    var h: Harness = undefined;
    try startTest(&storage, &h, 64);
    defer h.deinit();

    const stream = try h.connect();
    var client: Client = undefined;
    client.init(testing.io, stream);
    defer client.close();

    var request: [1024]u8 = undefined;
    @memset(&request, 'A');
    try client.send(&request);

    var response: [2048]u8 = undefined;
    const got = try client.readAll(&response);
    try testing.expect(mem.startsWith(u8, got, "HTTP/1.1 431 Request Header Fields Too Large\r\n"));
}

test "unsupported version is 505" {
    var storage: TestConfig = .{};
    var h: Harness = undefined;
    try startTest(&storage, &h, 64);
    defer h.deinit();

    const stream = try h.connect();
    var client: Client = undefined;
    client.init(testing.io, stream);
    defer client.close();

    try client.send("GET / HTTP/2.0\r\nHost: x\r\nConnection: close\r\n\r\n");

    var response: [2048]u8 = undefined;
    const got = try client.readAll(&response);
    try testing.expect(mem.startsWith(u8, got, "HTTP/1.1 505 HTTP Version Not Supported\r\n"));
}

test "204 and 304 omit Content-Length and the body" {
    var storage: TestConfig = .{};
    var h: Harness = undefined;
    try startTest(&storage, &h, 64);
    defer h.deinit();

    const stream = try h.connect();
    var client: Client = undefined;
    client.init(testing.io, stream);
    defer client.close();

    try client.send(
        "GET /204 HTTP/1.1\r\nHost: x\r\n\r\n" ++
            "GET /304 HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
    );

    var response: [2048]u8 = undefined;
    const got = try client.readAll(&response);
    try testing.expect(mem.find(u8, got, "HTTP/1.1 204 No Content\r\n") != null);
    try testing.expect(mem.find(u8, got, "HTTP/1.1 304 Not Modified\r\n") != null);
    try testing.expect(mem.find(u8, got, "Content-Length") == null);
}

test "a body split across writes" {
    var storage: TestConfig = .{};
    var h: Harness = undefined;
    try startTest(&storage, &h, 64);
    defer h.deinit();

    const stream = try h.connect();
    var client: Client = undefined;
    client.init(testing.io, stream);
    defer client.close();

    try client.send(
        "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhe",
    );
    try client.send("llo");

    var response: [2048]u8 = undefined;
    const got = try client.readAll(&response);
    try testing.expect(mem.find(u8, got, "HTTP/1.1 200 OK") != null);
    try testing.expect(mem.find(u8, got, "/ 5\n") != null);
}
