//! Types shared by the server engines.

const std = @import("std");
const Allocator = std.mem.Allocator;

const h1 = @import("../root.zig");

/// One request/response exchange handed to the application.
pub const Exchange = struct {
    /// The engine slot serving this exchange. Stable for the exchange; the
    /// slot is reused after `onExchangeComplete`.
    id: usize,
    conn: *h1.ServerConn,
    request: h1.ServerConn.Request,
    /// Engine-owned allocator for this exchange. It is valid from handler
    /// entry until `onExchangeComplete` returns. The engine resets it before
    /// the slot serves another request.
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
