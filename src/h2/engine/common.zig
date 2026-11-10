//! Types shared by the HTTP/2 server engines.
//!
//! The engine buffers one request and hands it to the handler as an
//! `Exchange`. The exchange arena owns the copied head, trailers, and request
//! body; it stays valid until `complete` returns. The response body is
//! borrowed, so it must stay valid until the engine has queued it.
//!
//! A streaming engine runs the handler on the request head instead of on the
//! complete body. The handler then reads the body a chunk at a time through
//! `request_body` and may write response bytes before the request ends:
//!
//!     fn handle(_: *anyopaque, exchange: *Exchange) anyerror!void {
//!         while (true) {
//!             const chunk = exchange.request_body.?.next() catch |err| switch (err) {
//!                 error.Pending => return exchange.waitForProgress(),
//!                 error.EndOfStream => return exchange.endResponse(&.{...}),
//!                 error.Canceled => return,
//!                 else => return err,
//!             };
//!             if (!exchange.response_started) {
//!                 try exchange.beginResponse(.{ .status = .ok });
//!             }
//!             var rest = chunk.data;
//!             while (rest.len != 0) {
//!                 const written = try exchange.write(rest);
//!                 if (written == 0) return exchange.waitForProgress();
//!                 rest = rest[written..];
//!             }
//!         }
//!     }
//!
//! `handle` is re-entered on the next turn instead of being parked on a stack
//! frame: the engine calls it again when the body has bytes, the request ends,
//! or response output drains. Keep cross-turn state in the handler, not in
//! locals.

const std = @import("std");
const Allocator = std.mem.Allocator;
const time = @import("stdx").time;

const Header = @import("../../header.zig").Header;
const Headers = @import("../../header.zig").Headers;
const head = @import("../head.zig");
const frame = @import("../frame.zig");
const common = @import("../../engine/common.zig");
pub const stream = @import("../../engine/stream.zig");

pub const ResponseOptions = common.ResponseOptions;

/// A type-erased HTTP/2 handler over this engine's exchange.
pub const Handler = common.Handler(Exchange);

/// One complete request, copied into the exchange arena.
pub const Request = struct {
    head: head.RequestHead,
    /// The whole request body, up to `Config.body_bytes`. Empty when the
    /// engine streams; use `Exchange.request_body` instead.
    body: []const u8,
    /// The trailer section, empty when the request had none.
    trailers: Headers,
};

/// The engine behind `beginResponse`, `write`, `endResponse`, and
/// `resetStream`. The connection supplies one per slot; a handler never
/// builds one.
pub const Sink = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Queue a complete response from a borrowed slice: the buffered path.
        buffered: *const fn (
            ptr: *anyopaque,
            options: ResponseOptions,
            body: []const u8,
        ) SinkError!void,
        /// Queue the response head without END_STREAM.
        begin: *const fn (ptr: *anyopaque, options: ResponseOptions) SinkError!void,
        /// Queue as much of `bytes` as flow control and the output budget
        /// accept. Returns the accepted count; the caller keeps the rest.
        write: *const fn (ptr: *anyopaque, bytes: []const u8) SinkError!usize,
        /// Queue the last body byte, or a trailer section, and END_STREAM.
        end: *const fn (ptr: *anyopaque, trailers: []const Header) SinkError!void,
        /// Queue RST_STREAM. The exchange completes after `handle` returns.
        reset: *const fn (ptr: *anyopaque, code: frame.ErrorCode) SinkError!void,
    };

    /// A local failure or a closed stream, not a peer outcome. A reset stream
    /// reports `StreamClosed`; the reset code is on the peer's frame.
    pub const SinkError = error{
        ResponseNotStarted,
        ResponseEnded,
        StreamClosed,
        ConnectionClosed,
        WouldBlock,
        InvalidResponse,
        OutOfMemory,
    };
};

/// Why the engine called the handler on this turn.
pub const WakeReason = enum {
    /// The request head, body data, END_STREAM, or drained response output.
    progress,
    /// The deadline the handler armed has passed. The engine clears it before
    /// the call, so a handler that parks again without arming a new one makes
    /// progress instead of spinning on a stale deadline.
    expired,
};

pub const Exchange = struct {
    /// The engine's stream slot. Stable until `complete`, then reused.
    id: usize,
    stream_id: u31,
    request: Request,
    /// Per-stream storage for the request and any handler allocations.
    arena: Allocator,
    response: ?Response = null,
    /// A streaming engine only: the request body, one chunk at a time.
    /// `error.Pending` means no bytes are buffered yet; `error.EndOfStream`
    /// means END_STREAM arrived. A borrowed chunk stays valid until the next
    /// `next` call.
    request_body: ?stream.ReadStream,
    /// The peer's RST_STREAM code, once the stream was reset.
    reset_code: ?u32,
    /// A response head is queued, by `respond` or `beginResponse`.
    response_started: bool,
    /// The engine behind the response API. Every engine supplies one.
    sink: Sink,
    /// Set by `waitForProgress`; the engine parks the slot for this turn.
    parked: bool,
    /// Opaque application state for this exchange. The engine never reads or
    /// frees it. A streaming handler keeps its cursor here, because each turn
    /// gets a fresh `Exchange` value and locals do not survive a park.
    context: ?*anyopaque,
    /// Why the engine invoked the handler this turn.
    wake: WakeReason,
    /// The handler's absolute awake-clock deadline, or `.none`. On expiry the
    /// engine clears it and invokes again with `wake = .expired`.
    deadline: time.OptionalTimestamp,

    pub const Response = struct {
        options: ResponseOptions,
        body: []const u8,
    };

    pub const RespondError = error{
        AlreadyResponded,
        AlreadyEnded,
        ResponseNotStarted,
        ResponseEnded,
        InvalidResponse,
        WouldBlock,
        StreamClosed,
        ConnectionClosed,
        OutOfMemory,
    };

    /// Record the response. The engine sends the HEADERS and pumps `body` under
    /// flow control. A non-empty `trailers` list is sent as its own HEADERS
    /// block after the body, which is how HTTP/2 carries a gRPC status.
    ///
    /// The options are copied into the exchange arena, so a stack-built header
    /// or trailer list is safe: the engine sends them after `handle` returns.
    /// The body is not copied. It must stay valid until `complete` returns.
    ///
    /// In a streaming engine this is the buffered convenience on top of
    /// `beginResponse`, `write`, and `endResponse`: the engine queues the same
    /// frames from the stored slice.
    pub fn respond(
        self: *Exchange,
        options: ResponseOptions,
        body: []const u8,
    ) RespondError!void {
        if (self.response_started) return error.AlreadyResponded;
        // h1 owns Connection close on this option. h2 does not silently treat
        // it as a stream or connection shutdown.
        if (options.close) return error.InvalidResponse;

        _ = head.validateResponse(.{
            .status = options.status,
            .content_type = options.content_type,
            .content_length = body.len,
            .headers = options.headers,
        }) catch return error.InvalidResponse;
        _ = head.trailers(.{ .items = options.trailers }) catch return error.InvalidResponse;
        for (options.trailers) |field| {
            // RFC 9110 6.5.1: these fields do not belong in a trailer section.
            if (std.ascii.eqlIgnoreCase(field.name, "content-length")) {
                return error.InvalidResponse;
            }
        }
        // The head and trailers are sent from the engine's pump, after `handle`
        // has returned and its frame is gone. Copy them; the body stays
        // borrowed by design, since it is pumped under flow control.
        const owned = try common.copyResponseOptions(self.arena, options);
        self.response = .{ .options = owned, .body = body };
        self.response_started = true;
        try self.sink.vtable.buffered(self.sink.ptr, owned, body);
    }

    /// Queue the response head without END_STREAM, so DATA may follow across
    /// turns. Requires a streaming engine.
    pub fn beginResponse(self: *Exchange, options: ResponseOptions) RespondError!void {
        if (self.response_started) return error.AlreadyResponded;
        if (options.close) return error.InvalidResponse;
        _ = head.validateResponse(.{
            .status = options.status,
            .content_type = options.content_type,
            .content_length = null,
            .headers = options.headers,
        }) catch return error.InvalidResponse;
        for (options.trailers) |field| {
            if (std.ascii.eqlIgnoreCase(field.name, "content-length")) {
                return error.InvalidResponse;
            }
        }
        const owned = try common.copyResponseOptions(self.arena, options);
        try self.sink.vtable.begin(self.sink.ptr, owned);
        self.response_started = true;
    }

    /// Queue response body bytes. Returns the accepted prefix; zero means flow
    /// control or the output budget is closed, and the caller parks with
    /// `waitForProgress`. The slice is copied into the session queue, so it
    /// does not outlive the call.
    pub fn write(self: *Exchange, bytes: []const u8) Sink.SinkError!usize {
        return self.sink.vtable.write(self.sink.ptr, bytes);
    }

    /// Queue the end of the response, with an optional trailer section.
    pub fn endResponse(self: *Exchange, trailers: []const Header) RespondError!void {
        for (trailers) |field| {
            if (std.ascii.eqlIgnoreCase(field.name, "content-length")) {
                return error.InvalidResponse;
            }
        }
        _ = head.trailers(.{ .items = trailers }) catch return error.InvalidResponse;
        try self.sink.vtable.end(self.sink.ptr, trailers);
    }

    /// Queue RST_STREAM and stop the exchange. Legal at any point, including
    /// mid-body.
    pub fn resetStream(self: *Exchange, code: frame.ErrorCode) Sink.SinkError!void {
        return self.sink.vtable.reset(self.sink.ptr, code);
    }

    /// Arm an absolute awake-clock deadline, or clear it with `.none`. On expiry
    /// the engine invokes the handler again with `wake = .expired`.
    pub fn setDeadline(self: *Exchange, deadline: time.OptionalTimestamp) void {
        self.deadline = deadline;
    }

    /// End this turn without a response. The engine calls `handle` again when
    /// the request body has bytes, the request ends, or response output
    /// drains. Call it after `request_body.next` returns `error.Pending` or
    /// `write` returns 0.
    pub fn waitForProgress(self: *Exchange) void {
        self.parked = true;
    }
};
