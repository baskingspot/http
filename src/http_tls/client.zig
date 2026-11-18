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
const tls_std = @import("tls_std");
const anchors = @import("anchors.zig");
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

/// A cancellation hook for one connection. It runs on the task driving the
/// TLS state, never concurrently with it, and at least every 100 ms while a
/// read waits. Returning true ends the handshake, or the pending read, with
/// `error.Canceled`. `context` must outlive the connection, because the hook
/// stays installed for its lifetime.
pub const Cancel = struct {
    context: *anyopaque,
    /// True ends the handshake or the pending read.
    shouldCancel: *const fn (context: *anyopaque) bool,
};

/// The protocol an ALPN selection stands for, or null when it is not HTTP.
pub fn protocolFor(selected: []const u8) ?client.Protocol {
    if (mem.eql(u8, selected, "h2")) return .h2;
    if (mem.eql(u8, selected, "http/1.1")) return .h1;
    return null;
}

/// Resolve the HTTP protocol for a finished handshake. ALPN is optional
/// (RFC 7301 §3.1): a peer that selects nothing did not use the extension, so
/// fall back to HTTP/1.1 when it was offered. h2 over TLS requires ALPN
/// (RFC 7540 §3.3), and any other offer is not evidence the peer speaks it, so
/// those stay unresolved.
fn negotiatedProtocol(
    selected: ?[]const u8,
    offered: []const []const u8,
) ?client.Protocol {
    if (selected) |name| return protocolFor(name);
    for (offered) |name| {
        if (mem.eql(u8, name, "http/1.1")) return .h1;
    }
    return null;
}

// ast-grep-ignore: public-struct-field-default -- init sets every field
pub const Connection = struct {
    inner: SocketClient,
    /// The offered list, borrowed for the connection's lifetime.
    alpn_protocols: []const []const u8,

    // ast-grep-ignore: public-struct-field-default -- options bag; h2 is the offer
    pub const Options = struct {
        /// How to trust the peer: PEM the adapter parses and owns, a store the
        /// caller loaded and keeps, or nothing (`insecure_no_chain_anchor`
        /// must then be set). A borrowed store must outlive the connection and
        /// must not be mutated or deinitialized while it is borrowed.
        trust: SocketClient.Options.Trust = .none,
        /// Test/demo opt-out from chain verification. Never set in production.
        /// Hostname verification still runs. Ignored when `trust` is not
        /// `.none`.
        insecure_no_chain_anchor: bool = false,
        /// ASCII DNS name for SNI and the DNS-ID check. The caller owns the
        /// bytes and must keep them alive for the connection's lifetime.
        host_name: []const u8,
        /// Current time in seconds since the Unix epoch, for certificate
        /// validity.
        now_sec: i64,
        /// The protocols to offer, in preference order. A selection must be
        /// one of them, or `init` is `error.WrongAlpn`. A peer that selects
        /// nothing did not use the extension (RFC 7301 §3.1), which `init`
        /// accepts; the caller decides what protocol that means. The slice is
        /// borrowed for the connection's lifetime.
        alpn: []const []const u8 = &automatic_alpn,
        /// Absolute monotonic deadline for the handshake and subsequent reads.
        deadline: time.OptionalTimestamp = .none,
        /// Consulted between handshake steps, between application reads, and
        /// while a read waits, so a caller can abandon a black-holed handshake
        /// or stop a stream it is blocked on. `context` must outlive the
        /// connection.
        cancel: ?Cancel = null,
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
            .trust = options.trust,
            .insecure_no_chain_anchor = options.insecure_no_chain_anchor,
            .host_name = options.host_name,
            .now_sec = options.now_sec,
            .alpn = self.alpn_protocols,
            .deadline_ns = if (options.deadline.get()) |deadline| deadline.nanoseconds else null,
            .cancel = if (options.cancel) |cancel| .{
                .context = cancel.context,
                .shouldCancel = cancel.shouldCancel,
            } else null,
        });

        // ALPN is optional (RFC 7301 §3.1): a peer that does not use the
        // extension selects nothing. A selection that was not offered is still
        // a protocol failure.
        if (self.inner.selectedAlpn()) |selected| {
            for (self.alpn_protocols) |offered| {
                if (mem.eql(u8, offered, selected)) return;
            }
            return error.WrongAlpn;
        }
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
    /// How to trust the peer; see `Connection.Options.trust`.
    trust: SocketClient.Options.Trust = .none,
    /// Test/demo opt-out from chain verification. Hostname verification still
    /// runs. Ignored when `trust` is not `.none`.
    insecure_no_chain_anchor: bool = false,
    /// The protocols to offer, in preference order. The peer's selection
    /// picks the HTTP adapter. A peer that selects nothing did not use ALPN
    /// (RFC 7301 §3.1); if `http/1.1` was offered, the connector speaks it,
    /// because h2 over TLS requires ALPN (RFC 7540 §3.3). Any other offer with
    /// no selection is `error.WrongAlpn`.
    alpn: []const []const u8 = &automatic_alpn,
    /// Unix seconds for certificate validity. Null reads the real clock at each
    /// handshake, which is what a long-lived client wants.
    now_sec: ?i64 = null,
    /// TCP keepalive for the dialed socket; see `plain.Keepalive`.
    keepalive: ?plain.Keepalive = null,
};

pub const ConnectError = error{
    /// The URL is cleartext. This connector only speaks TLS.
    PlainUnsupported,
    /// The peer selected no protocol, or one that was not offered.
    WrongAlpn,
    /// A deadline was set on a connection that cannot bound a socket wait.
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

    const stream = try plain.connectStream(context, .{ .keepalive = self.config.keepalive });
    errdefer stream.close(context.io);

    const wrapped = try context.gpa.create(Wrapped);
    errdefer {
        wrapped.tls.deinit();
        context.gpa.destroy(wrapped);
    }
    // The hook lives in the connection, not on this stack: the transport keeps
    // its context pointer for the life of the connection.
    wrapped.* = .{
        .allocator = context.gpa,
        .io = context.io,
        .stream = stream,
        .tls = undefined,
        .protocol = undefined,
        .deadline = context.deadline,
        .cancel = .{ .progress = context.progress, .phase = .handshake },
    };
    const cancel: ?Cancel = if (context.progress != null)
        .{ .context = &wrapped.cancel, .shouldCancel = TransportCancel.shouldCancel }
    else
        null;
    // The handshake gets the connect budget; everything after it gets the
    // exchange deadline.
    try wrapped.tls.init(context.gpa, context.io, stream, .{
        .trust = self.config.trust,
        .insecure_no_chain_anchor = self.config.insecure_no_chain_anchor,
        .host_name = context.url.host,
        .now_sec = self.config.now_sec orelse realSeconds(),
        .alpn = self.config.alpn,
        .deadline = context.dialDeadline(),
        .cancel = cancel,
    });
    wrapped.tls.setDeadline(context.deadline);
    // Past the handshake, the same hook covers reads on the live connection.
    wrapped.cancel.phase = .transfer;

    wrapped.protocol = negotiatedProtocol(wrapped.tls.selectedAlpn(), self.config.alpn) orelse
        return error.WrongAlpn;
    return wrapped.handle();
}

/// Bridges the connector's phase-aware hook to the transport's: the handshake
/// reports `.handshake`, a live read reports `.transfer`, and the polarity
/// flips because `transport.Progress` returns true to keep going. It lives in
/// the connection because the transport holds the pointer for its lifetime.
const TransportCancel = struct {
    progress: ?transport.Progress = null,
    phase: transport.Phase = .handshake,

    fn shouldCancel(context: *anyopaque) bool {
        const self: *TransportCancel = @ptrCast(@alignCast(context));
        const progress = self.progress orelse return false;
        return !progress.run(self.phase);
    }
};

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
    /// The caller's hook, alive for the connection's life because the
    /// transport holds its context pointer.
    cancel: TransportCancel = .{},
    /// Plaintext staging for the request. `SocketClient`'s writer hands every
    /// write straight to a TLS record, so without this the h1 head crosses the
    /// wire as one record per field and a peer that reads per record sees a
    /// partial head. One buffer batches the head and each body chunk.
    out: client.BufferedWriter = .{},

    fn handle(self: *Wrapped) transport.Connection {
        self.out.init(self.tls.writer());
        return .{
            .reader = self.tls.reader(),
            .writer = self.out.writer(),
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
    .shutdown = wrappedShutdown,
    .setDeadline = wrappedSetDeadline,
    .readCause = wrappedReadCause,
    .writeCause = wrappedWriteCause,
    .setCancel = wrappedSetCancel,
};

fn wrappedSetCancel(ptr: *anyopaque, cancel: ?transport.Progress) void {
    const self: *Wrapped = @ptrCast(@alignCast(ptr));
    // The tls layer holds `&self.cancel` for the connection's life, so only
    // the payload changes. A connection dialed without a hook has no bridge;
    // the client refuses reuse in that case.
    self.cancel.progress = cancel;
}

fn ignoreError(_: anyerror) void {}

fn wrappedShutdown(ptr: *anyopaque) void {
    const self: *Wrapped = @ptrCast(@alignCast(ptr));
    self.stream.shutdown(self.io, .both) catch |err| ignoreError(err);
}

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

test "a peer without ALPN falls back to HTTP/1.1 when it was offered" {
    try testing.expectEqual(client.Protocol.h1, negotiatedProtocol(null, &automatic_alpn).?);
    try testing.expectEqual(client.Protocol.h1, negotiatedProtocol(null, &.{"http/1.1"}).?);
    try testing.expectEqual(@as(?client.Protocol, null), negotiatedProtocol(null, &.{"h2"}));
    try testing.expectEqual(
        @as(?client.Protocol, null),
        negotiatedProtocol(null, &[_][]const u8{}),
    );
    try testing.expectEqual(client.Protocol.h2, negotiatedProtocol("h2", &automatic_alpn).?);
    try testing.expectEqual(
        @as(?client.Protocol, null),
        negotiatedProtocol("acme/1", &automatic_alpn),
    );
}

/// The easiest client in the package: one type for `http` and `https`, with the
/// adapter picked from the ALPN selection.
///
/// ```zig
/// var client: http_tls.Client = undefined;
/// try client.init(allocator, io, .{ .ca_pem = ca_pem });
/// defer client.deinit();
///
/// var response = try client.get("https://10.96.0.1:443/apis/v1");
/// defer response.body.close();
/// ```
///
/// Initialize it with `create`, or in place; the connector is allocated, so the
/// struct may move after `init`.
// ast-grep-ignore: public-struct-field-default -- connoisseur state; init sets every field
pub const Client = struct {
    /// Allocated so the client can move after `init`; the core client holds a
    /// connector pointing here.
    tls: *Connector,
    inner: client.Client,
    allocator: Allocator,
    /// The platform store, when the caller did not supply anchors.
    bundle: anchors.Bundle = .empty,
    owns_bundle: bool = false,

    // ast-grep-ignore: public-struct-field-default -- options bag; cleartext h1 and h2-then-h1 ALPN
    pub const Options = struct {
        /// How to trust the peer. `.none` loads the platform store, unless
        /// `insecure_no_chain_anchor` is set. A `.bundle` you pass is borrowed
        /// for the client's lifetime and must not be mutated while it is
        /// borrowed.
        trust: SocketClient.Options.Trust = .none,
        /// Test/demo opt-out from chain verification. Hostname verification
        /// still runs. Ignored when `ca_pem` is set.
        insecure_no_chain_anchor: bool = false,
        /// Protocols offered on a TLS connection, in preference order.
        alpn: []const []const u8 = &automatic_alpn,
        /// Cleartext settings, used for `http` URLs.
        plain: plain.Config = .{},
        /// TCP keepalive for TLS sockets; see `plain.Keepalive`. Cleartext
        /// uses `Options.plain.keepalive`.
        keepalive: ?plain.Keepalive = null,
        /// Deadline for every exchange that does not set its own.
        deadline: time.OptionalTimestamp = .none,
        /// Dial budget for every exchange that does not set its own.
        connect_deadline: time.OptionalTimestamp = .none,
        max_header_bytes: usize = 16 * 1024,
        max_headers: usize = 128,
    };

    pub fn init(self: *Client, allocator: Allocator, io: Io, options: Options) !void {
        self.* = .{
            .tls = undefined,
            .inner = undefined,
            .allocator = allocator,
        };
        errdefer if (self.owns_bundle) self.bundle.deinit(allocator);

        const connector = try allocator.create(Connector);
        errdefer allocator.destroy(connector);
        self.tls = connector;

        // No anchors and no opt-out means the platform store, which is what a
        // caller expects from a client that just works.
        var trust = options.trust;
        if (options.trust == .none and !options.insecure_no_chain_anchor) {
            try tls_std.trust_store.loadSystem(
                &self.bundle,
                allocator,
                io,
                Io.Clock.real.now(io),
            );
            self.owns_bundle = true;
            trust = .{ .bundle = &self.bundle };
        }

        connector.* = .init(.{
            .trust = trust,
            .insecure_no_chain_anchor = options.insecure_no_chain_anchor,
            .alpn = options.alpn,
            .keepalive = options.keepalive,
        });
        try self.inner.init(allocator, io, .{
            .plain = options.plain,
            .tls = self.tls.handle(),
            .max_header_bytes = options.max_header_bytes,
            .max_headers = options.max_headers,
            .deadline = options.deadline,
            .connect_deadline = options.connect_deadline,
        });
    }

    /// Allocate a client and initialize it. Release it with `destroy`.
    pub fn create(allocator: Allocator, io: Io, options: Options) !*Client {
        const self = try allocator.create(Client);
        errdefer allocator.destroy(self);
        try self.init(allocator, io, options);
        return self;
    }

    /// Release a client made by `create`.
    pub fn destroy(self: *Client) void {
        const allocator = self.allocator;
        self.deinit();
        allocator.destroy(self);
    }

    pub fn deinit(self: *Client) void {
        self.inner.deinit();
        if (self.owns_bundle) self.bundle.deinit(self.allocator);
        self.allocator.destroy(self.tls);
        self.* = undefined;
    }

    /// One `GET` to an `http` or `https` URL.
    pub fn get(self: *Client, url_text: []const u8) !client.Response {
        return self.inner.get(url_text);
    }

    pub fn fetch(
        self: *Client,
        url_text: []const u8,
        options: client.RequestOptions,
    ) !client.Response {
        return self.inner.fetch(url_text, options);
    }

    pub fn send(
        self: *Client,
        url: client.Url,
        options: client.RequestOptions,
    ) !client.Response {
        return self.inner.send(url, options);
    }

    pub fn protocol(self: *const Client) ?client.Protocol {
        return self.inner.protocol();
    }

    pub fn readCause(self: *const Client) ?anyerror {
        return self.inner.readCause();
    }

    pub fn writeCause(self: *const Client) ?anyerror {
        return self.inner.writeCause();
    }
};
