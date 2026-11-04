//! Types shared by the HTTP/2 server engines.
//!
//! The engine buffers one request and hands it to the handler as an
//! `Exchange`. The exchange arena owns the copied head, trailers, and request
//! body; it stays valid until `complete` returns. The response body is
//! borrowed, so it must stay valid until the engine has queued it.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Header = @import("../../header.zig").Header;
const Headers = @import("../../header.zig").Headers;
const Status = @import("../../status.zig").Status;
const head = @import("../head.zig");

/// One complete request, copied into the exchange arena.
pub const Request = struct {
    head: head.RequestHead,
    /// The whole request body, up to `Config.body_bytes`.
    body: []const u8,
    /// The trailer section, empty when the request had none.
    trailers: Headers,
};

/// The response fields the engine adds around a body.
// ast-grep-ignore: public-struct-field-default -- options bag; status defaults to 200
pub const ResponseOptions = struct {
    status: Status = .ok,
    content_type: ?[]const u8 = null,
    /// Extra regular fields. The engine adds `:status` and `content-length`.
    headers: []const Header = &.{},
};

pub const Exchange = struct {
    /// The engine's stream slot. Stable until `complete`, then reused.
    id: usize,
    stream_id: u31,
    request: Request,
    /// Per-stream storage for the request and any handler allocations.
    arena: Allocator,
    response: ?Response = null,

    pub const Response = struct {
        options: ResponseOptions,
        body: []const u8,
    };

    pub const RespondError = error{
        AlreadyResponded,
        InvalidResponse,
    };

    /// Record the response. The engine sends the HEADERS and pumps `body` under
    /// flow control. The body must stay valid until `complete` returns. The
    /// extra headers are borrowed for the same lifetime.
    pub fn respond(
        self: *Exchange,
        options: ResponseOptions,
        body: []const u8,
    ) RespondError!void {
        if (self.response != null) return error.AlreadyResponded;

        _ = head.validateResponse(.{
            .status = options.status,
            .content_type = options.content_type,
            .content_length = body.len,
            .headers = options.headers,
        }) catch return error.InvalidResponse;
        self.response = .{ .options = options, .body = body };
    }
};

/// A type-erased HTTP/2 handler. Build a vtable with `ptr` pointing at the
/// handler state; a stateless handler passes `ptr = undefined`.
pub const Handler = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Build the response with `exchange.respond`. The engine supplies a
        /// 500 if the handler returns without one.
        handle: *const fn (ptr: *anyopaque, exchange: *Exchange) anyerror!void,
        /// The exchange is finished: the response was queued, the stream was
        /// reset, or the connection ended. The arena is readable; the engine
        /// resets it afterward.
        complete: *const fn (ptr: *anyopaque, exchange: *Exchange) void,
        /// `handle` returned an error, or the engine could not serve the
        /// connection. The engine has already arranged a 500 or a reset.
        report_error: *const fn (ptr: *anyopaque, err: anyerror) void,
    };

    pub fn noopComplete(_: *anyopaque, _: *Exchange) void {}
    pub fn noopReportError(_: *anyopaque, _: anyerror) void {}
};
