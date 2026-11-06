//! Types shared by the server engines.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Status = @import("../../status.zig").Status;
pub const Rejection = h1.ServerConn.Rejection;
const h1 = @import("../root.zig");
const common = @import("../../engine/common.zig");
const stream = @import("../../engine/stream.zig");

pub const ResponseOptions = common.ResponseOptions;
pub const PolicyContext = common.PolicyContext;
pub const PolicyResponse = common.PolicyResponse;

/// One request/response exchange handed to the application.
pub const Exchange = struct {
    /// The engine slot serving this exchange. Stable for the exchange; the
    /// slot is reused after `complete` returns.
    id: usize,
    conn: *h1.ServerConn,
    request: h1.ServerConn.Request,
    response_stream: ?stream.ResponseStream = null,
    response_options: ?h1.ServerConn.ResponseOptions = null,
    /// Engine-owned allocator for this exchange. It is valid from handler
    /// entry until `complete` returns. The engine resets it before the slot
    /// serves another request.
    arena: Allocator,

    /// The body may borrow `arena` or handler-owned memory. Either way, the
    /// bytes must stay valid until the response completes.
    pub fn respond(
        self: *Exchange,
        options: h1.ServerConn.ResponseOptions,
        body: []const u8,
    ) h1.ServerConn.RespondError!void {
        if (self.response_stream != null) return error.InvalidState;
        return self.conn.respond(options, body);
    }

    /// Register a pull-based response body. The engine writes the head and
    /// pulls chunks after `handle` returns. `content_length` controls framing.
    pub fn respondStream(
        self: *Exchange,
        options: h1.ServerConn.ResponseOptions,
        source: stream.ResponseStream,
    ) h1.ServerConn.RespondError!void {
        if (self.response_stream != null) return error.InvalidState;
        if (self.conn.sendSlices().head.len != 0) return error.InvalidState;
        self.response_stream = source;
        self.response_options = options;
    }
};

/// A type-erased HTTP handler over this engine's exchange.
pub const Handler = common.Handler(Exchange);

/// Run the application policy callback, then replace the queued rejection.
pub fn review(
    handler: Handler,
    id: usize,
    arena: Allocator,
    conn: *h1.ServerConn,
    rejection: Rejection,
) !void {
    const context: PolicyContext = .{
        .id = id,
        .status = rejection.status,
        .reason = rejection.reason,
        .arena = arena,
    };
    const replacement = handler.vtable.policy_response(handler.ptr, context) catch |err| {
        handler.vtable.report_error(handler.ptr, err);
        return conn.reviewRejection(.{ .options = .{ .status = context.status }, .body = "" });
    };
    return conn.reviewRejection(replacement);
}
