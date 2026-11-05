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
const head = @import("../head.zig");
const common = @import("../../engine/common.zig");

pub const ResponseOptions = common.ResponseOptions;

/// One complete request, copied into the exchange arena.
pub const Request = struct {
    head: head.RequestHead,
    /// The whole request body, up to `Config.body_bytes`.
    body: []const u8,
    /// The trailer section, empty when the request had none.
    trailers: Headers,
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
        // h1 owns Connection close on this option. h2 does not silently treat
        // it as a stream or connection shutdown.
        if (options.close) return error.InvalidResponse;

        _ = head.validateResponse(.{
            .status = options.status,
            .content_type = options.content_type,
            .content_length = body.len,
            .headers = options.headers,
        }) catch return error.InvalidResponse;
        self.response = .{ .options = options, .body = body };
    }
};

/// A type-erased HTTP/2 handler over this engine's exchange.
pub const Handler = common.Handler(Exchange);
