//! A blocking HTTP/1 server engine over std.Io.
//!
//! One connection is served at a time. The engine uses the Io runtime's
//! blocking network streams, so it cannot enforce the connection deadlines;
//! all timeouts are zero. Use it for tools, tests, and trusted peers. The
//! evented engines are separate.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const mem = std.mem;
const ArenaAllocator = std.heap.ArenaAllocator;

const Header = @import("../../header.zig").Header;
const h1 = @import("../root.zig");
const common = @import("../../engine/common.zig");
pub const Exchange = @import("common.zig").Exchange;
pub const Handler = @import("common.zig").Handler;

/// Buffers and policy for one connection. The request buffer holds the head
/// and body.
// ast-grep-ignore: public-struct-field-default -- options bag; defaults are the policy
pub const Config = struct {
    allocator: mem.Allocator,
    request_buffer: []u8,
    headers: []Header,
    response_head_buffer: []u8,
    common: common.Config = .{},
};

/// Accept connections until an unrecoverable accept error.
pub fn run(
    io: Io,
    listener: *Io.net.Server,
    handler: Handler,
    config: Config,
) !void {
    while (true) {
        const stream = listener.accept(io) catch |err| switch (err) {
            error.ConnectionAborted, error.WouldBlock => continue,
            error.ProcessFdQuotaExceeded,
            error.SystemFdQuotaExceeded,
            error.SystemResources,
            => {
                io.sleep(.fromSeconds(1), .awake) catch |sleep_err| switch (sleep_err) {
                    error.Canceled => return,
                };
                continue;
            },
            error.Canceled => return,
            else => return err,
        };
        defer stream.close(io);

        serve(io, stream, handler, config) catch |err| {
            handler.vtable.report_error(handler.ptr, err);
            continue;
        };
    }
}

/// Serve one connection until it closes.
pub fn serve(
    io: Io,
    stream: Io.net.Stream,
    handler: Handler,
    config: Config,
) !void {
    // `readVec` writes straight into the ServerConn request buffer. A nonzero
    // reader buffer would accept bytes outside that buffer.
    var stream_reader = stream.reader(io, &.{});
    var write_buffer: [1024]u8 = undefined;
    var stream_writer = stream.writer(io, &write_buffer);
    return serveIo(io, &stream_reader.interface, &stream_writer.interface, handler, config);
}

/// Serve one connection over a caller-owned plaintext reader and writer.
/// TLS adapters call this after the handshake; the stream adapters call it
/// from `serve`.
pub fn serveIo(
    io: Io,
    reader: *Io.Reader,
    writer: *Io.Writer,
    handler: Handler,
    config: Config,
) !void {
    var arena: ArenaAllocator = .init(config.allocator);
    defer arena.deinit();

    var conn: h1.ServerConn = .init(.{
        .request_buffer = config.request_buffer,
        .headers = config.headers,
        .response_buffer = config.response_head_buffer,
        .limits = .{
            .body_bytes = config.common.body_bytes,
            .idle_timeout = .zero,
            .head_timeout = .zero,
            .body_timeout = .zero,
            .write_timeout = .zero,
            .total_timeout = .zero,
            .drain_timeout = .zero,
        },
    });
    conn.start(now(io));

    var event = conn.advance(now(io));
    while (true) {
        switch (event) {
            .request => |request| {
                const done = try handleRequest(
                    io,
                    &conn,
                    writer,
                    handler,
                    config,
                    &arena,
                    request,
                );
                switch (done) {
                    .keep_alive, .read => event = conn.advance(now(io)),
                    .close, .close_after_drain => return,
                    .more => unreachable,
                }
            },
            .need_more => {
                if (try writePending(io, &conn, writer)) |done| {
                    switch (done) {
                        .read, .keep_alive => event = conn.advance(now(io)),
                        .close, .close_after_drain => return,
                        .more => unreachable,
                    }
                } else {
                    const dst = conn.recvBuffer();
                    if (dst.len == 0) return error.NoBuffer;
                    var iovecs: [1][]u8 = .{dst};
                    const n = reader.readVec(&iovecs) catch |err| switch (err) {
                        error.EndOfStream => {
                            switch (conn.eof(now(io))) {
                                .closed => return,
                                .reject => {
                                    _ = try writePending(io, &conn, writer);
                                    return;
                                },
                                else => unreachable,
                            }
                        },
                        else => return err,
                    };
                    event = conn.received(n, now(io));
                }
            },
            .reject => {
                _ = try writePending(io, &conn, writer);
                return;
            },
            .closed => return,
        }
    }
}

fn handleRequest(
    io: Io,
    conn: *h1.ServerConn,
    writer: *Io.Writer,
    handler: Handler,
    config: Config,
    arena: *ArenaAllocator,
    request: h1.ServerConn.Request,
) !h1.ServerConn.Done {
    var exchange: Exchange = .{
        .id = 0,
        .conn = conn,
        .request = request,
        .arena = arena.allocator(),
    };
    handler.vtable.handle(handler.ptr, &exchange) catch |err| {
        handler.vtable.report_error(handler.ptr, err);
        if (conn.sendSlices().head.len == 0) {
            exchange.respond(.{ .status = .internal_server_error }, "") catch |resp_err| {
                complete(handler, &exchange, arena, config.common.arena_retain_bytes);
                return resp_err;
            };
        }
    };

    const done = writePending(io, conn, writer) catch |err| {
        complete(handler, &exchange, arena, config.common.arena_retain_bytes);
        return err;
    };
    if (done) |value| {
        switch (value) {
            .keep_alive, .close, .close_after_drain => {
                complete(handler, &exchange, arena, config.common.arena_retain_bytes);
            },
            .read, .more => {},
        }
        return value;
    }
    complete(handler, &exchange, arena, config.common.arena_retain_bytes);
    return error.NoResponse;
}

fn complete(
    handler: Handler,
    exchange: *Exchange,
    arena: *ArenaAllocator,
    retain_bytes: usize,
) void {
    handler.vtable.complete(handler.ptr, exchange);
    common.resetArena(arena, retain_bytes);
}

fn writePending(
    io: Io,
    conn: *h1.ServerConn,
    writer: *Io.Writer,
) !?h1.ServerConn.Done {
    while (true) {
        const slices = conn.sendSlices();
        if (slices.head.len == 0 and slices.body.len == 0) return null;

        var vec: [2][]const u8 = .{ slices.head, slices.body };
        try writer.writeVecAll(&vec);
        try writer.flush();

        switch (conn.sent(slices.head.len + slices.body.len, now(io))) {
            .more => continue,
            else => |done| return done,
        }
    }
}

fn now(io: Io) Io.Timestamp {
    return Io.Clock.awake.now(io);
}

const TestClient = struct {
    io: Io,
    address: Io.net.IpAddress,
    result: ?anyerror = null,

    fn run(self: *TestClient) void {
        self.request() catch |err| {
            self.result = err;
        };
    }

    fn request(self: *TestClient) !void {
        const stream = try self.address.connect(self.io, .{ .mode = .stream });
        defer stream.close(self.io);

        var read_buffer: [256]u8 = undefined;
        var write_buffer: [256]u8 = undefined;
        var stream_reader = stream.reader(self.io, &read_buffer);
        const reader = &stream_reader.interface;
        var stream_writer = stream.writer(self.io, &write_buffer);
        const writer = &stream_writer.interface;

        try writer.writeAll(
            "GET / HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n",
        );
        try writer.flush();

        var response: [1024]u8 = undefined;
        var used: usize = 0;
        while (used < response.len) {
            var iovecs: [1][]u8 = .{response[used..]};
            used += reader.readVec(&iovecs) catch |err| switch (err) {
                error.EndOfStream => break,
                else => return err,
            };
        }

        try testing.expect(mem.find(u8, response[0..used], "HTTP/1.1 200 OK") != null);
        try testing.expect(mem.find(u8, response[0..used], "hello\n") != null);
    }
};

const TestHandler = struct {
    fn handler(_: *TestHandler) Handler {
        return .{ .ptr = undefined, .vtable = &.{
            .handle = handle,
            .complete = Handler.noopComplete,
            .report_error = Handler.noopReportError,
        } };
    }

    fn handle(_: *anyopaque, exchange: *Exchange) anyerror!void {
        const body = try exchange.arena.dupe(u8, "hello\n");
        try exchange.respond(.{ .status = .ok, .content_type = "text/plain" }, body);
    }
};

test "serve one blocking connection" {
    const address = try Io.net.IpAddress.parseLiteral("127.0.0.1:0");
    var listener = try address.listen(testing.io, .{ .mode = .stream, .reuse_address = true });
    defer listener.deinit(testing.io);

    var client_address = address;
    client_address.setPort(listener.socket.address.getPort());

    var client: TestClient = .{ .io = testing.io, .address = client_address };
    const thread = try std.Thread.spawn(.{}, TestClient.run, .{&client});
    var joined = false;
    defer if (!joined) thread.join();

    const stream = try listener.accept(testing.io);
    var request_buffer: [1024]u8 = undefined;
    var headers: [16]Header = undefined;
    var response_head: [256]u8 = undefined;
    var test_handler: TestHandler = .{};
    serve(testing.io, stream, test_handler.handler(), .{
        .allocator = testing.allocator,
        .request_buffer = &request_buffer,
        .headers = &headers,
        .response_head_buffer = &response_head,
    }) catch |err| {
        stream.close(testing.io);
        thread.join();
        joined = true;
        return err;
    };
    stream.close(testing.io);

    thread.join();
    joined = true;
    try testing.expect(client.result == null);
}
