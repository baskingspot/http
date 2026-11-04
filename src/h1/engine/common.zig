//! Types shared by the server engines.

const std = @import("std");
const Allocator = std.mem.Allocator;

const h1 = @import("../root.zig");

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

/// A type-erased HTTP handler. Build a vtable with `ptr` pointing at the
/// handler state; a stateless handler passes `ptr = undefined`.
pub const Handler = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Build the response. Must call `exchange.respond` before returning.
        handle: *const fn (ptr: *anyopaque, exchange: *Exchange) anyerror!void,
        /// The response is complete or the connection closed first. The
        /// exchange arena is still readable; the engine resets it afterward.
        complete: *const fn (ptr: *anyopaque, exchange: *Exchange) void,
        /// `handle` returned an error. The engine has already sent the 500.
        report_error: *const fn (ptr: *anyopaque, err: anyerror) void,
    };

    pub fn noopComplete(_: *anyopaque, _: *Exchange) void {}
    pub fn noopReportError(_: *anyopaque, _: anyerror) void {}
};
