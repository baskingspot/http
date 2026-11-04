//! A sans-I/O HTTP/1 server connection state machine.
//!
//! The connection owns no memory and does no I/O. The caller supplies the
//! request buffer, the field storage, and the response head buffer, then drives
//! the machine from a socket loop:
//!
//!     var conn = h1.ServerConn.init(.{ ... });
//!     conn.start(now);                    // before the first read
//!     const dst = conn.recvBuffer();      // read into this
//!     switch (conn.received(n, now)) { ... }
//!     conn.respond(.{ .status = .ok }, body);
//!     const slices = conn.sendSlices();   // writev these
//!     switch (conn.sent(n, now)) { ... }
//!
//! After `.keep_alive`, call `advance` before the next read; it parses a
//! pipelined request already in the buffer. `.sent` starts the idle head
//! timer on `.keep_alive`. After `.read`, read the request body. Call `eof`
//! when the peer closes and `tick` when the poll deadline expires; `tick`
//! covers every phase.
//!
//! Policy responses are queued by the machine. The application never writes a
//! 400, 408, 413, 417, 431, 501, or 505 path itself.
//!
//! Request bodies are buffered. A body that does not fit is 413. Chunked
//! request bodies are not implemented yet and are 501.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const assert = std.debug.assert;
const ascii = std.ascii;
const mem = std.mem;

const Header = @import("../header.zig").Header;
const Headers = @import("../header.zig").Headers;
const Method = @import("../method.zig").Method;
const Status = @import("../status.zig").Status;
const token_list = @import("../token_list.zig");
const h1 = @import("root.zig");

const ServerConn = @This();

// ast-grep-ignore: public-struct-field-default -- options bag; the defaults are the policy
pub const Limits = struct {
    /// Largest buffered request body. The request buffer must also hold it.
    body_bytes: usize = 64 * 1024,
    /// Zero disables the deadline. Starts at accept and after a keep-alive
    /// response; it covers the idle wait and the head.
    head_timeout: Io.Duration = .fromSeconds(5),
    /// Zero disables the deadline.
    body_timeout: Io.Duration = .fromSeconds(10),
    write_timeout: Io.Duration = .fromSeconds(10),
    /// Zero disables the deadline. Starts with the first request byte.
    total_timeout: Io.Duration = .fromSeconds(30),
};

// ast-grep-ignore: public-struct-field-default -- options bag; the caller overrides one knob
pub const Config = struct {
    request_buffer: []u8,
    headers: []Header,
    response_buffer: []u8,
    limits: Limits = .{},
};

// ast-grep-ignore: public-struct-field-default -- options bag; the caller overrides one knob
pub const ResponseOptions = struct {
    status: Status = .ok,
    content_type: ?[]const u8 = null,
    /// Extra fields after the machine's. Do not duplicate Content-Length or
    /// Connection.
    headers: []const Header = &.{},
};

pub const Request = struct {
    /// Borrows the request buffer and the caller's header storage. Valid until
    /// the response completes.
    head: h1.RequestHead,
    /// A slice of the request buffer. Valid until the response completes.
    body: []const u8,
};

pub const Event = union(enum) {
    /// Read more bytes into `recvBuffer`, after draining `sendSlices`.
    need_more,
    /// A complete request. Respond, then drain `sendSlices`.
    request: Request,
    /// The machine queued this policy response. Send it, then close. `sent`
    /// reports whether the engine must drain input before the close.
    reject: Status,
    /// The peer closed with no partial request.
    closed,
};

pub const Slices = struct {
    head: []const u8,
    body: []const u8,
};

pub const Done = union(enum) {
    /// More response bytes remain.
    more,
    /// The interim response is complete; read the request body.
    read,
    /// The response is complete and the connection can parse the next request.
    keep_alive,
    /// The response is complete and the connection must close.
    close,
    /// The response is complete. The request body was not fully read; drain
    /// input before close so a reset does not discard the response.
    close_after_drain,
};

/// The action for an expired poll deadline.
pub const Tick = union(enum) {
    /// No deadline has expired.
    none,
    /// The machine queued this 408. Send it, then close.
    reject: Status,
    /// Close now. Part of a response is already on the wire.
    close,
};

pub const RespondError = h1.Writer.Error || error{
    InvalidState,
    InvalidStatus,
    ResponseHeadTooLarge,
};

const Phase = enum { head, body, app, response, closed };
const ResponseKind = enum { none, interim, final };

request_buffer: []u8,
headers: []Header,
response_buffer: []u8,
limits: Limits,

phase: Phase,
used: usize,
search: h1.SearchState,
version: h1.Version,
head: h1.RequestHead,
body_start: usize,
body_len: usize,
keep_alive: bool,
head_only: bool,
body_allowed: bool,
head_parsed: bool,
body_chunked: bool,
drain_close: bool,

response: []const u8,
response_head_len: usize,
response_head_sent: usize,
response_body_sent: usize,
response_kind: ResponseKind,

last_now: Io.Timestamp,
phase_start: ?Io.Timestamp,
phase_deadline: ?Io.Timestamp,
total_deadline: ?Io.Timestamp,

pub fn init(config: Config) ServerConn {
    assert(config.response_buffer.len >= 64);
    return .{
        .request_buffer = config.request_buffer,
        .headers = config.headers,
        .response_buffer = config.response_buffer,
        .limits = config.limits,

        .phase = .head,
        .used = 0,
        .search = .init,
        .version = .@"HTTP/1.1",
        .head = undefined,
        .body_start = 0,
        .body_len = 0,
        .keep_alive = true,
        .head_only = false,
        .body_allowed = true,
        .head_parsed = false,
        .body_chunked = false,
        .drain_close = false,

        .response = "",
        .response_head_len = 0,
        .response_head_sent = 0,
        .response_body_sent = 0,
        .response_kind = .none,

        .last_now = .zero,
        .phase_start = null,
        .phase_deadline = null,
        .total_deadline = null,
    };
}

/// Start the idle head deadline. Call once after accept, before the first read.
/// Without it a silent connection has no deadline. The total request timeout
/// starts with the first input byte.
pub fn start(self: *ServerConn, now: Io.Timestamp) void {
    assert(self.phase == .head);
    self.last_now = now;
    self.startPhase(now, self.limits.head_timeout);
}

/// Where the engine should read. Empty while a response or the application
/// owns the connection.
pub fn recvBuffer(self: *ServerConn) []u8 {
    return switch (self.phase) {
        .head, .body => self.request_buffer[self.used..],
        .app, .response, .closed => self.request_buffer[0..0],
    };
}

/// Account for `n` bytes read into `recvBuffer`.
pub fn received(self: *ServerConn, n: usize, now: Io.Timestamp) Event {
    assert(self.phase == .head or self.phase == .body);
    assert(n <= self.request_buffer.len - self.used);

    self.last_now = now;
    self.startInputDeadlines(now);
    if (self.timedOut(now)) return self.reject(.request_timeout, false);

    if (n == 0) return self.eof(now);

    self.used += n;
    return switch (self.phase) {
        .head => self.parseHead(now),
        .body => self.parseBody(),
        else => unreachable,
    };
}

/// Parse bytes already in the request buffer. Call after `.keep_alive` before
/// the next read, so a pipelined request is handled without a syscall.
pub fn advance(self: *ServerConn, now: Io.Timestamp) Event {
    assert(self.phase == .head or self.phase == .body);
    self.last_now = now;

    if (self.used == 0) {
        assert(self.phase == .head);
        self.startIdleDeadline(now);
        if (self.timedOut(now)) return self.reject(.request_timeout, false);
        return .need_more;
    }

    self.startInputDeadlines(now);
    if (self.timedOut(now)) return self.reject(.request_timeout, false);
    return switch (self.phase) {
        .head => self.parseHead(now),
        .body => self.parseBody(),
        else => unreachable,
    };
}

/// The peer closed. A clean close before any request bytes is `.closed`; a
/// partial head or body is the policy 400.
pub fn eof(self: *ServerConn, now: Io.Timestamp) Event {
    self.last_now = now;
    if (self.phase == .head and self.used == 0) {
        self.phase = .closed;
        self.clearDeadlines();
        return .closed;
    }
    return self.reject(.bad_request, false);
}

/// The poll deadline fired. Covers every phase. A head, body, or application
/// timeout queues a 408. A response timeout closes, because part of the
/// response may be on the wire.
pub fn tick(self: *ServerConn, now: Io.Timestamp) Tick {
    self.last_now = now;
    if (!self.timedOut(now)) return .none;

    return switch (self.phase) {
        .head, .body, .app => self.rejectTick(),
        .response => {
            self.phase = .closed;
            self.clearDeadlines();
            return .close;
        },
        .closed => .none,
    };
}

fn rejectTick(self: *ServerConn) Tick {
    return switch (self.reject(.request_timeout, false)) {
        .reject => |status| .{ .reject = status },
        .closed => .close,
        else => unreachable,
    };
}

/// Queue a final response. Only valid after a `.request` event. The body must
/// stay valid until the response completes. A HEAD request sends Content-Length
/// and the head only. A 204 or 304 response ignores the body and omits
/// Content-Length.
pub fn respond(
    self: *ServerConn,
    options: ResponseOptions,
    body: []const u8,
) RespondError!void {
    if (self.phase != .app) return error.InvalidState;
    if (options.status.class()) |class| {
        if (class == .informational) return error.InvalidStatus;
    }

    self.queueResponse(options, body, .final) catch |err| switch (err) {
        error.WriteFailed => return error.ResponseHeadTooLarge,
        else => return err,
    };
    self.phase = .response;
}

/// The next response bytes, in order. Zero-length head means the head is done.
pub fn sendSlices(self: *const ServerConn) Slices {
    if (self.phase != .response) return .{ .head = "", .body = "" };
    return .{
        .head = self.response_buffer[self.response_head_sent..self.response_head_len],
        .body = if (self.sendBody()) self.response[self.response_body_sent..] else "",
    };
}

/// Account for `n` response bytes written from `sendSlices`.
pub fn sent(self: *ServerConn, n: usize, now: Io.Timestamp) Done {
    assert(self.phase == .response);
    self.last_now = now;

    const head_remaining = self.response_head_len - self.response_head_sent;
    const body_remaining = if (self.sendBody()) self.response.len - self.response_body_sent else 0;
    assert(n <= head_remaining + body_remaining);
    self.phase_deadline = addDeadline(now, self.limits.write_timeout);

    if (n < head_remaining) {
        self.response_head_sent += n;
        return .more;
    }

    self.response_head_sent = self.response_head_len;
    if (!self.sendBody()) {
        self.response_body_sent = self.response.len;
    } else {
        self.response_body_sent += n - head_remaining;
        if (self.response_body_sent < self.response.len) return .more;
    }

    if (self.response_kind == .interim) {
        self.response_kind = .none;
        self.response_head_len = 0;
        self.response = "";
        self.response_head_sent = 0;
        self.response_body_sent = 0;
        self.phase = .body;
        self.startPhase(now, self.limits.body_timeout);
        return .read;
    }

    if (!self.keep_alive) {
        self.phase = .closed;
        self.clearDeadlines();
        const done: Done = if (self.drain_close) .close_after_drain else .close;
        self.drain_close = false;
        return done;
    }

    const consumed = self.body_start + self.body_len;
    const leftover = self.used - consumed;
    @memmove(self.request_buffer[0..leftover], self.request_buffer[consumed..self.used]);
    self.used = leftover;
    self.search = .init;
    self.phase = .head;
    self.phase_start = null;
    self.phase_deadline = null;
    self.total_deadline = null;
    self.body_start = 0;
    self.body_len = 0;
    self.head = undefined;
    self.head_parsed = false;
    self.body_chunked = false;
    self.drain_close = false;
    self.version = .@"HTTP/1.1";
    self.head_only = false;
    self.body_allowed = true;
    self.startIdleDeadline(now);
    return .keep_alive;
}

/// The earliest active deadline. Null when every timeout is disabled or the
/// connection is closed. Call `start` after accept so a silent connection has
/// a deadline.
pub fn deadline(self: *const ServerConn) ?Io.Timestamp {
    return earliest(self.phase_deadline, self.total_deadline);
}

fn parseHead(self: *ServerConn, now: Io.Timestamp) Event {
    const parsed = h1.parseRequest(
        self.request_buffer[0..self.used],
        &self.search,
        self.headers,
    ) catch |err| switch (err) {
        error.Incomplete => {
            if (self.used == self.request_buffer.len) {
                return self.reject(.request_header_fields_too_large, true);
            }
            return .need_more;
        },
        error.Invalid => return self.reject(.bad_request, true),
        error.UnsupportedVersion => return self.reject(.http_version_not_supported, true),
        error.TooManyHeaders => return self.reject(.request_header_fields_too_large, true),
    };

    self.version = parsed.head.version;
    self.head_only = if (parsed.head.method) |method| method == .HEAD else false;
    self.head = parsed.head;
    self.body_start = parsed.consumed;
    self.head_parsed = true;
    self.body_chunked = false;

    const framing = h1.framing.request(self.version, self.head.headers) catch {
        // The framing is unknown, so a body may still arrive. Signal a drain.
        self.body_chunked = true;
        return self.reject(.bad_request, true);
    };
    switch (framing) {
        .none => self.body_len = 0,
        .length => |length| {
            if (length > std.math.maxInt(usize)) {
                self.body_len = std.math.maxInt(usize);
                return self.reject(.payload_too_large, true);
            }
            self.body_len = @intCast(length);
            if (self.body_len > self.limits.body_bytes) {
                return self.reject(.payload_too_large, true);
            }
            if (self.body_len > self.request_buffer.len - self.body_start) {
                return self.reject(.payload_too_large, true);
            }
        },
        .chunked => {
            self.body_len = 0;
            self.body_chunked = true;
            return self.reject(.not_implemented, true);
        },
    }

    const host_value = h1.host(self.head.headers) catch return self.reject(.bad_request, true);
    if (self.version == .@"HTTP/1.1" and host_value == null) {
        return self.reject(.bad_request, true);
    }
    self.keep_alive = h1.persistent(self.version, self.head.headers);

    const expect_continue = expectsContinue(self.head.headers) catch
        return self.reject(.expectation_failed, true);

    if (self.used - self.body_start >= self.body_len) return self.completeRequest();

    if (expect_continue and self.version != .@"HTTP/1.0") {
        self.queueContinue() catch return self.reject(.internal_server_error, false);
        return .need_more;
    }

    self.phase = .body;
    self.startPhase(now, self.limits.body_timeout);
    return .need_more;
}

fn parseBody(self: *ServerConn) Event {
    if (self.used - self.body_start >= self.body_len) return self.completeRequest();
    if (self.used == self.request_buffer.len) return self.reject(.payload_too_large, true);
    return .need_more;
}

fn completeRequest(self: *ServerConn) Event {
    self.phase = .app;
    self.phase_start = null;
    self.phase_deadline = null;
    return .{ .request = .{
        .head = self.head,
        .body = self.request_buffer[self.body_start..][0..self.body_len],
    } };
}

fn reject(self: *ServerConn, status: Status, drain: bool) Event {
    self.keep_alive = false;
    self.drain_close = drain and self.unreadBody();
    self.total_deadline = null;
    self.queueResponse(.{ .status = status }, "", .final) catch {
        self.phase = .closed;
        self.clearDeadlines();
        return .closed;
    };
    self.phase = .response;
    return .{ .reject = status };
}

fn unreadBody(self: *const ServerConn) bool {
    if (!self.head_parsed) return self.used > 0;
    if (self.body_chunked) return true;
    return self.used - self.body_start < self.body_len;
}

fn queueResponse(
    self: *ServerConn,
    options: ResponseOptions,
    body: []const u8,
    kind: ResponseKind,
) h1.Writer.Error!void {
    self.body_allowed = statusAllowsBody(options.status);
    var io: Io.Writer = .fixed(self.response_buffer);
    var w: h1.Writer = .init(&io);

    try w.statusLine(self.version, options.status);
    if (options.content_type) |content_type| try w.field("Content-Type", content_type);
    if (self.body_allowed) try w.contentLength(@intCast(body.len));
    if (!self.keep_alive) {
        try w.field("Connection", "close");
    } else if (self.version == .@"HTTP/1.0") {
        try w.field("Connection", "keep-alive");
    }
    for (options.headers) |header| try w.field(header.name, header.value);
    try w.endFields();

    self.response_head_len = io.buffered().len;
    self.response = body;
    self.response_head_sent = 0;
    self.response_body_sent = 0;
    self.response_kind = kind;
    self.phase_deadline = addDeadline(self.last_now, self.limits.write_timeout);
}

fn queueContinue(self: *ServerConn) h1.Writer.Error!void {
    var io: Io.Writer = .fixed(self.response_buffer);
    var w: h1.Writer = .init(&io);
    try w.statusLine(self.version, .@"continue");
    try w.endFields();

    self.response_head_len = io.buffered().len;
    self.response = "";
    self.body_allowed = false;
    self.response_head_sent = 0;
    self.response_body_sent = 0;
    self.response_kind = .interim;
    self.phase = .response;
    self.phase_deadline = addDeadline(self.last_now, self.limits.write_timeout);
}

fn sendBody(self: *const ServerConn) bool {
    return !self.head_only and self.body_allowed;
}

fn statusAllowsBody(status: Status) bool {
    const class = status.class() orelse return true;
    return switch (class) {
        .informational => false,
        .success => status != .no_content,
        .redirect => status != .not_modified,
        else => true,
    };
}

fn clearDeadlines(self: *ServerConn) void {
    self.phase_start = null;
    self.phase_deadline = null;
    self.total_deadline = null;
}

fn startInputDeadlines(self: *ServerConn, now: Io.Timestamp) void {
    if (self.total_deadline == null) {
        self.total_deadline = addDeadline(now, self.limits.total_timeout);
    }
    if (self.phase_start == null) {
        self.startPhase(now, switch (self.phase) {
            .head => self.limits.head_timeout,
            .body => self.limits.body_timeout,
            else => unreachable,
        });
    }
}

fn startIdleDeadline(self: *ServerConn, now: Io.Timestamp) void {
    assert(self.phase == .head);
    if (self.phase_start == null) {
        self.startPhase(now, self.limits.head_timeout);
    }
}

fn startPhase(self: *ServerConn, now: Io.Timestamp, timeout: Io.Duration) void {
    self.phase_start = now;
    self.phase_deadline = addDeadline(now, timeout);
}

fn timedOut(self: *const ServerConn, now: Io.Timestamp) bool {
    const at = self.deadline() orelse return false;
    return now.durationTo(at).nanoseconds < 0;
}

fn addDeadline(now: Io.Timestamp, duration: Io.Duration) ?Io.Timestamp {
    if (duration.nanoseconds == 0) return null;
    return now.addDuration(duration);
}

fn earliest(a: ?Io.Timestamp, b: ?Io.Timestamp) ?Io.Timestamp {
    if (a == null) return b;
    if (b == null) return a;
    return if (a.?.nanoseconds <= b.?.nanoseconds) a else b;
}

fn expectsContinue(headers: Headers) error{UnsupportedExpect}!bool {
    var values = headers.values("Expect");
    var seen = false;
    while (values.next()) |value| {
        var tokens = token_list.iterator(value);
        while (tokens.next()) |token| {
            if (!ascii.eqlIgnoreCase(token, "100-continue")) return error.UnsupportedExpect;
            seen = true;
        }
    }
    return seen;
}

const TestClock = struct {
    now: Io.Timestamp = .zero,

    fn advance(self: *TestClock, ns: i96) void {
        self.now = .fromNanoseconds(self.now.nanoseconds + ns);
    }
};

const TestConn = struct {
    request_buffer: [1024]u8 = undefined,
    response_buffer: [512]u8 = undefined,
    headers: [16]Header = undefined,
    conn: ServerConn,
    clock: TestClock = .{},
    out_buffer: [2048]u8 = undefined,
    out_len: usize = 0,

    fn init(self: *TestConn, limits: Limits) void {
        self.* = .{ .conn = undefined };
        self.conn = .init(.{
            .request_buffer = &self.request_buffer,
            .headers = &self.headers,
            .response_buffer = &self.response_buffer,
            .limits = limits,
        });
    }

    fn feed(self: *TestConn, bytes: []const u8) !Event {
        const dst = self.conn.recvBuffer();
        try testing.expect(bytes.len <= dst.len);
        @memcpy(dst[0..bytes.len], bytes);
        return self.conn.received(bytes.len, self.clock.now);
    }

    fn advance(self: *TestConn) Event {
        return self.conn.advance(self.clock.now);
    }

    fn drain(self: *TestConn) !Done {
        while (true) {
            const slices = self.conn.sendSlices();
            if (slices.head.len == 0 and slices.body.len == 0) return .more;

            try testing.expect(
                self.out_len + slices.head.len + slices.body.len <= self.out_buffer.len,
            );
            @memcpy(self.out_buffer[self.out_len..][0..slices.head.len], slices.head);
            self.out_len += slices.head.len;
            @memcpy(self.out_buffer[self.out_len..][0..slices.body.len], slices.body);
            self.out_len += slices.body.len;

            const done = self.conn.sent(slices.head.len + slices.body.len, self.clock.now);
            switch (done) {
                .more => {},
                .read, .keep_alive, .close, .close_after_drain => return done,
            }
        }
    }

    fn out(self: *const TestConn) []const u8 {
        return self.out_buffer[0..self.out_len];
    }
};

fn expectRequest(event: Event) !Request {
    return switch (event) {
        .request => |request| request,
        else => error.TestUnexpectedEvent,
    };
}

fn expectReject(event: Event, status: Status) !void {
    switch (event) {
        .reject => |got| try testing.expectEqual(status, got),
        else => return error.TestUnexpectedEvent,
    }
}

test "a request and a response" {
    var t: TestConn = undefined;
    t.init(.{});

    const request = try expectRequest(try t.feed(
        "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n",
    ));
    try testing.expectEqualStrings("/", request.head.target);
    try testing.expectEqualStrings("GET", request.head.method_token);
    try testing.expectEqualStrings("", request.body);

    try t.conn.respond(.{ .status = .ok, .content_type = "text/plain" }, "hello");
    const done = try t.drain();
    try testing.expectEqual(.keep_alive, std.meta.activeTag(done));
    try testing.expect(mem.startsWith(u8, t.out(), "HTTP/1.1 200 OK\r\n"));
    try testing.expect(mem.endsWith(u8, t.out(), "\r\n\r\nhello"));
}

test "a body that arrives in pieces" {
    var t: TestConn = undefined;
    t.init(.{});

    try testing.expectEqual(.need_more, std.meta.activeTag(try t.feed(
        "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhe",
    )));

    const request = try expectRequest(try t.feed("llo"));
    try testing.expectEqualStrings("hello", request.body);
}

test "pipelined requests keep the leftover" {
    var t: TestConn = undefined;
    t.init(.{});

    const first = try expectRequest(try t.feed(
        "GET /a HTTP/1.1\r\nHost: x\r\n\r\nGET /b HTTP/1.1\r\nHost: x\r\n\r\n",
    ));
    try testing.expectEqualStrings("/a", first.head.target);

    try t.conn.respond(.{ .status = .ok }, "one");
    try testing.expectEqual(.keep_alive, std.meta.activeTag(try t.drain()));

    const second = try expectRequest(t.advance());
    try testing.expectEqualStrings("/b", second.head.target);
    try t.conn.respond(.{ .status = .ok }, "two");
    try testing.expectEqual(.keep_alive, std.meta.activeTag(try t.drain()));

    try testing.expect(mem.find(u8, t.out(), "one") != null);
    try testing.expect(mem.find(u8, t.out(), "two") != null);
}

test "Expect: 100-continue queues the interim response" {
    var t: TestConn = undefined;
    t.init(.{});

    try testing.expectEqual(.need_more, std.meta.activeTag(try t.feed(
        "POST / HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\nContent-Length: 5\r\n\r\n",
    )));

    try testing.expectEqual(.read, std.meta.activeTag(try t.drain()));
    try testing.expect(mem.startsWith(u8, t.out(), "HTTP/1.1 100 Continue\r\n\r\n"));

    const request = try expectRequest(try t.feed("hello"));
    try testing.expectEqualStrings("hello", request.body);
}

test "policy responses are queued without the application" {
    var t: TestConn = undefined;
    t.init(.{ .body_bytes = 4 });

    try expectReject(try t.feed(
        "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\n",
    ), .payload_too_large);
    try testing.expectEqual(.close_after_drain, std.meta.activeTag(try t.drain()));
    try testing.expect(mem.startsWith(u8, t.out(), "HTTP/1.1 413 "));

    t = undefined;
    t.init(.{});
    try expectReject(try t.feed(
        "POST / HTTP/1.1\r\nHost: x\r\nExpect: nope\r\nContent-Length: 1\r\n\r\n",
    ), .expectation_failed);

    t = undefined;
    t.init(.{});
    try expectReject(try t.feed(
        "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n",
    ), .not_implemented);

    t = undefined;
    t.init(.{});
    try expectReject(try t.feed("GET / HTTP/1.1\r\n\r\n"), .bad_request);
}

test "a full request buffer is 431" {
    var t: TestConn = undefined;
    t.init(.{});

    var full: [1024]u8 = undefined;
    @memset(&full, 'A');
    try expectReject(try t.feed(&full), .request_header_fields_too_large);
    try testing.expectEqual(.close_after_drain, std.meta.activeTag(try t.drain()));
    try testing.expect(mem.startsWith(u8, t.out(), "HTTP/1.1 431 "));
}

test "HEAD sends the length but not the body" {
    var t: TestConn = undefined;
    t.init(.{});

    _ = try expectRequest(try t.feed("HEAD / HTTP/1.1\r\nHost: x\r\n\r\n"));
    try t.conn.respond(.{ .status = .ok, .content_type = "text/plain" }, "hello");

    try testing.expectEqual(.keep_alive, std.meta.activeTag(try t.drain()));
    try testing.expect(mem.find(u8, t.out(), "Content-Length: 5") != null);
    try testing.expect(mem.find(u8, t.out(), "hello") == null);
}

test "partial sends advance the head and body" {
    var t: TestConn = undefined;
    t.init(.{});

    _ = try expectRequest(try t.feed("GET / HTTP/1.1\r\nHost: x\r\n\r\n"));
    try t.conn.respond(.{ .status = .ok, .content_type = "text/plain" }, "hello");

    const first = t.conn.sendSlices();
    try testing.expect(first.head.len > 1);
    try testing.expectEqual(.more, std.meta.activeTag(t.conn.sent(1, t.clock.now)));

    const rest = t.conn.sendSlices();
    const total = rest.head.len + rest.body.len;
    try testing.expectEqual(.keep_alive, std.meta.activeTag(t.conn.sent(total, t.clock.now)));
}

test "a timeout is a 408 policy response" {
    var t: TestConn = undefined;
    t.init(.{ .head_timeout = .fromSeconds(1) });

    try testing.expectEqual(.need_more, std.meta.activeTag(try t.feed("GET /")));
    t.clock.advance(2 * std.time.ns_per_s);

    switch (t.conn.tick(t.clock.now)) {
        .reject => |status| try testing.expectEqual(Status.request_timeout, status),
        else => return error.TestExpectedTimeout,
    }
}

test "eof closes a clean connection and rejects a partial head" {
    var t: TestConn = undefined;
    t.init(.{});
    try testing.expectEqual(.closed, std.meta.activeTag(t.conn.eof(t.clock.now)));

    t = undefined;
    t.init(.{});
    _ = try t.feed("GET /");
    try expectReject(t.conn.eof(t.clock.now), .bad_request);
}

test "Connection: close closes after the response" {
    var t: TestConn = undefined;
    t.init(.{});

    _ = try expectRequest(try t.feed(
        "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
    ));
    try t.conn.respond(.{ .status = .ok }, "");
    try testing.expectEqual(.close, std.meta.activeTag(try t.drain()));
    try testing.expect(mem.find(u8, t.out(), "Connection: close") != null);
}

test "HTTP/1.0 keep-alive is explicit in the response" {
    var t: TestConn = undefined;
    t.init(.{});

    _ = try expectRequest(try t.feed(
        "GET / HTTP/1.0\r\nHost: x\r\nConnection: keep-alive\r\n\r\n",
    ));
    try t.conn.respond(.{ .status = .ok }, "");
    try testing.expectEqual(.keep_alive, std.meta.activeTag(try t.drain()));
    try testing.expect(mem.find(u8, t.out(), "Connection: keep-alive") != null);
}

test "a 204 omits Content-Length and the body" {
    var t: TestConn = undefined;
    t.init(.{});

    _ = try expectRequest(try t.feed("GET / HTTP/1.1\r\nHost: x\r\n\r\n"));
    try t.conn.respond(.{ .status = .no_content }, "nope");

    try testing.expectEqual(.keep_alive, std.meta.activeTag(try t.drain()));
    try testing.expect(mem.find(u8, t.out(), "Content-Length") == null);
    try testing.expect(mem.find(u8, t.out(), "nope") == null);
    try testing.expect(mem.startsWith(u8, t.out(), "HTTP/1.1 204 No Content\r\n"));
}

test "start gives a silent connection a deadline" {
    var t: TestConn = undefined;
    t.init(.{});
    try testing.expect(t.conn.deadline() == null);

    t.conn.start(t.clock.now);
    try testing.expect(t.conn.deadline() != null);

    t.clock.advance(6 * std.time.ns_per_s);
    switch (t.conn.tick(t.clock.now)) {
        .reject => |status| try testing.expectEqual(Status.request_timeout, status),
        else => return error.TestExpectedTimeout,
    }
}

test "the total timeout starts with the first request byte" {
    var t: TestConn = undefined;
    t.init(.{ .head_timeout = .fromSeconds(60), .total_timeout = .fromSeconds(30) });
    t.conn.start(t.clock.now);

    t.clock.advance(29 * std.time.ns_per_s);
    try testing.expectEqual(.need_more, std.meta.activeTag(try t.feed("GET /")));

    t.clock.advance(2 * std.time.ns_per_s);
    try testing.expectEqual(.none, std.meta.activeTag(t.conn.tick(t.clock.now)));
}

test "keep-alive leaves an idle deadline" {
    var t: TestConn = undefined;
    t.init(.{});

    _ = try expectRequest(try t.feed("GET / HTTP/1.1\r\nHost: x\r\n\r\n"));
    try t.conn.respond(.{ .status = .ok }, "");
    try testing.expectEqual(.keep_alive, std.meta.activeTag(try t.drain()));
    try testing.expect(t.conn.deadline() != null);
}

test "HTTP/1.0 does not receive 100 Continue" {
    var t: TestConn = undefined;
    t.init(.{});

    try testing.expectEqual(.need_more, std.meta.activeTag(try t.feed(
        "POST / HTTP/1.0\r\nHost: x\r\nExpect: 100-continue\r\nContent-Length: 5\r\n\r\n",
    )));
    try testing.expectEqual(.more, std.meta.activeTag(try t.drain()));
    try testing.expectEqual(0, t.out().len);

    const request = try expectRequest(try t.feed("hello"));
    try testing.expectEqualStrings("hello", request.body);
}

test "a response timeout closes the connection" {
    var t: TestConn = undefined;
    t.init(.{ .total_timeout = .fromSeconds(1), .write_timeout = .fromSeconds(30) });

    _ = try expectRequest(try t.feed("GET / HTTP/1.1\r\nHost: x\r\n\r\n"));
    try t.conn.respond(.{ .status = .ok }, "");
    t.clock.advance(2 * std.time.ns_per_s);
    try testing.expectEqual(.close, std.meta.activeTag(t.conn.tick(t.clock.now)));
}

test "a final 1xx response is rejected" {
    var t: TestConn = undefined;
    t.init(.{});

    _ = try expectRequest(try t.feed("GET / HTTP/1.1\r\nHost: x\r\n\r\n"));
    try testing.expectError(
        error.InvalidStatus,
        t.conn.respond(.{ .status = .@"continue" }, ""),
    );
    try testing.expectError(
        error.InvalidStatus,
        t.conn.respond(.{ .status = .switching_protocols }, ""),
    );
}

test "a reject with no unread body closes without draining" {
    var t: TestConn = undefined;
    t.init(.{});

    try expectReject(try t.feed("GET / HTTP/1.1\r\n\r\n"), .bad_request);
    try testing.expectEqual(.close, std.meta.activeTag(try t.drain()));
}

test "respond outside a request is an error" {
    var t: TestConn = undefined;
    t.init(.{});
    try testing.expectError(error.InvalidState, t.conn.respond(.{}, ""));
}
