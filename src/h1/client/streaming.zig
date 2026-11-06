//! A blocking HTTP/1 client with a streaming response body.
//!
//! The client writes one request, parses the response head into a per-response
//! arena, and exposes body bytes through the shared client `Body` interface.
//! It does not own the transport; the caller closes the stream.

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
pub const BodyResult = common.BodyResult;
pub const BodyError = common.BodyError;
pub const Local = common.Local;
pub const Response = common.Response;
pub const Config = common.Config;

const body_vtable: Body.VTable = .{
    .read = Client.bodyRead,
    .resetCode = Client.bodyResetCode,
    .localCause = Client.bodyLocalCause,
    .close = Client.bodyClose,
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
    active: bool,
    body_eof: bool,
    body_local: ?Local,
    dirty: bool,
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
            .active = false,
            .body_eof = false,
            .body_local = null,
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
        self.body_local = null;
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
                        .body = .{ .ptr = self, .vtable = &body_vtable },
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
        return if (n == 0) self.conn.eof() else self.conn.received(n);
    }

    fn bodyRead(ptr: *anyopaque) BodyError!BodyResult {
        const self: *Client = @ptrCast(@alignCast(ptr));
        return self.readBody();
    }

    fn readBody(self: *Client) BodyError!BodyResult {
        if (!self.active) return .eof;
        while (true) {
            // A slice returned on the previous call is still the current
            // slice. The next read releases it and advances the connection.
            if (self.pending.len != 0) self.pending = &.{};
            if (self.body_eof) return .eof;

            var event = self.conn.next() catch |err| return self.bodyFailure(err);
            while (true) {
                switch (event) {
                    .body => |bytes| {
                        if (bytes.len == 0) {
                            self.dirty = true;
                            return error.Protocol;
                        }
                        self.pending = bytes;
                        return .{ .data = bytes };
                    },
                    .done => {
                        self.body_eof = true;
                        return .eof;
                    },
                    .need_more => event = self.readEvent() catch |err| return self.bodyFailure(err),
                    .response => {
                        self.dirty = true;
                        return error.Protocol;
                    },
                    .closed => {
                        self.dirty = true;
                        return error.Truncated;
                    },
                }
            }
        }
    }

    fn bodyFailure(self: *Client, err: anyerror) BodyError {
        return switch (err) {
            error.Canceled => blk: {
                self.body_local = .canceled;
                break :blk error.LocalCanceled;
            },
            error.OutOfMemory => blk: {
                self.body_local = .out_of_memory;
                self.dirty = true;
                break :blk error.LocalOutOfMemory;
            },
            error.BufferTooSmall => blk: {
                self.body_local = .capacity;
                break :blk error.LocalCapacity;
            },
            error.WouldBlock => blk: {
                self.body_local = .unusable;
                self.dirty = true;
                break :blk error.LocalUnusable;
            },
            error.Incomplete,
            error.EndOfStream,
            error.ReadFailed,
            => blk: {
                self.dirty = true;
                break :blk error.Truncated;
            },
            else => blk: {
                self.dirty = true;
                break :blk error.Protocol;
            },
        };
    }

    fn bodyResetCode(_: *anyopaque) ?u32 {
        return null;
    }

    fn bodyLocalCause(ptr: *anyopaque) ?Local {
        const self: *Client = @ptrCast(@alignCast(ptr));
        return self.body_local;
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
            const max_drain_bytes = 1024 * 1024;
            var drained: usize = 0;
            while (drained < max_drain_bytes) {
                const result = self.readBody() catch |err| switch (err) {
                    error.LocalCanceled, error.LocalCapacity => break,
                    else => {
                        self.dirty = true;
                        break;
                    },
                };
                switch (result) {
                    .data => |bytes| drained += bytes.len,
                    .eof => break,
                }
            }
            if (!self.body_eof) self.dirty = true;
        }
        self.active = false;
        self.body_eof = false;
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
    var used: usize = 0;
    while (true) {
        switch (try response.body.read()) {
            .data => |bytes| {
                try testing.expect(bytes.len != 0);
                @memcpy(got[used..][0..bytes.len], bytes);
                used += bytes.len;
            },
            .eof => break,
        }
    }
    try testing.expectEqualStrings("hello world", got[0..used]);
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
    var used: usize = 0;
    while (true) {
        switch (try response.body.read()) {
            .data => |bytes| {
                @memcpy(got[used..][0..bytes.len], bytes);
                used += bytes.len;
            },
            .eof => break,
        }
    }
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
