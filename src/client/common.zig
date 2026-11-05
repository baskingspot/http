//! The shared HTTP client contract.
//!
//! Protocol adapters provide a negotiated transport and implement the same
//! request, response-head, and streaming-body shapes. Response heads are
//! snapshots; body bytes are always copied to the caller.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const Header = @import("../header.zig").Header;
const Headers = @import("../header.zig").Headers;
const Status = @import("../status.zig").Status;

/// The application protocol selected by the transport.
pub const Protocol = enum { h1, h2 };

pub const Scheme = enum {
    http,
    https,

    pub fn token(self: Scheme) []const u8 {
        return switch (self) {
            .http => "http",
            .https => "https",
        };
    }
};

// ast-grep-ignore: public-struct-field-default -- request with optional body and headers
pub const Request = struct {
    /// The exact wire method token. Methods are case-sensitive and the
    /// registry is open.
    method_token: []const u8,
    scheme: Scheme,
    /// h1 sends this as Host; h2 sends it as `:authority`.
    authority: []const u8,
    /// The origin-form path and query. h2 sends it as `:path`.
    target: []const u8,
    /// Regular fields only, in wire order. Names are lowercase for h2.
    /// Never include Host or an h2 pseudo-field.
    headers: []const Header = &.{},
    /// Empty in the first streaming slice. Request-body streaming is later.
    body: []const u8 = "",
};

pub const ResponseHead = struct {
    protocol: Protocol,
    status: Status,
    /// Client-owned snapshot, valid until `Body.close` or the next request.
    headers: Headers,
};

pub const Body = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Copy response body bytes into `out`. Returns 0 at clean EOF.
        /// Protocol errors (reset, GOAWAY, framing) are returned as errors.
        read: *const fn (ptr: *anyopaque, out: []u8) anyerror!usize,
        /// Finish the response. Idempotent. Releases unread flow control and
        /// resets an incomplete stream where the protocol supports it.
        close: *const fn (ptr: *anyopaque) void,
    };

    pub fn read(self: Body, out: []u8) anyerror!usize {
        return self.vtable.read(self.ptr, out);
    }

    pub fn close(self: Body) void {
        self.vtable.close(self.ptr);
    }
};

pub const Response = struct {
    head: ResponseHead,
    body: Body,
};

// ast-grep-ignore: public-struct-field-default -- options bag; arena policy
pub const Config = struct {
    allocator: Allocator,
    /// Maximum snapshot bytes for response field names and values.
    max_header_bytes: usize = 16 * 1024,
    /// Maximum response field records.
    max_headers: usize = 128,
};

test "scheme tokens and body vtable" {
    try testing.expectEqualStrings("http", Scheme.http.token());
    try testing.expectEqualStrings("https", Scheme.https.token());
    try testing.expectEqual(@as(usize, 16 * 1024), (Config{
        .allocator = testing.allocator,
    }).max_header_bytes);
}
