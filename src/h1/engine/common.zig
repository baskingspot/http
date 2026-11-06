//! Types shared by the server engines.

const std = @import("std");
const Io = std.Io;
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
// ast-grep-ignore: public-struct-field-default -- defer support is an engine capability
pub const Exchange = struct {
    /// The engine slot serving this exchange. Stable for the exchange; the
    /// slot is reused after `complete` returns.
    id: usize,
    conn: *h1.ServerConn,
    request: h1.ServerConn.Request,
    response_stream: ?stream.ResponseStream = null,
    response_options: ?h1.ServerConn.ResponseOptions = null,
    deferred: ?common.Deferred(Exchange) = null,
    deferred_deadline: ?Io.Timestamp = null,
    deferred_timeout: Io.Duration = .zero,
    deferred_on_timeout: ?PolicyResponse = null,
    waker: ?common.Waker = null,
    /// Set by the readiness engine. The blocking engine has no wake loop.
    defer_supported: bool = false,
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
        if (self.response_stream != null or self.deferred != null) return error.InvalidState;
        return self.conn.respond(options, body);
    }

    /// Register a pull-based response body. The engine writes the head and
    /// pulls chunks after `handle` returns. `content_length` controls framing.
    pub fn respondStream(
        self: *Exchange,
        options: h1.ServerConn.ResponseOptions,
        source: stream.ResponseStream,
    ) (h1.ServerConn.RespondError || Allocator.Error)!void {
        if (self.response_stream != null or self.deferred != null) return error.InvalidState;
        if (self.conn.sendSlices().head.len != 0) return error.InvalidState;
        self.response_options = try common.copyResponseOptions(self.arena, options);
        self.response_stream = source;
    }

    /// Park the exchange until external work completes. The handler returns
    /// without responding; the engine calls `callback` on its own thread after
    /// `wake`. The context must live until `complete`. `cancel` runs if the
    /// client disconnects or the request deadline expires before the response.
    /// Only readiness engines support this; the blocking engine returns
    /// `error.Unsupported`.
    pub fn deferResponse(
        self: *Exchange,
        context: *anyopaque,
        callback: *const fn (
            context: *anyopaque,
            exchange: *Exchange,
        ) anyerror!common.ResumeResult,
        cancel: *const fn (context: *anyopaque) void,
        defer_options: common.DeferOptions,
    ) (error{ Unsupported, InvalidState } || Allocator.Error)!void {
        if (!self.defer_supported) return error.Unsupported;
        if (self.response_stream != null or self.deferred != null) return error.InvalidState;
        if (self.conn.sendSlices().head.len != 0) return error.InvalidState;
        var copied = defer_options;
        if (copied.timeout.nanoseconds != 0) {
            copied.on_timeout.options = try common.copyResponseOptions(
                self.arena,
                copied.on_timeout.options,
            );
            copied.on_timeout.body = try self.arena.dupe(u8, copied.on_timeout.body);
        }
        self.deferred_on_timeout = copied.on_timeout;
        self.deferred = .{ .context = context, .callback = callback, .cancel = cancel };
        self.deferred_timeout = copied.timeout;
    }

    /// Copy this handle before returning from `handle` if a worker may outlive
    /// the exchange. Calling `wake` on a completed exchange reads a cleared
    /// field.
    pub fn wakeHandle(self: *const Exchange) ?common.Waker {
        return self.waker;
    }

    /// Wake the engine so it resumes a deferred exchange. Safe from another
    /// thread while the exchange is alive.
    pub fn wake(self: *Exchange) void {
        if (self.waker) |waker| waker.wake();
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
