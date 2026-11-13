//! A blocking TLS client with HTTP ALPN policy.
//!
//! `tls_nonblocking.SocketClient` owns the socket I/O, handshake, records,
//! trust store, and plaintext reader/writer. This wrapper keeps HTTP's policy:
//! one offered protocol, and that exact selection is required.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const mem = std.mem;
const tls = @import("tls");
const tls_nonblocking = @import("tls_nonblocking");
const http = @import("http");
const time = @import("stdx").time;
const client = http.client;
const Driver = http.h2.client.Driver;

const SocketClient = tls_nonblocking.SocketClient;

pub const Error = error{
    /// The handshake finished without the ALPN protocol this client requires.
    WrongAlpn,
};

pub const ReadError = SocketClient.ReadError;
pub const WriteError = SocketClient.WriteError;

// ast-grep-ignore: public-struct-field-default -- init sets every field
pub const Connection = struct {
    inner: SocketClient,
    required_alpn: []const u8,
    alpn_protocols: [1][]const u8,

    // ast-grep-ignore: public-struct-field-default -- options bag; alpn defaults to h2
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
        /// The one ALPN protocol to offer and require.
        alpn: []const u8 = "h2",
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
            .required_alpn = options.alpn,
            .alpn_protocols = .{options.alpn},
        };
        errdefer self.inner.deinit();
        try self.inner.init(allocator, io, socket, .{
            .ca_pem = options.ca_pem,
            .insecure_no_chain_anchor = options.insecure_no_chain_anchor,
            .host_name = options.host_name,
            .now_sec = options.now_sec,
            .alpn = &self.alpn_protocols,
            .deadline_ns = if (options.deadline.get()) |deadline| deadline.nanoseconds else null,
        });

        const selected = self.inner.selectedAlpn() orelse return error.WrongAlpn;
        if (!mem.eql(u8, selected, self.required_alpn)) return error.WrongAlpn;
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
    /// the previous expiry. Socket writes are not deadline-bounded.
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
