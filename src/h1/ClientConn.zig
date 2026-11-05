//! A sans-I/O HTTP/1 client connection.
//!
//! The caller owns the receive buffer and header storage, writes the request
//! with `h1.Writer`, feeds response bytes, and consumes borrowed body slices.
//! The machine buffers only the current receive window; it never allocates and
//! never buffers the whole body.
//!
//! One request is in flight at a time. A final response, or an interim 1xx
//! head, is returned as `Event.response`. Body bytes follow as `Event.body`;
//! `Event.done` ends the response. Leftover bytes after `done` belong to the
//! next response, and `start` preserves them.

const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;

const Header = @import("../header.zig").Header;
const Method = @import("../method.zig").Method;
const h1 = @import("root.zig");

const ClientConn = @This();

// ast-grep-ignore: public-struct-field-default -- options bag; buffer policy
pub const Config = struct {
    /// Caller-owned receive window. The caller reads into `recvBuffer()`.
    recv_buffer: []u8,
    /// Caller-owned field storage for the current response head.
    headers: []Header,
    /// Caller-owned storage for chunked trailers. Empty rejects trailers.
    trailers: []Header = &.{},
    /// Maximum body bytes delivered to the caller.
    body_bytes: u64 = 16 * 1024 * 1024,
};

pub const Response = struct {
    head: h1.ResponseHead,
    framing: h1.framing.ResponseBody,
};

pub const Event = union(enum) {
    /// Read more bytes into `recvBuffer` and call either `received`.
    need_more,
    /// A response head. Call `next` for its body.
    response: Response,
    /// A borrowed body slice, valid until the next call to the machine.
    body: []const u8,
    /// The response is complete. Call `start` for the next request.
    done,
    /// The peer closed before any response bytes.
    closed,
};

pub const Error = h1.Error || h1.framing.Error || h1.chunked.Error || error{
    HeadTooLarge,
    BodyTooLarge,
};

const Phase = enum { head, body, done, closed };

recv_buffer: []u8,
headers: []Header,
trailers: []Header,
body_bytes: u64,

phase: Phase,
used: usize,
cursor: usize,
/// End of the current response head. The head borrows `recv_buffer[0..head_end]`,
/// so a refill must not write below it.
head_end: usize,
search: h1.SearchState,
method: ?Method,
version: h1.Version,
head: h1.ResponseHead,
framing: h1.framing.ResponseBody,
chunked: h1.chunked.Decoder,
body_remaining: u64,
delivered: u64,
eof_seen: bool,

pub fn init(config: Config) ClientConn {
    return .{
        .recv_buffer = config.recv_buffer,
        .headers = config.headers,
        .trailers = config.trailers,
        .body_bytes = config.body_bytes,
        .phase = .head,
        .used = 0,
        .cursor = 0,
        .head_end = 0,
        .search = .init,
        .method = null,
        .version = .@"HTTP/1.1",
        .head = undefined,
        .framing = .none,
        .chunked = undefined,
        .body_remaining = 0,
        .delivered = 0,
        .eof_seen = false,
    };
}

/// Begin the next response. Call before writing a request and after `done`.
/// Leftover bytes from the previous response stay at the front of the receive
/// buffer.
pub fn start(self: *ClientConn, method: Method) void {
    assert(self.phase == .head or self.phase == .done);
    // The finished head is dead; the next one is parsed from offset 0.
    self.head_end = 0;
    if (self.phase == .done) self.compactTo(0);
    self.phase = .head;
    self.cursor = 0;
    self.search = .init;
    self.method = method;
    self.head = undefined;
    self.framing = .none;
    self.body_remaining = 0;
    self.delivered = 0;
    self.eof_seen = false;
}

/// Where the caller reads. Empty when body bytes are still unconsumed or the
/// response is complete.
pub fn recvBuffer(self: *ClientConn) []u8 {
    switch (self.phase) {
        .head, .body => {},
        .done, .closed => return self.recv_buffer[0..0],
    }
    if (self.cursor != 0 and self.cursor == self.used) self.compactTo(self.head_end);
    return self.recv_buffer[self.used..];
}

/// Account for bytes read into `recvBuffer`.
pub fn received(self: *ClientConn, n: usize) Error!Event {
    assert(self.phase == .head or self.phase == .body);
    assert(n <= self.recv_buffer.len - self.used);
    if (n == 0) return self.eof();
    self.used += n;
    return self.step();
}

/// Process bytes already in the receive buffer. Call after `Event.response`
/// to get body data, or after `Event.body` to get the next slice.
pub fn next(self: *ClientConn) Error!Event {
    return self.step();
}

/// The peer closed. A clean close before any bytes is `closed`; a close in the
/// middle of a head or length/chunked body is an error.
pub fn eof(self: *ClientConn) Error!Event {
    self.eof_seen = true;
    switch (self.phase) {
        .head => {
            if (self.used == 0) {
                self.phase = .closed;
                return .closed;
            }
            return error.Incomplete;
        },
        .body => switch (self.framing) {
            .close => return self.step(),
            .length => if (self.body_remaining != 0) return error.Incomplete,
            .chunked => if (!self.chunked.isDone()) return error.Incomplete,
            .none, .tunnel => {},
        },
        .done => return .done,
        .closed => return .closed,
    }
    return self.step();
}

fn step(self: *ClientConn) Error!Event {
    return switch (self.phase) {
        .head => self.parseHead(),
        .body => self.bodyStep(),
        .done => .done,
        .closed => .closed,
    };
}

fn parseHead(self: *ClientConn) Error!Event {
    const parsed = h1.parseResponse(
        self.recv_buffer[0..self.used],
        &self.search,
        self.headers,
    ) catch |err| switch (err) {
        error.Incomplete => {
            if (self.used == self.recv_buffer.len) return error.HeadTooLarge;
            return .need_more;
        },
        else => return err,
    };

    self.version = parsed.head.version;
    self.head = parsed.head;
    self.cursor = parsed.consumed;
    self.head_end = parsed.consumed;
    self.framing = try h1.framing.response(
        self.head.version,
        self.head.status,
        self.method,
        self.head.headers,
    );

    switch (self.framing) {
        .none => self.phase = .done,
        .length => |length| {
            if (length > self.body_bytes) return error.BodyTooLarge;
            self.body_remaining = length;
            self.phase = if (length == 0) .done else .body;
        },
        .chunked => {
            self.chunked = .init(self.trailers);
            self.phase = .body;
        },
        .close => self.phase = .body,
        .tunnel => self.phase = .done,
    }

    return .{ .response = .{
        .head = self.head,
        .framing = self.framing,
    } };
}

fn bodyStep(self: *ClientConn) Error!Event {
    return switch (self.framing) {
        .none, .tunnel => self.finish(),
        .length => self.lengthBody(),
        .chunked => self.chunkedBody(),
        .close => self.closeBody(),
    };
}

fn lengthBody(self: *ClientConn) Error!Event {
    if (self.body_remaining == 0) return self.finish();

    const available = self.used - self.cursor;
    if (available == 0) return .need_more;
    const n: usize = @intCast(@min(@as(u64, available), self.body_remaining));
    try self.deliver(n);
    const slice = self.recv_buffer[self.cursor..][0..n];
    self.cursor += n;
    self.body_remaining -= n;
    if (self.body_remaining == 0) self.phase = .done;
    return .{ .body = slice };
}

fn closeBody(self: *ClientConn) Error!Event {
    const available = self.used - self.cursor;
    if (available != 0) {
        try self.deliver(available);
        const slice = self.recv_buffer[self.cursor..self.used];
        self.cursor = self.used;
        return .{ .body = slice };
    }
    if (self.eof_seen) return self.finish();
    return .need_more;
}

fn chunkedBody(self: *ClientConn) Error!Event {
    while (true) {
        const body_start = self.cursor;
        const step_result = self.chunked.next(
            self.recv_buffer[body_start..self.used],
        ) catch |err| switch (err) {
            error.Incomplete => {
                if (body_start == self.head_end and self.used == self.recv_buffer.len) {
                    return error.BodyTooLarge;
                }
                self.compactTo(self.head_end);
                return .need_more;
            },
            else => return err,
        };
        self.cursor += step_result.consumed;

        switch (step_result.event) {
            .data => |data| {
                try self.deliver(data.len);
                return .{ .body = self.recv_buffer[body_start..][0..data.len] };
            },
            .trailers => return self.finish(),
            .need_more => {
                if (self.cursor == body_start) {
                    if (self.used == self.recv_buffer.len) {
                        self.compactTo(self.head_end);
                        if (self.used == self.recv_buffer.len) return error.BodyTooLarge;
                    }
                    return .need_more;
                }
                // The decoder consumed a size line or a chunk terminator.
                // Loop so a complete chunk in this buffer becomes a body
                // event without another call from the caller.
                if (self.cursor == self.used) self.compactTo(self.head_end);
            },
        }
    }
}

fn deliver(self: *ClientConn, n: usize) Error!void {
    if (n > self.body_bytes - self.delivered) return error.BodyTooLarge;
    self.delivered += n;
}

fn finish(self: *ClientConn) Event {
    self.phase = .done;
    // Nothing of this head is live any more: move leftover bytes to offset 0
    // for the next response.
    self.head_end = 0;
    self.compactTo(0);
    return .done;
}

/// Move unconsumed bytes down to `floor` and account for the reads already
/// made. While a head is live the floor is `head_end`, which keeps its text
/// intact for the caller; `0` repositions leftover bytes for the next head.
fn compactTo(self: *ClientConn, floor: usize) void {
    assert(floor <= self.cursor);
    if (self.cursor == floor) return;
    const remaining = self.used - self.cursor;
    if (remaining != 0) {
        @memmove(self.recv_buffer[floor..][0..remaining], self.recv_buffer[self.cursor..self.used]);
    }
    self.used = floor + remaining;
    self.cursor = floor;
}

test "content-length response" {
    var buffer: [1024]u8 = undefined;
    var headers: [8]Header = undefined;
    var conn: ClientConn = .init(.{ .recv_buffer = &buffer, .headers = &headers });
    conn.start(.GET);

    const bytes = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello";
    @memcpy(buffer[0..bytes.len], bytes);

    switch (try conn.received(bytes.len)) {
        .response => |response| {
            try testing.expectEqual(.ok, response.head.status);
            try testing.expectEqual(h1.framing.ResponseBody{ .length = 5 }, response.framing);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (try conn.next()) {
        .body => |body| try testing.expectEqualStrings("hello", body),
        else => return error.TestUnexpectedResult,
    }
    try testing.expectEqual(Event.done, try conn.next());
}

test "split head and body" {
    var buffer: [1024]u8 = undefined;
    var headers: [8]Header = undefined;
    var conn: ClientConn = .init(.{ .recv_buffer = &buffer, .headers = &headers });
    conn.start(.GET);

    const first = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n";
    @memcpy(buffer[0..first.len], first);
    try testing.expectEqual(Event.need_more, try conn.received(first.len));

    const rest = "\r\nhello";
    @memcpy(buffer[first.len..][0..rest.len], rest);
    switch (try conn.received(rest.len)) {
        .response => {},
        else => return error.TestUnexpectedResult,
    }
    switch (try conn.next()) {
        .body => |body| try testing.expectEqualStrings("hello", body),
        else => return error.TestUnexpectedResult,
    }
    try testing.expectEqual(Event.done, try conn.next());
}

test "HEAD has no body despite Content-Length" {
    var buffer: [1024]u8 = undefined;
    var headers: [8]Header = undefined;
    var conn: ClientConn = .init(.{ .recv_buffer = &buffer, .headers = &headers });
    conn.start(.HEAD);

    const bytes = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\n";
    @memcpy(buffer[0..bytes.len], bytes);
    switch (try conn.received(bytes.len)) {
        .response => |response| try testing.expectEqual(.none, response.framing),
        else => return error.TestUnexpectedResult,
    }
    try testing.expectEqual(Event.done, try conn.next());
}

test "chunked response across reads" {
    var buffer: [1024]u8 = undefined;
    var headers: [8]Header = undefined;
    var conn: ClientConn = .init(.{ .recv_buffer = &buffer, .headers = &headers });
    conn.start(.GET);

    const head = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n";
    @memcpy(buffer[0..head.len], head);
    switch (try conn.received(head.len)) {
        .response => |response| try testing.expectEqual(.chunked, response.framing),
        else => return error.TestUnexpectedResult,
    }

    const data = "5\r\nhel";
    @memcpy(buffer[head.len..][0..data.len], data);
    switch (try conn.received(data.len)) {
        .body => |body| try testing.expectEqualStrings("hel", body),
        else => return error.TestUnexpectedResult,
    }

    const rest = "lo\r\n0\r\n\r\n";
    const used = conn.used;
    @memcpy(buffer[used..][0..rest.len], rest);
    switch (try conn.received(rest.len)) {
        .body => |body| try testing.expectEqualStrings("lo", body),
        else => return error.TestUnexpectedResult,
    }
    try testing.expectEqual(Event.done, try conn.next());
}

test "close-delimited response" {
    var buffer: [1024]u8 = undefined;
    var headers: [8]Header = undefined;
    var conn: ClientConn = .init(.{ .recv_buffer = &buffer, .headers = &headers });
    conn.start(.GET);

    const bytes = "HTTP/1.1 200 OK\r\n\r\nhello";
    @memcpy(buffer[0..bytes.len], bytes);
    switch (try conn.received(bytes.len)) {
        .response => |response| try testing.expectEqual(.close, response.framing),
        else => return error.TestUnexpectedResult,
    }
    switch (try conn.next()) {
        .body => |body| try testing.expectEqualStrings("hello", body),
        else => return error.TestUnexpectedResult,
    }
    try testing.expectEqual(Event.done, try conn.eof());
}

test "interim response leaves the final response" {
    var buffer: [1024]u8 = undefined;
    var headers: [8]Header = undefined;
    var conn: ClientConn = .init(.{ .recv_buffer = &buffer, .headers = &headers });
    conn.start(.GET);

    const bytes = "HTTP/1.1 100 Continue\r\n\r\n" ++
        "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok";
    @memcpy(buffer[0..bytes.len], bytes);
    switch (try conn.received(bytes.len)) {
        .response => |response| try testing.expectEqual(.@"continue", response.head.status),
        else => return error.TestUnexpectedResult,
    }

    conn.start(.GET);
    switch (try conn.next()) {
        .response => |response| try testing.expectEqual(.ok, response.head.status),
        else => return error.TestUnexpectedResult,
    }
    switch (try conn.next()) {
        .body => |body| try testing.expectEqualStrings("ok", body),
        else => return error.TestUnexpectedResult,
    }
    try testing.expectEqual(Event.done, try conn.next());
}

test "leftover bytes belong to the next response" {
    var buffer: [1024]u8 = undefined;
    var headers: [8]Header = undefined;
    var conn: ClientConn = .init(.{ .recv_buffer = &buffer, .headers = &headers });
    conn.start(.GET);

    const bytes = "HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\na" ++
        "HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\nb";
    @memcpy(buffer[0..bytes.len], bytes);
    switch (try conn.received(bytes.len)) {
        .response => {},
        else => return error.TestUnexpectedResult,
    }
    switch (try conn.next()) {
        .body => |body| try testing.expectEqualStrings("a", body),
        else => return error.TestUnexpectedResult,
    }
    try testing.expectEqual(Event.done, try conn.next());

    conn.start(.GET);
    switch (try conn.next()) {
        .response => {},
        else => return error.TestUnexpectedResult,
    }
    switch (try conn.next()) {
        .body => |body| try testing.expectEqualStrings("b", body),
        else => return error.TestUnexpectedResult,
    }
    try testing.expectEqual(Event.done, try conn.next());
}

test "EOF before a response" {
    var buffer: [1024]u8 = undefined;
    var headers: [8]Header = undefined;
    var conn: ClientConn = .init(.{ .recv_buffer = &buffer, .headers = &headers });
    conn.start(.GET);
    try testing.expectEqual(Event.closed, try conn.eof());
}

test "body over the limit" {
    var buffer: [1024]u8 = undefined;
    var headers: [8]Header = undefined;
    var conn: ClientConn = .init(.{
        .recv_buffer = &buffer,
        .headers = &headers,
        .body_bytes = 2,
    });
    conn.start(.GET);
    const bytes = "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nabc";
    @memcpy(buffer[0..bytes.len], bytes);
    try testing.expectError(error.BodyTooLarge, conn.received(bytes.len));
}

test "a body read keeps the head it borrowed" {
    var buffer: [1024]u8 = undefined;
    var headers: [8]Header = undefined;
    var conn: ClientConn = .init(.{ .recv_buffer = &buffer, .headers = &headers });
    conn.start(.GET);

    const head = "HTTP/1.1 200 OK\r\nServer: h1\r\nContent-Length: 20\r\n\r\n";
    @memcpy(buffer[0..head.len], head);
    const response = switch (try conn.received(head.len)) {
        .response => |response| response,
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqual(Event.need_more, try conn.next());

    // The head is consumed, so the next read gets the front of the buffer
    // after the head, never over it: the caller still holds `response.head`.
    const body = "0123456789abcdefghij";
    const dst = conn.recvBuffer();
    @memcpy(dst[0..body.len], body);
    switch (try conn.received(body.len)) {
        .body => |slice| try testing.expectEqualStrings(body, slice),
        else => return error.TestUnexpectedResult,
    }
    try testing.expectEqualStrings("OK", response.head.reason);
    try testing.expectEqualStrings("h1", response.head.headers.items[0].value);
    try testing.expectEqual(Event.done, try conn.next());
}

test "chunked body reads keep the head" {
    var buffer: [1024]u8 = undefined;
    var headers: [8]Header = undefined;
    var conn: ClientConn = .init(.{ .recv_buffer = &buffer, .headers = &headers });
    conn.start(.GET);

    const head = "HTTP/1.1 200 OK\r\nServer: h1\r\nTransfer-Encoding: chunked\r\n\r\n";
    @memcpy(buffer[0..head.len], head);
    const response = switch (try conn.received(head.len)) {
        .response => |response| response,
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqual(Event.need_more, try conn.next());

    const rest = "14\r\n0123456789abcdefghij\r\n0\r\n\r\n";
    const dst = conn.recvBuffer();
    @memcpy(dst[0..rest.len], rest);
    switch (try conn.received(rest.len)) {
        .body => |slice| try testing.expectEqualStrings("0123456789abcdefghij", slice),
        else => return error.TestUnexpectedResult,
    }
    try testing.expectEqualStrings("OK", response.head.reason);
    try testing.expectEqualStrings("h1", response.head.headers.items[0].value);
    try testing.expectEqual(Event.done, try conn.next());
}

test "close-delimited body reads keep the head" {
    var buffer: [1024]u8 = undefined;
    var headers: [8]Header = undefined;
    var conn: ClientConn = .init(.{ .recv_buffer = &buffer, .headers = &headers });
    conn.start(.GET);

    const head = "HTTP/1.1 200 OK\r\nServer: h1\r\n\r\n";
    @memcpy(buffer[0..head.len], head);
    const response = switch (try conn.received(head.len)) {
        .response => |response| response,
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqual(Event.need_more, try conn.next());

    const body = "0123456789abcdefghij";
    const dst = conn.recvBuffer();
    @memcpy(dst[0..body.len], body);
    switch (try conn.received(body.len)) {
        .body => |slice| try testing.expectEqualStrings(body, slice),
        else => return error.TestUnexpectedResult,
    }
    try testing.expectEqual(Event.done, try conn.eof());
    try testing.expectEqualStrings("OK", response.head.reason);
    try testing.expectEqualStrings("h1", response.head.headers.items[0].value);
}

test "a final head after an interim response survives its body read" {
    var buffer: [1024]u8 = undefined;
    var headers: [8]Header = undefined;
    var conn: ClientConn = .init(.{ .recv_buffer = &buffer, .headers = &headers });
    conn.start(.GET);

    const interim = "HTTP/1.1 100 Continue\r\n\r\n";
    @memcpy(buffer[0..interim.len], interim);
    switch (try conn.received(interim.len)) {
        .response => |response| try testing.expectEqual(.@"continue", response.head.status),
        else => return error.TestUnexpectedResult,
    }
    conn.start(.GET);

    const head = "HTTP/1.1 200 OK\r\nServer: h1\r\nContent-Length: 20\r\n\r\n";
    const dst = conn.recvBuffer();
    @memcpy(dst[0..head.len], head);
    const response = switch (try conn.received(head.len)) {
        .response => |response| response,
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqual(Event.need_more, try conn.next());

    const body = "0123456789abcdefghij";
    const body_dst = conn.recvBuffer();
    @memcpy(body_dst[0..body.len], body);
    switch (try conn.received(body.len)) {
        .body => |slice| try testing.expectEqualStrings(body, slice),
        else => return error.TestUnexpectedResult,
    }
    try testing.expectEqualStrings("OK", response.head.reason);
    try testing.expectEqualStrings("h1", response.head.headers.items[0].value);
    try testing.expectEqual(Event.done, try conn.next());
}
