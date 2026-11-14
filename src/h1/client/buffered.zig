//! An HTTP/1 client over `std.Io.net` that buffers the whole body.
//!
//! The adapter writes one request with `h1.Writer`, feeds the response into
//! `h1.ClientConn`, and copies the body into a caller-owned buffer. It does
//! not allocate, does not own the stream, and does not reuse the connection.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const mem = std.mem;
const ascii = std.ascii;

const Header = @import("../../header.zig").Header;
const Method = @import("../../method.zig").Method;
const h1 = @import("../root.zig");

// ast-grep-ignore: public-struct-field-default -- options bag; caller overrides one field
pub const Request = struct {
    method: Method,
    target: []const u8,
    headers: []const Header = &.{},
    body: []const u8 = "",
};

// ast-grep-ignore: public-struct-field-default -- options bag; the buffers are the policy
pub const Config = struct {
    /// Receive window for response heads and body bytes.
    recv_buffer: []u8,
    /// Field storage for the response head.
    headers: []Header,
    /// Trailer storage for chunked responses. Empty rejects trailers.
    trailers: []Header = &.{},
    /// Destination for the complete response body.
    body_buffer: []u8,
    /// Writer buffer for the request.
    write_buffer: []u8,
};

pub const Response = struct {
    head: h1.ResponseHead,
    framing: h1.framing.ResponseBody,
    body: []u8,
};

/// Write one request and read one response. The caller owns the stream and
/// must close it. Payload and field slices in `Response` borrow `config`.
pub fn fetch(
    io: Io,
    stream: Io.net.Stream,
    request: Request,
    config: Config,
) !Response {
    var stream_writer = stream.writer(io, config.write_buffer);
    var stream_reader = stream.reader(io, &.{});
    return fetchIo(&stream_reader.interface, &stream_writer.interface, request, config);
}

/// Write one request and read one response over caller-owned plaintext
/// reader and writer interfaces. TLS adapters call this after the handshake.
pub fn fetchIo(
    reader: *Io.Reader,
    writer: *Io.Writer,
    request: Request,
    config: Config,
) !Response {
    var w: h1.Writer = .init(writer);

    try w.requestLine(request.method, request.target, .@"HTTP/1.1");
    var has_length = false;
    var has_transfer = false;
    for (request.headers) |header| {
        if (ascii.eqlIgnoreCase(header.name, "content-length")) has_length = true;
        if (ascii.eqlIgnoreCase(header.name, "transfer-encoding")) has_transfer = true;
        try w.field(header.name, header.value);
    }
    if (request.body.len != 0 and !has_length and !has_transfer) {
        try w.contentLength(request.body.len);
    }
    try w.endFields();
    if (request.body.len != 0) try w.body(request.body);
    try writer.flush();

    // This adapter materializes the whole body into a caller-owned buffer, so
    // it states the cap the caller actually has instead of inheriting one.
    var conn: h1.ClientConn = .init(.{
        .recv_buffer = config.recv_buffer,
        .headers = config.headers,
        .trailers = config.trailers,
        .body_bytes = @intCast(config.body_buffer.len),
    });
    conn.start(request.method);

    var final: ?h1.ClientConn.Response = null;
    var body_used: usize = 0;
    var event = try conn.next();
    while (true) {
        switch (event) {
            .need_more => {
                const dst = conn.recvBuffer();
                if (dst.len == 0) return error.BufferTooSmall;
                var iovecs: [1][]u8 = .{dst};
                const n = reader.readVec(&iovecs) catch |err| switch (err) {
                    error.EndOfStream => 0,
                    else => return err,
                };
                event = if (n == 0) try conn.eof() else try conn.received(n);
            },
            .response => |response| {
                if (response.head.status.class() == .informational) {
                    conn.start(request.method);
                    event = try conn.next();
                    continue;
                }
                final = response;
                event = try conn.next();
            },
            .body => |bytes| {
                if (bytes.len > config.body_buffer.len - body_used) return error.BodyTooLarge;
                @memcpy(config.body_buffer[body_used..][0..bytes.len], bytes);
                body_used += bytes.len;
                event = try conn.next();
            },
            .done => {
                const response = final orelse return error.NoResponse;
                return .{
                    .head = response.head,
                    .framing = response.framing,
                    .body = config.body_buffer[0..body_used],
                };
            },
            .closed => return error.EndOfStream,
        }
    }
}

const Fixture = struct {
    io: Io,
    listener: Io.net.Server,
    address: Io.net.IpAddress,
    response: []const u8,
    /// Write the head and the body as two writes with a gap, so the client
    /// reads them separately. Real servers do this.
    split: bool = false,
    result: ?anyerror = null,
    thread: std.Thread,

    fn init(self: *Fixture, response: []const u8) !void {
        self.io = testing.io;
        self.response = response;
        self.result = null;
        self.address = try .parseLiteral("127.0.0.1:0");
        self.listener = try self.address.listen(self.io, .{
            .mode = .stream,
            .reuse_address = true,
        });
        self.address.setPort(self.listener.socket.address.getPort());
        self.thread = try .spawn(.{}, run, .{self});
    }

    fn deinit(self: *Fixture) void {
        self.thread.join();
        self.listener.deinit(self.io);
        if (self.result) |err| @panic(@errorName(err));
        self.* = undefined;
    }

    fn run(self: *Fixture) void {
        const stream = self.listener.accept(self.io) catch |err| {
            self.result = err;
            return;
        };
        defer stream.close(self.io);

        var request_buffer: [512]u8 = undefined;
        var request_used: usize = 0;
        var stream_reader = stream.reader(self.io, &.{});
        while (request_used < request_buffer.len) {
            var iovecs: [1][]u8 = .{request_buffer[request_used..]};
            request_used += stream_reader.interface.readVec(&iovecs) catch break;
            if (mem.find(u8, request_buffer[0..request_used], "\r\n\r\n") != null) break;
        }

        var buffer: [256]u8 = undefined;
        var writer = stream.writer(self.io, &buffer);
        const head_len = if (self.split)
            (mem.find(u8, self.response, "\r\n\r\n") orelse 0) + 4
        else
            self.response.len;
        writer.interface.writeAll(self.response[0..head_len]) catch |err| {
            self.result = err;
            return;
        };
        writer.interface.flush() catch |err| {
            self.result = err;
            return;
        };
        if (self.split) {
            self.io.sleep(.{ .nanoseconds = 20 * std.time.ns_per_ms }, .awake) catch |err| {
                self.result = err;
                return;
            };
            writer.interface.writeAll(self.response[head_len..]) catch |err| {
                self.result = err;
                return;
            };
            writer.interface.flush() catch |err| {
                self.result = err;
            };
        }
    }
};

const TestBuffers = struct {
    recv: [4096]u8 = undefined,
    headers: [16]Header = undefined,
    trailers: [8]Header = undefined,
    body: [4096]u8 = undefined,
    write: [256]u8 = undefined,

    fn config(self: *TestBuffers) Config {
        return .{
            .recv_buffer = &self.recv,
            .headers = &self.headers,
            .trailers = &self.trailers,
            .body_buffer = &self.body,
            .write_buffer = &self.write,
        };
    }
};

fn sampleRequest() Request {
    return .{
        .method = .GET,
        .target = "/",
        .headers = &.{.{ .name = "Host", .value = "example.com" }},
    };
}

test "buffered client reads Content-Length" {
    var fixture: Fixture = undefined;
    try fixture.init("HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello");
    defer fixture.deinit();

    var buffers: TestBuffers = .{};
    const stream = try fixture.address.connect(fixture.io, .{ .mode = .stream });
    defer stream.close(fixture.io);
    const response = try fetch(fixture.io, stream, sampleRequest(), buffers.config());
    try testing.expectEqual(.ok, response.head.status);
    try testing.expectEqualStrings("hello", response.body);
}

test "buffered client reads chunked and skips an interim response" {
    var fixture: Fixture = undefined;
    try fixture.init(
        "HTTP/1.1 100 Continue\r\n\r\n" ++
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n" ++
            "5\r\nhello\r\n0\r\n\r\n",
    );
    defer fixture.deinit();

    var buffers: TestBuffers = .{};
    const stream = try fixture.address.connect(fixture.io, .{ .mode = .stream });
    defer stream.close(fixture.io);
    const response = try fetch(fixture.io, stream, sampleRequest(), buffers.config());
    try testing.expectEqual(.ok, response.head.status);
    try testing.expectEqualStrings("hello", response.body);
}

test "buffered client reads a close-delimited body" {
    var fixture: Fixture = undefined;
    try fixture.init("HTTP/1.1 200 OK\r\nConnection: close\r\n\r\nhello");
    defer fixture.deinit();

    var buffers: TestBuffers = .{};
    const stream = try fixture.address.connect(fixture.io, .{ .mode = .stream });
    defer stream.close(fixture.io);
    const response = try fetch(fixture.io, stream, sampleRequest(), buffers.config());
    try testing.expectEqual(.ok, response.head.status);
    try testing.expectEqualStrings("hello", response.body);
}

test "buffered client keeps the head when the body arrives later" {
    var fixture: Fixture = undefined;
    try fixture.init("HTTP/1.1 200 OK\r\nServer: h1\r\nContent-Length: 20\r\n\r\n" ++
        "0123456789abcdefghij");
    defer fixture.deinit();
    fixture.split = true;

    var buffers: TestBuffers = .{};
    const stream = try fixture.address.connect(fixture.io, .{ .mode = .stream });
    defer stream.close(fixture.io);
    const response = try fetch(fixture.io, stream, sampleRequest(), buffers.config());
    try testing.expectEqualStrings("0123456789abcdefghij", response.body);
    // The head borrows the receive buffer; the body read must not land on it.
    try testing.expectEqualStrings("OK", response.head.reason);
    try testing.expectEqualStrings("h1", response.head.headers.items[0].value);
}
