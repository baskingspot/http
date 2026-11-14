//! The dial seam for the client.
//!
//! A `Connector` turns a parsed URL into a byte transport: a reader, a writer,
//! the protocol the transport negotiated, and the one deadline both directions
//! honor. `http` ships a cleartext connector and never names a TLS type, so an
//! `https` peer needs a connector from `http_tls` or from any other module that
//! implements this vtable.
//!
//! The seam sits above the protocol adapters, not below them. `client.Client`
//! still takes the reader and writer and does the exchange; a connector only
//! provides them, which keeps dialing and HTTP framing independent.
//!
//! The handle is a type-erased pointer to the connector's own state. Initialize
//! the connector in its final location and keep it there while any connection
//! it made is alive.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const time = @import("stdx").time;

const common = @import("common.zig");
const Url = @import("../uri.zig").Url;

pub const Protocol = common.Protocol;

/// A step of a connection attempt, reported to `Progress`.
pub const Phase = enum {
    /// Turning the host into addresses.
    resolve,
    /// Reaching one address.
    connect,
    /// A transport handshake, such as TLS.
    handshake,
};

/// A caller hook between blocking steps. A connector calls it before each
/// blocking step, and a handshake or connect that can wait in slices calls it
/// between them.
pub const Progress = struct {
    context: *anyopaque,
    /// Return false to abandon the attempt. A connector that sees false stops
    /// and reports `error.Stopped`.
    step: *const fn (context: *anyopaque, phase: Phase) bool,

    pub fn run(self: Progress, phase: Phase) bool {
        return self.step(self.context, phase);
    }
};

// ast-grep-ignore: public-struct-field-default -- options bag; no deadline by default
pub const Context = struct {
    io: Io,
    gpa: Allocator,
    url: Url,
    /// One absolute monotonic deadline for the whole attempt and every later
    /// read and write on the connection. `.none` waits indefinitely.
    deadline: time.OptionalTimestamp = .none,
    progress: ?Progress = null,
};

pub const Connector = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Dial `context.url` and return the transport. The connection's
        /// storage belongs to the connector, and `Connection.deinit` releases
        /// it. The error set stays open because each transport has its own
        /// failures; a connector documents the names it raises.
        connect: *const fn (ptr: *anyopaque, context: Context) anyerror!Connection,
    };

    pub fn connect(self: Connector, context: Context) anyerror!Connection {
        return self.vtable.connect(self.ptr, context);
    }
};

/// A live byte transport. `reader` and `writer` point into the connector's
/// storage and stay valid until `deinit`.
pub const Connection = struct {
    reader: *Io.Reader,
    writer: *Io.Writer,
    /// The negotiated protocol. Cleartext connectors report prior knowledge;
    /// a TLS connector reports the ALPN selection.
    protocol: Protocol,
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Close the socket and release the connection. TLS state is released
        /// first.
        deinit: *const fn (ptr: *anyopaque) void,
        /// Set the absolute monotonic deadline for later reads and writes.
        /// A transport that cannot bound a wait reports
        /// `error.DeadlineUnsupported` rather than accepting a deadline it
        /// will ignore.
        setDeadline: *const fn (
            ptr: *anyopaque,
            deadline: time.OptionalTimestamp,
        ) error{DeadlineUnsupported}!void,
        /// Why the last read failed, for `client.Config.read_cause`. The
        /// reader surface has no room for a cause, so the transport keeps it.
        readCause: *const fn (ptr: *const anyopaque) ?anyerror,
        /// Why the last write failed.
        writeCause: *const fn (ptr: *const anyopaque) ?anyerror,
    };

    pub fn deinit(self: *Connection) void {
        self.vtable.deinit(self.ptr);
        self.* = undefined;
    }

    pub fn setDeadline(
        self: *Connection,
        deadline: time.OptionalTimestamp,
    ) error{DeadlineUnsupported}!void {
        return self.vtable.setDeadline(self.ptr, deadline);
    }

    pub fn readCause(self: *const Connection) ?anyerror {
        return self.vtable.readCause(self.ptr);
    }

    pub fn writeCause(self: *const Connection) ?anyerror {
        return self.vtable.writeCause(self.ptr);
    }

    /// Bind this transport to a response body, so a deadline expiry reads as
    /// `.local = .timed_out` instead of a peer truncation.
    pub fn cause(self: *const Connection) common.ReadCause {
        return .{ .context = self.ptr, .cause = self.vtable.readCause };
    }
};
