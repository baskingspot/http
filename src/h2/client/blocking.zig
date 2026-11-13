//! A blocking HTTP/2 client with streaming request and response bodies.
//!
//! The adapter owns a `h2.Session`, serializes one request at a time, and
//! snapshots response header names and values into the per-response arena.
//! `begin` sends the request head and hands back a `BodyWriter`; `response`
//! waits for the response head. The two sides of the stream are independent,
//! so a caller can write a body chunk, read a response chunk, and write again
//! before either side ends. `request` is the static-body convenience built on
//! the same two calls.
//!
//! Body reads and writes both drive the connection, so SETTINGS
//! acknowledgments and WINDOW_UPDATE frames are flushed in either direction.
//! Response DATA that arrives during a write is buffered until the caller
//! reads it; flow-control credit for it is returned as it is consumed, which
//! bounds that buffer to the connection window.
//!
//! The request, response, body, and config types come from the shared client
//! contract; `h1.client.streaming` implements the same contract.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const mem = std.mem;
const ascii = std.ascii;
const assert = std.debug.assert;
const testing = std.testing;

const shared = @import("../../client/root.zig");
pub const Protocol = shared.Protocol;
pub const Scheme = shared.Scheme;
pub const Request = shared.Request;
pub const ResponseHead = shared.ResponseHead;
pub const Body = shared.Body;
pub const BodyWriter = shared.BodyWriter;
pub const Response = shared.Response;
pub const Config = shared.Config;
const compat = @import("../../compat.zig");
const Header = @import("../../header.zig").Header;
const Headers = @import("../../header.zig").Headers;
const hpack = @import("../../hpack/root.zig");
const Status = @import("../../status.zig").Status;
const engine = @import("../engine/blocking.zig");
const frame = @import("../frame.zig");
const session_mod = @import("../session.zig");
const Session = session_mod.Session;
const Event = session_mod.Event;

pub const RequestState = enum { idle, staged, in_flight, committed };

// ast-grep-ignore: public-struct-field-default -- client state; init sets every field
pub const Client = struct {
    allocator: Allocator,
    reader: *Io.Reader,
    writer: *Io.Writer,
    arena: std.heap.ArenaAllocator,
    max_header_bytes: usize,
    max_headers: usize,
    session: Session,
    stream_id: u31 = 0,
    active: bool = false,
    /// The peer sent END_STREAM for the current response.
    remote_end: bool = false,
    /// All response bytes have been delivered to the caller.
    body_eof: bool = false,
    /// A reset was queued by `close`.
    reset_sent: bool = false,
    /// The request body sent END_STREAM.
    request_closed: bool = false,
    /// Staged until the request's END_HEADERS reaches the writer.
    request_state: RequestState = .idle,
    /// A write or connection failure poisoned this client.
    connection_poisoned: bool = false,
    /// Bytes successfully handed to the writer.
    output_written: u64 = 0,
    /// Response bytes received and not yet handed to the caller.
    inbox: std.ArrayList(u8) = .empty,
    /// Flow-control charge for `inbox`, including padding.
    inbox_flow: u32 = 0,
    /// Response bytes handed to the caller. Held until the reader has taken
    /// all of it, then released.
    chunk: std.ArrayList(u8) = .empty,
    /// Bytes of `chunk` the caller's writer has already taken. A short write
    /// resumes here instead of dropping the tail.
    chunk_consumed: usize = 0,
    /// Flow-control charge for `chunk`. Released only once the chunk is fully
    /// handed over.
    chunk_flow: u32 = 0,
    /// Unfed transport bytes, kept when the session input buffer is full.
    net_buffer: [4096]u8 = undefined,
    net_start: usize = 0,
    net_end: usize = 0,
    body: Body = undefined,
    body_writer: BodyWriter = undefined,
    /// The response byte stream `body.reader` points at. The client must stay
    /// put for the life of the body.
    body_reader: Io.Reader = undefined,
    /// Why a read on the caller's reader failed, when the reader latches one.
    read_cause: ?shared.ReadCause = null,
    goaway: ?shared.GoAway = null,
    /// Response head received while the request body was still being written.
    early_head: ?ResponseHead = null,
    /// The tail of a static `Request.body` that did not fit the send window.
    /// `readBody` sends it as the caller consumes the response. The streaming
    /// writer has no such remainder: it blocks instead.
    pending_body: []const u8 = &.{},
    /// `response` already returned the head for this request.
    response_taken: bool = false,
    /// RST_STREAM code when the last read returned error.Reset.
    body_reset_code: ?u32 = null,
    /// Why the last `error.ReadFailed` happened.
    body_outcome: ?shared.Outcome = null,

    /// Initialize in its final location. The caller owns the reader, writer,
    /// header storage, and allocator.
    pub fn init(
        self: *Client,
        reader: *Io.Reader,
        writer: *Io.Writer,
        config: Config,
    ) !void {
        return self.initOptions(reader, writer, config, .{ .role = .client });
    }

    fn initOptions(
        self: *Client,
        reader: *Io.Reader,
        writer: *Io.Writer,
        config: Config,
        options: session_mod.Options,
    ) !void {
        var session_options = options;
        session_options.role = .client;
        self.* = .{
            .allocator = config.allocator,
            .reader = reader,
            .writer = writer,
            .arena = .init(config.allocator),
            .max_header_bytes = config.max_header_bytes,
            .max_headers = config.max_headers,
            .session = try .init(config.allocator, session_options),
        };
        errdefer self.session.deinit(self.allocator);
        errdefer self.arena.deinit();
        self.body = .{ .ptr = self, .vtable = &body_vtable, .reader = &self.body_reader };
        self.body_reader = .{
            .vtable = &body_reader_vtable,
            .buffer = &.{},
            .seek = 0,
            .end = 0,
        };
        self.read_cause = config.read_cause;
        self.body_writer = .{ .ptr = self, .vtable = &body_writer_vtable };

        // Flush the client preface and initial SETTINGS. sendFrame starts at a
        // frame boundary, so the preface is drained here with the byte API.
        try self.flushBytes();
    }

    pub fn deinit(self: *Client) void {
        self.closeBody();
        self.inbox.deinit(self.allocator);
        self.chunk.deinit(self.allocator);
        self.session.deinit(self.allocator);
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn commitState(self: *const Client) RequestState {
        return self.request_state;
    }

    pub fn isConnectionPoisoned(self: *const Client) bool {
        return self.connection_poisoned;
    }

    /// The connection-level GOAWAY boundary, if one arrived. Compare with
    /// `streamId()`: a body result of `truncated` above this boundary was not
    /// processed by the peer.
    pub fn goAway(self: *const Client) ?shared.GoAway {
        return self.goaway;
    }

    /// The last request's stream id. Preserved after `Body.close` so a caller
    /// can compare it with `goAway().last_stream_id`.
    pub fn streamId(self: *const Client) u31 {
        return self.stream_id;
    }

    /// Send one request, including its body, and wait for the response head.
    ///
    /// A final response that arrives before the body is sent ends the send
    /// early: the rest stays in `pending_body` and `readBody` sends it under
    /// flow control as the response is consumed. This is the v0.1 contract,
    /// and it is why the static body is not simply `write` plus `close`.
    pub fn request(self: *Client, value: Request) !Response {
        errdefer self.closeBody();
        try self.start(value, value.body.len == 0, value.body.len);
        if (value.body.len != 0) {
            self.writeStaticBody(value.body) catch |err| {
                self.closeBody();
                return err;
            };
        }
        if (self.pending_body.len == 0) self.closeRequestBody();
        return self.response();
    }

    fn writeStaticBody(self: *Client, body: []const u8) !void {
        var offset: usize = 0;
        while (offset < body.len) {
            const accepted = self.session.submitData(
                self.allocator,
                self.stream_id,
                body[offset..],
                true,
            ) catch |err| {
                self.connection_poisoned = true;
                return err;
            };
            offset += accepted;
            if (accepted != 0) {
                self.flushFrames() catch |err| {
                    self.connection_poisoned = true;
                    return err;
                };
            }
            if (offset == body.len) break;

            const event = self.nextEvent() catch |err| {
                self.connection_poisoned = true;
                return err;
            };
            self.onWriteEvent(event) catch |err| {
                self.connection_poisoned = true;
                return err;
            };
            if (self.early_head != null) {
                self.pending_body = body[offset..];
                return;
            }
        }
    }

    /// Send the request head without END_STREAM and return its body writer.
    /// `value.body` must be empty; the caller writes the body. The response
    /// head is read with `response`, which may be called before or after any
    /// `write`.
    pub fn begin(self: *Client, value: Request) !BodyWriter {
        if (value.body.len != 0) return error.BodyNotAllowed;
        try self.start(value, false, 0);
        return self.body_writer;
    }

    /// Drop the in-flight request without reading its response. Idempotent.
    /// A caller that stopped after `begin` or a failed `response` uses this so
    /// the client can take another request.
    pub fn abort(self: *Client) void {
        self.closeBody();
    }

    /// Wait for the response head. Callable once per request, before or after
    /// the request body ends.
    pub fn response(self: *Client) !Response {
        if (!self.active) return error.NoRequest;
        if (self.response_taken) return error.ResponseTaken;
        if (self.early_head) |head| {
            self.response_taken = true;
            self.early_head = null;
            return .{ .head = head, .body = self.body };
        }

        while (true) {
            const event = self.nextEvent() catch |err| {
                self.connection_poisoned = true;
                return err;
            };
            switch (event) {
                .settings => self.flushFrames() catch |err| {
                    self.connection_poisoned = true;
                    return err;
                },
                .window_update => {},
                .response => |head_event| {
                    if (head_event.stream_id != self.stream_id) return error.UnexpectedStream;
                    if (head_event.head.status.class() == .informational) {
                        if (head_event.end_stream) return error.ProtocolError;
                        continue;
                    }
                    const headers = try self.snapshot(head_event.head.headers);
                    if (head_event.end_stream) {
                        self.remote_end = true;
                        self.body_eof = true;
                    }
                    self.response_taken = true;
                    return .{
                        .head = .{
                            .protocol = .h2,
                            .status = head_event.head.status,
                            .headers = headers,
                        },
                        .body = self.body,
                    };
                },
                .goaway => |goaway| {
                    self.goaway = .{
                        .last_stream_id = goaway.last_stream_id,
                        .code = compat.enumToInt(goaway.code),
                    };
                    if (self.stream_id > goaway.last_stream_id) {
                        self.connection_poisoned = true;
                        return error.GoAway;
                    }
                },
                .connection_error => {
                    self.connection_poisoned = true;
                    return error.ConnectionError;
                },
                .reset => return error.StreamReset,
                .trailers => return error.UnexpectedTrailers,
                .data => return error.UnexpectedData,
                .request => return error.UnexpectedRequest,
            }
        }
    }

    /// Queue the request head and reset the per-request state.
    fn start(
        self: *Client,
        value: Request,
        end_stream: bool,
        content_length: usize,
    ) !void {
        if (self.active) return error.RequestInProgress;
        if (self.connection_poisoned) return error.ConnectionPoisoned;
        if (self.goaway != null) return error.GoAway;
        if (value.authority.len == 0) return error.InvalidAuthority;
        self.request_state = .idle;
        _ = self.arena.reset(.free_all);
        self.early_head = null;
        self.response_taken = false;
        self.request_closed = false;

        var has_length = false;
        for (value.headers) |header| {
            if (ascii.eqlIgnoreCase(header.name, "content-length")) has_length = true;
        }
        const add_length = content_length != 0 and !has_length;
        const field_count = 4 + value.headers.len + @as(usize, if (add_length) 1 else 0);
        const fields = try self.allocator.alloc(Header, field_count);
        defer self.allocator.free(fields);

        fields[0] = .{ .name = ":method", .value = value.method_token };
        fields[1] = .{ .name = ":scheme", .value = value.scheme.token() };
        fields[2] = .{ .name = ":authority", .value = value.authority };
        fields[3] = .{ .name = ":path", .value = value.target };

        for (value.headers, 0..) |header, index| {
            if (ascii.eqlIgnoreCase(header.name, "host")) return error.DuplicateAuthority;
            if (!validLowerHeaderName(header.name)) return error.InvalidHeader;
            fields[4 + index] = header;
        }
        if (add_length) {
            var length_text: [20]u8 = undefined;
            const text = try std.fmt.bufPrint(&length_text, "{d}", .{content_length});
            fields[field_count - 1] = .{ .name = "content-length", .value = text };
        }

        const id = self.session.submitRequest(
            self.allocator,
            fields,
            end_stream,
        ) catch |err| {
            return err;
        };
        const run = self.session.lastHeaderRun() orelse return error.MissingHeaderRun;
        if (run.stream_id != id) return error.MissingHeaderRun;
        self.request_state = .staged;
        self.stream_id = id;
        self.active = true;
        self.remote_end = false;
        self.body_eof = false;
        self.body_reset_code = null;
        self.body_outcome = null;
        self.reset_sent = false;
        self.request_closed = end_stream;
        self.pending_body = &.{};
        self.inbox_flow = 0;
        self.chunk_flow = 0;
        self.inbox.clearRetainingCapacity();
        self.chunk.clearRetainingCapacity();
        self.chunk_consumed = 0;
        self.net_start = 0;
        self.net_end = 0;

        errdefer self.closeBody();
        self.flushFrames() catch |err| {
            self.connection_poisoned = true;
            return err;
        };
    }

    fn validLowerHeaderName(name: []const u8) bool {
        if (name.len == 0 or name[0] == ':') return false;
        for (name) |byte| {
            if (byte >= 'A' and byte <= 'Z') return false;
        }
        return true;
    }

    fn snapshot(self: *Client, headers: Headers) !Headers {
        if (headers.items.len > self.max_headers) return error.HeadersTooLarge;

        var total: usize = 0;
        for (headers.items) |header| {
            total = std.math.add(usize, total, header.name.len) catch
                return error.HeadersTooLarge;
            total = std.math.add(usize, total, header.value.len) catch
                return error.HeadersTooLarge;
        }
        if (total > self.max_header_bytes) return error.HeadersTooLarge;

        const arena = self.arena.allocator();
        const items = try arena.alloc(Header, headers.items.len);
        const bytes = try arena.alloc(u8, total);

        var used: usize = 0;
        for (headers.items, 0..) |header, index| {
            @memcpy(bytes[used..][0..header.name.len], header.name);
            const name = bytes[used..][0..header.name.len];
            used += header.name.len;
            @memcpy(bytes[used..][0..header.value.len], header.value);
            const value = bytes[used..][0..header.value.len];
            used += header.value.len;
            items[index] = .{ .name = name, .value = value };
        }
        return .{ .items = items };
    }

    /// Write request-body bytes. Blocks until every byte is queued, reading
    /// events so flow control can open. Response events that arrive first are
    /// kept for `response` and the body reader.
    fn writeBody(self: *Client, bytes: []const u8) shared.BodyWriteError!void {
        if (!self.active or self.request_closed) return error.Closed;
        if (bytes.len == 0) return;

        var offset: usize = 0;
        while (offset < bytes.len) {
            const accepted = self.session.submitData(
                self.allocator,
                self.stream_id,
                bytes[offset..],
                false,
            ) catch |err| return self.writeFailure(err);
            if (accepted != 0) {
                offset += accepted;
                self.flushFrames() catch |err| return self.writeFailure(err);
                continue;
            }
            const event = self.nextEvent() catch |err| return self.writeFailure(err);
            self.onWriteEvent(event) catch |err| return self.writeFailure(err);
        }
    }

    fn onWriteEvent(self: *Client, event: Event) !void {
        switch (event) {
            .window_update => {},
            .settings => try self.flushFrames(),
            .response => |head_event| {
                if (head_event.stream_id != self.stream_id) return error.UnexpectedStream;
                if (head_event.head.status.class() == .informational) {
                    if (head_event.end_stream) return error.ProtocolError;
                    return;
                }
                if (self.response_taken or self.early_head != null) {
                    return error.UnexpectedResponse;
                }
                self.early_head = .{
                    .protocol = .h2,
                    .status = head_event.head.status,
                    .headers = try self.snapshot(head_event.head.headers),
                };
                if (head_event.end_stream) self.remote_end = true;
            },
            .data => |data| {
                if (data.stream_id != self.stream_id) return error.UnexpectedData;
                try self.buffer(data.bytes);
                if (data.end_stream) self.remote_end = true;
            },
            .trailers => |trailers| {
                if (trailers.stream_id != self.stream_id) return error.UnexpectedTrailers;
                self.remote_end = true;
            },
            .goaway => |goaway| {
                self.goaway = .{
                    .last_stream_id = goaway.last_stream_id,
                    .code = compat.enumToInt(goaway.code),
                };
                if (self.stream_id > goaway.last_stream_id) {
                    self.connection_poisoned = true;
                    return error.GoAway;
                }
            },
            .connection_error => {
                self.connection_poisoned = true;
                return error.ConnectionError;
            },
            .reset => |reset| {
                self.body_reset_code = compat.enumToInt(reset.code);
                return error.Reset;
            },
            .request => return error.UnexpectedRequest,
        }
    }

    /// Keep response bytes that arrived before the caller read them. The flow
    /// charge stays until `readBody` hands them out and the next read
    /// supersedes them, so the buffer is bounded by the connection window.
    fn buffer(self: *Client, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        try self.inbox.appendSlice(self.allocator, bytes);
        self.inbox_flow += @intCast(bytes.len);
    }

    /// Make the next chunk of response bytes current, or report the end of the
    /// stream. The current chunk must be handed out first: its window credit is
    /// released here, so a caller that stops reading stops the peer.
    fn advanceBody(self: *Client) anyerror!void {
        if (!self.active) return error.EndOfStream;
        if (self.body_eof) return error.EndOfStream;

        if (self.chunk.items.len != 0) {
            self.chunk.clearRetainingCapacity();
            self.chunk_consumed = 0;
            try self.releaseChunk();
        }

        while (true) {
            if (self.inbox.items.len != 0) {
                mem.swap(std.ArrayList(u8), &self.chunk, &self.inbox);
                self.chunk_flow = self.inbox_flow;
                self.inbox_flow = 0;
                self.chunk_consumed = 0;
                return;
            }

            if (self.pending_body.len != 0) {
                const accepted = try self.session.submitData(
                    self.allocator,
                    self.stream_id,
                    self.pending_body,
                    true,
                );
                if (accepted != 0) {
                    self.pending_body = self.pending_body[accepted..];
                    try self.flushFrames();
                    if (self.pending_body.len != 0) continue;
                }
                // No window. Read an event; response bytes are the
                // backpressure point.
            }

            if (self.remote_end) {
                self.body_eof = true;
                self.pending_body = &.{};
                return error.EndOfStream;
            }

            const event = try self.nextEvent();
            switch (event) {
                .data => |data| {
                    if (data.stream_id != self.stream_id) return error.UnexpectedData;
                    // Padding was already returned by Session.onData; only the
                    // application bytes are still charged to the windows.
                    try self.buffer(data.bytes);
                    if (data.end_stream) self.remote_end = true;
                },
                .trailers => |trailers| {
                    if (trailers.stream_id != self.stream_id) return error.UnexpectedTrailers;
                    if (trailers.end_stream) self.remote_end = true;
                },
                .response => |head_event| {
                    if (head_event.stream_id != self.stream_id) return error.UnexpectedResponse;
                    if (head_event.head.status.class() == .informational) {
                        if (head_event.end_stream) return error.ProtocolError;
                        continue;
                    }
                    // A second final response head is a protocol violation.
                    return error.UnexpectedResponse;
                },
                .settings => try self.flushFrames(),
                .window_update => {},
                .goaway => |goaway| {
                    self.goaway = .{
                        .last_stream_id = goaway.last_stream_id,
                        .code = compat.enumToInt(goaway.code),
                    };
                    if (self.stream_id > goaway.last_stream_id) return error.Truncated;
                },
                .connection_error => return error.ConnectionError,
                .reset => |reset| {
                    if (reset.code == .no_error and self.remote_end) {
                        self.body_eof = true;
                        return error.EndOfStream;
                    }
                    self.body_reset_code = compat.enumToInt(reset.code);
                    return error.Reset;
                },
                .request => return error.UnexpectedRequest,
            }
        }
    }

    fn bodyStream(erased: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const self: *Client = @fieldParentPtr("body_reader", erased);
        return self.streamBody(w, limit);
    }

    /// Pump body bytes into `w`. Returns the count written, which is never more
    /// than `limit`, and reports a clean end as `error.EndOfStream`. A writer
    /// that accepts a prefix leaves the rest in `chunk`, where the next call
    /// resumes without releasing window credit it has not handed over.
    fn streamBody(self: *Client, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        if (!self.active) return error.EndOfStream;

        var written: usize = 0;
        const cap = limit.minInt(std.math.maxInt(usize));
        if (cap == 0) return 0;
        while (written < cap) {
            const available = self.chunk.items[self.chunk_consumed..];
            if (available.len != 0) {
                const take = available[0..@min(available.len, cap - written)];
                const n = w.write(take) catch return error.WriteFailed;
                self.chunk_consumed += n;
                written += n;
                if (n != take.len) return written;
                continue;
            }
            // Never block for more bytes once this call has some. A duplex
            // caller writes between reads, and waiting here would deadlock it.
            if (written != 0) return written;
            if (self.advanceBody()) |_| {} else |err| {
                if (err == error.EndOfStream) break;
                return self.failBody(err);
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
            .truncated, .protocol_error => self.connection_poisoned = true,
            .reset => {},
            .local => |local| switch (local) {
                .canceled, .capacity => {},
                else => self.connection_poisoned = true,
            },
        }
        return error.ReadFailed;
    }

    fn classify(self: *const Client, err: anyerror) shared.Outcome {
        return switch (err) {
            error.Reset => .{ .reset = self.body_reset_code orelse 0 },
            error.Canceled => .{ .local = .canceled },
            error.OutOfMemory => .{ .local = .out_of_memory },
            error.InputFull, error.BufferTooSmall => .{ .local = .capacity },
            error.WouldBlock => .{ .local = .unusable },
            // The reader reports `error.ReadFailed` for every failure of its
            // own and keeps the cause, so ask it rather than guess.
            error.ReadFailed => if (self.read_cause) |latched| blk: {
                const cause = latched.get() orelse break :blk shared.Outcome.truncated;
                break :blk shared.common.localFromCause(cause);
            } else shared.Outcome.truncated,
            error.EndOfStream,
            error.ConnectionClosed,
            error.WriteFailed,
            error.BrokenPipe,
            error.Truncated,
            => shared.Outcome.truncated,
            else => shared.Outcome.protocol_error,
        };
    }

    fn writeFailure(self: *Client, err: anyerror) shared.BodyWriteError {
        const outcome: shared.BodyWriteError = switch (err) {
            error.Reset => error.Reset,
            error.OutOfMemory => blk: {
                self.connection_poisoned = true;
                break :blk error.LocalOutOfMemory;
            },
            error.ProtocolError,
            error.UnexpectedData,
            error.UnexpectedTrailers,
            error.UnexpectedResponse,
            error.UnexpectedStream,
            error.UnexpectedRequest,
            => blk: {
                self.connection_poisoned = true;
                break :blk error.Protocol;
            },
            else => blk: {
                self.connection_poisoned = true;
                break :blk error.Truncated;
            },
        };
        return outcome;
    }

    fn bodyOutcome(ptr: *anyopaque) ?shared.Outcome {
        const self: *Client = @ptrCast(@alignCast(ptr));
        return self.body_outcome;
    }

    /// Return the flow-control credit for the chunk the caller finished with.
    fn releaseChunk(self: *Client) !void {
        if (self.chunk_flow == 0) return;
        const count = self.chunk_flow;
        self.chunk_flow = 0;
        try self.session.release(self.allocator, self.stream_id, count);
        try self.flushFrames();
    }

    fn closeRequestBody(self: *Client) void {
        if (!self.active or self.request_closed) return;
        if (self.pending_body.len != 0) return;
        self.request_closed = true;
        _ = self.session.submitData(
            self.allocator,
            self.stream_id,
            &.{},
            true,
        ) catch |err| switch (err) {
            error.StreamClosed, error.UnknownStream, error.ConnectionClosed => return,
            else => {
                self.connection_poisoned = true;
                return;
            },
        };
        self.flushFrames() catch |err| ignoreError(err);
    }

    fn closeBody(self: *Client) void {
        if (!self.active) return;

        if (self.inbox_flow != 0) {
            self.session.release(
                self.allocator,
                self.stream_id,
                self.inbox_flow,
            ) catch |err| ignoreError(err);
        }
        if (self.chunk_flow != 0) {
            self.session.release(
                self.allocator,
                self.stream_id,
                self.chunk_flow,
            ) catch |err| ignoreError(err);
        }
        self.inbox_flow = 0;
        self.chunk_flow = 0;

        // An unfinished request body is abandoned with NO_ERROR, not CANCEL:
        // the response that arrived first is still the answer. An unfinished
        // response is CANCEL. Both sides done needs no reset at all.
        const code: ?frame.ErrorCode = if (!self.remote_end)
            .cancel
        else if (!self.request_closed)
            .no_error
        else
            null;
        if (code) |reset_code| {
            self.session.submitReset(
                self.allocator,
                self.stream_id,
                reset_code,
            ) catch |err| ignoreError(err);
            self.reset_sent = true;
        }
        self.flushFrames() catch |err| ignoreError(err);

        self.active = false;
        self.remote_end = false;
        self.body_eof = false;
        self.request_closed = false;
        self.response_taken = false;
        self.net_start = 0;
        self.net_end = 0;
        self.early_head = null;
        self.pending_body = &.{};
        self.inbox.clearRetainingCapacity();
        self.chunk.clearRetainingCapacity();
        _ = self.arena.reset(.free_all);
    }

    fn nextEvent(self: *Client) !Event {
        while (true) {
            const event = try self.session.nextEvent(self.allocator);
            if (event) |value| return value;
            try self.flushFrames();

            if (self.net_start < self.net_end) {
                const consumed = self.session.receive(
                    self.net_buffer[self.net_start..self.net_end],
                );
                if (consumed != 0) {
                    self.net_start += consumed;
                    if (self.net_start == self.net_end) {
                        self.net_start = 0;
                        self.net_end = 0;
                    }
                    continue;
                }
                const next = try self.session.nextEvent(self.allocator);
                if (next) |value| return value;
                if (self.session.isClosed()) {
                    self.connection_poisoned = true;
                    return error.ConnectionClosed;
                }
                return error.InputFull;
            }

            var vecs: [1][]u8 = .{&self.net_buffer};
            const n = self.reader.readVec(&vecs) catch |err| switch (err) {
                error.EndOfStream => {
                    self.connection_poisoned = true;
                    return error.EndOfStream;
                },
                error.ReadFailed => {
                    self.connection_poisoned = true;
                    return error.ReadFailed;
                },
            };
            if (n == 0) {
                // A buffered reader can satisfy readVec by filling its own
                // buffer and returning 0. That is not EOF; move those bytes.
                const buffered = self.reader.buffered();
                if (buffered.len == 0) {
                    self.connection_poisoned = true;
                    return error.EndOfStream;
                }
                const take = @min(buffered.len, self.net_buffer.len);
                @memcpy(self.net_buffer[0..take], buffered[0..take]);
                self.reader.toss(take);
                self.net_start = 0;
                self.net_end = take;
                continue;
            }
            self.net_start = 0;
            self.net_end = n;
        }
    }

    fn flushBytes(self: *Client) !void {
        var out: [4096]u8 = undefined;
        while (true) {
            const n = self.session.send(&out);
            if (n == 0) break;
            self.writer.writeAll(out[0..n]) catch |err| {
                self.connection_poisoned = true;
                return err;
            };
            self.output_written += n;
        }
        self.writer.flush() catch |err| {
            self.connection_poisoned = true;
            return err;
        };
    }

    fn flushFrames(self: *Client) !void {
        var out: [9 + 16 * 1024]u8 = undefined;
        while (true) {
            const n = try self.session.sendFrame(&out);
            if (n == 0) break;

            const end_headers = isEndHeaders(out[0..n], self.stream_id);
            if (self.request_state == .staged and !end_headers) {
                self.request_state = .in_flight;
            }
            self.writer.writeAll(out[0..n]) catch |err| {
                // writeAll may have accepted a prefix containing the complete
                // END_HEADERS frame. A non-idempotent request must not be
                // retried once that frame could be visible.
                if (end_headers and self.request_state != .committed) {
                    self.request_state = .committed;
                }
                return err;
            };
            self.writer.flush() catch |err| {
                if (end_headers and self.request_state != .committed) {
                    self.request_state = .committed;
                }
                return err;
            };
            self.output_written += n;
            if (end_headers and self.request_state != .committed) {
                self.request_state = .committed;
            }
        }
    }

    fn isEndHeaders(bytes: []const u8, stream_id: u31) bool {
        if (bytes.len < 9) return false;
        const frame_type = bytes[3];
        if (frame_type != 0x1 and frame_type != 0x9) return false;
        if (bytes[4] & 0x4 == 0) return false;
        const id = mem.readInt(u32, bytes[5..9], .big) & 0x7fff_ffff;
        return id == stream_id;
    }
};

fn ignoreError(_: anyerror) void {}

/// Test-only: write the next piece of the body into `out`, or return null at a
/// clean end. The writer never short-writes because each destination here is
/// exactly the size of the response.
fn readInto(body: Body, out: []u8) !?usize {
    // A fixed writer errors when it is full, so the room left is the limit.
    // Null means the body ended, or `out` had no room; every caller here sizes
    // `out` to what is left of the response, so the two coincide.
    if (out.len == 0) return null;
    var writer = Io.Writer.fixed(out);
    return body.reader.stream(&writer, .limited(out.len)) catch |err| switch (err) {
        error.EndOfStream => null,
        else => return err,
    };
}

/// The body stream. `Client.bodyReader` is the field this vtable is looked up
/// from, and the client never moves after `init`.
const body_reader_vtable: Io.Reader.VTable = .{
    .stream = Client.bodyStream,
};

const body_vtable: Body.VTable = .{
    .outcome = Client.bodyOutcome,
    .close = bodyClose,
};

fn bodyClose(ptr: *anyopaque) void {
    const self: *Client = @ptrCast(@alignCast(ptr));
    self.closeBody();
}

const body_writer_vtable: BodyWriter.VTable = .{
    .write = bodyWrite,
    .close = bodyWriterClose,
};

fn bodyWrite(ptr: *anyopaque, bytes: []const u8) shared.BodyWriteError!void {
    const self: *Client = @ptrCast(@alignCast(ptr));
    return self.writeBody(bytes);
}

fn bodyWriterClose(ptr: *anyopaque) void {
    const self: *Client = @ptrCast(@alignCast(ptr));
    self.closeRequestBody();
}

const TestApp = struct {
    body: []const u8,
    echo_request: bool = false,
    seen: usize = 0,

    fn handler(self: *TestApp) engine.Handler {
        return .{ .ptr = self, .vtable = &.{
            .handle = handle,
            .complete = engine.Handler.noopComplete,
            .report_error = reportError,
            .policy_response = engine.Handler.defaultPolicyResponse,
        } };
    }

    fn handle(ptr: *anyopaque, exchange: *engine.Exchange) anyerror!void {
        const self: *TestApp = @ptrCast(@alignCast(ptr));
        self.seen += 1;
        try exchange.respond(.{
            .status = .ok,
            .content_type = "text/plain",
        }, if (self.echo_request) exchange.request.body else self.body);
    }

    fn reportError(_: *anyopaque, _: anyerror) void {}
};

const Server = struct {
    io: Io,
    listener: *Io.net.Server,
    handler: engine.Handler,
    result: ?anyerror = null,

    fn run(self: *Server) void {
        const stream = self.listener.accept(self.io) catch |err| {
            self.result = err;
            return;
        };
        defer stream.close(self.io);
        var read_buffer: [4096]u8 = undefined;
        var write_buffer: [4096]u8 = undefined;
        engine.serve(self.io, stream, self.handler, .{
            .allocator = testing.allocator,
            .read_buffer = &read_buffer,
            .write_buffer = &write_buffer,
            .max_streams = 4,
            .common = .{ .body_bytes = 256 * 1024 },
        }) catch |err| {
            self.result = err;
        };
    }
};

const Harness = struct {
    io: Io,
    listener: Io.net.Server,
    address: Io.net.IpAddress,
    app: TestApp,
    server: Server,
    thread: std.Thread,
    allow_server_read_failed: bool = false,

    fn init(self: *Harness, body: []const u8) !void {
        return self.initEcho(body, false);
    }

    fn initEcho(self: *Harness, body: []const u8, echo: bool) !void {
        self.io = testing.io;
        self.app = .{ .body = body, .echo_request = echo };
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
            .handler = self.app.handler(),
        };
        self.thread = try .spawn(.{}, Server.run, .{&self.server});
    }

    fn deinit(self: *Harness) void {
        self.thread.join();
        self.listener.deinit(self.io);
        if (self.server.result) |err| {
            if (!(self.allow_server_read_failed and err == error.ReadFailed)) {
                std.debug.panic("server failed: {s}", .{@errorName(err)});
            }
        }
        self.* = undefined;
    }

    fn connect(self: *Harness) !Io.net.Stream {
        return self.address.connect(self.io, .{ .mode = .stream });
    }
};

test "the blocking client streams a response body" {
    const expected = "hello, streaming world";
    var harness: Harness = undefined;
    try harness.init(expected);
    defer harness.deinit();

    const stream = try harness.connect();
    defer stream.close(harness.io);

    var reader = stream.reader(harness.io, &.{});
    var write_buffer: [4096]u8 = undefined;
    var writer = stream.writer(harness.io, &write_buffer);

    var client: Client = undefined;
    try client.init(
        &reader.interface,
        &writer.interface,
        .{ .allocator = testing.allocator },
    );
    defer client.deinit();

    const response = try client.request(.{
        .method_token = "GET",
        .scheme = .http,
        .authority = "example.com",
        .target = "/",
    });
    defer response.body.close();
    try testing.expectEqual(RequestState.committed, client.commitState());

    try testing.expectEqual(Protocol.h2, response.head.protocol);
    try testing.expectEqual(@as(u16, 200), response.head.status.code());
    try testing.expectEqualStrings(
        "text/plain",
        response.head.headers.get("content-type").?,
    );

    var received: [expected.len]u8 = undefined;
    var used: usize = 0;
    while (try readInto(response.body, received[used..])) |n| used += n;
    try testing.expectEqual(@as(usize, expected.len), used);
    try testing.expectEqualStrings(expected, &received);
    try testing.expectEqualStrings(
        "text/plain",
        response.head.headers.get("content-type").?,
    );
    try testing.expectEqual(@as(usize, 1), harness.app.seen);
}

test "the blocking client releases flow control while streaming" {
    var big: [100 * 1024]u8 = undefined;
    for (&big, 0..) |*byte, index| byte.* = @intCast(index % 251);

    var harness: Harness = undefined;
    try harness.init(&big);
    defer harness.deinit();

    const stream = try harness.connect();
    defer stream.close(harness.io);

    var reader = stream.reader(harness.io, &.{});
    var write_buffer: [4096]u8 = undefined;
    var writer = stream.writer(harness.io, &write_buffer);

    var client: Client = undefined;
    try client.init(
        &reader.interface,
        &writer.interface,
        .{ .allocator = testing.allocator },
    );
    defer client.deinit();

    const response = try client.request(.{
        .method_token = "GET",
        .scheme = .http,
        .authority = "example.com",
        .target = "/",
    });
    defer response.body.close();

    var scratch: [64 * 1024]u8 = undefined;
    var offset: usize = 0;
    while (try readInto(response.body, &scratch)) |n| {
        try testing.expect(offset + n <= big.len);
        try testing.expectEqualSlices(u8, big[offset..][0..n], scratch[0..n]);
        offset += n;
    }
    try testing.expectEqual(big.len, offset);
}

test "the blocking client sends a request body" {
    var harness: Harness = undefined;
    try harness.initEcho("", true);
    defer harness.deinit();

    const stream = try harness.connect();
    defer stream.close(harness.io);

    var reader = stream.reader(harness.io, &.{});
    var write_buffer: [4096]u8 = undefined;
    var writer = stream.writer(harness.io, &write_buffer);

    var client: Client = undefined;
    try client.init(
        &reader.interface,
        &writer.interface,
        .{ .allocator = testing.allocator },
    );
    defer client.deinit();

    const payload = "request body";
    const response = try client.request(.{
        .method_token = "POST",
        .scheme = .http,
        .authority = "example.com",
        .target = "/",
        .body = payload,
    });
    defer response.body.close();

    var received: [payload.len]u8 = undefined;
    var used: usize = 0;
    while (try readInto(response.body, received[used..])) |n| used += n;
    try testing.expectEqualStrings(payload, received[0..used]);
}

test "the blocking client sends a request body through flow control" {
    var harness: Harness = undefined;
    try harness.initEcho("", true);
    defer harness.deinit();

    const stream = try harness.connect();
    defer stream.close(harness.io);

    var reader = stream.reader(harness.io, &.{});
    var write_buffer: [4096]u8 = undefined;
    var writer = stream.writer(harness.io, &write_buffer);

    var client: Client = undefined;
    try client.init(
        &reader.interface,
        &writer.interface,
        .{ .allocator = testing.allocator },
    );
    defer client.deinit();

    var payload: [100 * 1024]u8 = undefined;
    for (&payload, 0..) |*byte, index| byte.* = @intCast(index % 251);
    const response = try client.request(.{
        .method_token = "POST",
        .scheme = .http,
        .authority = "example.com",
        .target = "/",
        .body = &payload,
    });
    defer response.body.close();

    var scratch: [64 * 1024]u8 = undefined;
    var offset: usize = 0;
    while (try readInto(response.body, &scratch)) |n| {
        try testing.expectEqualSlices(u8, payload[offset..][0..n], scratch[0..n]);
        offset += n;
    }
    try testing.expectEqual(payload.len, offset);
}

test "closing an incomplete response resets the stream and is idempotent" {
    var big: [32 * 1024]u8 = undefined;
    @memset(&big, 'x');

    var harness: Harness = undefined;
    try harness.init(&big);
    harness.allow_server_read_failed = true;
    defer harness.deinit();

    const stream = try harness.connect();
    defer stream.close(harness.io);

    var reader = stream.reader(harness.io, &.{});
    var write_buffer: [4096]u8 = undefined;
    var writer = stream.writer(harness.io, &write_buffer);

    var client: Client = undefined;
    try client.init(
        &reader.interface,
        &writer.interface,
        .{ .allocator = testing.allocator },
    );
    defer client.deinit();

    const response = try client.request(.{
        .method_token = "GET",
        .scheme = .http,
        .authority = "example.com",
        .target = "/",
    });

    var scratch: [4096]u8 = undefined;
    try testing.expect((try readInto(response.body, &scratch)).? > 0);
    const stream_id = client.streamId();
    try testing.expect(stream_id != 0);
    response.body.close();
    try testing.expectEqual(stream_id, client.streamId());
    try testing.expect(client.reset_sent);
    response.body.close();
    try testing.expectEqual(@as(?usize, null), try readInto(response.body, &scratch));
}

test "connection poison is separate from request commit" {
    var reader = Io.Reader.failing;
    var out_buffer: [4096]u8 = undefined;
    var writer = Io.Writer.fixed(&out_buffer);

    var client: Client = undefined;
    try client.init(
        &reader,
        &writer,
        .{ .allocator = testing.allocator },
    );
    defer client.deinit();

    try testing.expectError(error.ReadFailed, client.request(.{
        .method_token = "POST",
        .scheme = .http,
        .authority = "example.com",
        .target = "/",
    }));
    try testing.expectEqual(RequestState.committed, client.commitState());
    try testing.expect(client.isConnectionPoisoned());
    try testing.expectError(error.ConnectionPoisoned, client.request(.{
        .method_token = "GET",
        .scheme = .http,
        .authority = "example.com",
        .target = "/",
    }));
}

test "a no-body response can be followed by another request" {
    var harness: Harness = undefined;
    try harness.init("");
    defer harness.deinit();

    const stream = try harness.connect();
    defer stream.close(harness.io);

    var reader = stream.reader(harness.io, &.{});
    var write_buffer: [4096]u8 = undefined;
    var writer = stream.writer(harness.io, &write_buffer);

    var client: Client = undefined;
    try client.init(
        &reader.interface,
        &writer.interface,
        .{ .allocator = testing.allocator },
    );
    defer client.deinit();

    for (0..2) |_| {
        const response = try client.request(.{
            .method_token = "GET",
            .scheme = .http,
            .authority = "example.com",
            .target = "/",
        });
        var scratch: [16]u8 = undefined;
        try testing.expectEqual(@as(?usize, null), try readInto(response.body, &scratch));
        response.body.close();
    }
    try testing.expectEqual(@as(usize, 2), harness.app.seen);
}

test "request validation happens before serialization" {
    var reader = Io.Reader.failing;
    var out_buffer: [4096]u8 = undefined;
    var writer = Io.Writer.fixed(&out_buffer);

    var client: Client = undefined;
    try client.init(
        &reader,
        &writer,
        .{ .allocator = testing.allocator },
    );
    defer client.deinit();

    try testing.expectError(error.DuplicateAuthority, client.request(.{
        .method_token = "GET",
        .scheme = .http,
        .authority = "example.com",
        .target = "/",
        .headers = &.{.{ .name = "Host", .value = "example.com" }},
    }));
    try testing.expectError(error.InvalidHeader, client.request(.{
        .method_token = "GET",
        .scheme = .http,
        .authority = "example.com",
        .target = "/",
        .headers = &.{.{ .name = "X-Test", .value = "one" }},
    }));
    try testing.expectError(error.InvalidHeader, client.request(.{
        .method_token = "GET",
        .scheme = .http,
        .authority = "example.com",
        .target = "/",
        .headers = &.{.{ .name = ":path", .value = "/" }},
    }));
}

test "closing after remote END_STREAM releases without resetting" {
    var body: [1024]u8 = undefined;
    @memset(&body, 'y');

    var harness: Harness = undefined;
    try harness.init(&body);
    harness.allow_server_read_failed = true;
    defer harness.deinit();

    const stream = try harness.connect();
    defer stream.close(harness.io);

    var reader = stream.reader(harness.io, &.{});
    var write_buffer: [4096]u8 = undefined;
    var writer = stream.writer(harness.io, &write_buffer);

    var client: Client = undefined;
    try client.init(
        &reader.interface,
        &writer.interface,
        .{ .allocator = testing.allocator },
    );
    defer client.deinit();

    const response = try client.request(.{
        .method_token = "GET",
        .scheme = .http,
        .authority = "example.com",
        .target = "/",
    });
    var scratch: [4096]u8 = undefined;
    try testing.expect((try readInto(response.body, &scratch)).? > 0);
    response.body.close();
    try testing.expect(!client.reset_sent);
    try testing.expectEqual(@as(?usize, null), try readInto(response.body, &scratch));
}

test "the blocking client sends a static request body" {
    var harness: Harness = undefined;
    try harness.init("body response");
    defer harness.deinit();

    const stream = try harness.connect();
    defer stream.close(harness.io);

    var reader = stream.reader(harness.io, &.{});
    var write_buffer: [4096]u8 = undefined;
    var writer = stream.writer(harness.io, &write_buffer);

    var client: Client = undefined;
    try client.init(
        &reader.interface,
        &writer.interface,
        .{ .allocator = testing.allocator },
    );
    defer client.deinit();

    const response = try client.request(.{
        .method_token = "POST",
        .scheme = .http,
        .authority = "example.com",
        .target = "/",
        .body = "hello",
    });
    try testing.expectEqual(Protocol.h2, response.head.protocol);
    var got: [13]u8 = undefined;
    var used: usize = 0;
    while (try readInto(response.body, got[used..])) |n| used += n;
    try testing.expectEqualStrings("body response", got[0..used]);
    response.body.close();
}

test "header snapshot enforces byte and field limits" {
    var reader = Io.Reader.failing;
    var out_buffer: [4096]u8 = undefined;
    var writer = Io.Writer.fixed(&out_buffer);

    var client: Client = undefined;
    try client.init(
        &reader,
        &writer,
        .{ .allocator = testing.allocator },
    );
    defer client.deinit();

    var fields = [_]Header{
        .{ .name = "content-type", .value = "text/plain" },
        .{ .name = "x-test", .value = "v" },
    };
    const fields_view: Headers = .{ .items = &fields };
    const total = "content-type".len + "text/plain".len +
        "x-test".len + "v".len;

    client.max_header_bytes = total;
    const head = try client.snapshot(fields_view);
    try testing.expectEqualStrings("text/plain", head.get("content-type").?);

    _ = client.arena.reset(.free_all);
    client.max_header_bytes = total - 1;
    try testing.expectError(error.HeadersTooLarge, client.snapshot(fields_view));

    client.max_header_bytes = total;
    client.max_headers = 1;
    try testing.expectError(error.HeadersTooLarge, client.snapshot(fields_view));
}

test "a failed END_HEADERS write is treated as committed" {
    var reader = Io.Reader.failing;
    var out_buffer: [4096]u8 = undefined;
    var writer = Io.Writer.fixed(&out_buffer);

    var client: Client = undefined;
    try client.init(
        &reader,
        &writer,
        .{ .allocator = testing.allocator },
    );
    defer client.deinit();

    var failing = Io.Writer.failing;
    client.writer = &failing;

    try testing.expectError(error.WriteFailed, client.request(.{
        .method_token = "POST",
        .scheme = .http,
        .authority = "example.com",
        .target = "/",
    }));
    try testing.expectEqual(RequestState.committed, client.commitState());
    try testing.expect(client.isConnectionPoisoned());
}

const LimitedWriter = struct {
    writer: Io.Writer,
    limit: usize,
    written: usize = 0,
    storage: [64 * 1024]u8 = undefined,

    const vtable: Io.Writer.VTable = .{ .drain = drain };

    fn init() LimitedWriter {
        return .{
            .writer = .{ .vtable = &vtable, .buffer = &.{} },
            .limit = 0,
        };
    }

    fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        _ = splat;
        const self: *LimitedWriter = @fieldParentPtr("writer", w);
        if (data.len == 0) return 0;
        const bytes = data[0];
        const room = if (self.written < self.limit) self.limit - self.written else 0;
        const take = @min(room, bytes.len);
        @memcpy(self.storage[self.written..][0..take], bytes[0..take]);
        self.written += take;
        if (take != bytes.len) return error.WriteFailed;
        return take;
    }
};

test "a split header run commits when END_HEADERS fails" {
    var reader = Io.Reader.failing;
    var limited = LimitedWriter.init();
    limited.limit = 1024 * 1024;

    var client: Client = undefined;
    try client.initOptions(
        &reader,
        &limited.writer,
        .{ .allocator = testing.allocator },
        .{ .role = .client, .max_send_header_block = 64 * 1024 },
    );
    defer client.deinit();

    limited.limit = limited.written + 9 + 16 * 1024 + 32;

    var value: [40 * 1024]u8 = undefined;
    for (&value, 0..) |*byte, index| byte.* = 'a' + @as(u8, @intCast(index % 26));
    const headers = [_]Header{
        .{ .name = "x-big", .value = &value },
    };

    try testing.expectError(error.WriteFailed, client.request(.{
        .method_token = "GET",
        .scheme = .http,
        .authority = "example.com",
        .target = "/",
        .headers = &headers,
    }));
    try testing.expectEqual(RequestState.committed, client.commitState());
    try testing.expect(client.isConnectionPoisoned());
}

test "informational response does not become the final head" {
    var payload: [100 * 1024]u8 = undefined;
    @memset(&payload, 'q');

    var server_bytes: [2048]u8 = undefined;
    var server_used: usize = 0;

    var settings_buffer: [64]u8 = undefined;
    var settings_writer = frame.Writer.init(&settings_buffer);
    try settings_writer.begin(.settings, 0, 0);
    settings_writer.end();
    const settings_bytes = settings_writer.written();
    @memcpy(server_bytes[server_used..][0..settings_bytes.len], settings_bytes);
    server_used += settings_bytes.len;

    var storage = try hpack.TableStorage.init(testing.allocator, 4096);
    defer storage.deinit(testing.allocator);
    var encoder = hpack.Encoder.init(storage);
    var block_buffer: [1024]u8 = undefined;
    var frame_buffer: [2048]u8 = undefined;

    const info = try encoder.encodeResponse(.{ .status = .@"continue" }, &block_buffer);
    var info_writer = frame.Writer.init(&frame_buffer);
    try info_writer.begin(.headers, frame.flags.end_headers, 1);
    try info_writer.bytes(info);
    info_writer.end();
    const info_bytes = info_writer.written();
    @memcpy(server_bytes[server_used..][0..info_bytes.len], info_bytes);
    server_used += info_bytes.len;

    const final = try encoder.encodeResponse(.{ .status = .ok }, &block_buffer);
    var final_writer = frame.Writer.init(&frame_buffer);
    try final_writer.begin(.headers, frame.flags.end_headers, 1);
    try final_writer.bytes(final);
    final_writer.end();
    const final_bytes = final_writer.written();
    @memcpy(server_bytes[server_used..][0..final_bytes.len], final_bytes);
    server_used += final_bytes.len;

    var reader = Io.Reader.fixed(server_bytes[0..server_used]);
    var output: [256 * 1024]u8 = undefined;
    var writer = Io.Writer.fixed(&output);

    var client: Client = undefined;
    try client.init(
        &reader,
        &writer,
        .{ .allocator = testing.allocator },
    );
    defer client.deinit();

    const response = try client.request(.{
        .method_token = "POST",
        .scheme = .http,
        .authority = "example.com",
        .target = "/",
        .body = &payload,
    });
    defer response.body.close();

    try testing.expectEqual(@as(u16, 200), response.head.status.code());
    // The server never released the request window. If request() had waited
    // for the body to drain, the whole 100 KiB would be in the writer.
    try testing.expect(writer.end < payload.len);
}
