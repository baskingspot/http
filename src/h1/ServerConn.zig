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
//! pipelined request already in the buffer. `.sent` starts the idle timer on
//! `.keep_alive`; the first request byte starts the head and total timers.
//! After `.read`, read the request body. When `.sent` returns
//! `.close_after_drain`, `recvBuffer` is empty: read into your own scratch
//! buffer and discard the bytes. The machine does not route drained bytes.
//! Close on EOF, or when `tick` returns `.close` at the drain deadline. A zero
//! `drain_timeout` skips the drain and returns `.close` instead.
//!
//! Call `eof` when the peer closes during a request and `tick` when the poll
//! deadline expires; `tick` covers every phase.
//!
//! Policy responses are queued by the machine. A handler can review the status
//! and body through `Handler.VTable.policy_response` before they are written.
//! The parser and engine still own the rejection and drain decision.
//!
//! Request bodies default to the request buffer. A `.request_head` event lets
//! the application respond from the head alone or call `acceptBody` with its
//! own storage. Body bytes already received are copied there; later reads land
//! there directly. If the final short read is below `min_read_bytes`, the
//! machine uses request-buffer scratch instead. A body that does not fit the
//! chosen storage is 413.
//! `switchProtocols` sends a 101 and ends HTTP for this connection. Chunked
//! request bodies are not implemented yet and are 501.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const assert = std.debug.assert;
const ascii = std.ascii;
const mem = std.mem;

const Header = @import("../header.zig").Header;
const content_length = @import("../content_length.zig");
const Headers = @import("../header.zig").Headers;
const Method = @import("../method.zig").Method;
const Status = @import("../status.zig").Status;
const token_list = @import("../token_list.zig");
const h1 = @import("root.zig");
pub const RejectReason = @import("../engine/common.zig").RejectReason;
const PolicyResponse = @import("../engine/common.zig").PolicyResponse;

const ServerConn = @This();

// ast-grep-ignore: public-struct-field-default -- options bag; the defaults are the policy
pub const Limits = struct {
    /// Largest request body an application may accept.
    body_bytes: usize = 64 * 1024,
    /// Minimum usable space in a read destination. Reject a head without
    /// enough room. Reject a default-buffered body without enough room. For
    /// the final short read into application-owned body storage, use request
    /// buffer scratch and copy only the body bytes across.
    min_read_bytes: usize = 0,
    /// Zero disables the deadline. Starts at accept and after a keep-alive
    /// response, while the connection waits for the next request.
    idle_timeout: Io.Duration = .fromSeconds(5),
    /// Zero disables the deadline. Starts with the first request byte.
    head_timeout: Io.Duration = .fromSeconds(5),
    /// Zero disables the deadline.
    body_timeout: Io.Duration = .fromSeconds(10),
    write_timeout: Io.Duration = .fromSeconds(10),
    /// Zero disables the deadline. Starts with the first request byte.
    total_timeout: Io.Duration = .fromSeconds(30),
    /// Bounds a lingering close after an unread request body. The engine
    /// drains input until the deadline. Zero skips the drain and returns
    /// `.close` instead.
    drain_timeout: Io.Duration = .fromSeconds(1),
};

// ast-grep-ignore: public-struct-field-default -- options bag; the caller overrides one knob
pub const Config = struct {
    request_buffer: []u8,
    headers: []Header,
    response_buffer: []u8,
    limits: Limits = .{},
    /// Coalesce the head and body prefix when they fit. The buffer supplies
    /// the copy room and every send slice respects this cap. Zero preserves
    /// the separate head/body slices.
    write_chunk_bytes: usize = 0,
};

// ast-grep-ignore: public-struct-field-default -- options bag; the caller overrides one knob
/// Extra fields after the machine's. Do not duplicate Content-Length or
/// Connection.
pub const ResponseOptions = @import("../engine/common.zig").ResponseOptions;

pub const Rejection = struct {
    status: Status,
    reason: RejectReason,
};

pub const Head = struct {
    head: h1.RequestHead,
    /// The complete Content-Length body size, before choosing a sink.
    body_bytes: usize,
};

pub const Request = struct {
    /// Borrows the request buffer and the caller's header storage. Valid until
    /// the response completes. A `request_head` head must survive the call to
    /// `acceptBody` or `bufferBody`; then its storage must survive this request
    /// event. If the caller responds from `request_head` without accepting a
    /// body, it may instead copy what it needs and reuse the header storage
    /// after the response. No field slice survives that reuse.
    head: h1.RequestHead,
    /// A slice of the chosen body storage. Valid until the response completes.
    body: []const u8,
};

pub const Event = union(enum) {
    /// Read more bytes into `recvBuffer`, after draining `sendSlices`.
    need_more,
    /// The request head is complete but the body is not. Respond immediately
    /// to refuse or switch protocols, or call `acceptBody` or `bufferBody`.
    request_head: Head,
    /// A complete request. Respond, then drain `sendSlices`.
    request: Request,
    /// The machine queued this policy response. Send it, then close. `sent`
    /// reports whether the engine must drain input before the close.
    reject: Rejection,
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
    /// A 101 response is complete. The stream belongs to the next protocol;
    /// `remainingInput` returns bytes read past the request, and HTTP
    /// deadlines no longer apply.
    switched,
    /// The response is complete. The request body was not fully read; drain
    /// the raw socket into scratch storage until `deadline` expires or the
    /// peer closes, so a reset does not discard the response. `recvBuffer` is
    /// empty in this phase. `Limits.drain_timeout` bounds the drain; zero
    /// skips it and returns `.close`.
    close_after_drain,
};

/// The action for an expired poll deadline.
pub const Tick = union(enum) {
    /// No deadline has expired.
    none,
    /// The machine queued this 408. Send it, then close.
    reject: Rejection,
    /// Close now. Part of a response is on the wire, or a drain deadline
    /// expired.
    close,
};

pub const RespondError = h1.Writer.Error || error{
    InvalidState,
    InvalidStatus,
    ResponseHeadTooLarge,
};

const Phase = enum { head, body, app, response, drain, switched, closed };
const ResponseKind = enum { none, interim, final };

/// Values in storage, not the public options shape.
const StoredLimits = struct {
    body_bytes: usize,
    min_read_bytes: usize,
    idle_timeout: i64,
    head_timeout: i64,
    body_timeout: i64,
    write_timeout: i64,
    total_timeout: i64,
    drain_timeout: i64,
};

fn storedDuration(duration: Io.Duration) i64 {
    return @intCast(@min(duration.nanoseconds, std.math.maxInt(i64)));
}

fn storedLimits(limits: Limits) StoredLimits {
    return .{
        .body_bytes = limits.body_bytes,
        .min_read_bytes = limits.min_read_bytes,
        .idle_timeout = storedDuration(limits.idle_timeout),
        .head_timeout = storedDuration(limits.head_timeout),
        .body_timeout = storedDuration(limits.body_timeout),
        .write_timeout = storedDuration(limits.write_timeout),
        .total_timeout = storedDuration(limits.total_timeout),
        .drain_timeout = storedDuration(limits.drain_timeout),
    };
}

request_buffer: []u8,
headers: []Header,
response_buffer: []u8,
limits: StoredLimits,
write_chunk_bytes: usize,

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
idle: bool,

/// Target selected by `acceptBody` or `bufferBody`. Its length is the
/// complete request body, not merely the currently available bytes.
body_target: []u8,
body_received: usize,
/// First byte in the request buffer that does not belong to this request.
/// With an external body target this can precede all later body reads.
leftover_start: usize,
external_body: bool,
expect_continue: bool,
switch_protocols: bool,

response: []const u8,
response_head_len: usize,
response_head_sent: usize,
response_body_sent: usize,
response_kind: ResponseKind,

// Keep the storage at i64 nanoseconds. The public calls still take
// Io.Timestamp; an embedding pool must not inherit 16-byte alignment.
last_now: i64,
phase_deadline: ?i64,
total_deadline: ?i64,

pub fn init(config: Config) ServerConn {
    assert(config.response_buffer.len >= 64);
    return .{
        .request_buffer = config.request_buffer,
        .headers = config.headers,
        .response_buffer = config.response_buffer,
        .limits = storedLimits(config.limits),
        .write_chunk_bytes = config.write_chunk_bytes,

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
        .idle = true,

        .body_target = &.{},
        .body_received = 0,
        .leftover_start = 0,
        .external_body = false,
        .expect_continue = false,
        .switch_protocols = false,

        .response = "",
        .response_head_len = 0,
        .response_head_sent = 0,
        .response_body_sent = 0,
        .response_kind = .none,

        .last_now = 0,
        .phase_deadline = null,
        .total_deadline = null,
    };
}

/// Start the idle deadline. Call once after accept, before the first read.
/// Without it a silent connection has no deadline. The first input byte starts
/// the head and total request timeouts.
pub fn start(self: *ServerConn, now: Io.Timestamp) void {
    assert(self.phase == .head);
    self.idle = true;
    self.last_now = @intCast(now.nanoseconds);
    self.startIdleDeadline(now);
}

/// Where the engine should read. Empty while a response, the application, or
/// a drain owns the connection.
pub fn recvBuffer(self: *ServerConn) []u8 {
    if (self.phase == .body and self.external_body) {
        const remaining = self.body_target.len - self.body_received;
        if (self.scratchBodyRead(remaining)) {
            return self.request_buffer[self.used..];
        }
        return self.body_target[self.body_received..];
    }
    return switch (self.phase) {
        .head, .body => self.request_buffer[self.used..],
        .app, .response, .drain, .switched, .closed => self.request_buffer[0..0],
    };
}

/// Account for a non-empty read into `recvBuffer`. A zero-byte read is not
/// data: call `eof` when the transport reports a clean close. This keeps an
/// empty transport completion from becoming an accidental 400.
pub fn received(self: *ServerConn, n: usize, now: Io.Timestamp) Event {
    assert(self.phase == .head or self.phase == .body);
    assert(n > 0);

    self.last_now = @intCast(now.nanoseconds);
    if (self.timedOut(now)) return self.reject(.request_timeout, false, .request_timeout);

    if (self.phase == .body and self.external_body) {
        const remaining = self.body_target.len - self.body_received;
        if (self.scratchBodyRead(remaining)) {
            // The short final body read uses request-buffer scratch so the
            // transport still has its minimum room. Copy only body bytes; the
            // rest of a pipelined read stays at `leftover_start`.
            const scratch_start = self.used;
            assert(n <= self.request_buffer.len - scratch_start);
            const copied = @min(n, remaining);
            if (copied != 0) {
                @memcpy(
                    self.body_target[self.body_received..][0..copied],
                    self.request_buffer[scratch_start..][0..copied],
                );
            }
            self.body_received += copied;
            self.used += n;
            self.leftover_start = scratch_start + copied;
            self.startInputDeadlines(now);
            return self.parseBody();
        }
        assert(n <= remaining);
        self.body_received += n;
        self.startInputDeadlines(now);
        return self.parseBody();
    }
    assert(n <= self.request_buffer.len - self.used);
    self.used += n;
    if (self.phase == .body) self.body_received += n;
    self.startInputDeadlines(now);
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
    self.last_now = @intCast(now.nanoseconds);

    if (self.used == 0) {
        assert(self.phase == .head);
        self.startIdleDeadline(now);
        if (self.timedOut(now)) return self.reject(.request_timeout, false, .request_timeout);
        return .need_more;
    }

    if (self.timedOut(now)) return self.reject(.request_timeout, false, .request_timeout);
    self.startInputDeadlines(now);
    return switch (self.phase) {
        .head => self.parseHead(now),
        .body => self.parseBody(),
        else => unreachable,
    };
}

/// The peer closed. This is the only zero-byte input path. A clean close
/// before any request bytes is `.closed`; a partial head or body is the
/// policy 400.
pub fn eof(self: *ServerConn, now: Io.Timestamp) Event {
    self.last_now = @intCast(now.nanoseconds);
    if (self.phase == .head and self.idle and onlyBlankLines(self.request_buffer[0..self.used])) {
        self.phase = .closed;
        self.clearDeadlines();
        return .closed;
    }
    return self.reject(.bad_request, false, .malformed_head);
}

/// The poll deadline fired. Covers every phase. A head, body, or application
/// timeout queues a 408. A response or drain timeout closes.
pub fn tick(self: *ServerConn, now: Io.Timestamp) Tick {
    self.last_now = @intCast(now.nanoseconds);
    if (!self.timedOut(now)) return .none;

    return switch (self.phase) {
        .head, .body, .app => self.rejectTick(),
        .response, .drain => {
            self.phase = .closed;
            self.clearDeadlines();
            return .close;
        },
        .switched, .closed => .none,
    };
}

fn rejectTick(self: *ServerConn) Tick {
    return switch (self.reject(.request_timeout, false, .request_timeout)) {
        .reject => |status| .{ .reject = status },
        .closed => .close,
        else => unreachable,
    };
}

/// Queue a final response after `.request` or `.request_head`. The body must
/// stay valid until the response completes. An early response leaves request
/// bytes unread and drains them before closing instead of treating them as
/// another request. A HEAD request sends Content-Length and the head only.
/// A 204 or 304 response ignores the body and omits Content-Length.
pub fn respond(
    self: *ServerConn,
    options: ResponseOptions,
    body: []const u8,
) RespondError!void {
    return self.respondInner(options, body, false);
}

/// Queue a 101 response after a request head, then hand the stream to the
/// application. After `sent` returns `.switched`, HTTP is finished. Bytes
/// already read past the head remain available through `remainingInput`.
/// The caller owns Connection. Supply `Connection: Upgrade` when needed; the
/// machine emits no Connection field for a switch, even when the request says
/// close.
pub fn switchProtocols(self: *ServerConn, options: ResponseOptions) RespondError!void {
    if (self.phase != .app) return error.InvalidState;
    var switched = options;
    switched.status = .switching_protocols;
    return self.respondInner(switched, "", true);
}

fn respondInner(
    self: *ServerConn,
    options: ResponseOptions,
    body: []const u8,
    switching: bool,
) RespondError!void {
    if (self.phase != .app) return error.InvalidState;
    if (options.status.class()) |class| {
        if (class == .informational and !switching) return error.InvalidStatus;
    }
    if ((options.close or self.unreadBody()) and !switching) {
        self.keep_alive = false;
        self.drain_close = self.unreadBody();
    }
    self.switch_protocols = switching;

    self.queueResponse(options, body, .final) catch |err| switch (err) {
        error.WriteFailed => return error.ResponseHeadTooLarge,
        else => return err,
    };
    self.phase = .response;
}

/// Replace a queued machine rejection with an application response. The
/// response still owns unread input and closes after sending.
pub fn reviewRejection(self: *ServerConn, replacement: PolicyResponse) RespondError!void {
    if (self.phase != .response or self.response_kind != .final) {
        return error.InvalidState;
    }
    if (replacement.options.status.class() == .informational) return error.InvalidStatus;
    self.keep_alive = false;
    self.queueResponse(replacement.options, replacement.body, .final) catch |err| switch (err) {
        error.WriteFailed => return error.ResponseHeadTooLarge,
        else => return err,
    };
}

/// The next response bytes, in order. Zero-length head means the head is done.
pub fn sendSlices(self: *const ServerConn) Slices {
    if (self.phase != .response) return .{ .head = "", .body = "" };
    var head = self.response_buffer[self.response_head_sent..self.response_head_len];
    var body = if (self.sendBody()) self.response[self.response_body_sent..] else "";
    if (self.write_chunk_bytes != 0) {
        head = head[0..@min(head.len, self.write_chunk_bytes)];
    }
    if (self.write_chunk_bytes != 0 and head.len < self.write_chunk_bytes) {
        body = body[0..@min(body.len, self.write_chunk_bytes - head.len)];
    } else if (self.write_chunk_bytes != 0) {
        body = "";
    }
    return .{ .head = head, .body = body };
}

/// Account for `n` response bytes written from `sendSlices`.
pub fn sent(self: *ServerConn, n: usize, now: Io.Timestamp) Done {
    assert(self.phase == .response);
    self.last_now = @intCast(now.nanoseconds);

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

    if (self.switch_protocols) {
        self.switch_protocols = false;
        self.phase = .switched;
        self.clearDeadlines();
        return .switched;
    }

    if (!self.keep_alive) {
        const drain = self.drain_close;
        self.drain_close = false;
        if (drain and self.limits.drain_timeout != 0) {
            self.phase = .drain;
            self.phase_deadline = addDeadline(now, self.limits.drain_timeout);
            self.total_deadline = null;
            return .close_after_drain;
        }
        self.phase = .closed;
        self.clearDeadlines();
        return .close;
    }

    const consumed = self.leftover_start;
    assert(consumed <= self.used);
    const leftover = self.used - consumed;
    @memmove(self.request_buffer[0..leftover], self.request_buffer[consumed..self.used]);
    self.used = leftover;
    self.search = .init;
    self.phase = .head;
    self.phase_deadline = null;
    self.total_deadline = null;
    self.body_start = 0;
    self.body_len = 0;
    self.head = undefined;
    self.head_parsed = false;
    self.body_chunked = false;
    self.body_target = &.{};
    self.body_received = 0;
    self.leftover_start = 0;
    self.external_body = false;
    self.expect_continue = false;
    self.switch_protocols = false;
    self.drain_close = false;
    self.version = .@"HTTP/1.1";
    self.head_only = false;
    self.body_allowed = true;
    self.idle = true;
    self.startIdleDeadline(now);
    return .keep_alive;
}

/// Bytes already read past the request that produced the 101. The stream
/// stays open; these bytes are valid while `remainingInput` is called.
pub fn remainingInput(self: *ServerConn) []const u8 {
    assert(self.phase == .switched);
    return self.request_buffer[self.leftover_start..self.used];
}

/// Accept this request body into memory chosen from the request head. Bytes
/// already received are copied once; subsequent reads go there directly.
/// When it is too small, return a 413 rather than waiting on the default buffer.
pub fn acceptBody(self: *ServerConn, storage: []u8) Event {
    assert(self.phase == .app);
    assert(self.body_received < self.body_len);
    self.idle = false;
    if (self.body_len > storage.len) return self.reject(.payload_too_large, true, .body_too_large);
    return self.setBodyStorage(storage[0..self.body_len], true);
}

/// Keep the current default behavior: buffer the body in the request buffer.
pub fn bufferBody(self: *ServerConn) Event {
    if (self.phase != .app) return .need_more;
    const end = self.body_start + self.body_len;
    if (end > self.request_buffer.len) {
        return self.reject(.payload_too_large, true, .body_too_large);
    }
    return self.setBodyStorage(self.request_buffer[self.body_start..end], false);
}

fn setBodyStorage(self: *ServerConn, storage: []u8, external: bool) Event {
    assert(self.body_received <= self.body_len);
    assert(self.body_len == storage.len);
    if (external) {
        const already = self.used - self.body_start;
        assert(self.body_received <= already);
        if (self.body_received != 0) {
            @memcpy(
                storage[0..self.body_received],
                self.request_buffer[self.body_start..][0..self.body_received],
            );
        }
    }
    if (external) {
        self.leftover_start = self.body_start + self.body_received;
    } else {
        self.leftover_start = self.body_start + self.body_len;
    }
    self.body_target = storage;
    self.external_body = external;
    self.phase = .body;
    self.startPhase(.fromNanoseconds(self.last_now), self.limits.body_timeout);
    if (self.body_received == self.body_len) return self.completeRequest();
    if (self.expect_continue and self.version != .@"HTTP/1.0") {
        self.queueContinue() catch
            return self.reject(.internal_server_error, false, .internal_error);
        self.expect_continue = false;
        return .need_more;
    }
    return self.parseBody();
}

/// The earliest active deadline. Null when every timeout is disabled or the
/// connection is closed. Call `start` after accept so a silent connection has
/// a deadline.
pub fn deadline(self: *const ServerConn) ?Io.Timestamp {
    const at = earliest(self.phase_deadline, self.total_deadline) orelse return null;
    return .fromNanoseconds(at);
}

fn parseHead(self: *ServerConn, _: Io.Timestamp) Event {
    const parsed = h1.parseRequest(
        self.request_buffer[0..self.used],
        &self.search,
        self.headers,
    ) catch |err| switch (err) {
        error.Incomplete => {
            if (self.readTooSmall(self.request_buffer.len - self.used)) {
                return self.reject(.request_header_fields_too_large, true, .head_too_large);
            }
            return .need_more;
        },
        error.Invalid => return self.reject(.bad_request, true, .malformed_head),
        error.UnsupportedVersion => return self.reject(
            .http_version_not_supported,
            true,
            .unsupported_version,
        ),
        error.TooManyHeaders => return self.reject(
            .request_header_fields_too_large,
            true,
            .too_many_fields,
        ),
    };

    self.version = parsed.head.version;
    self.head_only = if (parsed.head.method) |method| method == .HEAD else false;
    self.head = parsed.head;
    self.body_start = parsed.consumed;
    self.leftover_start = parsed.consumed;
    self.head_parsed = true;
    self.body_chunked = false;
    self.external_body = false;

    const framing = h1.framing.request(self.version, self.head.headers) catch |err| {
        // The framing is unknown, so a body may still arrive. Signal a drain.
        self.body_chunked = true;
        return self.framingReject(err);
    };
    switch (framing) {
        .none => self.body_len = 0,
        .length => |length| {
            if (length > std.math.maxInt(usize)) {
                self.body_len = std.math.maxInt(usize);
                return self.reject(.payload_too_large, true, .body_too_large);
            }
            self.body_len = @intCast(length);
            if (self.body_len > self.limits.body_bytes) {
                return self.reject(.payload_too_large, true, .body_too_large);
            }
        },
        .chunked => {
            self.body_len = 0;
            self.body_chunked = true;
            return self.reject(.not_implemented, true, .chunked_unsupported);
        },
    }

    const host_value = h1.host(self.head.headers) catch
        return self.reject(.bad_request, true, .invalid_host);
    if (self.version == .@"HTTP/1.1" and host_value == null) {
        return self.reject(.bad_request, true, .missing_host);
    }
    self.keep_alive = h1.persistent(self.version, self.head.headers);

    self.expect_continue = expectsContinue(self.head.headers) catch
        return self.reject(.expectation_failed, true, .unsupported_expectation);

    const arrived = self.used - self.body_start;
    if (arrived >= self.body_len) {
        self.leftover_start = self.body_start + self.body_len;
        self.body_received = self.body_len;
        self.body_target = self.request_buffer[self.body_start..][0..self.body_len];
        return self.completeRequest();
    }

    self.body_received = arrived;
    self.phase = .app;
    return .{ .request_head = .{
        .head = self.head,
        .body_bytes = self.body_len,
    } };
}

fn framingReject(self: *ServerConn, err: h1.framing.Error) Event {
    if (err == error.ConflictingFraming) {
        return self.reject(.bad_request, true, .conflicting_framing);
    }
    if (err == error.InvalidContentLength) return self.lengthReject();
    return self.reject(.bad_request, true, .invalid_framing);
}

fn lengthReject(self: *ServerConn) Event {
    var parser: content_length.Parser = .{};
    var values = self.head.headers.values("Content-Length");
    while (values.next()) |value| {
        parser.feed(value) catch |err| switch (err) {
            error.Conflicting => {
                return self.reject(.bad_request, true, .conflicting_length);
            },
            error.Invalid, error.Overflow => {
                return self.reject(.bad_request, true, .invalid_length);
            },
        };
    }
    return self.reject(.bad_request, true, .invalid_length);
}

fn parseBody(self: *ServerConn) Event {
    if (self.body_received >= self.body_len) return self.completeRequest();
    if (self.external_body) {
        const remaining = self.body_target.len - self.body_received;
        if (self.scratchBodyRead(remaining) and
            self.request_buffer.len - self.used < self.limits.min_read_bytes)
        {
            return self.reject(.payload_too_large, true, .body_too_large);
        }
        return .need_more;
    }
    const free = if (self.body_target.len == 0)
        self.request_buffer.len - self.used
    else
        self.body_target.len - self.body_received;
    if (self.readTooSmall(free)) return self.reject(.payload_too_large, true, .body_too_large);
    return .need_more;
}

fn readTooSmall(self: *const ServerConn, free: usize) bool {
    return free == 0 or (self.limits.min_read_bytes != 0 and free < self.limits.min_read_bytes);
}

fn scratchBodyRead(self: *const ServerConn, remaining: usize) bool {
    return self.limits.min_read_bytes != 0 and remaining < self.limits.min_read_bytes;
}

fn completeRequest(self: *ServerConn) Event {
    self.phase = .app;
    self.idle = false;
    self.phase_deadline = null;
    return .{ .request = .{
        .head = self.head,
        .body = if (self.body_target.len == 0)
            self.request_buffer[self.body_start..][0..self.body_len]
        else
            self.body_target,
    } };
}

/// True while the input is only complete or partial empty lines. A bare CR is
/// a possible CRLF prefix; it is not yet a request-line byte.
fn onlyBlankLines(bytes: []const u8) bool {
    for (bytes, 0..) |byte, index| {
        const expected: u8 = if (index % 2 == 0) '\r' else '\n';
        if (byte != expected) return false;
    }
    return true;
}

fn reject(
    self: *ServerConn,
    status: Status,
    drain: bool,
    reason: RejectReason,
) Event {
    self.keep_alive = false;
    self.drain_close = drain and self.unreadBody();
    self.total_deadline = null;
    self.queueResponse(.{ .status = status }, "", .final) catch {
        self.phase = .closed;
        self.clearDeadlines();
        return .closed;
    };
    self.phase = .response;
    return .{ .reject = .{ .status = status, .reason = reason } };
}

fn unreadBody(self: *const ServerConn) bool {
    if (!self.head_parsed) return self.used > 0;
    if (self.body_chunked) return true;
    if (self.body_len == 0) return false;
    return self.body_received < self.body_len or self.leftover_start == self.body_start;
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
    if (!self.switch_protocols) {
        if (!self.keep_alive) {
            try w.field("Connection", "close");
        } else if (self.version == .@"HTTP/1.0") {
            try w.field("Connection", "keep-alive");
        }
    }
    for (options.headers) |header| try w.field(header.name, header.value);
    try w.endFields();

    self.response_head_len = io.buffered().len;
    self.response = body;
    if (self.sendBody() and self.write_chunk_bytes != 0 and
        self.response_head_len < self.write_chunk_bytes)
    {
        const room = @min(
            self.write_chunk_bytes - self.response_head_len,
            self.response_buffer.len - self.response_head_len,
        );
        const copied = @min(room, body.len);
        @memcpy(
            self.response_buffer[self.response_head_len..][0..copied],
            body[0..copied],
        );
        self.response_head_len += copied;
        self.response = body[copied..];
    }
    self.response_head_sent = 0;
    self.response_body_sent = 0;
    self.response_kind = kind;
    self.phase_deadline = addDeadline(.fromNanoseconds(self.last_now), self.limits.write_timeout);
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
    self.phase_deadline = addDeadline(.fromNanoseconds(self.last_now), self.limits.write_timeout);
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
    self.phase_deadline = null;
    self.total_deadline = null;
}

fn startInputDeadlines(self: *ServerConn, now: Io.Timestamp) void {
    if (self.phase != .head) self.idle = false;
    if (self.idle and onlyBlankLines(self.request_buffer[0..self.used])) return;
    if (self.total_deadline == null) {
        self.total_deadline = addDeadline(now, self.limits.total_timeout);
    }
    if (self.idle) {
        assert(self.phase == .head);
        self.idle = false;
        self.startPhase(now, self.limits.head_timeout);
    } else {
        self.startPhase(now, switch (self.phase) {
            .head => self.limits.head_timeout,
            .body => self.limits.body_timeout,
            else => unreachable,
        });
    }
}

fn startIdleDeadline(self: *ServerConn, now: Io.Timestamp) void {
    assert(self.phase == .head);
    assert(self.idle);
    self.startPhase(now, self.limits.idle_timeout);
}

fn startPhase(self: *ServerConn, now: Io.Timestamp, timeout: i64) void {
    self.phase_deadline = addDeadline(now, timeout);
}

fn timedOut(self: *const ServerConn, now: Io.Timestamp) bool {
    const at = self.deadline() orelse return false;
    return now.durationTo(at).nanoseconds < 0;
}

fn addDeadline(now: Io.Timestamp, duration: i64) ?i64 {
    if (duration == 0) return null;
    const ns = now.addDuration(.{ .nanoseconds = duration }).nanoseconds;
    return @intCast(@min(ns, std.math.maxInt(i64)));
}

fn earliest(a: ?i64, b: ?i64) ?i64 {
    if (a == null) return b;
    if (b == null) return a;
    return if (a.? <= b.?) a else b;
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
        self.initChunk(limits, 0);
    }

    fn initChunk(self: *TestConn, limits: Limits, write_chunk_bytes: usize) void {
        self.* = .{ .conn = undefined };
        self.conn = .init(.{
            .request_buffer = &self.request_buffer,
            .headers = &self.headers,
            .response_buffer = &self.response_buffer,
            .limits = limits,
            .write_chunk_bytes = write_chunk_bytes,
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
                .read, .keep_alive, .close, .close_after_drain, .switched => return done,
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
        .reject => |got| try testing.expectEqual(status, got.status),
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

    switch (try t.feed(
        "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhe",
    )) {
        .request_head => {},
        else => return error.TestUnexpectedEvent,
    }
    _ = t.conn.bufferBody();

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

    switch (try t.feed(
        "POST / HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\nContent-Length: 5\r\n\r\n",
    )) {
        .request_head => {},
        else => return error.TestUnexpectedEvent,
    }
    _ = t.conn.bufferBody();

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
        .reject => |rejection| {
            try testing.expectEqual(Status.request_timeout, rejection.status);
            try testing.expectEqual(.request_timeout, rejection.reason);
        },
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
        .reject => |rejection| {
            try testing.expectEqual(Status.request_timeout, rejection.status);
            try testing.expectEqual(.request_timeout, rejection.reason);
        },
        else => return error.TestExpectedTimeout,
    }
}

test "the total timeout starts with the first request byte" {
    var t: TestConn = undefined;
    t.init(.{
        .idle_timeout = .fromSeconds(60),
        .head_timeout = .fromSeconds(60),
        .total_timeout = .fromSeconds(30),
    });
    t.conn.start(t.clock.now);

    t.clock.advance(29 * std.time.ns_per_s);
    try testing.expectEqual(.need_more, std.meta.activeTag(try t.feed("GET /")));

    t.clock.advance(2 * std.time.ns_per_s);
    try testing.expectEqual(.none, std.meta.activeTag(t.conn.tick(t.clock.now)));
}

test "idle and head timeouts are separate" {
    var t: TestConn = undefined;
    t.init(.{
        .idle_timeout = .fromSeconds(1),
        .head_timeout = .fromSeconds(5),
        .total_timeout = .fromSeconds(30),
    });
    t.conn.start(t.clock.now);

    t.clock.advance(900 * std.time.ns_per_ms);
    try testing.expectEqual(.need_more, std.meta.activeTag(try t.feed("GET /")));

    t.clock.advance(4300 * std.time.ns_per_ms);
    try testing.expectEqual(.none, std.meta.activeTag(t.conn.tick(t.clock.now)));

    t.clock.advance(1000 * std.time.ns_per_ms);
    switch (t.conn.tick(t.clock.now)) {
        .reject => |rejection| {
            try testing.expectEqual(Status.request_timeout, rejection.status);
            try testing.expectEqual(.request_timeout, rejection.reason);
        },
        else => return error.TestExpectedTimeout,
    }
}

test "a byte after the idle deadline is a 408" {
    var t: TestConn = undefined;
    t.init(.{ .idle_timeout = .fromSeconds(1) });
    t.conn.start(t.clock.now);

    t.clock.advance(2 * std.time.ns_per_s);
    try expectReject(try t.feed("GET /"), .request_timeout);
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

    switch (try t.feed(
        "POST / HTTP/1.0\r\nHost: x\r\nExpect: 100-continue\r\nContent-Length: 5\r\n\r\n",
    )) {
        .request_head => {},
        else => return error.TestUnexpectedEvent,
    }
    _ = t.conn.bufferBody();
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

test "a drain has its own deadline" {
    var t: TestConn = undefined;
    t.init(.{ .body_bytes = 4, .drain_timeout = .fromSeconds(1) });

    try expectReject(try t.feed(
        "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\n",
    ), .payload_too_large);
    try testing.expectEqual(.close_after_drain, std.meta.activeTag(try t.drain()));
    try testing.expectEqual(0, t.conn.recvBuffer().len);
    try testing.expect(t.conn.deadline() != null);

    t.clock.advance(2 * std.time.ns_per_s);
    try testing.expectEqual(.close, std.meta.activeTag(t.conn.tick(t.clock.now)));
}

test "a zero drain timeout skips the drain" {
    var t: TestConn = undefined;
    t.init(.{ .body_bytes = 4, .drain_timeout = .zero });

    try expectReject(try t.feed(
        "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\n",
    ), .payload_too_large);
    try testing.expectEqual(.close, std.meta.activeTag(try t.drain()));
    try testing.expect(t.conn.deadline() == null);
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

test "a large body goes into application-provided memory" {
    var t: TestConn = undefined;
    t.init(.{ .body_bytes = 5 * 1024 * 1024 });
    t.conn.start(t.clock.now);

    const bytes = "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5242880\r\n\r\nhe";
    switch (try t.feed(bytes)) {
        .request_head => |head| try testing.expectEqual(5 * 1024 * 1024, head.body_bytes),
        else => return error.TestUnexpectedEvent,
    }

    const memory = try testing.allocator.alloc(u8, 5 * 1024 * 1024);
    defer testing.allocator.free(memory);
    var filled: usize = 2;
    var event = t.conn.acceptBody(memory);
    while (filled < memory.len) {
        const dst = t.conn.recvBuffer();
        const n = @min(dst.len, 1021);
        @memset(dst[0..n], 'x');
        event = t.conn.received(n, t.clock.now);
        filled += n;
    }
    switch (event) {
        .request => |request| {
            try testing.expectEqual(memory.len, request.body.len);
            try testing.expectEqual('h', memory[0]);
            try testing.expectEqual('e', memory[1]);
            try testing.expectEqual('x', memory[memory.len - 1]);
        },
        else => return error.TestUnexpectedEvent,
    }

    try t.conn.respond(.{ .status = .ok }, "");
    try testing.expectEqual(.keep_alive, std.meta.activeTag(try t.drain()));
}

test "a head can be refused without a body sink" {
    var t: TestConn = undefined;
    t.init(.{});

    switch (try t.feed(
        "POST /large HTTP/1.1\r\nHost: x\r\nContent-Length: 500\r\n\r\nxx",
    )) {
        .request_head => |head| {
            try testing.expectEqualStrings("/large", head.head.target);
            try testing.expectEqual(500, head.body_bytes);
        },
        else => return error.TestUnexpectedEvent,
    }

    try t.conn.respond(.{ .status = .service_unavailable }, "later");
    try testing.expectEqual(.close_after_drain, std.meta.activeTag(try t.drain()));
    try testing.expect(mem.startsWith(u8, t.out(), "HTTP/1.1 503 "));
    try testing.expect(mem.endsWith(u8, t.out(), "\r\n\r\nlater"));
}

test "101 hands over the stream and its leftover bytes" {
    var t: TestConn = undefined;
    t.init(.{});
    t.conn.start(t.clock.now);

    _ = try expectRequest(try t.feed(
        "GET /chat HTTP/1.1\r\nHost: x\r\nConnection: close, Upgrade\r\n" ++
            "Upgrade: websocket\r\n\r\nnext protocol",
    ));
    try t.conn.switchProtocols(.{ .headers = &.{
        .{ .name = "Connection", .value = "Upgrade" },
        .{ .name = "Upgrade", .value = "websocket" },
    } });
    try testing.expectEqual(.switched, std.meta.activeTag(try t.drain()));
    try testing.expect(!mem.containsAtLeast(u8, t.out(), 1, "Connection: close"));
    try testing.expectEqualStrings("next protocol", t.conn.remainingInput());
    try testing.expect(t.conn.deadline() == null);

    t.clock.advance(60 * std.time.ns_per_s);
    try testing.expectEqual(.none, std.meta.activeTag(t.conn.tick(t.clock.now)));
    try testing.expectEqual(0, t.conn.recvBuffer().len);
}

test "a minimum read window rejects a nearly full head" {
    var t: TestConn = undefined;
    t.init(.{ .min_read_bytes = 64 });

    var input: [1000]u8 = undefined;
    @memset(&input, 'A');
    try expectReject(try t.feed(&input), .request_header_fields_too_large);
    try testing.expectEqual(.close_after_drain, std.meta.activeTag(try t.drain()));
    try testing.expect(mem.startsWith(u8, t.out(), "HTTP/1.1 431 "));
}

test "a minimum read window rejects a default-buffered body" {
    var t: TestConn = undefined;
    t.init(.{ .min_read_bytes = 64 });

    switch (try t.feed(
        "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 100\r\n\r\nxx",
    )) {
        .request_head => {},
        else => return error.TestUnexpectedEvent,
    }
    try testing.expectEqual(.need_more, std.meta.activeTag(t.conn.bufferBody()));

    const bytes = [_]u8{'x'} ** 64;
    try expectReject(try t.feed(&bytes), .payload_too_large);
    try testing.expectEqual(.close_after_drain, std.meta.activeTag(try t.drain()));
    try testing.expect(mem.startsWith(u8, t.out(), "HTTP/1.1 413 "));
}

test "a copied head permits shared field storage" {
    var shared: [16]Header = undefined;
    var a: TestConn = undefined;
    var b: TestConn = undefined;
    a.init(.{});
    b.init(.{});
    a.conn.headers = &shared;
    b.conn.headers = &shared;

    var target: [64]u8 = undefined;
    switch (try a.feed(
        "POST /large HTTP/1.1\r\nHost: x\r\nContent-Length: 500\r\n\r\n",
    )) {
        .request_head => |head| {
            target = undefined;
            @memcpy(target[0..head.head.target.len], head.head.target);
        },
        else => return error.TestUnexpectedEvent,
    }
    try a.conn.respond(.{ .status = .payload_too_large }, "");
    try testing.expectEqual(.close_after_drain, std.meta.activeTag(try a.drain()));

    const request = try expectRequest(try b.feed("GET /next HTTP/1.1\r\nHost: x\r\n\r\n"));
    try testing.expectEqualStrings("/next", request.head.target);
    try testing.expectEqualStrings("/large", target[0..6]);
}

test "an application body buffer that is too small is 413" {
    var t: TestConn = undefined;
    t.init(.{});

    switch (try t.feed(
        "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 500\r\n\r\n",
    )) {
        .request_head => {},
        else => return error.TestUnexpectedEvent,
    }
    var small: [10]u8 = undefined;
    try expectReject(t.conn.acceptBody(&small), .payload_too_large);
    try testing.expectEqual(.close_after_drain, std.meta.activeTag(try t.drain()));
    try testing.expect(mem.startsWith(u8, t.out(), "HTTP/1.1 413 "));
}

test "a minimum read window copies the external body tail" {
    var t: TestConn = undefined;
    t.init(.{ .min_read_bytes = 64 });

    switch (try t.feed(
        "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhe",
    )) {
        .request_head => {},
        else => return error.TestUnexpectedEvent,
    }

    var body: [5]u8 = undefined;
    _ = t.conn.acceptBody(&body);

    // Only three body bytes remain. The receive destination is request
    // scratch, not the too-short tail of the application's buffer.
    const dst = t.conn.recvBuffer();
    try testing.expect(dst.len >= 64);
    try testing.expect(dst.ptr == t.request_buffer[t.conn.used..].ptr);
    @memcpy(dst[0..3], "llo");
    _ = t.conn.received(3, t.clock.now);
    try testing.expectEqualStrings("hello", &body);

    try t.conn.respond(.{ .status = .ok }, "");
    try testing.expectEqual(.keep_alive, std.meta.activeTag(try t.drain()));
    try testing.expectEqual(.need_more, std.meta.activeTag(t.advance()));
    try testing.expectEqual(0, t.conn.used);

    const next = try expectRequest(try t.feed(
        "GET /next HTTP/1.1\r\nHost: x\r\n\r\n",
    ));
    try testing.expectEqualStrings("GET", next.head.method_token);
    try testing.expectEqualStrings("/next", next.head.target);
}

test "external short-body scratch preserves a pipelined request" {
    var t: TestConn = undefined;
    t.init(.{ .min_read_bytes = 64 });

    switch (try t.feed(
        "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhe",
    )) {
        .request_head => {},
        else => return error.TestUnexpectedEvent,
    }
    var body: [5]u8 = undefined;
    _ = t.conn.acceptBody(&body);

    const wire = "llo" ++ "GET /next HTTP/1.1\r\nHost: x\r\n\r\n";
    const dst = t.conn.recvBuffer();
    try testing.expect(wire.len <= dst.len);
    @memcpy(dst[0..wire.len], wire);
    const first = try expectRequest(t.conn.received(wire.len, t.clock.now));
    try testing.expectEqualStrings("hello", first.body);

    try t.conn.respond(.{ .status = .ok }, "one");
    try testing.expectEqual(.keep_alive, std.meta.activeTag(try t.drain()));
    const second = try expectRequest(t.advance());
    try testing.expectEqualStrings("/next", second.head.target);
}

test "a machine rejection accepts a shaped policy response" {
    var t: TestConn = undefined;
    t.init(.{});

    try expectReject(try t.feed(
        "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n",
    ), .not_implemented);
    try t.conn.reviewRejection(.{
        .options = .{ .status = .bad_request, .content_type = "application/json" },
        .body = "{\"error\":\"bad framing\"}",
    });
    try testing.expectEqual(.close_after_drain, std.meta.activeTag(try t.drain()));
    try testing.expect(mem.startsWith(u8, t.out(), "HTTP/1.1 400 Bad Request\r\n"));
    try testing.expect(mem.find(u8, t.out(), "Content-Type: application/json") != null);
    try testing.expect(mem.endsWith(u8, t.out(), "{\"error\":\"bad framing\"}"));
}

test "ResponseOptions.close owns the connection close" {
    var t: TestConn = undefined;
    t.init(.{});

    _ = try expectRequest(try t.feed("GET / HTTP/1.1\r\nHost: x\r\n\r\n"));
    try t.conn.respond(.{ .status = .ok, .close = true }, "");
    try testing.expectEqual(.close, std.meta.activeTag(try t.drain()));
    try testing.expectEqual(1, mem.count(u8, t.out(), "Connection: close"));
}

test "CRLF after keep-alive leaves the connection idle" {
    var t: TestConn = undefined;
    t.init(.{ .idle_timeout = .fromSeconds(60), .head_timeout = .fromSeconds(5) });
    t.conn.start(t.clock.now);

    _ = try expectRequest(try t.feed("GET / HTTP/1.1\r\nHost: x\r\n\r\n"));
    try t.conn.respond(.{ .status = .ok }, "");
    try testing.expectEqual(.keep_alive, std.meta.activeTag(try t.drain()));

    try testing.expectEqual(.need_more, std.meta.activeTag(try t.feed("\r\n")));
    try testing.expectEqual(
        60 * std.time.ns_per_s,
        t.conn.deadline().?.nanoseconds,
    );
    try testing.expectEqual(.closed, std.meta.activeTag(t.conn.eof(t.clock.now)));
}

test "trickled CRLF keeps the idle deadline until a request starts" {
    var t: TestConn = undefined;
    t.init(.{ .idle_timeout = .fromMilliseconds(100), .head_timeout = .fromSeconds(5) });
    t.conn.start(t.clock.now);

    try testing.expectEqual(.need_more, std.meta.activeTag(try t.feed("\r")));
    t.clock.advance(10 * std.time.ns_per_ms);
    try testing.expectEqual(.need_more, std.meta.activeTag(try t.feed("\n")));
    t.clock.advance(100 * std.time.ns_per_ms);
    switch (t.conn.tick(t.clock.now)) {
        .reject => |rejection| {
            try testing.expectEqual(.request_timeout, rejection.status);
            try testing.expectEqual(.request_timeout, rejection.reason);
        },
        else => return error.TestExpectedTimeout,
    }
}

test "CRLF followed by a request works normally" {
    var t: TestConn = undefined;
    t.init(.{ .idle_timeout = .fromSeconds(2), .head_timeout = .fromMilliseconds(100) });
    t.conn.start(t.clock.now);

    try testing.expectEqual(.need_more, std.meta.activeTag(try t.feed("\r\n\r\n")));
    t.clock.advance(10 * std.time.ns_per_ms);
    const request = try expectRequest(try t.feed("GET / HTTP/1.1\r\nHost: x\r\n\r\n"));
    try testing.expectEqualStrings("/", request.head.target);
    try testing.expect(t.conn.deadline().?.nanoseconds > t.clock.now.nanoseconds);
}

fn expectRejectReason(
    t: *TestConn,
    input: []const u8,
    status: Status,
    reason: RejectReason,
) !void {
    switch (try t.feed(input)) {
        .reject => |rejection| {
            try testing.expectEqual(status, rejection.status);
            try testing.expectEqual(reason, rejection.reason);
        },
        else => return error.TestUnexpectedEvent,
    }
}

test "rejection reasons distinguish parser and framing failures" {
    var t: TestConn = undefined;

    t = undefined;
    t.init(.{});
    try expectRejectReason(&t, "GET / HTTP/1.1\r\n\r\n", .bad_request, .missing_host);

    t = undefined;
    t.init(.{});
    try expectRejectReason(&t, "GET HTTP/1.1\r\n\r\n", .bad_request, .malformed_head);

    t = undefined;
    t.init(.{});
    try expectRejectReason(
        &t,
        "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\n",
        .bad_request,
        .conflicting_length,
    );

    t = undefined;
    t.init(.{});
    try expectRejectReason(
        &t,
        "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: no\r\n\r\n",
        .bad_request,
        .invalid_length,
    );

    t = undefined;
    t.init(.{});
    try expectRejectReason(
        &t,
        "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 1\r\nTransfer-Encoding: chunked\r\n\r\n",
        .bad_request,
        .conflicting_framing,
    );

    t = undefined;
    t.init(.{});
    try expectRejectReason(
        &t,
        "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n",
        .not_implemented,
        .chunked_unsupported,
    );

    t = undefined;
    t.init(.{ .body_bytes = 16 });
    try expectRejectReason(
        &t,
        "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 1000\r\n\r\n",
        .payload_too_large,
        .body_too_large,
    );

    t = undefined;
    t.init(.{});
    var full: [1024]u8 = undefined;
    @memset(&full, 'A');
    try expectRejectReason(&t, &full, .request_header_fields_too_large, .head_too_large);

    t = undefined;
    t.init(.{});
    var fields: [17 * 8]u8 = undefined;
    var used: usize = 0;
    @memcpy(fields[used..][0..16], "GET / HTTP/1.1\r\n");
    used += 16;
    for (0..17) |_| {
        @memcpy(fields[used..][0..6], "X: 1\r\n");
        used += 6;
    }
    @memcpy(fields[used..][0..2], "\r\n");
    used += 2;
    try expectRejectReason(
        &t,
        fields[0..used],
        .request_header_fields_too_large,
        .too_many_fields,
    );
}

test "ServerConn has ordinary pointer alignment" {
    try testing.expect(@alignOf(ServerConn) <= @alignOf(usize));
}

test "a small response coalesces into one slice" {
    var t: TestConn = undefined;
    t.initChunk(.{}, 4096);

    _ = try expectRequest(try t.feed("GET / HTTP/1.1\r\nHost: x\r\n\r\n"));
    try t.conn.respond(.{ .status = .ok }, "hello");
    const slices = t.conn.sendSlices();
    try testing.expectEqual(0, slices.body.len);
    try testing.expect(mem.endsWith(u8, slices.head, "\r\n\r\nhello"));
    try testing.expectEqual(.keep_alive, std.meta.activeTag(try t.drain()));
}

test "a large body respects the write chunk cap" {
    var t: TestConn = undefined;
    t.initChunk(.{}, 512);

    _ = try expectRequest(try t.feed("GET / HTTP/1.1\r\nHost: x\r\n\r\n"));
    var body: [4096]u8 = undefined;
    @memset(&body, 'z');
    try t.conn.respond(.{ .status = .ok }, &body);

    var written: usize = 0;
    while (true) {
        const slices = t.conn.sendSlices();
        try testing.expect(slices.head.len + slices.body.len <= 512);
        const done = t.conn.sent(slices.head.len + slices.body.len, t.clock.now);
        written += slices.head.len + slices.body.len;
        if (std.meta.activeTag(done) == .keep_alive) break;
    }
    try testing.expect(written > body.len);
}

test "an interim response never coalesces with its next response" {
    var t: TestConn = undefined;
    t.initChunk(.{}, 4096);
    t.conn.queueContinue() catch |err| {
        _ = @errorName(err);
        return err;
    };
    try testing.expectEqualStrings("HTTP/1.1 100 Continue\r\n\r\n", t.conn.sendSlices().head);
    try testing.expectEqual(.read, std.meta.activeTag(try t.drain()));
}
