//! Integration tests for the readiness engines.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const builtin = @import("builtin");
const mem = std.mem;
const panic = std.debug.panic;

const http = @import("http");
const h1 = http.h1;
const options = @import("engine_options");
const engine = if (options.kqueue)
    h1.engine.kqueue
else if (options.epoll)
    h1.engine.epoll
else
    h1.engine.poll;

const ChunkStream = struct {
    chunks: []const []const u8,
    index: usize = 0,
    pulls: *usize,

    const vtable: http.stream.ReadStream.VTable = .{ .next = next, .close = close };

    fn next(ptr: *anyopaque) http.stream.ReadError!http.stream.ReadResult {
        const self: *ChunkStream = @ptrCast(@alignCast(ptr));
        self.pulls.* += 1;
        if (self.index >= self.chunks.len) return error.EndOfStream;
        const chunk = self.chunks[self.index];
        self.index += 1;
        return .{ .data = chunk };
    }

    fn close(_: *anyopaque) void {}
};

const TestApp = struct {
    complete_count: usize = 0,
    last_reason: ?h1.ServerConn.RejectReason = null,
    pulls: usize = 0,
    io: Io = testing.io,

    fn handler(self: *TestApp) engine.Handler {
        return .{ .ptr = self, .vtable = &.{
            .handle = handle,
            .complete = complete,
            .report_error = reportError,
            .policy_response = policyResponse,
        } };
    }

    fn handle(ptr: *anyopaque, exchange: *engine.Exchange) anyerror!void {
        const self: *TestApp = @ptrCast(@alignCast(ptr));
        const target = exchange.request.head.target;
        if (mem.eql(u8, target, "/stream") or
            mem.eql(u8, target, "/stream-head"))
        {
            const source = try exchange.arena.create(ChunkStream);
            source.* = .{
                .chunks = &.{ "one\n", "two\n" },
                .pulls = &self.pulls,
            };
            try exchange.respondStream(.{
                .status = .ok,
                .content_type = "text/plain",
            }, .{
                .stream = .{ .ptr = source, .vtable = &ChunkStream.vtable },
                .content_length = null,
            });
            return;
        }
        if (mem.eql(u8, target, "/stream-204") or
            mem.eql(u8, target, "/stream-304"))
        {
            const source = try exchange.arena.create(ChunkStream);
            source.* = .{
                .chunks = &.{ "ignored\n", "also ignored\n" },
                .pulls = &self.pulls,
            };
            try exchange.respondStream(.{
                .status = if (mem.eql(u8, target, "/stream-204"))
                    .no_content
                else
                    .not_modified,
            }, .{
                .stream = .{ .ptr = source, .vtable = &ChunkStream.vtable },
                .content_length = null,
            });
            return;
        }
        if (mem.eql(u8, target, "/stream-length")) {
            const source = try exchange.arena.create(ChunkStream);
            source.* = .{
                .chunks = &.{ "one\n", "two\n" },
                .pulls = &self.pulls,
            };
            try exchange.respondStream(.{ .status = .ok }, .{
                .stream = .{ .ptr = source, .vtable = &ChunkStream.vtable },
                .content_length = 8,
            });
            return;
        }
        if (mem.eql(u8, target, "/stream-short") or
            mem.eql(u8, target, "/stream-long"))
        {
            const source = try exchange.arena.create(ChunkStream);
            source.* = .{
                .chunks = if (mem.eql(u8, target, "/stream-short"))
                    &.{"abc"}
                else
                    &.{"abcdef"},
                .pulls = &self.pulls,
            };
            try exchange.respondStream(.{ .status = .ok }, .{
                .stream = .{ .ptr = source, .vtable = &ChunkStream.vtable },
                .content_length = 5,
            });
            return;
        }
        if (mem.eql(u8, target, "/no-response")) return;
        if (mem.eql(u8, target, "/big")) {
            const body = try exchange.arena.alloc(u8, 1024 * 1024);
            @memset(body, 'x');
            try exchange.respond(.{ .status = .ok }, body);
            return;
        }
        if (mem.eql(u8, target, "/arena")) {
            const body = try exchange.arena.alloc(u8, 64 * 1024);
            @memset(body, 'a');
            try exchange.respond(.{ .status = .ok }, body);
            return;
        }
        if (mem.eql(u8, target, "/plain")) {
            try exchange.respond(.{ .status = .ok }, "plain\n");
            return;
        }
        if (mem.eql(u8, target, "/deferred-timeout")) {
            const ctx = try exchange.arena.create(DeferredCtx);
            ctx.* = .{};
            try exchange.deferResponse(ctx, deferredResume, deferredCancel, .{
                .timeout = .fromMilliseconds(20),
                .on_timeout = .{
                    .options = .{ .status = .service_unavailable },
                    .body = "timed out\n",
                },
            });
            return;
        }
        if (mem.eql(u8, target, "/deferred")) {
            const ctx = try exchange.arena.create(DeferredCtx);
            ctx.* = .{};
            try exchange.deferResponse(ctx, deferredResume, deferredCancel, .{});
            const thread = try std.Thread.spawn(
                .{},
                wakeDeferred,
                .{ testing.io, exchange },
            );
            thread.detach();
            return;
        }
        const body = try std.fmt.allocPrint(
            exchange.arena,
            "{s} {d}\n",
            .{ target, exchange.request.body.len },
        );
        try exchange.respond(.{ .status = .ok, .content_type = "text/plain" }, body);
    }

    fn complete(ptr: *anyopaque, exchange: *engine.Exchange) void {
        _ = exchange;
        const self: *TestApp = @ptrCast(@alignCast(ptr));
        self.complete_count += 1;
    }

    fn reportError(_: *anyopaque, err: anyerror) void {
        _ = @errorName(err);
    }

    fn policyResponse(
        ptr: *anyopaque,
        context: engine.PolicyContext,
    ) anyerror!engine.PolicyResponse {
        const self: *TestApp = @ptrCast(@alignCast(ptr));
        self.last_reason = context.reason;
        if (context.status != .not_implemented) {
            return .{ .options = .{ .status = context.status }, .body = "" };
        }
        const body = try std.fmt.allocPrint(
            context.arena,
            "{{\"error\":{d}}}\n",
            .{context.status.code()},
        );
        return .{
            .options = .{ .status = .bad_request, .content_type = "application/json" },
            .body = body,
        };
    }
};

const DeferredCtx = struct {};

fn deferredResume(
    _: *anyopaque,
    exchange: *engine.Exchange,
) anyerror!http.engine.ResumeResult {
    try exchange.respond(.{ .status = .ok }, "deferred\n");
    return .responded;
}

fn deferredCancel(_: *anyopaque) void {}

fn wakeDeferred(io: Io, exchange: *engine.Exchange) void {
    io.sleep(.fromMilliseconds(10), .awake) catch return;
    exchange.wake();
}

const PollServer = engine.Server;

const Harness = struct {
    io: Io,
    server: PollServer,
    thread: std.Thread,
    result: ?anyerror = null,
    address: Io.net.IpAddress,
    app: TestApp = .{},
    joined: bool = false,

    fn init(self: *Harness, limits: h1.ServerConn.Limits, max_connections: usize) !void {
        try self.initConfig(limits, max_connections, 16 * 1024);
    }

    fn initConfig(
        self: *Harness,
        limits: h1.ServerConn.Limits,
        max_connections: usize,
        arena_retain_bytes: usize,
    ) !void {
        self.io = testing.io;
        self.app = .{};
        self.result = null;
        self.joined = false;
        const address: Io.net.IpAddress = try .parseLiteral("127.0.0.1:0");
        self.server = try .init(self.io, address, self.app.handler(), .{
            .allocator = testing.allocator,
            .max_connections = max_connections,
            .common = .{ .arena_retain_bytes = arena_retain_bytes },
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
            panic("poll server failed: {s}", .{@errorName(err)});
        }
        self.* = undefined;
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
        if (mem.find(u8, out[0..used], "\r\n\r\n")) |end| {
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
    try testing.expectEqual(2, mem.count(u8, got, "HTTP/1.1 200 OK"));
    try testing.expect(mem.find(u8, got, "/one 0\n") != null);
    try testing.expect(mem.find(u8, got, "/two 0\n") != null);
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
    try testing.expect(mem.find(u8, got, "HTTP/1.1 200 OK") != null);
    try testing.expect(mem.find(u8, got, "/ 5\n") != null);
}

test "poll closes an idle connection" {
    var h: Harness = undefined;
    try h.initConfig(.{
        .idle_timeout = .fromSeconds(1),
        .head_timeout = .fromSeconds(1),
        .total_timeout = .fromSeconds(5),
    }, 8, 16 * 1024);
    defer h.deinit();

    const stream = try h.connect();
    defer stream.close(h.io);

    var response: [512]u8 = undefined;
    const got = try readAll(stream, h.io, &response);
    try testing.expectEqualStrings("", got);
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
    try testing.expect(mem.find(u8, got, "HTTP/1.1 200 OK") != null);
    try testing.expect(mem.find(u8, got, "/ 0\n") != null);
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
    try testing.expect(mem.startsWith(u8, got, "HTTP/1.1 408 Request Timeout\r\n"));
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
    try testing.expect(mem.find(u8, got, "HTTP/1.1 200 OK") != null);
    try testing.expect(mem.find(u8, got, "/ 5\n") != null);
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
    try testing.expect(mem.find(u8, got, "HTTP/1.1 200 OK") != null);
    try testing.expect(mem.find(u8, got, "/ 0\n") != null);
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
    try testing.expect(mem.startsWith(u8, got, "HTTP/1.1 500 Internal Server Error\r\n"));
}

test "poll second listener reports AddressInUse" {
    var h: Harness = undefined;
    try h.init(.{}, 8);
    defer h.deinit();

    var address = h.address;
    address.setPort(h.server.port());
    var second_app: TestApp = .{};
    try testing.expectError(
        error.AddressInUse,
        PollServer.init(h.io, address, second_app.handler(), .{
            .allocator = testing.allocator,
            .max_connections = 8,
        }),
    );
}

test "poll serves a body larger than the arena retain limit" {
    var h: Harness = undefined;
    try h.init(.{}, 8);
    defer h.deinit();

    const stream = try h.connect();
    defer stream.close(h.io);
    try send(
        stream,
        h.io,
        "GET /big HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
    );

    var response: [1024 * 1024 + 1024]u8 = undefined;
    const got = try readAll(stream, h.io, &response);
    try testing.expect(mem.startsWith(u8, got, "HTTP/1.1 200 OK\r\n"));
    try testing.expectEqual(1024 * 1024, mem.count(u8, got, "x"));
}

test "poll resets the arena between keep-alive requests" {
    var h: Harness = undefined;
    try h.initConfig(.{}, 1, 4 * 1024);
    defer h.deinit();

    const stream = try h.connect();
    defer stream.close(h.io);
    try send(
        stream,
        h.io,
        "GET /arena HTTP/1.1\r\nHost: x\r\n\r\n" ++
            "GET /arena HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
    );

    var response: [140 * 1024]u8 = undefined;
    const got = try readAll(stream, h.io, &response);
    try testing.expectEqual(2, mem.count(u8, got, "HTTP/1.1 200 OK"));
    try testing.expect(h.server.slots[0].arena.queryCapacity() <= 4 * 1024);
}

test "poll resets the arena between connections" {
    var h: Harness = undefined;
    try h.initConfig(.{}, 1, 4 * 1024);
    defer h.deinit();

    {
        const stream = try h.connect();
        defer stream.close(h.io);
        try send(
            stream,
            h.io,
            "GET /arena HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
        );
        var response: [70 * 1024]u8 = undefined;
        _ = try readAll(stream, h.io, &response);
    }
    {
        const stream = try h.connect();
        defer stream.close(h.io);
        try send(
            stream,
            h.io,
            "GET /arena HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
        );
        var response: [70 * 1024]u8 = undefined;
        _ = try readAll(stream, h.io, &response);
    }

    try testing.expect(h.server.slots[0].arena.queryCapacity() <= 4 * 1024);
}

test "poll does not allocate the arena when the handler does not use it" {
    var h: Harness = undefined;
    try h.initConfig(.{}, 8, 4 * 1024);
    defer h.deinit();

    const stream = try h.connect();
    defer stream.close(h.io);
    try send(
        stream,
        h.io,
        "GET /plain HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
    );

    var response: [1024]u8 = undefined;
    _ = try readAll(stream, h.io, &response);
    try testing.expectEqual(0, h.server.slots[0].arena.queryCapacity());
}

test "poll a slow reader hits the write deadline" {
    var h: Harness = undefined;
    try h.initConfig(.{
        .write_timeout = .fromMilliseconds(50),
        .total_timeout = .fromSeconds(5),
    }, 8, 16 * 1024);
    defer h.deinit();

    const stream = try h.connect();
    defer stream.close(h.io);

    var receive_buffer: c_int = 1024;
    try std.posix.setsockopt(
        stream.socket.handle,
        std.posix.SOL.SOCKET,
        std.posix.SO.RCVBUF,
        mem.asBytes(&receive_buffer),
    );

    try send(
        stream,
        h.io,
        "GET /big HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
    );

    try testing.io.sleep(.fromMilliseconds(200), .awake);

    var response: [4096]u8 = undefined;
    const got = try readAll(stream, h.io, &response);
    try testing.expect(mem.startsWith(u8, got, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(got.len < 4 * 1024 * 1024);
    try testing.expect(h.server.slots[0].arena.queryCapacity() <= 16 * 1024);
}

test "poll reports exchange completion" {
    var h: Harness = undefined;
    try h.init(.{}, 8);
    defer h.deinit();

    const stream = try h.connect();
    defer stream.close(h.io);
    try send(stream, h.io, "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");

    var response: [1024]u8 = undefined;
    const got = try readAll(stream, h.io, &response);
    try testing.expect(mem.find(u8, got, "HTTP/1.1 200 OK") != null);
    try testing.expectEqual(1, h.app.complete_count);
}

test "poll serves a deferred handler" {
    var h: Harness = undefined;
    try h.init(.{}, 8);
    defer h.deinit();

    const stream = try h.connect();
    defer stream.close(h.io);
    try send(stream, h.io, "GET /deferred HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");

    var response: [1024]u8 = undefined;
    const got = try readAll(stream, h.io, &response);
    try testing.expect(mem.find(u8, got, "HTTP/1.1 200 OK") != null);
    try testing.expect(mem.endsWith(u8, got, "deferred\n"));
}

test "poll keeps a pipelined request across a deferred response" {
    var h: Harness = undefined;
    try h.init(.{}, 8);
    defer h.deinit();

    const stream = try h.connect();
    defer stream.close(h.io);
    try send(
        stream,
        h.io,
        "GET /deferred HTTP/1.1\r\nHost: x\r\n\r\n" ++
            "GET /plain HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
    );

    var response: [2048]u8 = undefined;
    const got = try readAll(stream, h.io, &response);
    try testing.expectEqual(
        @as(usize, 2),
        mem.count(u8, got, "HTTP/1.1 200 OK"),
    );
    try testing.expect(mem.find(u8, got, "deferred\n") != null);
    try testing.expect(mem.find(u8, got, "plain\n") != null);
}

test "poll serves a deferred timeout" {
    var h: Harness = undefined;
    try h.init(.{}, 8);
    defer h.deinit();

    const stream = try h.connect();
    defer stream.close(h.io);
    try send(
        stream,
        h.io,
        "GET /deferred-timeout HTTP/1.1\r\nHost: x\r\n" ++
            "Connection: close\r\n\r\n",
    );

    var response: [1024]u8 = undefined;
    const got = try readAll(stream, h.io, &response);
    try testing.expect(mem.find(u8, got, "HTTP/1.1 503 Service Unavailable") != null);
    try testing.expect(mem.endsWith(u8, got, "timed out\n"));
}

test "poll listener honors TCP_DEFER_ACCEPT" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var app: TestApp = .{};
    const address: Io.net.IpAddress = try .parseLiteral("127.0.0.1:0");
    var server = try PollServer.init(testing.io, address, app.handler(), .{
        .allocator = testing.allocator,
        .max_connections = 1,
        .tcp_defer_accept = true,
    });
    defer server.deinit();

    var value: u32 = 0;
    var len: std.posix.socklen_t = @sizeOf(u32);
    const rc = std.posix.system.getsockopt(
        server.listener.fd,
        6, // IPPROTO_TCP
        9, // TCP_DEFER_ACCEPT
        mem.asBytes(&value),
        &len,
    );
    try testing.expectEqual(std.posix.E.SUCCESS, std.posix.errno(rc));
    try testing.expectEqual(@as(u32, 1), value);
}

test "poll accept backoff defaults to 50 ms" {
    const config: engine.Config = .{
        .allocator = testing.allocator,
        .max_connections = 1,
    };
    try testing.expectEqual(50 * std.time.ns_per_ms, config.accept_backoff.nanoseconds);
}

test "poll lets the application shape a framing rejection" {
    var h: Harness = undefined;
    try h.init(.{}, 8);
    defer h.deinit();

    const stream = try h.connect();
    defer stream.close(h.io);
    try send(
        stream,
        h.io,
        "POST / HTTP/1.1\r\nHost: x\r\n" ++
            "Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n",
    );

    var response: [1024]u8 = undefined;
    const got = try readAll(stream, h.io, &response);
    try testing.expect(mem.startsWith(u8, got, "HTTP/1.1 400 Bad Request\r\n") != false);
    try testing.expect(mem.find(u8, got, "Content-Type: application/json") != null);
    try testing.expect(mem.endsWith(u8, got, "{\"error\":501}\n"));
}

test "poll streams chunked and keeps the connection alive" {
    var h: Harness = undefined;
    try h.init(.{}, 8);
    defer h.deinit();

    const stream = try h.connect();
    defer stream.close(h.io);

    try send(
        stream,
        h.io,
        "GET /stream HTTP/1.1\r\nHost: x\r\n\r\n" ++
            "GET /tail HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
    );

    var response: [2048]u8 = undefined;
    const got = try readAll(stream, h.io, &response);
    try testing.expectEqual(2, mem.count(u8, got, "HTTP/1.1 200 OK"));
    try testing.expect(mem.find(u8, got, "Transfer-Encoding: chunked") != null);
    try testing.expect(mem.find(u8, got, "4\r\none\n\r\n4\r\ntwo\n\r\n0\r\n\r\n") != null);
    try testing.expect(mem.find(u8, got, "/tail 0\n") != null);
}

test "poll streams close-delimited on HTTP/1.0" {
    var h: Harness = undefined;
    try h.init(.{}, 8);
    defer h.deinit();

    const stream = try h.connect();
    defer stream.close(h.io);

    try send(stream, h.io, "GET /stream HTTP/1.0\r\n\r\n");

    var response: [2048]u8 = undefined;
    const got = try readAll(stream, h.io, &response);
    try testing.expect(mem.startsWith(u8, got, "HTTP/1.0 200 OK\r\n"));
    try testing.expect(mem.find(u8, got, "Transfer-Encoding") == null);
    try testing.expect(mem.endsWith(u8, got, "one\ntwo\n"));
}

test "poll does not pull a stream for HEAD, 204, or 304" {
    var h: Harness = undefined;
    try h.init(.{}, 8);
    defer h.deinit();

    const stream = try h.connect();
    defer stream.close(h.io);

    try send(
        stream,
        h.io,
        "HEAD /stream HTTP/1.1\r\nHost: x\r\n\r\n" ++
            "GET /stream-204 HTTP/1.1\r\nHost: x\r\n\r\n" ++
            "GET /stream-304 HTTP/1.1\r\nHost: x\r\n\r\n" ++
            "GET /tail HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
    );

    var response: [2048]u8 = undefined;
    const got = try readAll(stream, h.io, &response);
    try testing.expectEqual(4, mem.count(u8, got, "HTTP/1.1"));
    try testing.expect(mem.find(u8, got, "Transfer-Encoding") == null);
    try testing.expect(mem.find(u8, got, "one\n") == null);
    try testing.expect(mem.find(u8, got, "/tail 0\n") != null);
    try testing.expectEqual(0, h.app.pulls);
}

test "poll uses Content-Length for a known-length stream" {
    var h: Harness = undefined;
    try h.init(.{}, 8);
    defer h.deinit();

    const stream = try h.connect();
    defer stream.close(h.io);

    try send(stream, h.io, "GET /stream-length HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");

    var response: [2048]u8 = undefined;
    const got = try readAll(stream, h.io, &response);
    try testing.expect(mem.find(u8, got, "Content-Length: 8") != null);
    try testing.expect(mem.find(u8, got, "Transfer-Encoding") == null);
    try testing.expect(mem.endsWith(u8, got, "one\ntwo\n"));
}

test "poll closes a known-length stream on underrun and overrun" {
    var h: Harness = undefined;
    try h.init(.{}, 8);
    defer h.deinit();

    inline for (.{ "/stream-short", "/stream-long" }) |target| {
        const stream = try h.connect();
        defer stream.close(h.io);
        var request: [128]u8 = undefined;
        const head = try std.fmt.bufPrint(
            &request,
            "GET {s} HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
            .{target},
        );
        try send(stream, h.io, head);

        var response: [2048]u8 = undefined;
        const got = try readAll(stream, h.io, &response);
        try testing.expect(mem.startsWith(u8, got, "HTTP/1.1 200 OK\r\n"));
        try testing.expectEqual(1, mem.count(u8, got, "HTTP/1.1"));
        try testing.expect(mem.find(u8, got, "abcdef") == null);
    }
}
