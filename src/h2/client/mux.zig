//! A multiplexed HTTP/2 client: several requests in flight over one
//! connection, each on its own thread.
//!
//! `submit` queues a request and returns its `Stream`; `Stream.response` waits
//! for the head and `body.reader` waits for the body. A pump thread owns the
//! transport reads and feeds one `h2.Session`, so a slow body reader on one
//! stream does not stall another. All session access is under one lock; body
//! bytes are buffered per stream and charged to that stream's flow-control
//! window, so the peer stops sending on a stream nobody reads while the rest
//! of the connection keeps moving.
//!
//! The connection is owned: `deinit` shuts the transport down to unblock the
//! pump, joins it, then closes it. A `Stream`, `Response`, or `Body` is invalid
//! once the mux is deinitialized or its body is closed.
//!
//! The transport must accept reads and writes from different threads at the
//! same time. A cleartext socket does. `tls_nonblocking.SocketClient` does
//! not (all calls on one connection must be serial), so a TLS connection
//! needs the poll-driven pump this crate has not built yet; until then the
//! mux serves h2c.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const mem = std.mem;
const ascii = std.ascii;

const shared = @import("../../client/root.zig");
const time = @import("stdx").time;
const transport = @import("../../client/transport.zig");
const Header = @import("../../header.zig").Header;
const Headers = @import("../../header.zig").Headers;
const Status = @import("../../status.zig").Status;
const frame = @import("../frame.zig");
const session_mod = @import("../session.zig");
const Session = session_mod.Session;
const Event = session_mod.Event;

pub const Protocol = shared.Protocol;
pub const Request = shared.Request;
pub const Response = shared.Response;
pub const ResponseHead = shared.ResponseHead;
pub const Body = shared.Body;
pub const BodyWriter = shared.BodyWriter;

// ast-grep-ignore: public-struct-field-default -- options bag; defaults are the policy
pub const Options = struct {
    allocator: Allocator,
    /// Snapshot limits for response fields.
    max_header_bytes: usize = 16 * 1024,
    max_headers: usize = 128,
    /// Local streams this client offers to have open at once.
    max_streams: u16 = 32,
    /// Deadline for the pump's transport reads. `.none` waits until the
    /// connection closes; per-request deadlines stop their own stream.
    read_deadline: time.OptionalTimestamp = .none,
};

/// One request and its response.
pub const Stream = struct {
    mux: *Mux,
    id: u31,
    deadline: time.OptionalTimestamp,
    arena: std.heap.ArenaAllocator,
    head: ?ResponseHead,
    /// A failure that ended the stream, from a reset, a GOAWAY, or the
    /// connection.
    failed: ?anyerror,
    reset_code: ?u32,
    /// Response bytes delivered by the pump and not yet handed to the caller.
    data: std.ArrayList(u8),
    data_start: usize,
    /// Bytes still charged to this stream's receive window.
    stream_charge: u32,
    remote_end: bool,
    request_closed: bool,
    response_taken: bool,
    /// Static request-body bytes the peer's window has not taken yet. They go
    /// out as the caller consumes the response, so a peer that answers before
    /// reading the body cannot wedge the request.
    pending: []const u8,
    /// Set by `Body.close`.
    user_done: bool,
    body_outcome: ?shared.Outcome,
    cond: Io.Condition,
    body: Body,
    body_reader: Io.Reader,
    writer: BodyWriter,

    /// Wait for the response head.
    pub fn response(self: *Stream) !Response {
        const mux = self.mux;
        mux.mutex.lockUncancelable(mux.io);
        defer mux.mutex.unlock(mux.io);

        while (self.head == null) {
            if (self.failed) |err| return mapHeadError(err);
            if (mux.fatal) |err| return mapHeadError(err);
            try self.checkDeadlineLocked();
            mux.waitLocked(&self.cond, self.deadline) catch |err| switch (err) {
                error.Timeout => {
                    self.timeoutLocked();
                    return error.TimedOut;
                },
                error.Canceled => return error.Canceled,
            };
        }
        if (self.response_taken) return error.ResponseTaken;
        self.response_taken = true;
        return .{ .head = self.head.?, .body = self.body };
    }

    /// A writer for a request body after `Mux.begin`.
    pub fn bodyWriter(self: *Stream) BodyWriter {
        return self.writer;
    }

    /// Drop the exchange, resetting the stream when it is unfinished.
    pub fn abort(self: *Stream) void {
        const mux = self.mux;
        mux.mutex.lockUncancelable(mux.io);
        defer mux.mutex.unlock(mux.io);
        self.closeLocked();
    }

    fn mapHeadError(err: anyerror) anyerror {
        return switch (err) {
            error.Reset => error.StreamReset,
            error.GoAway => error.GoAway,
            error.EndOfStream, error.ConnectionClosed, error.ReadFailed => error.ConnectionClosed,
            else => err,
        };
    }

    fn checkDeadlineLocked(self: *Stream) !void {
        const deadline = self.deadline.get() orelse return;
        if (time.now(.awake).nanoseconds < deadline.nanoseconds) return;
        self.timeoutLocked();
        return error.TimedOut;
    }

    fn timeoutLocked(self: *Stream) void {
        self.body_outcome = .{ .local = .timed_out };
        self.failed = error.TimedOut;
        self.resetLocked(.cancel);
    }

    fn resetLocked(self: *Stream, code: frame.ErrorCode) void {
        self.mux.session.submitReset(self.mux.allocator, self.id, code) catch return;
        self.mux.flushLocked() catch |err| ignoreError(err);
    }

    fn closeLocked(self: *Stream) void {
        const mux = self.mux;
        if (self.user_done) return;
        self.user_done = true;

        // Return the credit for bytes nobody will read, so the peer stops
        // sending on a stream that is gone.
        if (self.stream_charge != 0) {
            mux.session.releaseStream(mux.allocator, self.id, self.stream_charge) catch |err|
                ignoreError(err);
            self.stream_charge = 0;
        }
        const code: ?frame.ErrorCode = if (!self.remote_end)
            .cancel
        else if (!self.request_closed)
            .no_error
        else
            null;
        if (code) |reset_code| mux.session.submitReset(
            mux.allocator,
            self.id,
            reset_code,
        ) catch |err| ignoreError(err);
        mux.flushLocked() catch |err| ignoreError(err);
        mux.removeStream(self);
    }

    fn readBody(self: *Stream, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const mux = self.mux;
        mux.mutex.lockUncancelable(mux.io);
        defer mux.mutex.unlock(mux.io);

        const cap = limit.minInt(std.math.maxInt(usize));
        if (cap == 0) return 0;

        while (true) {
            const available = self.data.items[self.data_start..];
            if (available.len != 0) {
                const take = available[0..@min(available.len, cap)];
                const n = w.write(take) catch return error.WriteFailed;
                if (n == 0) return error.WriteFailed;
                self.data_start += n;
                if (self.stream_charge >= n) self.stream_charge -= @intCast(n);
                mux.session.releaseStream(mux.allocator, self.id, @intCast(n)) catch |err|
                    ignoreError(err);
                mux.flushLocked() catch |err| ignoreError(err);
                return n;
            }
            if (self.failed) |err| return self.failBody(err);
            if (mux.fatal) |err| return self.failBody(err);
            if (self.remote_end) return error.EndOfStream;

            if (self.pending.len != 0) {
                const accepted = mux.session.submitData(
                    mux.allocator,
                    self.id,
                    self.pending,
                    true,
                ) catch |err| return self.failBody(err);
                if (accepted != 0) {
                    self.pending = self.pending[accepted..];
                    mux.flushLocked() catch |err| return self.failBody(err);
                    if (self.pending.len == 0) self.request_closed = true;
                    continue;
                }
            }

            mux.waitLocked(&self.cond, self.deadline) catch |err| switch (err) {
                error.Timeout => {
                    self.timeoutLocked();
                    return error.ReadFailed;
                },
                error.Canceled => return self.failBody(error.Canceled),
            };
        }
    }

    fn failBody(self: *Stream, err: anyerror) error{ReadFailed} {
        self.body_outcome = classify(err, self.reset_code);
        return error.ReadFailed;
    }

    fn bodyOutcome(ptr: *anyopaque) ?shared.Outcome {
        const self: *Stream = @ptrCast(@alignCast(ptr));
        return self.body_outcome;
    }

    fn writeBody(self: *Stream, bytes: []const u8) shared.BodyWriteError!void {
        const mux = self.mux;
        mux.mutex.lockUncancelable(mux.io);
        defer mux.mutex.unlock(mux.io);

        if (self.user_done or self.request_closed) return error.Closed;
        var offset: usize = 0;
        while (offset < bytes.len) {
            if (self.failed != null) return error.Reset;
            if (mux.fatal != null) return error.Truncated;
            const accepted = mux.session.submitData(
                mux.allocator,
                self.id,
                bytes[offset..],
                false,
            ) catch |err| return writeFailure(err);
            if (accepted != 0) {
                offset += accepted;
                mux.flushLocked() catch |err| return writeFailure(err);
                continue;
            }
            mux.waitLocked(&self.cond, self.deadline) catch |err| switch (err) {
                error.Timeout => {
                    self.timeoutLocked();
                    return error.Reset;
                },
                error.Canceled => return error.Reset,
            };
        }
    }

    fn closeRequestBody(self: *Stream) void {
        const mux = self.mux;
        mux.mutex.lockUncancelable(mux.io);
        defer mux.mutex.unlock(mux.io);

        if (self.user_done or self.request_closed) return;
        self.request_closed = true;
        _ = mux.session.submitData(mux.allocator, self.id, &.{}, true) catch return;
        mux.flushLocked() catch |err| ignoreError(err);
    }
};

pub const Mux = struct {
    io: Io,
    allocator: Allocator,
    connection: transport.Connection,
    session: Session,
    options: Options,
    mutex: Io.Mutex,
    streams: std.AutoHashMapUnmanaged(u31, *Stream),
    stopped: bool,
    fatal: ?anyerror,
    goaway: ?shared.GoAway,
    output_written: u64,
    net_buffer: [4096]u8,
    thread: ?std.Thread,

    /// Allocate a mux and take ownership of an established h2 connection.
    pub fn create(
        allocator: Allocator,
        io: Io,
        connection: transport.Connection,
        options: Options,
    ) !*Mux {
        const self = try allocator.create(Mux);
        errdefer allocator.destroy(self);
        try self.init(allocator, io, connection, options);
        return self;
    }

    /// Initialize in its final location. The pump thread takes `self`, so the
    /// mux must not move afterwards.
    pub fn init(
        self: *Mux,
        allocator: Allocator,
        io: Io,
        connection: transport.Connection,
        options: Options,
    ) !void {
        self.* = .{
            .io = io,
            .allocator = allocator,
            .connection = connection,
            .options = options,
            .session = try .init(allocator, .{
                .role = .client,
                .max_streams = options.max_streams,
            }),
            .mutex = .init,
            .streams = .empty,
            .stopped = false,
            .fatal = null,
            .goaway = null,
            .output_written = 0,
            .net_buffer = undefined,
            .thread = null,
        };
        errdefer self.session.deinit(allocator);
        try self.connection.setDeadline(options.read_deadline);
        try self.flushPreface();
        self.thread = try .spawn(.{}, pump, .{self});
    }

    pub fn deinit(self: *Mux) void {
        self.mutex.lockUncancelable(self.io);
        self.stopped = true;
        self.broadcastAllLocked();
        self.mutex.unlock(self.io);
        // Shutdown wakes the pump's blocked read; close alone does not. Join
        // before deinit, because the pump finishes its read call on the
        // connection's own reader state.
        self.connection.shutdown();
        if (self.thread) |thread| thread.join();
        self.thread = null;
        self.connection.deinit();
        var it = self.streams.valueIterator();
        while (it.next()) |stream| self.destroyStream(stream.*);
        self.streams.deinit(self.allocator);
        self.session.deinit(self.allocator);
        self.* = undefined;
    }

    /// Free a mux made with `create`. The connection was consumed by `init`.
    pub fn destroy(self: *Mux) void {
        const allocator = self.allocator;
        self.deinit();
        allocator.destroy(self);
    }

    /// Queue a request, send its body as far as flow control allows, and
    /// return its stream. `response` waits for the head.
    pub fn submit(self: *Mux, value: Request, deadline: time.OptionalTimestamp) !*Stream {
        const stream = try self.start(value, deadline, value.body.len);
        errdefer stream.abort();

        if (value.body.len != 0) try self.sendStaticBody(stream, value.body);
        return stream;
    }

    /// Queue a request head without END_STREAM and return its stream. The
    /// caller writes the body through `Stream.bodyWriter` and closes it.
    pub fn begin(self: *Mux, value: Request, deadline: time.OptionalTimestamp) !*Stream {
        if (value.body.len != 0) return error.BodyNotAllowed;
        return self.start(value, deadline, 0);
    }

    /// `submit` and wait for the head in one call.
    pub fn request(self: *Mux, value: Request, deadline: time.OptionalTimestamp) !Response {
        const stream = try self.submit(value, deadline);
        errdefer stream.abort();
        return stream.response();
    }

    /// True when the connection can take another request.
    pub fn reusable(self: *const Mux) bool {
        return !self.stopped and self.fatal == null and self.goaway == null;
    }

    /// The last GOAWAY the peer sent, if any.
    pub fn goAway(self: *const Mux) ?shared.GoAway {
        return self.goaway;
    }

    fn start(
        self: *Mux,
        value: Request,
        deadline: time.OptionalTimestamp,
        content_length: usize,
    ) !*Stream {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.stopped) return error.ConnectionClosed;
        if (self.fatal) |err| return err;
        if (self.goaway != null) return error.GoAway;
        if (value.authority.len == 0) return error.InvalidAuthority;

        const fields = try self.requestFields(value, content_length);
        defer self.allocator.free(fields);

        const end_stream = content_length == 0;
        const id = try self.session.submitRequest(self.allocator, fields, end_stream);
        errdefer self.session.submitReset(self.allocator, id, .cancel) catch {};
        const stream = try self.createStream(id, deadline);
        try self.flushLocked();
        return stream;
    }

    fn requestFields(self: *Mux, value: Request, content_length: usize) ![]Header {
        var has_length = false;
        for (value.headers) |header| {
            if (ascii.eqlIgnoreCase(header.name, "content-length")) has_length = true;
        }
        const add_length = content_length != 0 and !has_length;
        const count = 4 + value.headers.len + @as(usize, if (add_length) 1 else 0);
        const fields = try self.allocator.alloc(Header, count);
        errdefer self.allocator.free(fields);

        fields[0] = .{ .name = ":method", .value = value.method.token() };
        fields[1] = .{ .name = ":scheme", .value = value.scheme.token() };
        fields[2] = .{ .name = ":authority", .value = value.authority };
        fields[3] = .{ .name = ":path", .value = value.target };
        for (value.headers, 0..) |header, index| {
            if (ascii.eqlIgnoreCase(header.name, "host")) return error.DuplicateAuthority;
            if (!validLowerHeaderName(header.name)) return error.InvalidHeader;
            fields[4 + index] = header;
        }
        if (add_length) {
            var text: [20]u8 = undefined;
            const length_text = try mem.print(&text, "{d}", .{content_length});
            fields[count - 1] = .{ .name = "content-length", .value = length_text };
        }
        return fields;
    }

    fn createStream(
        self: *Mux,
        id: u31,
        deadline: time.OptionalTimestamp,
    ) !*Stream {
        const stream = try self.allocator.create(Stream);
        stream.* = .{
            .mux = self,
            .id = id,
            .deadline = deadline,
            .arena = .init(self.allocator),
            .head = null,
            .failed = null,
            .reset_code = null,
            .data = .empty,
            .data_start = 0,
            .stream_charge = 0,
            .remote_end = false,
            .request_closed = false,
            .response_taken = false,
            .pending = &.{},
            .user_done = false,
            .body_outcome = null,
            .cond = .init,
            .body = undefined,
            .body_reader = undefined,
            .writer = undefined,
        };
        errdefer {
            stream.arena.deinit();
            self.allocator.destroy(stream);
        }
        stream.body = .{ .ptr = stream, .vtable = &body_vtable, .reader = &stream.body_reader };
        stream.body_reader = .{
            .vtable = &body_reader_vtable,
            .buffer = &.{},
            .seek = 0,
            .end = 0,
        };
        stream.writer = .{ .ptr = stream, .vtable = &body_writer_vtable };
        try self.streams.put(self.allocator, id, stream);
        return stream;
    }

    fn sendStaticBody(self: *Mux, stream: *Stream, body: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var offset: usize = 0;
        while (offset < body.len) {
            if (stream.failed) |err| return err;
            // A head that arrived first is the answer; the rest of the body
            // is dribbled out by the body reader.
            if (stream.head != null) {
                stream.pending = body[offset..];
                return;
            }
            const accepted = self.session.submitData(
                self.allocator,
                stream.id,
                body[offset..],
                true,
            ) catch |err| {
                stream.failed = err;
                return err;
            };
            if (accepted != 0) {
                offset += accepted;
                if (offset == body.len) stream.request_closed = true;
                try self.flushLocked();
                continue;
            }
            self.waitLocked(&stream.cond, stream.deadline) catch |err| switch (err) {
                error.Timeout => {
                    stream.timeoutLocked();
                    return error.TimedOut;
                },
                error.Canceled => return error.Canceled,
            };
        }
        try self.flushLocked();
    }

    // Pump

    fn pump(self: *Mux) void {
        while (true) {
            self.mutex.lockUncancelable(self.io);
            if (self.stopped) {
                self.mutex.unlock(self.io);
                return;
            }
            if (self.flushLocked()) |_| {} else |err| {
                self.failLocked(err);
                self.mutex.unlock(self.io);
                return;
            }
            self.mutex.unlock(self.io);

            var vecs: [1][]u8 = .{&self.net_buffer};
            const n = self.connection.reader.readVec(&vecs) catch |err| {
                self.failFromPump(err);
                return;
            };
            if (n == 0) {
                const buffered = self.connection.reader.buffered();
                if (buffered.len == 0) {
                    self.failFromPump(error.EndOfStream);
                    return;
                }
                const take = @min(buffered.len, self.net_buffer.len);
                @memcpy(self.net_buffer[0..take], buffered[0..take]);
                self.connection.reader.toss(take);
                self.feed(take) catch return;
                continue;
            }
            self.feed(n) catch return;
        }
    }

    fn feed(self: *Mux, len: usize) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.stopped) return;

        var offset: usize = 0;
        while (offset < len) {
            const consumed = self.session.receive(self.net_buffer[offset..len]);
            offset += consumed;
            self.drainEventsLocked() catch |err| {
                self.failLocked(err);
                return;
            };
            if (consumed == 0) {
                self.failLocked(error.InputFull);
                return;
            }
        }
        if (self.flushLocked()) |_| {} else |err| {
            self.failLocked(err);
            return;
        }
    }

    fn drainEventsLocked(self: *Mux) !void {
        while (try self.session.nextEvent(self.allocator)) |event| {
            try self.dispatchLocked(event);
        }
    }

    fn dispatchLocked(self: *Mux, event: Event) !void {
        switch (event) {
            .response => |value| {
                const stream = self.streams.get(value.stream_id) orelse return;
                if (value.head.status.class() == .informational) return;
                if (stream.head != null) return error.UnexpectedResponse;
                const headers = self.snapshot(stream, value.head.headers) catch |err| {
                    // Over the limit: end this stream, keep the connection.
                    stream.failed = err;
                    stream.resetLocked(.enhance_your_calm);
                    self.broadcast(stream);
                    return;
                };
                stream.head = .{
                    .protocol = .h2,
                    .status = value.head.status,
                    .headers = headers,
                };
                if (value.end_stream) stream.remote_end = true;
                self.broadcast(stream);
            },
            .data => |value| {
                const stream = self.streams.get(value.stream_id) orelse return;
                try stream.data.appendSlice(self.allocator, value.bytes);
                stream.stream_charge += @intCast(value.bytes.len);
                // The connection window is ours to return on arrival; the
                // stream window stays charged until the caller reads.
                self.session.releaseConnection(
                    self.allocator,
                    @intCast(value.bytes.len),
                ) catch |err| ignoreError(err);
                if (value.end_stream) stream.remote_end = true;
                self.broadcast(stream);
            },
            .trailers => |value| {
                const stream = self.streams.get(value.stream_id) orelse return;
                if (value.end_stream) stream.remote_end = true;
                self.broadcast(stream);
            },
            .reset => |value| {
                const stream = self.streams.get(value.stream_id) orelse return;
                stream.reset_code = @backingInt(value.code);
                stream.failed = error.Reset;
                stream.remote_end = true;
                self.broadcast(stream);
            },
            .window_update => |value| {
                if (value.stream_id == 0) {
                    self.broadcastAllLocked();
                } else if (self.streams.get(value.stream_id)) |stream| {
                    self.broadcast(stream);
                }
            },
            .settings => {},
            .goaway => |value| {
                self.goaway = .{
                    .last_stream_id = value.last_stream_id,
                    .code = @backingInt(value.code),
                };
                var it = self.streams.valueIterator();
                while (it.next()) |stream| {
                    if (stream.*.id > value.last_stream_id) {
                        stream.*.failed = error.GoAway;
                    }
                }
                self.broadcastAllLocked();
            },
            .connection_error => return error.ConnectionError,
            .request => return error.UnexpectedRequest,
        }
    }

    fn snapshot(self: *Mux, stream: *Stream, headers: Headers) !Headers {
        if (headers.items.len > self.options.max_headers) return error.HeadersTooLarge;
        var total: usize = 0;
        for (headers.items) |header| {
            total = std.math.add(usize, total, header.name.len) catch
                return error.HeadersTooLarge;
            total = std.math.add(usize, total, header.value.len) catch
                return error.HeadersTooLarge;
        }
        if (total > self.options.max_header_bytes) return error.HeadersTooLarge;

        const arena = stream.arena.allocator();
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

    // Shared state

    fn broadcast(self: *Mux, stream: *Stream) void {
        stream.cond.broadcast(self.io);
    }

    fn broadcastAllLocked(self: *Mux) void {
        var it = self.streams.valueIterator();
        while (it.next()) |stream| stream.*.cond.broadcast(self.io);
    }

    fn waitLocked(
        self: *Mux,
        cond: *Io.Condition,
        deadline: time.OptionalTimestamp,
    ) (error{Timeout} || error{Canceled})!void {
        const timeout: Io.Timeout = if (deadline.get()) |ts|
            .{ .deadline = .{ .raw = .{ .nanoseconds = ts.nanoseconds }, .clock = .awake } }
        else
            .none;
        cond.waitTimeout(self.io, &self.mutex, timeout) catch |err| switch (err) {
            error.Timeout => return error.Timeout,
            error.Canceled => return error.Canceled,
        };
    }

    fn failLocked(self: *Mux, err: anyerror) void {
        if (self.fatal == null) self.fatal = err;
        self.broadcastAllLocked();
    }

    fn failFromPump(self: *Mux, err: anyerror) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.stopped) return;
        self.failLocked(err);
    }

    fn removeStream(self: *Mux, stream: *Stream) void {
        _ = self.streams.remove(stream.id);
        self.destroyStream(stream);
    }

    fn destroyStream(self: *Mux, stream: *Stream) void {
        stream.data.deinit(self.allocator);
        stream.arena.deinit();
        self.allocator.destroy(stream);
    }

    fn flushLocked(self: *Mux) !void {
        var out: [9 + 16 * 1024]u8 = undefined;
        while (true) {
            const n = try self.session.sendFrame(&out);
            if (n == 0) break;
            try self.connection.writer.writeAll(out[0..n]);
            try self.connection.writer.flush();
            self.output_written += n;
        }
    }

    fn flushPreface(self: *Mux) !void {
        var out: [4096]u8 = undefined;
        while (true) {
            const n = self.session.send(&out);
            if (n == 0) break;
            try self.connection.writer.writeAll(out[0..n]);
            try self.connection.writer.flush();
            self.output_written += n;
        }
        try self.flushLocked();
    }
};

fn classify(err: anyerror, reset_code: ?u32) shared.Outcome {
    return switch (err) {
        error.Reset => .{ .reset = reset_code orelse 0 },
        error.TimedOut => .{ .local = .timed_out },
        error.Canceled => .{ .local = .canceled },
        error.OutOfMemory => .{ .local = .out_of_memory },
        error.BufferTooSmall, error.InputFull => .{ .local = .capacity },
        else => .truncated,
    };
}

fn writeFailure(err: anyerror) shared.BodyWriteError {
    return switch (err) {
        error.Reset => error.Reset,
        error.OutOfMemory => error.LocalOutOfMemory,
        error.ProtocolError, error.UnexpectedData, error.UnexpectedResponse => error.Protocol,
        else => error.Truncated,
    };
}

fn ignoreError(_: anyerror) void {}

fn validLowerHeaderName(name: []const u8) bool {
    if (name.len == 0 or name[0] == ':') return false;
    for (name) |byte| {
        if (byte >= 'A' and byte <= 'Z') return false;
    }
    return true;
}

const body_vtable: Body.VTable = .{
    .outcome = Stream.bodyOutcome,
    .close = bodyClose,
    .abort = bodyClose,
};

fn bodyClose(ptr: *anyopaque) void {
    const stream: *Stream = @ptrCast(@alignCast(ptr));
    stream.abort();
}

fn bodyReaderStream(
    erased: *Io.Reader,
    w: *Io.Writer,
    limit: Io.Limit,
) Io.Reader.StreamError!usize {
    const stream: *Stream = @alignCast(@fieldParentPtr("body_reader", erased));
    return stream.readBody(w, limit);
}

const body_reader_vtable: Io.Reader.VTable = .{ .stream = bodyReaderStream };

const body_writer_vtable: BodyWriter.VTable = .{
    .write = bodyWrite,
    .close = bodyWriterClose,
};

fn bodyWrite(ptr: *anyopaque, bytes: []const u8) shared.BodyWriteError!void {
    const stream: *Stream = @ptrCast(@alignCast(ptr));
    return stream.writeBody(bytes);
}

fn bodyWriterClose(ptr: *anyopaque) void {
    const stream: *Stream = @ptrCast(@alignCast(ptr));
    stream.closeRequestBody();
}

// Tests

const testing = std.testing;
const engine = @import("../engine/direct.zig");

const TestApp = struct {
    fn handler(self: *TestApp) engine.Handler {
        return .{ .ptr = self, .vtable = &.{
            .handle = handle,
            .complete = engine.Handler.noopComplete,
            .report_error = reportError,
            .policy_response = engine.Handler.defaultPolicyResponse,
        } };
    }

    fn handle(ptr: *anyopaque, exchange: *engine.Exchange) anyerror!void {
        _ = ptr;
        try exchange.respond(.{
            .status = .ok,
            .content_type = "text/plain",
        }, "stream ok");
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
            .max_streams = 8,
            .common = .{ .body_bytes = 256 * 1024 },
        }) catch |err| {
            self.result = err;
        };
    }
};

const TestConnection = struct {
    io: Io,
    stream: Io.net.Stream,
    read_buffer: [4096]u8 = undefined,
    write_buffer: [4096]u8 = undefined,
    read_state: Io.net.Stream.Reader = undefined,
    write_state: Io.net.Stream.Writer = undefined,

    fn init(self: *TestConnection, io: Io, stream: Io.net.Stream) void {
        self.io = io;
        self.stream = stream;
        self.read_state = stream.reader(io, &self.read_buffer);
        self.write_state = stream.writer(io, &self.write_buffer);
    }

    fn connection(self: *TestConnection) transport.Connection {
        return .{
            .reader = &self.read_state.interface,
            .writer = &self.write_state.interface,
            .protocol = .h2,
            .ptr = self,
            .vtable = &vtable,
        };
    }

    const vtable: transport.Connection.VTable = .{
        .deinit = closeTransport,
        .shutdown = shutdown,
        .setDeadline = setDeadline,
        .readCause = readCause,
        .writeCause = writeCause,
        .setCancel = setCancel,
    };

    fn closeTransport(ptr: *anyopaque) void {
        const self: *TestConnection = @ptrCast(@alignCast(ptr));
        self.stream.close(self.io);
        self.* = undefined;
    }

    fn shutdown(ptr: *anyopaque) void {
        const self: *TestConnection = @ptrCast(@alignCast(ptr));
        self.stream.shutdown(self.io, .both) catch |err| ignoreError(err);
    }

    fn setDeadline(_: *anyopaque, _: time.OptionalTimestamp) error{DeadlineUnsupported}!void {}

    fn readCause(_: *const anyopaque) ?anyerror {
        return null;
    }

    fn writeCause(_: *const anyopaque) ?anyerror {
        return null;
    }

    fn setCancel(_: *anyopaque, _: ?transport.Progress) void {}
};

const Harness = struct {
    io: Io,
    listener: Io.net.Server,
    address: Io.net.IpAddress,
    app: TestApp,
    server: Server,
    thread: std.Thread,

    fn init(self: *Harness) !void {
        self.io = testing.io;
        self.app = .{};
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
        if (self.server.result) |err| switch (err) {
            error.ReadFailed, error.EndOfStream => {},
            else => std.debug.panic("server failed: {s}", .{@errorName(err)}),
        };
        self.* = undefined;
    }

    fn connect(self: *Harness) !Io.net.Stream {
        return self.address.connect(self.io, .{ .mode = .stream });
    }
};

const Worker = struct {
    mux: *Mux,
    body: []const u8,
    err: ?anyerror = null,

    fn run(self: *Worker) void {
        const stream = self.mux.submit(.{
            .method = .GET,
            .scheme = .http,
            .authority = "127.0.0.1",
            .target = "/",
        }, .none) catch |err| {
            self.err = err;
            return;
        };
        var response = stream.response() catch |err| {
            self.err = err;
            return;
        };
        defer response.body.close();

        var buffer: [256]u8 = undefined;
        var writer = Io.Writer.fixed(&buffer);
        const n = response.body.reader.streamRemaining(&writer) catch |err| {
            self.err = err;
            return;
        };
        if (!mem.eql(u8, buffer[0..n], "stream ok")) self.err = error.WrongBody;
    }
};

test "concurrent streams share one connection" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var transport_connection: TestConnection = undefined;
    transport_connection.init(testing.io, try harness.connect());

    const mux = try Mux.create(
        testing.allocator,
        testing.io,
        transport_connection.connection(),
        .{ .allocator = testing.allocator, .max_streams = 8 },
    );
    defer mux.destroy();

    const bodies = [_][]const u8{
        "first request body",
        "second request body",
        "third request body",
        "fourth request body",
    };
    var workers: [bodies.len]Worker = undefined;
    var threads: [bodies.len]std.Thread = undefined;
    for (bodies, 0..) |body, index| {
        workers[index] = .{ .mux = mux, .body = body };
        threads[index] = try .spawn(.{}, Worker.run, .{&workers[index]});
    }
    for (threads) |thread| thread.join();
    for (workers) |worker| {
        if (worker.err) |err| return err;
    }
}
