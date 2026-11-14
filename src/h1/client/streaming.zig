//! An HTTP/1 client over std.Io with a streaming response body.
//!
//! The client writes one request, parses the response head into a per-response
//! arena, and exposes body bytes through a `std.Io.Reader` on the shared client
//! `Body`. Framing is decoded here: whether the response is delimited by
//! Content-Length, by chunked framing, or by the close of the connection never
//! reaches the caller. It does not own the transport; the caller closes the
//! stream.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const ascii = std.ascii;

const common = @import("../../client/common.zig");
const Header = @import("../../header.zig").Header;
const Headers = @import("../../header.zig").Headers;
const Method = @import("../../method.zig").Method;
const h1 = @import("../root.zig");

pub const Request = common.Request;
pub const ResponseHead = common.ResponseHead;
pub const Body = common.Body;
pub const Outcome = common.Outcome;
pub const ReadCause = common.ReadCause;
pub const Local = common.Local;
pub const Response = common.Response;
pub const Config = common.Config;

const body_vtable: Body.VTable = .{
    .outcome = Client.bodyOutcome,
    .close = Client.bodyClose,
};

/// The body stream. `Client.bodyReader` is the field this vtable is looked up
/// from, and the client never moves after `init`.
const body_reader_vtable: Io.Reader.VTable = .{
    .stream = Client.bodyStream,
};

pub const Client = struct {
    allocator: Allocator,
    reader: *Io.Reader,
    writer: *Io.Writer,
    arena: std.heap.ArenaAllocator,
    conn: h1.ClientConn,
    recv: [16 * 1024]u8,
    header_storage: []Header,
    max_header_bytes: usize,
    max_headers: usize,
    read_cause: ?ReadCause,
    active: bool,
    body_eof: bool,
    body_outcome: ?Outcome,
    /// The response byte stream. `request` hands out a `Body` holding a pointer
    /// here, so the client must stay put for the life of that body.
    body_reader: Io.Reader,
    dirty: bool,
    /// Body bytes the machine delivered that the writer has not taken yet. The
    /// slice borrows `recv`, and no advancing operation runs while it is
    /// non-empty, so a writer that accepts a prefix never loses bytes.
    pending: []const u8,

    pub fn init(
        self: *Client,
        reader: *Io.Reader,
        writer: *Io.Writer,
        config: Config,
    ) !void {
        if (config.max_headers == 0) return error.InvalidConfig;
        const header_storage = try config.allocator.alloc(Header, config.max_headers);
        errdefer config.allocator.free(header_storage);

        self.* = .{
            .allocator = config.allocator,
            .reader = reader,
            .writer = writer,
            .arena = std.heap.ArenaAllocator.init(config.allocator),
            .conn = undefined,
            .recv = undefined,
            .header_storage = header_storage,
            .max_header_bytes = config.max_header_bytes,
            .max_headers = config.max_headers,
            .read_cause = config.read_cause,
            .active = false,
            .body_eof = false,
            .body_outcome = null,
            .body_reader = .{
                .vtable = &body_reader_vtable,
                .buffer = &.{},
                .seek = 0,
                .end = 0,
            },
            .dirty = false,
            .pending = &.{},
        };
        self.conn = h1.ClientConn.init(.{
            .recv_buffer = &self.recv,
            .headers = header_storage,
            .trailers = &.{},
        });
    }

    pub fn deinit(self: *Client) void {
        self.closeBody();
        self.arena.deinit();
        self.allocator.free(self.header_storage);
        self.* = undefined;
    }

    pub fn request(self: *Client, value: Request) !Response {
        if (self.active) return error.RequestInProgress;
        if (self.dirty) return error.ConnectionDirty;
        if (value.authority.len == 0) return error.InvalidAuthority;

        _ = self.arena.reset(.free_all);
        self.body_eof = false;
        self.body_outcome = null;
        self.pending = &.{};

        const method = Method.parse(value.method_token);
        var w: h1.Writer = .init(self.writer);
        try w.requestLineToken(value.method_token, value.target, .@"HTTP/1.1");
        var has_length = false;
        var has_transfer = false;
        for (value.headers) |header| {
            if (header.name.len == 0 or header.name[0] == ':') return error.InvalidHeader;
            if (ascii.eqlIgnoreCase(header.name, "host")) return error.DuplicateAuthority;
            if (ascii.eqlIgnoreCase(header.name, "content-length")) has_length = true;
            if (ascii.eqlIgnoreCase(header.name, "transfer-encoding")) has_transfer = true;
            try w.field(header.name, header.value);
        }
        try w.field("Host", value.authority);
        if (value.body.len != 0 and !has_length and !has_transfer) {
            try w.contentLength(value.body.len);
        }
        try w.endFields();
        if (value.body.len != 0) try w.body(value.body);
        try self.writer.flush();

        self.conn.start(method);
        var event = try self.conn.next();
        while (true) {
            switch (event) {
                .need_more => event = try self.readEvent(),
                .response => |response| {
                    if (response.head.status.class() == .informational) {
                        self.conn.start(method);
                        event = try self.conn.next();
                        continue;
                    }
                    const head = self.snapshot(response.head) catch |err| {
                        self.dirty = true;
                        return err;
                    };
                    self.active = true;
                    return .{
                        .head = head,
                        .body = .{
                            .ptr = self,
                            .vtable = &body_vtable,
                            .reader = &self.body_reader,
                        },
                    };
                },
                .body, .done => return error.UnexpectedBody,
                .closed => return error.EndOfStream,
            }
        }
    }

    fn snapshot(self: *Client, head: h1.ResponseHead) !ResponseHead {
        if (head.headers.items.len > self.max_headers) return error.HeadersTooLarge;
        var bytes: usize = 0;
        for (head.headers.items) |header| {
            bytes = std.math.add(usize, bytes, header.name.len) catch return error.HeadersTooLarge;
            bytes = std.math.add(usize, bytes, header.value.len) catch return error.HeadersTooLarge;
        }
        if (bytes > self.max_header_bytes) return error.HeadersTooLarge;

        const items = try self.arena.allocator().alloc(Header, head.headers.items.len);
        const storage = try self.arena.allocator().alloc(u8, bytes);
        var offset: usize = 0;
        for (head.headers.items, 0..) |header, index| {
            const name = storage[offset..][0..header.name.len];
            offset += header.name.len;
            @memcpy(name, header.name);
            const value = storage[offset..][0..header.value.len];
            offset += header.value.len;
            @memcpy(value, header.value);
            items[index] = .{ .name = name, .value = value };
        }
        return .{
            .protocol = .h1,
            .status = head.status,
            .headers = .{ .items = items },
        };
    }

    fn readEvent(self: *Client) !h1.ClientConn.Event {
        const dst = self.conn.recvBuffer();
        if (dst.len == 0) return error.BufferTooSmall;
        var iovecs: [1][]u8 = .{dst};
        const n = self.reader.readVec(&iovecs) catch |err| switch (err) {
            error.EndOfStream => 0,
            else => return err,
        };
        if (n != 0) return self.conn.received(n);

        // A buffered reader can fill its own buffer and return 0. That is not
        // EOF; move those bytes into the connection buffer.
        const buffered = self.reader.buffered();
        if (buffered.len == 0) return self.conn.eof();
        const take = @min(buffered.len, dst.len);
        @memcpy(dst[0..take], buffered[0..take]);
        self.reader.toss(take);
        return self.conn.received(take);
    }

    fn bodyStream(erased: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const self: *Client = @fieldParentPtr("body_reader", erased);
        return self.streamBody(w, limit);
    }

    /// Pump body bytes into `w`. Returns the count written, which is never
    /// more than `limit`, and reports a clean end as `error.EndOfStream`. A
    /// writer that accepts a prefix keeps the rest in `pending` for the next
    /// call; nothing advances the connection while `pending` holds bytes.
    fn streamBody(self: *Client, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        if (!self.active) return error.EndOfStream;

        var written: usize = 0;
        const cap = limit.minInt(std.math.maxInt(usize));
        if (cap == 0) return 0;
        while (written < cap) {
            if (self.pending.len != 0) {
                const take = self.pending[0..@min(self.pending.len, cap - written)];
                const n = w.write(take) catch return error.WriteFailed;
                self.pending = self.pending[n..];
                written += n;
                if (n != take.len) return written;
                continue;
            }
            if (self.body_eof) break;
            // Never block for more bytes once this call has some. The reader is
            // free to hand back a short count.
            if (written != 0) return written;

            var event = self.conn.next() catch |err| return self.failBody(err);
            while (true) {
                switch (event) {
                    .body => |bytes| {
                        if (bytes.len == 0) return self.failBody(error.EmptyBody);
                        self.pending = bytes;
                        break;
                    },
                    .done => {
                        self.body_eof = true;
                        break;
                    },
                    .need_more => event = self.readEvent() catch |err| return self.failBody(err),
                    .response => return self.failBody(error.UnexpectedResponse),
                    .closed => return self.failBody(error.Truncated),
                }
            }
        }

        if (written == 0) return error.EndOfStream;
        return written;
    }

    /// Classify a reading failure, latch the cause on the body, and report it
    /// as `error.ReadFailed`, which is the only failure `Io.Reader` has room
    /// for.
    fn failBody(self: *Client, err: anyerror) error{ReadFailed} {
        const outcome = self.classify(err);
        self.body_outcome = outcome;
        switch (outcome) {
            .local => |local| switch (local) {
                .canceled, .capacity => {},
                else => self.dirty = true,
            },
            .truncated, .protocol_error, .reset => self.dirty = true,
        }
        return error.ReadFailed;
    }

    fn classify(self: *const Client, err: anyerror) Outcome {
        return switch (err) {
            // The reader reports `error.ReadFailed` for every failure of its
            // own and keeps the cause, so ask it rather than guess. A reader
            // that keeps no cause latches nothing and reads as a truncation.
            error.ReadFailed => if (self.read_cause) |latched| blk: {
                const cause = latched.get() orelse break :blk Outcome.truncated;
                break :blk common.localFromCause(cause);
            } else Outcome.truncated,
            error.Canceled => .{ .local = .canceled },
            error.OutOfMemory => .{ .local = .out_of_memory },
            error.BufferTooSmall => .{ .local = .capacity },
            error.WouldBlock => .{ .local = .unusable },
            error.Incomplete,
            error.EndOfStream,
            error.Truncated,
            => .truncated,
            error.EmptyBody => .protocol_error,
            else => .protocol_error,
        };
    }

    /// True when the last failure left the response recoverable: our own
    /// cancellation, or a local capacity limit.
    fn recoverable(self: *const Client) bool {
        const local = switch (self.body_outcome orelse return false) {
            .local => |local| local,
            else => return false,
        };
        return local == .canceled or local == .capacity;
    }

    fn bodyOutcome(ptr: *anyopaque) ?Outcome {
        const self: *Client = @ptrCast(@alignCast(ptr));
        return self.body_outcome;
    }

    fn bodyClose(ptr: *anyopaque) void {
        const self: *Client = @ptrCast(@alignCast(ptr));
        self.closeBody();
    }

    fn closeBody(self: *Client) void {
        if (!self.active) return;
        if (!self.body_eof) {
            // h1 cannot reset a stream. Drain a bounded amount so the
            // connection can be reused; a larger or failed drain leaves the
            // connection dirty for the caller to close.
            const max_drain_bytes: usize = 1024 * 1024;
            var buffer: [4096]u8 = undefined;
            var discarding: Io.Writer.Discarding = .init(&buffer);
            while (discarding.count < max_drain_bytes) {
                const used: usize = @intCast(discarding.count);
                const limit: Io.Limit = .limited(max_drain_bytes - used);
                const outcome = self.streamBody(&discarding.writer, limit);
                if (outcome) |_| continue else |err| switch (err) {
                    error.EndOfStream => break,
                    error.WriteFailed => {
                        self.dirty = true;
                        break;
                    },
                    error.ReadFailed => {
                        if (!self.recoverable()) self.dirty = true;
                        break;
                    },
                }
            }
            if (!self.body_eof) self.dirty = true;
        }
        self.active = false;
        self.body_eof = false;
        self.body_outcome = null;
        self.pending = &.{};
    }
};

const Fixture = struct {
    io: Io,
    listener: Io.net.Server,
    address: Io.net.IpAddress,
    response: []const u8,
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
        var used: usize = 0;
        var stream_reader = stream.reader(self.io, &.{});
        while (used < request_buffer.len) {
            var iovecs: [1][]u8 = .{request_buffer[used..]};
            used += stream_reader.interface.readVec(&iovecs) catch break;
            if (std.mem.find(u8, request_buffer[0..used], "\r\n\r\n") != null) break;
        }

        var buffer: [256]u8 = undefined;
        var writer = stream.writer(self.io, &buffer);
        const head_len = (std.mem.find(u8, self.response, "\r\n\r\n") orelse 0) + 4;
        writer.interface.writeAll(self.response[0..head_len]) catch |err| {
            self.result = err;
            return;
        };
        writer.interface.flush() catch |err| {
            self.result = err;
            return;
        };
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
};

test "streaming client copies a body that arrives after the head" {
    var fixture: Fixture = undefined;
    try fixture.init("HTTP/1.1 200 OK\r\nContent-Length: 11\r\n" ++
        "Connection: close\r\n\r\nhello world");
    defer fixture.deinit();

    const stream = try fixture.address.connect(fixture.io, .{ .mode = .stream });
    defer stream.close(fixture.io);

    var write_buffer: [256]u8 = undefined;
    var stream_writer = stream.writer(fixture.io, &write_buffer);
    var stream_reader = stream.reader(fixture.io, &.{});
    var client: Client = undefined;
    try client.init(&stream_reader.interface, &stream_writer.interface, .{
        .allocator = testing.allocator,
    });
    defer client.deinit();

    const response = try client.request(.{
        .method_token = "GET",
        .scheme = .http,
        .authority = "example.com",
        .target = "/",
    });
    try testing.expectEqual(.ok, response.head.status);
    try testing.expectEqual(common.Protocol.h1, response.head.protocol);

    var got: [11]u8 = undefined;
    var writer = Io.Writer.fixed(&got);
    const used = try response.body.reader.streamRemaining(&writer);
    try testing.expectEqualStrings("hello world", got[0..used]);
    try testing.expect(response.body.outcome() == null);
    response.body.close();
}

test "streaming client sends a static request body" {
    var fixture: Fixture = undefined;
    try fixture.init("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok");
    defer fixture.deinit();

    const stream = try fixture.address.connect(fixture.io, .{ .mode = .stream });
    defer stream.close(fixture.io);

    var write_buffer: [256]u8 = undefined;
    var stream_writer = stream.writer(fixture.io, &write_buffer);
    var stream_reader = stream.reader(fixture.io, &.{});
    var client: Client = undefined;
    try client.init(&stream_reader.interface, &stream_writer.interface, .{
        .allocator = testing.allocator,
    });
    defer client.deinit();

    const response = try client.request(.{
        .method_token = "POST",
        .scheme = .http,
        .authority = "example.com",
        .target = "/",
        .body = "hello",
    });
    try testing.expectEqual(.ok, response.head.status);
    var got: [2]u8 = undefined;
    var writer = Io.Writer.fixed(&got);
    const used = try response.body.reader.streamRemaining(&writer);
    try testing.expectEqualStrings("ok", got[0..used]);
    response.body.close();
}

test "request with a body reaches the response read" {
    var reader = Io.Reader.failing;
    var out: [1024]u8 = undefined;
    var writer = Io.Writer.fixed(&out);
    var client: Client = undefined;
    try client.init(&reader, &writer, .{ .allocator = testing.allocator });
    defer client.deinit();

    try testing.expectError(error.ReadFailed, client.request(.{
        .method_token = "POST",
        .scheme = .http,
        .authority = "example.com",
        .target = "/",
        .body = "x",
    }));
    try testing.expectError(error.DuplicateAuthority, client.request(.{
        .method_token = "GET",
        .scheme = .http,
        .authority = "example.com",
        .target = "/",
        .headers = &.{.{ .name = "host", .value = "example.com" }},
    }));
}

/// Serve `text` on one connection and hand the body to `body_fn`. This is the
/// setup one response needs, so the tests below differ only in their framing.
fn withBody(
    fixture: *Fixture,
    context: anytype,
    comptime body_fn: fn (@TypeOf(context), Body) anyerror!void,
) !void {
    const stream = try fixture.address.connect(fixture.io, .{ .mode = .stream });
    defer stream.close(fixture.io);

    var write_buffer: [256]u8 = undefined;
    var stream_writer = stream.writer(fixture.io, &write_buffer);
    var stream_reader = stream.reader(fixture.io, &.{});
    var client: Client = undefined;
    try client.init(&stream_reader.interface, &stream_writer.interface, .{
        .allocator = testing.allocator,
    });
    defer client.deinit();

    const response = try client.request(.{
        .method_token = "GET",
        .scheme = .http,
        .authority = "example.com",
        .target = "/",
    });
    defer response.body.close();
    try body_fn(context, response.body);
}

fn expectSameBytes(expected: []const u8, body: Body) !void {
    var got: [64]u8 = undefined;
    var writer = Io.Writer.fixed(&got);
    const used = try body.reader.streamRemaining(&writer);
    try testing.expectEqualStrings(expected, got[0..used]);
    try testing.expect(body.outcome() == null);
}

test "a streaming body is framing-blind" {
    const payload: []const u8 = "the same bytes every time";
    const responses = [_][]const u8{
        "HTTP/1.1 200 OK\r\nContent-Length: 25\r\nConnection: close\r\n\r\n" ++
            "the same bytes every time",
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n" ++
            "19\r\nthe same bytes every time\r\n0\r\n\r\n",
        "HTTP/1.1 200 OK\r\nConnection: close\r\n\r\nthe same bytes every time",
    };
    try testing.expectEqual(25, payload.len);

    for (responses) |text| {
        var fixture: Fixture = undefined;
        try fixture.init(text);
        defer fixture.deinit();
        try withBody(&fixture, payload, expectSameBytes);
    }
}

fn countBytes(expected: u64, body: Body) !void {
    var buffer: [4096]u8 = undefined;
    var discarding: Io.Writer.Discarding = .init(&buffer);
    _ = try body.reader.streamRemaining(&discarding.writer);
    try testing.expectEqual(expected, discarding.fullCount());
    try testing.expect(body.outcome() == null);
}

// The cap this used to hit was 16 MiB in `h1.ClientConn`, counted over the
// whole response. A streaming caller has no such bound: the machine buffers
// one receive window and the reader hands its bytes on.
test "a streaming body has no total-size cap" {
    const total: usize = 17 * 1024 * 1024;
    const gpa = testing.allocator;

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    var chunk: [64 * 1024]u8 = undefined;
    @memset(&chunk, 'x');
    var remaining = total;
    while (remaining > 0) {
        const n = @min(remaining, chunk.len);
        var size_buf: [32]u8 = undefined;
        try body.appendSlice(gpa, try std.fmt.bufPrint(&size_buf, "{x}\r\n", .{n}));
        try body.appendSlice(gpa, chunk[0..n]);
        try body.appendSlice(gpa, "\r\n");
        remaining -= n;
    }
    try body.appendSlice(gpa, "0\r\n\r\n");

    const response = try std.fmt.allocPrint(
        gpa,
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n{s}",
        .{body.items},
    );
    defer gpa.free(response);

    var fixture: Fixture = undefined;
    try fixture.init(response);
    defer fixture.deinit();
    try withBody(&fixture, @as(u64, total), countBytes);
}

/// A writer that accepts at most `step` bytes per call, so every write into it
/// is short. The body must keep the remainder rather than drop it.
const Trickle = struct {
    out: [64]u8 = undefined,
    used: usize = 0,
    step: usize = 3,
    writer: Io.Writer,

    fn init(self: *Trickle) void {
        self.* = .{ .writer = .{ .vtable = &.{ .drain = drain }, .buffer = &.{} } };
    }

    fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        _ = splat;
        const self: *Trickle = @fieldParentPtr("writer", w);
        if (data.len == 0) return 0;
        const take = @min(data[0].len, self.step);
        @memcpy(self.out[self.used..][0..take], data[0][0..take]);
        self.used += take;
        return take;
    }
};

fn trickleBody(_: void, body: Body) !void {
    var trickle: Trickle = undefined;
    trickle.init();
    _ = try body.reader.streamRemaining(&trickle.writer);
    try testing.expectEqualStrings("hello world", trickle.out[0..trickle.used]);
}

test "a short write keeps the rest of the body" {
    var fixture: Fixture = undefined;
    try fixture.init(
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n" ++
            "b\r\nhello world\r\n0\r\n\r\n",
    );
    defer fixture.deinit();
    try withBody(&fixture, @as(void, {}), trickleBody);
}

fn expectTruncated(_: void, body: Body) !void {
    var buffer: [64]u8 = undefined;
    var discarding: Io.Writer.Discarding = .init(&buffer);
    try testing.expectError(error.ReadFailed, body.reader.streamRemaining(&discarding.writer));
    try testing.expectEqual(Outcome.truncated, body.outcome().?);
}

test "a peer that stops mid-body is a truncation" {
    var fixture: Fixture = undefined;
    try fixture.init("HTTP/1.1 200 OK\r\nContent-Length: 20\r\n\r\nshort");
    defer fixture.deinit();
    try withBody(&fixture, @as(void, {}), expectTruncated);
}

/// A reader that serves `head` and then fails every read with
/// `error.ReadFailed`, latching a cause the way a TLS connection does.
const LatchReader = struct {
    head: []const u8,
    pos: usize = 0,
    latched: ?anyerror = null,
    reader: Io.Reader,

    fn init(self: *LatchReader, head: []const u8) void {
        self.* = .{
            .head = head,
            .reader = .{ .vtable = &.{ .stream = stream }, .buffer = &.{}, .seek = 0, .end = 0 },
        };
    }

    fn stream(erased: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const self: *LatchReader = @fieldParentPtr("reader", erased);
        const rest = self.head[self.pos..];
        if (rest.len == 0) return error.ReadFailed;
        const take = rest[0..limit.minInt(rest.len)];
        const n = try w.write(take);
        self.pos += n;
        return n;
    }

    fn cause(context: *const anyopaque) ?anyerror {
        const self: *const LatchReader = @ptrCast(@alignCast(context));
        return self.latched;
    }
};

test "a latched read cause reaches the body instead of reading as a truncation" {
    var source: LatchReader = undefined;
    source.init("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\n");
    source.latched = error.TimedOut;

    var out: [256]u8 = undefined;
    var out_writer = Io.Writer.fixed(&out);
    var client: Client = undefined;
    try client.init(&source.reader, &out_writer, .{
        .allocator = testing.allocator,
        .read_cause = .{ .context = &source, .cause = LatchReader.cause },
    });
    defer client.deinit();

    const response = try client.request(.{
        .method_token = "GET",
        .scheme = .http,
        .authority = "example.com",
        .target = "/",
    });
    defer response.body.close();

    var got: [16]u8 = undefined;
    var got_writer = Io.Writer.fixed(&got);
    try testing.expectError(error.ReadFailed, response.body.reader.streamRemaining(&got_writer));
    try testing.expectEqual(Outcome{ .local = .timed_out }, response.body.outcome().?);
}

/// The reader has no internal buffer, so the `Reader` surface that needs one
/// (`peek`, `take`, `takeArray`) is out. Everything that writes into a caller
/// buffer is in, and that is what a body is for.
fn readWithStdHelpers(_: void, body: Body) !void {
    const head = "the same bytes";
    try testing.expectEqual(8 + 6, head.len);
    var prefix: [8]u8 = undefined;
    try body.reader.readSliceAll(prefix[0..]);
    try testing.expectEqualStrings(head[0..8], &prefix);

    const rest = try body.reader.allocRemaining(testing.allocator, .limited(1024));
    defer testing.allocator.free(rest);
    try testing.expectEqualStrings(head[8..], rest);
}

test "a body reader serves readSliceAll and allocRemaining" {
    var fixture: Fixture = undefined;
    try fixture.init(
        "HTTP/1.1 200 OK\r\nContent-Length: 14\r\nConnection: close\r\n\r\nthe same bytes",
    );
    defer fixture.deinit();
    try withBody(&fixture, @as(void, {}), readWithStdHelpers);
}
