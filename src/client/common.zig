//! The shared HTTP client contract.
//!
//! Protocol adapters provide a negotiated transport and implement the same
//! request, response-head, and streaming-body shapes. Response heads are
//! snapshots; body bytes are borrowed from the connection until the next
//! advancing operation.

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

/// A local failure, not a peer outcome. The enum is closed: a new local
/// failure adds a variant rather than reusing `protocol`.
pub const Local = enum {
    /// Our cancellation. The stream is unfinished; close or reset the stream
    /// and keep the connection.
    canceled,
    /// A local buffer or policy limit ended this response. Reset the stream;
    /// the connection survives and this request is done.
    capacity,
    /// Allocation failed. The connection is not usable; close it.
    out_of_memory,
    /// A local failure left a partial frame on the wire. The connection is not
    /// usable; close it. A blocking adapter must not produce this.
    unusable,
};

/// The terminal outcome of one blocking body read.
pub const BodyRead = union(enum) {
    /// A borrowed body slice. Never empty. Its lifetime is per connection, not
    /// per body: the next operation that advances the connection invalidates
    /// it. Holding it pins the h2 connection-level flow-control window, so a
    /// caller that keeps bytes across another read must copy them.
    data: []const u8,
    /// The body is complete.
    eof,
    /// The peer reset this stream. The code is the RFC 9113 RST_STREAM code;
    /// REFUSED_STREAM (0x08) is the only reset that guarantees no processing.
    reset: u32,
    /// The transport or stream ended before the body was complete. A GOAWAY
    /// boundary can make this retry-safe; see the connection's `goAway()`.
    truncated,
    /// The peer sent a malformed frame or an invalid response. The connection
    /// is unusable and must be closed.
    protocol,
    /// A local failure. See `Local` for whether the connection survives.
    local: Local,
};

/// A non-blocking body outcome. Blocking `Body` adapters never return
/// `would_block`; evented clients use this shape instead of overloading Body.
pub const BodyStep = union(enum) {
    data: []const u8,
    eof,
    reset: u32,
    truncated,
    protocol,
    local: Local,
    would_block,
};

/// The blocking-client body contract.
///
/// `read` may block, never returns `would_block`, never returns empty data, and
/// reports completion with `eof`. A step client gets `BodyStep`; the evented
/// engines deliver exchanges through their own pump. Holding four 16 KiB
/// slices exhausts the default 65,535-byte h2 connection window.
pub const Body = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Return the next body bytes or a terminal outcome. The borrowed slice
        /// is valid until any operation that advances the connection; a caller
        /// that holds it across another read must copy. Holding an h2 slice
        /// pins the connection window for every stream.
        read: *const fn (ptr: *anyopaque) BodyRead,
        /// Finish the response. Idempotent. Releases unread flow control and
        /// resets an incomplete stream where the protocol supports it.
        close: *const fn (ptr: *anyopaque) void,
    };

    pub fn read(self: Body) BodyRead {
        return self.vtable.read(self.ptr);
    }

    pub fn close(self: Body) void {
        self.vtable.close(self.ptr);
    }
};

pub const Response = struct {
    head: ResponseHead,
    body: Body,
};

/// A connection-level GOAWAY. Streams at or below `last_stream_id` remain
/// valid; streams above it were not processed.
pub const GoAway = struct {
    last_stream_id: u31,
    code: u32,
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
