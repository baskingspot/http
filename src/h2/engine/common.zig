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
        OutOfMemory,
    };

    /// Record the response. The engine sends the HEADERS and pumps `body` under
    /// flow control. A non-empty `trailers` list is sent as its own HEADERS
    /// block after the body, which is how HTTP/2 carries a gRPC status.
    ///
    /// The options are copied into the exchange arena, so a stack-built header
    /// or trailer list is safe: the engine sends them after `handle` returns.
    /// The body is not copied. It must stay valid until `complete` returns.
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
        _ = head.trailers(.{ .items = options.trailers }) catch return error.InvalidResponse;
        for (options.trailers) |field| {
            // RFC 9110 6.5.1: these fields do not belong in a trailer section.
            if (std.ascii.eqlIgnoreCase(field.name, "content-length")) {
                return error.InvalidResponse;
            }
        }
        // The head and trailers are sent from `pumpAll`, after `handle` has
        // returned and its frame is gone. Copy them; the body stays borrowed
        // by design, since it is pumped under flow control.
        const owned = try common.copyResponseOptions(self.arena, options);
        self.response = .{ .options = owned, .body = body };
    }
};

/// A type-erased HTTP/2 handler over this engine's exchange.
pub const Handler = common.Handler(Exchange);
