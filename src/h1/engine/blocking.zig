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
const Status = @import("../../status.zig").Status;
const h1 = @import("../root.zig");
const common = @import("../../engine/common.zig");
const stream_mod = @import("../../engine/stream.zig");
const api = @import("common.zig");
pub const Exchange = @import("common.zig").Exchange;
pub const Handler = @import("common.zig").Handler;
pub const PolicyContext = @import("common.zig").PolicyContext;
pub const PolicyResponse = @import("common.zig").PolicyResponse;

/// Buffers and policy for one connection. The request buffer holds the head
/// and body.
// ast-grep-ignore: public-struct-field-default -- options bag; defaults are the policy
pub const Config = struct {
    allocator: mem.Allocator,
    request_buffer: []u8,
    headers: []Header,
    response_head_buffer: []u8,
    common: common.Config = .{},
    /// Coalesce and cap response chunks. Zero preserves separate head/body.
    write_chunk_bytes: usize = 0,
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
        .write_chunk_bytes = config.write_chunk_bytes,
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
            .request_head => event = conn.bufferBody(),
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
                    .close, .close_after_drain, .switched => return,
                    .more => unreachable,
                }
            },
            .need_more => {
                if (try writePending(io, &conn, writer)) |done| {
                    switch (done) {
                        .read, .keep_alive => event = conn.advance(now(io)),
                        .close, .close_after_drain, .switched => return,
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
                    event = if (n == 0) conn.eof(now(io)) else conn.received(n, now(io));
                }
            },
            .reject => |rejection| {
                try reviewPolicy(handler, &arena, &conn, rejection);
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
        if (exchange.response_stream) |source| {
            source.stream.close();
            exchange.response_stream = null;
            exchange.response_options = null;
        }
        if (conn.sendSlices().head.len == 0) {
            exchange.respond(.{ .status = .internal_server_error }, "") catch |resp_err| {
                complete(handler, &exchange, arena, config.common.arena_retain_bytes);
                return resp_err;
            };
            try reviewPolicy(handler, arena, conn, .{
                .status = .internal_server_error,
                .reason = .internal_error,
            });
        }
    };

    if (exchange.response_stream) |source| {
        writeStreamResponse(writer, &exchange, source) catch |err| {
            source.stream.close();
            complete(handler, &exchange, arena, config.common.arena_retain_bytes);
            return err;
        };
        source.stream.close();
        complete(handler, &exchange, arena, config.common.arena_retain_bytes);
        return .close;
    }

    const done = writePending(io, conn, writer) catch |err| {
        complete(handler, &exchange, arena, config.common.arena_retain_bytes);
        return err;
    };
    if (done) |value| {
        switch (value) {
            .keep_alive, .close, .close_after_drain, .switched => {
                complete(handler, &exchange, arena, config.common.arena_retain_bytes);
            },
            .read, .more => {},
        }
        return value;
    }
    complete(handler, &exchange, arena, config.common.arena_retain_bytes);
    return error.NoResponse;
}

fn writeStreamResponse(
    writer: *Io.Writer,
    exchange: *Exchange,
    source: stream_mod.ResponseStream,
) !void {
    const options = exchange.response_options orelse return error.NoResponse;
    var w: h1.Writer = .init(writer);
    try w.statusLine(exchange.conn.negotiatedVersion(), options.status);
    if (options.content_type) |value| try w.field("Content-Type", value);
    for (options.headers) |header| try w.field(header.name, header.value);
    try w.field("Connection", "close");
    const chunked = source.content_length == null;
    if (chunked) {
        try w.chunked();
    } else {
        try w.contentLength(source.content_length.?);
    }
    try w.endFields();
    try writer.flush();

    var total: u64 = 0;
    while (true) {
        const result = source.stream.next() catch |err| switch (err) {
            error.EndOfStream => break,
            error.Pending => return error.StreamPending,
            else => return err,
        };
        const bytes = result.data;
        if (bytes.len == 0) return error.EmptyChunk;
        total = std.math.add(u64, total, bytes.len) catch return error.BodyTooLong;
        if (chunked) {
            try w.chunk(bytes);
        } else {
            if (total > source.content_length.?) return error.BodyTooLong;
            try writer.writeAll(bytes);
        }
        try writer.flush();
    }
    if (chunked) {
        try w.lastChunk(&.{});
    } else if (total != source.content_length.?) {
        return error.BodyTooShort;
    }
    try writer.flush();
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

fn reviewPolicy(
    handler: Handler,
    arena: *ArenaAllocator,
    conn: *h1.ServerConn,
    rejection: h1.ServerConn.Rejection,
) !void {
    try api.review(handler, 0, arena.allocator(), conn, rejection);
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
            .policy_response = Handler.defaultPolicyResponse,
        } };
    }

    fn handle(_: *anyopaque, exchange: *Exchange) anyerror!void {
        const body = try exchange.arena.dupe(u8, "hello\n");
        try exchange.respond(.{ .status = .ok, .content_type = "text/plain" }, body);
    }
};

const SliceStream = struct {
    sent: bool = false,
    const vtable: stream_mod.ReadStream.VTable = .{ .next = next, .close = close };

    fn next(ptr: *anyopaque) stream_mod.ReadError!stream_mod.ReadResult {
        const self: *SliceStream = @ptrCast(@alignCast(ptr));
        if (self.sent) return error.EndOfStream;
        self.sent = true;
        return .{ .data = "hello\n" };
    }

    fn close(_: *anyopaque) void {}
};

const TestStreamHandler = struct {
    fn handler(_: *TestStreamHandler) Handler {
        return .{ .ptr = undefined, .vtable = &.{
            .handle = handle,
            .complete = Handler.noopComplete,
            .report_error = Handler.noopReportError,
            .policy_response = Handler.defaultPolicyResponse,
        } };
    }

    fn handle(_: *anyopaque, exchange: *Exchange) anyerror!void {
        const body = try exchange.arena.create(SliceStream);
        body.* = .{};
        try exchange.respondStream(.{
            .status = .ok,
            .content_type = "text/plain",
        }, .{
            .stream = .{ .ptr = body, .vtable = &SliceStream.vtable },
            .content_length = null,
        });
    }
};

test "serve a chunked response stream" {
    const address = try Io.net.IpAddress.parseLiteral("127.0.0.1:0");
    var listener = try address.listen(testing.io, .{ .mode = .stream, .reuse_address = true });
    defer listener.deinit(testing.io);

    var client_address = address;
    client_address.setPort(listener.socket.address.getPort());

    var client: TestClient = .{ .io = testing.io, .address = client_address };
    const thread = try std.Thread.spawn(.{}, TestClient.run, .{&client});
    var joined = false;
    defer if (!joined) thread.join();

    const conn = try listener.accept(testing.io);
    var request_buffer: [1024]u8 = undefined;
    var headers: [16]Header = undefined;
    var response_head: [256]u8 = undefined;
    var test_handler: TestStreamHandler = .{};
    serve(testing.io, conn, test_handler.handler(), .{
        .allocator = testing.allocator,
        .request_buffer = &request_buffer,
        .headers = &headers,
        .response_head_buffer = &response_head,
    }) catch |err| {
        conn.close(testing.io);
        thread.join();
        joined = true;
        return err;
    };
    conn.close(testing.io);

    thread.join();
    joined = true;
    try testing.expect(client.result == null);
}

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
