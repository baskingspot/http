//! API shapes shared by the HTTP/1 and HTTP/2 server engines.
//!
//! The protocol engines keep their own exchange types. This module shares the
//! handler vtable shape, the response options, and the body/arena config knobs.
//! It does not try to hide streams, framing, or connection ownership.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Header = @import("../header.zig").Header;
const Status = @import("../status.zig").Status;

/// Why the connection machine selected a rejection. Statuses stay the same;
/// this is the additional information an application needs for its message.
pub const RejectReason = enum {
    malformed_head,
    conflicting_length,
    invalid_length,
    conflicting_framing,
    invalid_framing,
    chunked_unsupported,
    missing_host,
    invalid_host,
    too_many_fields,
    head_too_large,
    body_too_large,
    unsupported_version,
    unsupported_expectation,
    request_timeout,
    internal_error,
};

/// The response fields the application controls.
// ast-grep-ignore: public-struct-field-default -- options bag; status defaults to 200
pub const ResponseOptions = struct {
    status: Status = .ok,
    content_type: ?[]const u8 = null,
    /// For h1, close after this response and emit `Connection: close`.
    /// h2 `Exchange.respond` rejects this field; it has no stream-level
    /// Connection-close meaning.
    close: bool = false,
    /// Extra regular fields. The engine adds framing and protocol fields.
    headers: []const Header = &.{},
};

/// The context for a machine rejection. The head may not exist yet.
pub const PolicyContext = struct {
    /// The engine slot that rejected input.
    id: usize,
    /// The status chosen by the parser or connection machine.
    status: Status,
    /// The precise rejection category.
    reason: RejectReason,
    /// Storage for a replacement body. It lives until the response completes.
    arena: Allocator,
};

/// A replacement for the default status-and-empty-body rejection.
pub const PolicyResponse = struct {
    options: ResponseOptions,
    body: []const u8,
};

/// One type-erased handler over an engine's exchange type.
pub fn Handler(comptime Exchange: type) type {
    return struct {
        ptr: *anyopaque,
        vtable: *const VTable,

        pub const VTable = struct {
            /// Build the response. The engine supplies a 500 if the handler
            /// returns without one.
            handle: *const fn (ptr: *anyopaque, exchange: *Exchange) anyerror!void,
            /// The exchange is finished: the response was written, the stream
            /// was reset, or the connection ended. The arena is readable; the
            /// engine resets it afterward.
            complete: *const fn (ptr: *anyopaque, exchange: *Exchange) void,
            /// `handle` or the engine failed. The engine has already arranged
            /// its policy response or reset.
            report_error: *const fn (ptr: *anyopaque, err: anyerror) void,
            /// Review a parser or handler rejection. The body is allocated
            /// from `context.arena` or borrowed until the response completes.
            policy_response: *const fn (
                ptr: *anyopaque,
                context: PolicyContext,
            ) anyerror!PolicyResponse,
        };

        pub fn noopComplete(_: *anyopaque, _: *Exchange) void {}
        pub fn noopReportError(_: *anyopaque, _: anyerror) void {}

        /// Keep the machine's status and an empty body.
        pub fn defaultPolicyResponse(
            _: *anyopaque,
            context: PolicyContext,
        ) anyerror!PolicyResponse {
            return .{ .options = .{ .status = context.status }, .body = "" };
        }
    };
}

/// The two limits whose names mean the same thing in every engine.
// ast-grep-ignore: public-struct-field-default -- options bag; embedded in engine configs
pub const Config = struct {
    /// Largest buffered request body.
    body_bytes: usize = 64 * 1024,
    /// Retained per-exchange arena capacity after completion.
    arena_retain_bytes: usize = 16 * 1024,
};

pub fn resetArena(arena: *std.heap.ArenaAllocator, retain_bytes: usize) void {
    _ = arena.reset(.{ .retain_with_limit = retain_bytes });
}

/// The negotiated HTTP protocol a request arrived on.
pub const Protocol = enum { h1, h2 };

pub const stream = @import("stream.zig");
