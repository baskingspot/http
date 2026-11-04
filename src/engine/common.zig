//! API shapes shared by the HTTP/1 and HTTP/2 server engines.
//!
//! The protocol engines keep their own exchange types. This module shares the
//! handler vtable shape, the response options, and the body/arena config knobs.
//! It does not try to hide streams, framing, or connection ownership.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Header = @import("../header.zig").Header;
const Status = @import("../status.zig").Status;

/// The response fields the application controls.
// ast-grep-ignore: public-struct-field-default -- options bag; status defaults to 200
pub const ResponseOptions = struct {
    status: Status = .ok,
    content_type: ?[]const u8 = null,
    /// Extra regular fields. The engine adds framing and protocol fields.
    headers: []const Header = &.{},
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
        };

        pub fn noopComplete(_: *anyopaque, _: *Exchange) void {}
        pub fn noopReportError(_: *anyopaque, _: anyerror) void {}
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
