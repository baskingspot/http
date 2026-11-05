//! Types shared by the server engines.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Status = @import("../../status.zig").Status;
const h1 = @import("../root.zig");
const common = @import("../../engine/common.zig");

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
        return self.conn.respond(options, body);
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
    status: Status,
) !void {
    const context: PolicyContext = .{ .id = id, .status = status, .arena = arena };
    const replacement = handler.vtable.policy_response(handler.ptr, context) catch |err| {
        handler.vtable.report_error(handler.ptr, err);
        return conn.reviewRejection(.{ .options = .{ .status = status }, .body = "" });
    };
    return conn.reviewRejection(replacement);
}
