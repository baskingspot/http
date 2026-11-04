//! Types shared by the server engines.

const h1 = @import("../root.zig");

/// One request/response exchange handed to the application.
pub const Exchange = struct {
    conn: *h1.ServerConn,
    request: h1.ServerConn.Request,
    /// The per-connection response body scratch. A slice of this buffer stays
    /// valid until the response completes. `respond` may also borrow
    /// handler-owned memory that outlives the response; this scratch is a
    /// convenience, not a limit on the body size.
    response_body: []u8,

    pub fn respond(
        self: *Exchange,
        options: h1.ServerConn.ResponseOptions,
        body: []const u8,
    ) h1.ServerConn.RespondError!void {
        return self.conn.respond(options, body);
    }
};
