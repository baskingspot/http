//! A TLS client over std.Io with HTTP ALPN policy, and its `client.transport`
//! connector.
//!
//! `tls_nonblocking.SocketClient` owns the socket I/O, handshake, records,
//! trust store, and plaintext reader/writer. This wrapper keeps HTTP's policy:
//! the offered protocol list and the selected protocol. `Connector` adds the
//! dial, so a caller can open an `https` URL the same way it opens an `http`
//! one.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const mem = std.mem;
const testing = std.testing;
const tls = @import("tls");
const tls_nonblocking = @import("tls_nonblocking");
const http = @import("http");
const time = @import("stdx").time;
const client = http.client;
const plain = http.client.plain;
const transport = http.client.transport;
const Driver = http.h2.client.Driver;

const SocketClient = tls_nonblocking.SocketClient;

pub const Error = error{
    /// The handshake finished without a protocol this connection requires.
    WrongAlpn,
};

pub const ReadError = SocketClient.ReadError;
pub const WriteError = SocketClient.WriteError;

/// The default offer: HTTP/2, then HTTP/1.1.
pub const automatic_alpn = [_][]const u8{ "h2", "http/1.1" };

/// The protocol an ALPN selection stands for, or null when it is not HTTP.
pub fn protocolFor(selected: []const u8) ?client.Protocol {
    if (mem.eql(u8, selected, "h2")) return .h2;
    if (mem.eql(u8, selected, "http/1.1")) return .h1;
    return null;
}

// ast-grep-ignore: public-struct-field-default -- init sets every field
pub const Connection = struct {
    inner: SocketClient,
    /// The offered list, borrowed for the connection's lifetime.
    alpn_protocols: []const []const u8,

    // ast-grep-ignore: public-struct-field-default -- options bag; h2 is the offer
    pub const Options = struct {
        /// PEM certificate blocks, as handed by a caller that already holds
        /// them. At least one anchor must load, or `error.NoTrustAnchors`.
        /// Null trusts nothing unless `insecure_no_chain_anchor` is set.
        ca_pem: ?[]const u8 = null,
        /// Test/demo opt-out from chain verification. Never set in production.
        /// Hostname verification still runs. Ignored when `ca_pem` is set.
        insecure_no_chain_anchor: bool = false,
        /// ASCII DNS name for SNI and the DNS-ID check. The caller owns the
        /// bytes and must keep them alive for the connection's lifetime.
        host_name: []const u8,
        /// Current time in seconds since the Unix epoch, for certificate
        /// validity.
        now_sec: i64,
        /// The protocols to offer, in preference order. The selection must be
        /// one of them, or `init` is `error.WrongAlpn`. The slice is borrowed
        /// for the connection's lifetime.
        alpn: []const []const u8 = &automatic_alpn,
        /// Absolute monotonic deadline for the handshake and subsequent reads.
        deadline: time.OptionalTimestamp = .none,
    };

    /// Initialize in the final location. The socket stays caller-owned on
    /// success and failure; TLS state and the parsed trust anchors are owned
    /// here and released by `deinit`.
    pub fn init(
        self: *Connection,
        allocator: Allocator,
        io: Io,
        socket: Io.net.Stream,
        options: Options,
    ) !void {
        self.* = .{
            .inner = undefined,
            .alpn_protocols = options.alpn,
        };
        errdefer self.inner.deinit();
        try self.inner.init(allocator, io, socket, .{
            .ca_pem = options.ca_pem,
            .insecure_no_chain_anchor = options.insecure_no_chain_anchor,
            .host_name = options.host_name,
            .now_sec = options.now_sec,
            .alpn = self.alpn_protocols,
            .deadline_ns = if (options.deadline.get()) |deadline| deadline.nanoseconds else null,
        });

        const selected = self.inner.selectedAlpn() orelse return error.WrongAlpn;
        for (self.alpn_protocols) |offered| {
            if (mem.eql(u8, offered, selected)) return;
        }
        return error.WrongAlpn;
    }

    /// Release TLS state and trust anchors. The socket is not closed.
    pub fn deinit(self: *Connection) void {
        self.inner.deinit();
        self.* = undefined;
    }

    pub fn reader(self: *Connection) *Io.Reader {
        return self.inner.reader();
    }

    pub fn writer(self: *Connection) *Io.Writer {
        return self.inner.writer();
    }

    pub fn selectedAlpn(self: *const Connection) ?[]const u8 {
        return self.inner.selectedAlpn();
    }

    pub fn peerAlert(self: *const Connection) ?tls.alert.Alert {
        return self.inner.peerAlert();
    }

    pub fn readError(self: *const Connection) ?ReadError {
        return self.inner.readError();
    }

    pub fn writeError(self: *const Connection) ?WriteError {
        return self.inner.writeError();
    }

    /// Set the absolute monotonic deadline for subsequent read waits and clear
    /// the previous expiry. Socket writes are not deadline-bounded here.
    pub fn setDeadline(self: *Connection, deadline: time.OptionalTimestamp) void {
        // The released TLS adapter retains an optional i96. Widening a compact
        // nonnegative timestamp is exact, and its public unit stays on stdx.
        self.inner.setDeadline(if (deadline.get()) |at| at.nanoseconds else null);
    }

    /// True only when the latest deadline failure was `TimedOut`.
    pub fn expired(self: *const Connection) bool {
        return self.inner.expired();
    }

    /// Bind the HTTP driver to this plaintext reader's deadline and cause.
    pub fn readDeadline(self: *Connection) Driver.ReadDeadline {
        return .{ .context = self, .set = setReadDeadline, .cause = latchedReadCause };
    }

    /// Bind a client body to this reader's latched failure cause. Without it a
    /// body read that the deadline ended is indistinguishable from a peer
    /// that closed, and `client.Body.outcome` reports a truncation.
    pub fn readCause(self: *Connection) client.ReadCause {
        return .{ .context = self, .cause = latchedReadCause };
    }

    fn setReadDeadline(context: *anyopaque, deadline: time.OptionalTimestamp) void {
        const self: *Connection = @ptrCast(@alignCast(context));
        self.setDeadline(deadline);
    }

    fn latchedReadCause(context: *const anyopaque) ?anyerror {
        const self: *const Connection = @ptrCast(@alignCast(context));
        return self.readError();
    }
};

/// How a connector reaches `https` peers.
// ast-grep-ignore: public-struct-field-default -- options bag; h2 then h1 by default
pub const Config = struct {
    /// PEM trust anchors. Null trusts nothing unless
    /// `insecure_no_chain_anchor` is set.
    ca_pem: ?[]const u8 = null,
    /// Test/demo opt-out from chain verification. Hostname verification still
    /// runs. Ignored when `ca_pem` is set.
    insecure_no_chain_anchor: bool = false,
    /// The protocols to offer, in preference order. The peer's choice decides
    /// the HTTP adapter. An empty list offers none, and the connection then
    /// needs a protocol the caller knows some other way.
    alpn: []const []const u8 = &automatic_alpn,
    /// Unix seconds for certificate validity. Null reads the real clock at each
    /// handshake, which is what a long-lived client wants.
    now_sec: ?i64 = null,
};

pub const ConnectError = error{
    /// The URL is cleartext. This connector only speaks TLS.
    PlainUnsupported,
    /// The peer selected no protocol, or one that was not offered.
    WrongAlpn,
    /// A deadline was set on a Zig version that cannot bound a socket wait.
    DeadlineUnsupported,
};

/// A dialing `https` connector. It uses the same cleartext dial as
/// `client.plain`, then adds the record layer and reads the protocol from the
/// ALPN selection.
pub const Connector = struct {
    config: Config,

    pub fn init(config: Config) Connector {
        return .{ .config = config };
    }

    /// The type-erased handle. The returned value borrows `self`, so the
    /// connector stays put while any connection it made is alive.
    pub fn handle(self: *Connector) transport.Connector {
        return .{ .ptr = self, .vtable = &connector_vtable };
    }
};

const connector_vtable: transport.Connector.VTable = .{ .connect = connectorConnect };

fn connectorConnect(ptr: *anyopaque, context: transport.Context) anyerror!transport.Connection {
    const self: *Connector = @ptrCast(@alignCast(ptr));
    if (context.url.scheme == .http) return error.PlainUnsupported;
    if (context.deadline.get() != null or context.connect_deadline.get() != null)
        if (!plain.deadline_supported) return error.DeadlineUnsupported;

    const stream = try plain.connectStream(context, .{});
    errdefer stream.close(context.io);

    const wrapped = try context.gpa.create(Wrapped);
    errdefer {
        wrapped.tls.deinit();
        context.gpa.destroy(wrapped);
    }
    wrapped.* = .{
        .allocator = context.gpa,
        .io = context.io,
        .stream = stream,
        .tls = undefined,
        .protocol = undefined,
        .deadline = context.deadline,
    };
    // The handshake gets the connect budget; everything after it gets the
    // exchange deadline.
    try wrapped.tls.init(context.gpa, context.io, stream, .{
        .ca_pem = self.config.ca_pem,
        .insecure_no_chain_anchor = self.config.insecure_no_chain_anchor,
        .host_name = context.url.host,
        .now_sec = self.config.now_sec orelse realSeconds(),
        .alpn = self.config.alpn,
        .deadline = context.dialDeadline(),
    });
    wrapped.tls.setDeadline(context.deadline);

    const selected = wrapped.tls.selectedAlpn() orelse return error.WrongAlpn;
    wrapped.protocol = protocolFor(selected) orelse return error.WrongAlpn;
    return wrapped.handle();
}

fn realSeconds() i64 {
    return @intCast(@divTrunc(time.now(.real).nanoseconds, std.time.ns_per_s));
}

/// The TLS connection plus the socket it borrowed, owned together so the
/// transport vtable has one pointer and one `deinit`.
const Wrapped = struct {
    allocator: Allocator,
    io: Io,
    stream: Io.net.Stream,
    tls: Connection,
    protocol: client.Protocol,
    deadline: time.OptionalTimestamp,

    fn handle(self: *Wrapped) transport.Connection {
        return .{
            .reader = self.tls.reader(),
            .writer = self.tls.writer(),
            .protocol = self.protocol,
            .ptr = self,
            .vtable = &wrapped_vtable,
        };
    }

    fn close(self: *Wrapped) void {
        self.tls.deinit();
        self.stream.close(self.io);
        self.* = undefined;
    }
};

const wrapped_vtable: transport.Connection.VTable = .{
    .deinit = wrappedDeinit,
    .setDeadline = wrappedSetDeadline,
    .readCause = wrappedReadCause,
    .writeCause = wrappedWriteCause,
};

fn wrappedDeinit(ptr: *anyopaque) void {
    const self: *Wrapped = @ptrCast(@alignCast(ptr));
    const allocator = self.allocator;
    self.close();
    allocator.destroy(self);
}

fn wrappedSetDeadline(
    ptr: *anyopaque,
    deadline: time.OptionalTimestamp,
) error{DeadlineUnsupported}!void {
    if (deadline.get() != null and !plain.deadline_supported)
        return error.DeadlineUnsupported;
    const self: *Wrapped = @ptrCast(@alignCast(ptr));
    self.deadline = deadline;
    self.tls.setDeadline(deadline);
}

fn wrappedReadCause(ptr: *const anyopaque) ?anyerror {
    const self: *const Wrapped = @ptrCast(@alignCast(ptr));
    return self.tls.readError();
}

fn wrappedWriteCause(ptr: *const anyopaque) ?anyerror {
    const self: *const Wrapped = @ptrCast(@alignCast(ptr));
    return self.tls.writeError();
}

test "ALPN selections map to the HTTP adapter" {
    try testing.expectEqual(client.Protocol.h2, protocolFor("h2").?);
    try testing.expectEqual(client.Protocol.h1, protocolFor("http/1.1").?);
    try testing.expectEqual(@as(?client.Protocol, null), protocolFor("acme/1"));
    try testing.expectEqual(@as(?client.Protocol, null), protocolFor(""));
}
