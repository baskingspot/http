//! The shared HTTP client contract.
//!
//! Protocol adapters provide a negotiated transport and implement the same
//! request, response-head, and streaming-body shapes. Response heads are
//! snapshots; body bytes are borrowed from the connection until the next
//! advancing operation.
//!
//! A request body is either a static slice (`Request.body`) or a `BodyWriter`
//! the caller drives. The adapter writes each `BodyWriter.write` straight to
//! the connection, so DATA may follow a header block whose END_HEADERS is on
//! the wire, and the body does not have to exist up front. Nothing may
//! interleave a header block between HEADERS and its final CONTINUATION, so
//! every write appends whole frames, never a partial one.
//!
//! A streaming adapter (`h2.client.Client.begin`) returns the writer
//! after the request head is committed and reads the response head separately
//! with `response()`. The two sides of one stream are independent: the caller
//! may write body bytes, read a response chunk, and write again before either
//! side ends. A synchronous `write` accepts all the bytes it is given or fails;
//! a partial write is not a result. Request bytes are copied into the
//! connection queue during the call, so the slice does not outlive it.
//!
//! Trailers share the connection buffer with a borrowed body slice, so a
//! `trailers()` accessor must snapshot into the response arena when eof is
//! reported, not lazily on access.
//!
//! Connection failure and reuse are deliberately protocol-specific. h1's
//! `Body.close` drains an unfinished response into scratch and may leave the
//! connection `ConnectionDirty`; that state is recoverable only by reconnecting.
//! h2 resets the stream and keeps the connection unless it is
//! `ConnectionPoisoned`, which is terminal. A dual-protocol caller must branch
//! on those names and must not alias them.

const std = @import("std");
const Io = std.Io;
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
    /// Regular fields only, in wire order. Never include Host or an h2
    /// pseudo-field. A caller targeting both protocols must send lowercase
    /// names: h1 forwards them as-is, while h2 rejects uppercase as
    /// `InvalidHeader`.
    headers: []const Header = &.{},
    /// The whole request body, sent in one call. h1 sends it with
    /// Content-Length; h2 sends DATA inside the request stream. Empty is the
    /// common case. Use `Client.begin` and its `BodyWriter` when the body does
    /// not exist up front; `begin` rejects a non-empty slice here.
    body: []const u8 = "",
};

pub const ResponseHead = struct {
    protocol: Protocol,
    status: Status,
    /// Client-owned snapshot, valid until `Body.close` or the next request.
    headers: Headers,
};

/// A local failure, not a peer outcome. The enum is closed: a new local
/// failure adds a variant rather than reusing another.
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
    /// usable; close it. An Io-driven adapter must not produce this.
    unusable,
    /// A read deadline the caller set expired. The stream is unfinished, so
    /// the connection is not reusable.
    timed_out,
};

/// The request body of an in-flight request. The caller owns the bytes it
/// passes and the adapter copies them during the call.
///
/// `write` may block until flow control opens, and it never returns a short
/// count. `close` sends END_STREAM and is idempotent; the response body stays
/// readable after it. A write after `close` is `error.Closed`.
pub const BodyWriter = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        write: *const fn (ptr: *anyopaque, bytes: []const u8) BodyWriteError!void,
        close: *const fn (ptr: *anyopaque) void,
    };

    pub fn write(self: BodyWriter, bytes: []const u8) BodyWriteError!void {
        return self.vtable.write(self.ptr, bytes);
    }

    pub fn close(self: BodyWriter) void {
        self.vtable.close(self.ptr);
    }
};

/// Request-body failures. A reset stream is the peer's decision; the code is
/// on the client that produced the writer.
pub const BodyWriteError = error{
    /// The peer reset the stream mid-body. The connection survives.
    Reset,
    /// The connection ended before the body was sent. It is not reusable.
    Truncated,
    /// The peer or the adapter broke a protocol rule. The connection is not
    /// reusable.
    Protocol,
    /// The writer is already closed, or its request is no longer open.
    Closed,
    /// Allocation failed. The connection is not reusable.
    LocalOutOfMemory,
};

/// A successful body read. The slice is borrowed for the connection
/// operation and is never empty.
pub const BodyResult = struct {
    data: []const u8,
};

/// The evented body error set. An Io-driven body reports the same failures
/// as `error.ReadFailed` with the cause on `Body.outcome`.
pub const BodyError = error{
    EndOfStream,
    Truncated,
    Protocol,
    Reset,
    LocalCanceled,
    LocalCapacity,
    LocalOutOfMemory,
    LocalUnusable,
};

/// An evented body step. `WouldBlock` is an error, not a result variant.
pub const BodyStep = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        step: *const fn (ptr: *anyopaque) BodyStepError!BodyResult,
        resetCode: *const fn (ptr: *anyopaque) ?u32,
        localCause: *const fn (ptr: *anyopaque) ?Local,
        close: *const fn (ptr: *anyopaque) void,
    };

    pub fn step(self: BodyStep) BodyStepError!BodyResult {
        return self.vtable.step(self.ptr);
    }

    pub fn resetCode(self: BodyStep) ?u32 {
        return self.vtable.resetCode(self.ptr);
    }

    pub fn localCause(self: BodyStep) ?Local {
        return self.vtable.localCause(self.ptr);
    }

    pub fn close(self: BodyStep) void {
        self.vtable.close(self.ptr);
    }
};

pub const BodyStepError = BodyError || error{WouldBlock};

/// The client body contract for an Io-driven adapter.
///
/// The bytes are a `std.Io.Reader`, so a body goes anywhere a reader goes.
/// Framing is decoded beneath it, and a caller cannot observe whether the
/// response was delimited by Content-Length, by chunked framing, or by the
/// close of the connection.
///
/// `error.EndOfStream` is the only clean end. Every other read outcome is
/// `error.ReadFailed`, and `outcome` names the cause: a peer truncation, an h2
/// reset, a peer protocol fault, or a local failure. `Local.timed_out` is a
/// read deadline the caller set.
///
/// The reader has no internal buffer, so body bytes go straight from the
/// connection into the caller's writer. That rules out the `std.Io.Reader`
/// calls that require one — `peek`, `take`, and `takeArray` — and permits
/// everything that writes into a caller buffer: `stream`, `streamRemaining`,
/// `readVec`, `readSliceAll`, `allocRemaining`. Holding a borrowed slice pins
/// the connection the way an h2 DATA slice pins the window.
pub const Body = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    /// The body byte stream. Pass it to anything that takes a `*Io.Reader`.
    /// Every read after `close` is `error.EndOfStream`.
    reader: *Io.Reader,

    pub const VTable = struct {
        /// Why the last `error.ReadFailed` happened. Null before the first
        /// failure and after a clean end.
        outcome: *const fn (ptr: *anyopaque) ?Outcome,
        /// Finish the response. Idempotent. Releases unread flow control and
        /// resets an incomplete stream where the protocol supports it.
        close: *const fn (ptr: *anyopaque) void,
    };

    pub fn outcome(self: Body) ?Outcome {
        return self.vtable.outcome(self.ptr);
    }

    pub fn close(self: Body) void {
        self.vtable.close(self.ptr);
    }
};

/// Why a body read failed. `error.ReadFailed` carries no detail because
/// `Io.Reader.StreamError` has no room for one, so the body keeps it.
pub const Outcome = union(enum) {
    /// The peer stopped before the response ended. On h2, nothing above the
    /// connection's GOAWAY boundary was processed.
    truncated,
    /// The peer broke a framing or stream rule.
    protocol_error,
    /// The peer reset the stream. The connection survives on h2.
    reset: u32,
    /// Our own failure.
    local: Local,
};

/// Why a read on the caller's `*Io.Reader` failed.
///
/// `Io.Reader.StreamError` reports `error.ReadFailed` and nothing else, so an
/// adapter cannot recover the cause from the error. A caller whose reader has
/// a latch — `http_tls.client.Connection.readError` is the one in this repo —
/// supplies this, and the body reports the cause instead of guessing from the
/// error alone.
pub const ReadCause = struct {
    context: *const anyopaque,
    cause: *const fn (context: *const anyopaque) ?anyerror,

    pub fn get(self: ReadCause) ?anyerror {
        return self.cause(self.context);
    }
};

/// The local outcome for a latched reader cause. A cause this function does not
/// name leaves the connection unusable, which is what an unclassified local
/// failure means.
pub fn localFromCause(cause: anyerror) Outcome {
    return .{ .local = switch (cause) {
        error.TimedOut => .timed_out,
        error.Canceled => .canceled,
        error.OutOfMemory => .out_of_memory,
        else => .unusable,
    } };
}

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
    /// Why a read on the caller's reader failed, when the reader latches one.
    /// Null classifies a failure from the error alone.
    read_cause: ?ReadCause = null,
};

test "scheme tokens and body vtable" {
    try testing.expectEqualStrings("http", Scheme.http.token());
    try testing.expectEqualStrings("https", Scheme.https.token());
    try testing.expectEqual(@as(usize, 16 * 1024), (Config{
        .allocator = testing.allocator,
    }).max_header_bytes);
}
